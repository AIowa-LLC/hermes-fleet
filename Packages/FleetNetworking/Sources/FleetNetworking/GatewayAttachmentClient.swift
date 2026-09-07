import Foundation
import os
import FleetCore

/// R10-T1 — concrete `AttachmentStagingProviding` over the conversation
/// transport: composer attachments staged into the session workspace.
///
/// Wire ground truth (hermes-agent 0.21.0, verified at
/// `~/.hermes/hermes-agent/tui_gateway/methods_prompt.py` + `server.py`):
/// - `file.attach` — methods_prompt.py:1350-1395. Params
///   `{session_id, path?, data_url?, name?}`. The REMOTE-CLIENT form this
///   client always sends: `data_url` (a `data:<mime>;base64,<b64>` upload)
///   with `name`, and NO `path` — the path only exists on the client's disk
///   (`_stage_session_file_attachment` server.py:14506-14556 decodes and
///   writes into the session home's `attachments/` dir, which
///   `_desktop_attachment_dir` server.py:14445 anchors on the session
///   profile home so container bind-mounts resolve — #76577). Result
///   `{attached, name, path, ref_path, ref_text, uploaded}` — `ref_text` is
///   the ready-to-cite `@file:...` ref (`_attachment_ref_path`
///   server.py:14416-14426 relativizes against the session cwd; values with
///   whitespace/brackets get backtick-quoted by `_format_ref_value`
///   server.py:14394-14414).
/// - `image.attach_bytes` — methods_prompt.py:1163-1222. Params
///   `{session_id, content_base64 (or legacy `data` alias), filename?,
///   ext?}`. The decoder (`_decode_attach_base64` server.py:14298-14316)
///   accepts a `data:image/...;base64,` prefix — this client keeps it so the
///   mime is explicit. Result mirrors `image.attach` (:1120-1132):
///   `{attached, path, count, remainder, text, bytes, *_image_meta}` where
///   `_image_meta` (server.py:3140-3151) emits name/width/height/
///   token_estimate only when PIL can read the file.
/// - `pdf.attach` — methods_prompt.py:1224-1348. Params
///   `{session_id, content_base64, filename?}` (decoder pins
///   mime_prefix="application/pdf", :1263-1266; %PDF- magic enforced
///   :1272). Renders each page to a 150 DPI PNG via pdftoppm and queues the
///   pages as attached images (the vision pipeline accepts images, not
///   PDFs). Result (:1335-1347): `{attached, filename, pages_attached,
///   pages: [{path, page, *_image_meta}], count, text}`.
/// - `image.detach` — methods_prompt.py:1397-1412. Params
///   `{session_id, path}` → `{detached, count}`.
/// - Error codes: 4015 param missing, 4016 not-found / unsupported
///   extension, 4017 invalid base64, 4018 over cap (images 25 MB
///   server.py:14284 / PDFs 50 MB :14285), 4019 PDF page-range cap,
///   5027 write failed, 5028 pdf pipeline failure.
public struct GatewayAttachmentClient: AttachmentStagingProviding {
    public let gatewayID: GatewayID
    private let transport: GatewayWebSocketTransport

    private static let log = Logger(
        subsystem: "com.aiowa.hermesfleet", category: "gateway-attachments")

    public init(gatewayID: GatewayID, transport: GatewayWebSocketTransport) {
        self.gatewayID = gatewayID
        self.transport = transport
    }

    // MARK: - file.attach

    public func attachFile(sessionID: String, name: String, dataURL: String) async throws -> StagedFileAttachment {
        let result = try await request(
            method: "file.attach",
            params: .object([
                "session_id": .string(sessionID),
                // NO `path`: the remote-client form uploads bytes; a
                // client-local path would 5028 (file not found on gateway).
                "data_url": .string(dataURL),
                "name": .string(name),
            ]))
        guard let o = result.objectValue else {
            throw AttachmentStagingError.malformedResponse(detail: "file.attach result was not an object")
        }
        guard o["attached"]?.boolValue == true,
              let name = o["name"]?.stringValue,
              let refText = o["ref_text"]?.stringValue,
              let path = o["path"]?.stringValue else {
            throw AttachmentStagingError.malformedResponse(detail: "file.attach result missing attached/name/path/ref_text")
        }
        return StagedFileAttachment(
            name: name,
            path: path,
            refPath: o["ref_path"]?.stringValue ?? path,
            refText: refText,
            uploaded: o["uploaded"]?.boolValue ?? true)
    }

    // MARK: - image.attach_bytes

    public func attachImageBytes(sessionID: String, filename: String, dataURL: String) async throws -> StagedImageAttachment {
        let result = try await request(
            method: "image.attach_bytes",
            params: .object([
                "session_id": .string(sessionID),
                "content_base64": .string(dataURL),
                "filename": .string(filename),
            ]))
        guard let o = result.objectValue else {
            throw AttachmentStagingError.malformedResponse(detail: "image.attach_bytes result was not an object")
        }
        guard o["attached"]?.boolValue == true,
              let path = o["path"]?.stringValue,
              let count = o["count"]?.numberValue.map(Int.init) else {
            throw AttachmentStagingError.malformedResponse(detail: "image.attach_bytes result missing attached/path/count")
        }
        return StagedImageAttachment(
            path: path,
            name: o["name"]?.stringValue,
            count: count,
            byteCount: o["bytes"]?.numberValue.map(Int.init),
            width: o["width"]?.numberValue.map(Int.init),
            height: o["height"]?.numberValue.map(Int.init),
            tokenEstimate: o["token_estimate"]?.numberValue.map(Int.init))
    }

    // MARK: - pdf.attach

    public func attachPDF(sessionID: String, filename: String, dataURL: String) async throws -> StagedPDFAttachment {
        let result = try await request(
            method: "pdf.attach",
            params: .object([
                "session_id": .string(sessionID),
                "content_base64": .string(dataURL),
                "filename": .string(filename),
            ]))
        guard let o = result.objectValue else {
            throw AttachmentStagingError.malformedResponse(detail: "pdf.attach result was not an object")
        }
        guard o["attached"]?.boolValue == true,
              let filename = o["filename"]?.stringValue,
              let pagesAttached = o["pages_attached"]?.numberValue.map(Int.init),
              let count = o["count"]?.numberValue.map(Int.init) else {
            throw AttachmentStagingError.malformedResponse(detail: "pdf.attach result missing attached/filename/pages_attached/count")
        }
        let pages = (o["pages"]?.arrayValue ?? []).compactMap { row -> StagedPDFPage? in
            guard let page = row.objectValue,
                  let path = page["path"]?.stringValue,
                  let pageNumber = page["page"]?.numberValue.map(Int.init) else { return nil }
            return StagedPDFPage(
                path: path,
                pageNumber: pageNumber,
                name: page["name"]?.stringValue,
                width: page["width"]?.numberValue.map(Int.init),
                height: page["height"]?.numberValue.map(Int.init))
        }
        return StagedPDFAttachment(
            filename: filename,
            pagesAttached: pagesAttached,
            pages: pages,
            count: count)
    }

    // MARK: - image.detach

    public func detachImage(sessionID: String, path: String) async throws -> DetachedImageState {
        let result = try await request(
            method: "image.detach",
            params: .object([
                "session_id": .string(sessionID),
                "path": .string(path),
            ]))
        guard let o = result.objectValue,
              let count = o["count"]?.numberValue.map(Int.init) else {
            throw AttachmentStagingError.malformedResponse(detail: "image.detach result missing count")
        }
        return DetachedImageState(
            detached: o["detached"]?.boolValue ?? false,
            count: count)
    }

    // MARK: - transport

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        // Idempotent connect (P0-7) — the pane's transport starts cold; the
        // first attachment RPC opens it.
        if !isTransportReady {
            try await transport.connect()
        }
        do {
            return try await transport.request(method: method, params: params)
        } catch let error as JSONRPCError {
            throw Self.mapError(error)
        } catch let error as TransportError {
            throw Self.mapTransportError(error)
        }
    }

    private var isTransportReady: Bool {
        if case .connected = transport.state { return true }
        return false
    }

    static func mapError(_ error: JSONRPCError) -> AttachmentStagingError {
        switch error.code {
        case 4018, 4019:
            return .tooLarge(detail: error.message)
        case 4016:
            return .notFound(detail: error.message)
        default:
            return .rpcFailed("\(error.message) (\(error.code))")
        }
    }

    static func mapTransportError(_ error: TransportError) -> AttachmentStagingError {
        switch error {
        case .connectionClosed(let reason):
            return .rpcFailed("connection closed: \(reason.debugDescription)")
        case .requestTimeout:
            return .rpcFailed("request timed out")
        case .invalidState(let s):
            return .rpcFailed("invalid state: \(s)")
        default:
            return .rpcFailed(String(describing: error))
        }
    }
}
