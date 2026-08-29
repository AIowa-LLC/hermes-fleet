import Foundation

// MARK: - JSONValue
//
// A small Sendable, Codable JSON tree used for the free-form `params` /
// `result` / `error.data` members of JSON-RPC 2.0 frames. Keeping this as an
// explicit value type (instead of `[String: Any]`) makes the codec
// concurrency-safe under Swift 6 and lets tests assert on decoded payloads
// without JSONSerialization plumbing.

/// A Sendable JSON value tree.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Convenience: build from common Swift values (for tests and fixtures).
    public init(_ value: some Any) {
        self = JSONValue.from(value)
    }
}

// MARK: Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let n = try? container.decode(Double.self) { self = .number(n); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let arr = try? container.decode([JSONValue].self) { self = .array(arr); return }
        if let obj = try? container.decode([String: JSONValue].self) { self = .object(obj); return }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: conversion helpers

extension JSONValue {
    static func from(_ value: any Any) -> JSONValue {
        switch value {
        case let v as JSONValue: return v
        case let v as Bool: return .bool(v)
        case let v as Double: return .number(v)
        case let v as Int: return .number(Double(v))
        case let v as String: return .string(v)
        case let v as [any Any]: return .array(v.map(JSONValue.from))
        case let v as [String: any Any]: return .object(v.mapValues(JSONValue.from))
        case Optional<Any>.none: return .null
        default: return .null
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

// MARK: - JSON-RPC 2.0 message types

/// The `id` member of a request/response. JSON-RPC allows string or number.
public enum JSONRPCID: Sendable, Hashable, Codable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let n = try? container.decode(Int.self) { self = .number(n); return }
        if let d = try? container.decode(Double.self) { self = .number(Int(d)); return }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "JSON-RPC id must be a string or number")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        }
    }

    /// The wire value to echo back (string or number).
    public var wireValue: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return String(n)
        }
    }
}

/// A JSON-RPC 2.0 error object (`{code, message, data?}`).
public struct JSONRPCError: Sendable, Hashable, Codable, Error, LocalizedError {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? {
        message.isEmpty ? "JSON-RPC error \(code)" : "\(message) (\(code))"
    }

    public static let parseError = JSONRPCError(code: -32700, message: "parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "invalid request")
    public static let methodNotFound = JSONRPCError(code: -32601, message: "method not found")
    public static let invalidParams = JSONRPCError(code: -32602, message: "invalid params")
    public static let internalError = JSONRPCError(code: -32603, message: "internal error")
}

/// A client → server request frame.
public struct JSONRPCRequest: Sendable, Hashable, Codable {
    public var jsonrpc: String
    public var id: JSONRPCID
    public var method: String
    public var params: JSONValue?

    public init(id: JSONRPCID, method: String, params: JSONValue? = nil, jsonrpc: String = "2.0") {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A server → client success response frame.
public struct JSONRPCResponse: Sendable, Hashable, Codable {
    public var jsonrpc: String
    public var id: JSONRPCID
    public var result: JSONValue?

    public init(id: JSONRPCID, result: JSONValue?, jsonrpc: String = "2.0") {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
    }
}

/// A server → client error response frame.
public struct JSONRPCErrorResponse: Sendable, Hashable, Codable {
    public var jsonrpc: String
    public var id: JSONRPCID
    public var error: JSONRPCError

    public init(id: JSONRPCID, error: JSONRPCError, jsonrpc: String = "2.0") {
        self.jsonrpc = jsonrpc
        self.id = id
        self.error = error
    }
}

/// A server → client notification/event frame (`method != nil`, no `id`).
public struct JSONRPCEvent: Sendable, Hashable, Codable {
    public var jsonrpc: String
    public var method: String
    public var params: JSONValue?

    public init(method: String, params: JSONValue?, jsonrpc: String = "2.0") {
        self.jsonrpc = jsonrpc
        self.method = method
        self.params = params
    }
}

/// Any valid frame the codec can emit or consume.
public enum JSONRPCMessage: Sendable, Hashable {
    case request(JSONRPCRequest)
    case response(JSONRPCResponse)
    case error(JSONRPCErrorResponse)
    case event(JSONRPCEvent)
}

// MARK: - Frame codec

/// Encodes/decodes JSON-RPC 2.0 messages. A single encoded message is exactly
/// one line of JSON (no embedded newline), matching the gateway's
/// "newline-delimited JSON-RPC in both directions" wire protocol — which on a
/// WebSocket means each text frame is exactly one message.
public enum JSONRPCCodec {
    public static let jsonrpcVersion = "2.0"
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [] // compact, single line
        return e
    }()
    private static let decoder = JSONDecoder()

    public static func encode(_ message: JSONRPCMessage) throws -> String {
        let data: Data
        switch message {
        case .request(let m): data = try encoder.encode(m)
        case .response(let m): data = try encoder.encode(m)
        case .error(let m): data = try encoder.encode(m)
        case .event(let m): data = try encoder.encode(m)
        }
        guard let s = String(data: data, encoding: .utf8) else {
            throw CodecError.invalidUTF8
        }
        return s
    }

    public static func encodeData(_ message: JSONRPCMessage) throws -> Data {
        switch message {
        case .request(let m): return try encoder.encode(m)
        case .response(let m): return try encoder.encode(m)
        case .error(let m): return try encoder.encode(m)
        case .event(let m): return try encoder.encode(m)
        }
    }

    /// Encode a bare `JSONValue` back to JSON bytes (used to decode nested
    /// members like `error` without re-wrapping them in a message).
    public static func encode(_ value: JSONValue) throws -> Data {
        try encoder.encode(value)
    }

    /// Decode a single message from one line/WebSocket-text-frame.
    public static func decode(_ line: String) throws -> JSONRPCMessage {
        guard let data = line.data(using: .utf8) else { throw CodecError.invalidUTF8 }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> JSONRPCMessage {
        let value: JSONValue
        do {
            value = try decoder.decode(JSONValue.self, from: data)
        } catch {
            throw JSONRPCError.parseError
        }
        guard let obj = value.objectValue else { throw JSONRPCError.invalidRequest }
        guard obj["jsonrpc"]?.stringValue == jsonrpcVersion else {
            throw JSONRPCError.invalidRequest
        }
        let method = obj["method"]?.stringValue
        let hasID = obj["id"] != nil
        let hasError = obj["error"] != nil
        let hasResult = obj["result"] != nil

        if let method {
            // method + id → request; method without id → event/notification
            if hasID {
                let id = try decodeID(from: value)
                return .request(JSONRPCRequest(id: id, method: method, params: obj["params"]))
            }
            return .event(JSONRPCEvent(method: method, params: obj["params"]))
        }
        guard hasID else { throw JSONRPCError.invalidRequest }
        let id = try decodeID(from: value)
        if hasError {
            guard let e = obj["error"] else { throw JSONRPCError.invalidRequest }
            let err = try decoder.decode(JSONRPCError.self, from: try encode(e))
            return .error(JSONRPCErrorResponse(id: id, error: err))
        }
        if hasResult {
            return .response(JSONRPCResponse(id: id, result: obj["result"]))
        }
        throw JSONRPCError.invalidRequest
    }

    private static func decodeID(from value: JSONValue) throws -> JSONRPCID {
        if let s = value["id"]?.stringValue { return .string(s) }
        if let n = value["id"]?.numberValue { return .number(Int(n)) }
        throw JSONRPCError.invalidRequest
    }

    /// Split a byte stream into newline-delimited messages (the framing half
    /// of the "newline-delimited JSON-RPC" contract). Returns complete
    /// messages plus any trailing partial line for the next call.
    public static func decodeStream(_ data: Data, existingPartial: Data = Data())
        -> (messages: [JSONRPCMessage], partial: Data) {
        var buffer = existingPartial
        buffer.append(data)
        var messages: [JSONRPCMessage] = []
        var start = buffer.startIndex
        for i in buffer.indices where buffer[i] == 0x0A {
            let line = buffer[start..<i]
            start = buffer.index(after: i)
            if !line.isEmpty, let message = try? decode(line) { messages.append(message) }
        }
        let partial = Data(buffer[start...])
        return (messages, partial)
    }
}

public enum CodecError: Error, Equatable {
    case invalidUTF8
}
