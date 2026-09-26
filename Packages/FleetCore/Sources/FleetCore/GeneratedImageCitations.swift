import Foundation

/// Card D — generated-image citations: the wire contract that turns an
/// `image_generate` tool result into provenance-bound artifact material the
/// app can retrieve and render inline.
///
/// Wire ground truth (inspected, not assumed):
/// - `image_generate` returns JSON `{success, image, modality, …}`; the
///   current plugin providers download/save the image into
///   `$HERMES_HOME/cache/images/` and return that LOCAL path as `image`
///   (`agent/image_gen_provider.py` `save_b64_image` / `save_url_image`;
///   `plugins/image_gen/*` `success_response(image=…)`). The legacy FAL tool
///   returns the remote URL as `image` and adds `host_image` (the
///   gateway-deliverable local path) plus `agent_visible_image` (the same
///   file as seen by a non-local terminal backend) when the terminal is
///   remote — `tools/image_generation_tool.py`
///   `_postprocess_image_generate_result`.
/// - Desktop's display/dedupe contract is the reference behavior
///   (`apps/desktop/src/lib/generated-images.ts`): `DISPLAY_KEYS =
///   [host_image, image]` (host path wins), `ECHO_KEYS = [host_image, image,
///   agent_visible_image]`, and a payload with `success === false` is never a
///   result. The gateway's own media auto-append uses the same three fields
///   (`gateway/run.py` `_JSON_MEDIA_TOOL_PATH_FIELDS`).
/// - The live event carries the parsed result on `tool.complete`; the history
///   projection carries tool rows WITHOUT results
///   (`tui_gateway/session_history.py` `_history_to_messages`), so citations
///   are derived from live/replayed frames only — never invented from prose.

// MARK: - Citation

/// One generated-image result, parsed from the tool result payload.
///
/// `displaySource` is the preferred display material (`host_image`, else
/// `image`); `echoSources` is every path/URL variant the same result declares,
/// used to de-duplicate the model's restated copy of it in prose. A citation
/// is NOT a credential: retrieval still requires the owning gateway's
/// authenticated media API, and the display source may legitimately be a
/// remote URL (not retrievable through the gateway) — callers build an
/// `ArtifactReference` only when a gateway-local path actually validates.
public struct GeneratedImageCitation: Equatable, Hashable, Sendable, Codable {
    /// Display-key material, in key order (`host_image`, `image`) — the only
    /// fields the gateway itself serves (`agent_visible_image` is the
    /// agent-visible/container view of `host_image`, never host-served).
    /// `displaySource` is the first entry.
    public let retrievableSources: [String]
    /// Distinct path/URL variants (`host_image`, `image`, `agent_visible_image`,
    /// in that order, deduped) — the de-dupe set for prose echoes.
    public let echoSources: [String]

    public init(retrievableSources: [String], echoSources: [String]) {
        self.retrievableSources = retrievableSources
        self.echoSources = echoSources
    }

    /// Preferred display material (`host_image` else `image`).
    public var displaySource: String { retrievableSources.first ?? "" }

    /// Display label: the basename for path-like material, else the material
    /// itself is never rendered — callers render `ArtifactReference.displayName`
    /// for the retrievable path, or a generic label for URL-only results.
    public var displayName: String {
        ArtifactTransportRules.defaultName(forPath: displaySource)
    }

    /// Redacted printout (never the full host path beyond its basename).
    public var description: String {
        "GeneratedImageCitation(display: \(displayName), echoes: \(echoSources.count))"
    }

    public var debugDescription: String { description }
}

// MARK: - Rules

/// Pure result rules for `image_generate` (tool name, field keys, success
/// gate, prose-echo de-dupe). Deterministic and transport-free so the same
/// rules drive the transcript renderer, the artifact library and tests.
public enum GeneratedImageRules {

    /// The tool whose results cite retrievable artifacts.
    public static let toolName = "image_generate"

    /// Result fields that may name display material, in preference order
    /// (desktop `DISPLAY_KEYS`).
    public static let displayKeys = ["host_image", "image"]

    /// Result fields the model may restate in prose, in de-dupe order
    /// (desktop `ECHO_KEYS`).
    public static let echoKeys = ["host_image", "image", "agent_visible_image"]

    /// Parse a tool result payload into a citation.
    ///
    /// Returns nil unless:
    /// - the tool is exactly `image_generate`;
    /// - the payload is a JSON object;
    /// - `success` is absent or not `false` (desktop parity: only an explicit
    ///   failure is a failure — an error payload with `success: false` or a
    ///   non-object result never cites an artifact);
    /// - at least one display key carries a non-blank string.
    public static func citation(toolName: String, resultJSON: String?) -> GeneratedImageCitation? {
        guard toolName == Self.toolName else { return nil }
        guard let resultJSON, !resultJSON.isEmpty,
              let object = parseObject(resultJSON) else { return nil }
        if let success = object["success"] as? Bool, success == false { return nil }
        let retrievable = stringFields(object, keys: displayKeys)
        guard !retrievable.isEmpty else { return nil }
        return GeneratedImageCitation(
            retrievableSources: retrievable,
            echoSources: stringFields(object, keys: echoKeys)
        )
    }

    /// The gateway-local path for a citation on THIS gateway, or nil when the
    /// result names no retrievable material (e.g. a remote URL on a gateway
    /// whose terminal was local). Tries the display-key variants in key order
    /// (`host_image`, else `image`) and accepts only paths that pass the
    /// transport's fail-closed guards (absolute/home-relative, image
    /// extension, no traversal, not a URL). `agent_visible_image` is never a
    /// retrieval candidate: it names the agent-visible/container view, which
    /// the gateway's own filesystem does not serve.
    public static func retrievablePath(for citation: GeneratedImageCitation) -> String? {
        for candidate in citation.retrievableSources {
            if let validated = try? ArtifactTransportRules.validatedPath(candidate) {
                return validated
            }
        }
        return nil
    }

    /// The provenance-bound artifact reference for a citation, or nil when no
    /// gateway-local path validates. The reference carries gateway + session +
    /// profile so the transcript row and the artifact library can attribute
    /// the image without re-deriving it from prose.
    public static func artifactReference(
        for citation: GeneratedImageCitation,
        gatewayID: GatewayID,
        sessionID: String?,
        profile: String?
    ) -> ArtifactReference? {
        guard let path = retrievablePath(for: citation) else { return nil }
        return ArtifactReference(
            gatewayID: gatewayID,
            sessionID: sessionID,
            profile: profile,
            path: path
        )
    }

    // MARK: Prose-echo de-dupe (desktop parity)

    /// Strip a generated image out of prose so it only ever presents through
    /// the artifact slot (desktop `stripGeneratedImageEchoes` semantics):
    ///
    /// 1. Remove every Markdown image span `![alt](…)` and every
    ///    `[label](#media:…)` link — once a generation succeeded the model's
    ///    restated embedded media is a duplicate, whatever exact form it took.
    /// 2. Remove bare occurrences of each known source path/URL, bounded by
    ///    the same token boundaries Desktop uses (start/whitespace/`([{` on
    ///    the left; end/whitespace/`)]},.!?` on the right), tolerating the
    ///    `<…>` autolink wrapper.
    ///
    /// Surrounding prose is preserved. No sources ⇒ the text is returned
    /// unchanged (never a speculative strip).
    public static func strippingEchoes(in text: String, sources: [String]) -> String {
        guard !text.isEmpty, !sources.isEmpty else { return text }
        var stripped = removeMediaSpans(text)
        for source in unique(sources) {
            stripped = removingBareOccurrences(of: source, in: stripped)
        }
        return stripped
    }

    /// Convenience: strip the echoes declared by a set of citations from one
    /// prose string (streaming-safe — pure and deterministic).
    public static func strippingEchoes(in text: String, citations: [GeneratedImageCitation]) -> String {
        strippingEchoes(in: text, sources: unique(citations.flatMap(\.echoSources)))
    }

    /// Shared JSON-object parse for the generated-image rules family
    /// (FleetCore-internal: `ImageGenerationRules` reuses this exact parse so
    /// failure classification can never drift from citation parsing).
    static func jsonObject(_ json: String) -> [String: Any]? {
        parseObject(json)
    }

    // MARK: Internals

    /// Parse a JSON object without a JSON-RPC dependency (FleetCore has none).
    private static func parseObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Non-blank string fields, in key order, deduped.
    private static func stringFields(_ object: [String: Any], keys: [String]) -> [String] {
        unique(keys.compactMap { key -> String? in
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Drop Markdown image spans and `#media:` links (desktop parity).
    private static func removeMediaSpans(_ text: String) -> String {
        var result = text
        for pattern in ["!\\[[^\\]\\n]*\\]\\([^)\\n]*\\)", "\\[[^\\]\\n]*\\]\\(\\s*#media:[^)\\n]*\\)"] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result
    }

    /// Remove bare occurrences of one source, with Desktop's boundary rules.
    private static func removingBareOccurrences(of source: String, in text: String) -> String {
        guard !source.isEmpty else { return text }
        let escaped = NSRegularExpression.escapedPattern(for: source)
        // ICU classes: every literal bracket/brace must be escaped.
        let pattern = "(^|[\\s\\(\\[\\{])<?" + escaped + ">?(?=$|[\\s\\)\\]\\},.!?])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
    }
}
