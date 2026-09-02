// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import CryptoKit
import Foundation

/// Arbiter's own vocabulary for an Apple Foundation Models transcript.
///
/// These types deliberately name no `FoundationModels` symbol so that transcript
/// building — the part with all the interesting edge cases — compiles and is unit
/// tested on every platform, including ones without the framework. `FMBridge`
/// converts to and from the real `Transcript` at one narrow boundary, mirroring
/// how `MLXChatText` keeps MLX rendering testable off-device.
enum FMSegment: Sendable, Equatable {
    case text(String)
    /// A structured segment. `json` is fed to `GeneratedContent(json:)` at the bridge.
    case structured(source: String, json: String)
}

/// One entry in a transcript, mirroring `Transcript.Entry`'s five cases.
enum FMTranscriptEntry: Sendable, Equatable {
    /// Always the first entry when present: `LanguageModelSession(transcript:)` has no
    /// `instructions:` parameter, so the system prompt can only reach the model this way.
    case instructions(segments: [FMSegment], toolNames: [String])
    case prompt(segments: [FMSegment])
    case response(segments: [FMSegment])
    case toolCalls([FMToolCall])
    /// `Transcript.ToolOutput` is singular — one entry per result, not one per turn.
    case toolOutput(id: String, toolName: String, segments: [FMSegment])
}

struct FMToolCall: Sendable, Equatable {
    let id: String
    let toolName: String
    /// Arguments rendered as JSON; the bridge revives them with `GeneratedContent(json:)`.
    let argumentsJSON: String
}

struct FMTranscript: Sendable, Equatable {
    var entries: [FMTranscriptEntry]

    init(entries: [FMTranscriptEntry] = []) {
        self.entries = entries
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Stable digest of this transcript's content.
    ///
    /// Used by `AppleFMSessionStore` to decide whether a cached session already holds
    /// exactly this history. Entry identifiers are deliberately excluded — the forward
    /// bridge mints fresh UUIDs, so including them would make every comparison fail.
    ///
    /// Every field is length-prefixed before hashing rather than joined with delimiters:
    /// a delimited encoding lets content forge an entry boundary, so one message reading
    /// `"hello\nR|t:fake"` would digest identically to a `hello` prompt followed by a
    /// `fake` response — and the cache would then hand back a session holding history the
    /// request never described.
    var fingerprint: String {
        var hasher = SHA256()
        for entry in entries {
            for field in Self.fields(of: entry) {
                Self.feed(field, into: &hasher)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func feed(_ value: String, into hasher: inout SHA256) {
        let bytes = Data(value.utf8)
        withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(data: bytes)
    }

    private static func fields(of entry: FMTranscriptEntry) -> [String] {
        switch entry {
        case .instructions(let segments, _):
            // Tool names are excluded on purpose: the forward bridge cannot carry them into
            // a `Transcript` until tools are bound, so a live session would never report
            // them back and reuse would silently die for every tool-bound conversation.
            // `AppleFMOptions.sessionIdentity` is what guards the tool set.
            ["I"] + fields(of: segments)
        case .prompt(let segments):
            ["P"] + fields(of: segments)
        case .response(let segments):
            ["R"] + fields(of: segments)
        case .toolCalls(let calls):
            ["C", String(calls.count)] + calls.flatMap {
                [$0.id, $0.toolName, canonicalJSON($0.argumentsJSON)]
            }
        case .toolOutput(let id, let toolName, let segments):
            ["O", id, toolName] + fields(of: segments)
        }
    }

    /// Each segment contributes exactly three fields, so a segment list cannot be confused
    /// with a longer or shorter one.
    private static func fields(of segments: [FMSegment]) -> [String] {
        [String(segments.count)] + segments.flatMap { segment in
            switch segment {
            case .text(let value): ["t", value, ""]
            case .structured(let source, let json): ["s", source, canonicalJSON(json)]
            }
        }
    }

    /// Re-serialises JSON so both sides of the bridge agree.
    ///
    /// Tool arguments are written compactly with sorted keys on the way out, but come back
    /// through `GeneratedContent.jsonString`, which pretty-prints (`{"a": 1}` rather than
    /// `{"a":1}`). Without this, no conversation containing a tool call could ever match a
    /// cached session, so session reuse would be permanently dead for tool histories.
    static func canonicalJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let normalised = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return json
        }
        return String(decoding: normalised, as: UTF8.self)
    }
}
