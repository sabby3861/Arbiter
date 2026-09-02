// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import CryptoKit
import Foundation

/// A tool the runtime can execute on the model's behalf.
///
/// ``ToolDefinition`` is the wire contract a provider is told about; this adds the code
/// that runs when the model calls it, plus the two facts the loop needs to schedule it
/// safely: whether it may run alongside its siblings, and how long it is allowed to take.
///
/// ```swift
/// struct WeatherTool: ArbiterTool {
///     let definition = ToolDefinition(
///         name: "get_weather",
///         description: "Current conditions for a city",
///         inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]]
///     )
///
///     func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
///         guard case .object(let fields) = arguments,
///               case .string(let city)? = fields["city"] else { return .content("Unknown city") }
///         return .content(try await weatherService.summary(for: city))
///     }
/// }
/// ```
public protocol ArbiterTool: Sendable {
    /// What the model is told about this tool.
    var definition: ToolDefinition { get }

    /// Whether this tool may run concurrently with the other calls of the same turn.
    ///
    /// Defaults to `true`. Set `false` for a tool that mutates shared state or talks to a
    /// resource that serialises badly; the loop then runs it on its own, in the order the
    /// model asked for it, while concurrency-safe siblings still run in parallel.
    var isConcurrencySafe: Bool { get }

    /// How long one call may take before it is reported as a failure.
    ///
    /// `nil` means no limit beyond the caller's own cancellation. The overrunning call is
    /// cancelled, but cancellation in Swift is cooperative: a tool that never checks it
    /// still holds the round open until it returns, even though the model is told the call
    /// timed out. The deadline does not cover a wait for human approval.
    var timeout: Duration? { get }

    /// Run the tool.
    ///
    /// Throwing is reported back to the model as a tool result describing the failure, so
    /// it can recover or apologise, rather than aborting the run.
    func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput
}

public extension ArbiterTool {
    var isConcurrencySafe: Bool { true }
    var timeout: Duration? { nil }

    /// The name the model calls this tool by.
    var name: String { definition.name }
}

/// What a tool hands back.
public enum ToolOutput: Sendable, Equatable {
    /// The text the model reads as this call's result.
    case content(String)
    /// The call needs a human's consent before it happens.
    ///
    /// The loop suspends the call, publishes a ``ToolApprovalRequest`` on
    /// ``Arbiter/pendingApprovals`` and waits for ``Arbiter/approve(_:)`` or
    /// ``Arbiter/deny(_:reason:)``. On approval the tool is called a second time with
    /// ``ToolContext/isApproved`` set, and that call is expected to do the work and return
    /// `.content`. On denial the tool is not called again and the model is told it was
    /// refused.
    ///
    /// `payload` is what the human is shown — a rendering of what is about to happen.
    case requiresApproval(payload: String)
}

/// The circumstances of a single tool call.
public struct ToolContext: Sendable, Equatable {
    /// The provider's id for this call, used to correlate the result.
    public let callID: String
    /// The tool being called.
    public let toolName: String
    /// Stable hash of the call id and its arguments.
    ///
    /// The same call always produces the same key — including when a retry re-sends the
    /// turn that made it — so a tool reaching an external system can pass it along to
    /// deduplicate there. The loop uses it the same way, serving a repeat of one call from
    /// its first result. A *different* call to the same tool with the same arguments has a
    /// different id and so a different key, and really runs.
    public let idempotencyKey: String
    /// Which round of the loop this call belongs to, counting from 0.
    public let round: Int
    /// Whether a human has approved this call.
    ///
    /// `false` on the first call. A tool that needs consent returns
    /// ``ToolOutput/requiresApproval(payload:)`` then; when the human approves, the same
    /// call arrives again with this set to `true`.
    public let isApproved: Bool

    public init(
        callID: String,
        toolName: String,
        idempotencyKey: String,
        round: Int,
        isApproved: Bool
    ) {
        self.callID = callID
        self.toolName = toolName
        self.idempotencyKey = idempotencyKey
        self.round = round
        self.isApproved = isApproved
    }
}

/// A tool defined by a closure, for callers that do not need a type of their own.
///
/// ```swift
/// let clock = FunctionTool(
///     name: "now",
///     description: "The current time in ISO-8601",
///     inputSchema: ["type": "object", "properties": [:]]
/// ) { _, _ in Date.now.formatted(.iso8601) }
/// ```
public struct FunctionTool: ArbiterTool {
    public let definition: ToolDefinition
    public let isConcurrencySafe: Bool
    public let timeout: Duration?
    private let body: @Sendable (JSONValue, ToolContext) async throws -> ToolOutput

    /// A tool whose closure returns the text the model reads.
    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        isConcurrencySafe: Bool = true,
        timeout: Duration? = nil,
        execute: @escaping @Sendable (JSONValue, ToolContext) async throws -> String
    ) {
        self.init(
            name: name,
            description: description,
            inputSchema: inputSchema,
            isConcurrencySafe: isConcurrencySafe,
            timeout: timeout,
            call: { arguments, context in .content(try await execute(arguments, context)) }
        )
    }

    /// A tool whose closure returns a full ``ToolOutput``, so it can ask for approval.
    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        isConcurrencySafe: Bool = true,
        timeout: Duration? = nil,
        call: @escaping @Sendable (JSONValue, ToolContext) async throws -> ToolOutput
    ) {
        self.definition = ToolDefinition(
            name: name, description: description, inputSchema: inputSchema
        )
        self.isConcurrencySafe = isConcurrencySafe
        self.timeout = timeout
        self.body = call
    }

    public func call(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await body(arguments, context)
    }
}

enum ToolIdempotency {
    /// Hash of the call id and its arguments.
    ///
    /// The arguments are encoded with sorted keys so the same object hashes the same way
    /// between runs; `String(describing:)` of a dictionary would not.
    static func key(callID: String, arguments: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let argumentJSON = (try? encoder.encode(arguments)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        var hasher = SHA256()
        for field in [callID, argumentJSON] {
            let bytes = Data(field.utf8)
            withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
