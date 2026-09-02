// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
@testable import Arbiter

/// Covers the one piece of F7a that names FoundationModels types.
///
/// Guarded on the SDK and OS but not on Apple Intelligence: `Transcript` and
/// `GenerationError` are plain values with public initialisers, so none of this needs a
/// model to be installed or enabled.
@Suite("FMBridge")
struct FMBridgeTests {

    // MARK: - Error classification

    /// `FMErrorMapperTests` starts from an `FMErrorKind`; this is the step before it, where
    /// a mis-assigned case would otherwise go unnoticed.
    @Test func everyGenerationErrorCaseIsClassified() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "why")

        let expected: [(LanguageModelSession.GenerationError, FMErrorKind)] = [
            (.exceededContextWindowSize(context), .contextWindowExceeded("why")),
            (.assetsUnavailable(context), .assetsUnavailable("why")),
            (.guardrailViolation(context), .guardrailViolation("why")),
            (.unsupportedGuide(context), .unsupportedGuide("why")),
            (.unsupportedLanguageOrLocale(context), .unsupportedLanguage("why")),
            (.decodingFailure(context), .decodingFailure("why")),
            (.rateLimited(context), .rateLimited("why")),
            (.concurrentRequests(context), .concurrentRequests("why")),
            (
                .refusal(
                    LanguageModelSession.GenerationError.Refusal(transcriptEntries: []),
                    context
                ),
                .refusal("why")
            ),
        ]

        for (error, kind) in expected {
            #expect(FMBridge.errorKind(for: error) == kind)
        }
    }

    /// Cancellation must reach the caller as `CancellationError`, not as a provider failure.
    @Test func cancellationIsNotClassified() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        #expect(FMBridge.errorKind(for: CancellationError()) == nil)
    }

    /// Apple wraps an executor's throw in `ToolCallError`, cancellation included. Left
    /// wrapped, a cancelled tool would be reported as a bad request and the cancellation
    /// would never reach the caller.
    @Test func aCancelledToolIsReportedAsCancellationNotAsABadRequest() throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let tool = try FMBoundTool(binding: AppleFMToolBinding(
            definition: ToolDefinition(name: "slow", description: "", inputSchema: ["type": "object"]),
            execute: { _ in throw CancellationError() }
        ))

        let cancelled = LanguageModelSession.ToolCallError(tool: tool, underlyingError: CancellationError())
        #expect(FMBridge.errorKind(for: cancelled) == nil)

        struct Failure: Error {}
        let failed = LanguageModelSession.ToolCallError(tool: tool, underlyingError: Failure())
        guard case .toolCallFailed(let name, _)? = FMBridge.errorKind(for: failed) else {
            Issue.record("Expected toolCallFailed")
            return
        }
        #expect(name == "slow")
    }

    @Test func unrecognisedErrorsBecomeUnknown() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        struct Surprise: Error {}
        guard case .unknown = FMBridge.errorKind(for: Surprise()) else {
            Issue.record("Expected unknown")
            return
        }
    }

    // MARK: - Transcript round trip

    /// Session reuse compares a live session's transcript against a freshly built one, so
    /// the two directions must agree on a fingerprint. If they ever stop agreeing, reuse
    /// silently never happens.
    @Test func transcriptRoundTripPreservesTheFingerprint() throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let original = FMTranscript(entries: [
            .instructions(segments: [.text("Be terse.")], toolNames: []),
            .prompt(segments: [.text("Capital of France?")]),
            .response(segments: [.text("Paris.")]),
        ])

        let roundTripped = FMBridge.transcript(from: try FMBridge.transcript(from: original))

        #expect(roundTripped == original)
        #expect(roundTripped.fingerprint == original.fingerprint)
    }

    /// Tool arguments cross the boundary as JSON through `GeneratedContent`, which is free
    /// to reformat them — so the reverse direction has to canonicalise, or every
    /// conversation containing a tool call would lose session reuse permanently.
    @Test func transcriptRoundTripPreservesTheFingerprintWithToolTurns() throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let original = FMTranscript(entries: [
            .prompt(segments: [.text("Weather and time in Tokyo?")]),
            .toolCalls([
                FMToolCall(
                    id: "c1",
                    toolName: "get_weather",
                    argumentsJSON: #"{"city":"Tokyo","units":"c"}"#
                ),
            ]),
            .toolOutput(id: "c1", toolName: "get_weather", segments: [.text("18C")]),
            .response(segments: [.text("18C in Tokyo.")]),
        ])

        let roundTripped = FMBridge.transcript(from: try FMBridge.transcript(from: original))

        #expect(roundTripped.fingerprint == original.fingerprint)
    }

    @Test func malformedToolArgumentsAreRejectedNotCrashed() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let transcript = FMTranscript(entries: [
            .toolCalls([FMToolCall(id: "c1", toolName: "t", argumentsJSON: "not json")]),
        ])

        #expect(throws: ArbiterError.self) {
            _ = try FMBridge.transcript(from: transcript)
        }
    }

    // MARK: - Generation options

    @Test func generationOptionsCarryEveryField() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let options = FMBridge.generationOptions(from: FMGenerationSettings(
            sampling: .greedy, temperature: 0.4, maximumResponseTokens: 128
        ))
        #expect(options.temperature == 0.4)
        #expect(options.maximumResponseTokens == 128)
        #expect(options.sampling == .greedy)
    }

    @Test func samplingModesMapAcross() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let top = FMBridge.generationOptions(from: FMGenerationSettings(sampling: .randomTop(k: 5, seed: 7)))
        #expect(top.sampling == .random(top: 5, seed: 7))

        let threshold = FMBridge.generationOptions(
            from: FMGenerationSettings(sampling: .randomThreshold(probability: 0.9, seed: 7))
        )
        #expect(threshold.sampling == .random(probabilityThreshold: 0.9, seed: 7))

        // No sampling requested means Apple's default, not an imposed one.
        #expect(FMBridge.generationOptions(from: FMGenerationSettings()).sampling == nil)
    }

    // MARK: - Schemas

    /// The converter decides the shape; this is the step after it, where Apple validates
    /// what was built. A tree the converter accepts must be one `GenerationSchema` accepts.
    @Test func aConvertedSchemaBuildsAGenerationSchema() throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let tree = try FMSchemaConverter.tree(fromSchemaString: """
        {"type": "object",
         "$defs": {"Address": {"type": "object", "properties": {"city": {"type": "string"}}}},
         "properties": {
           "name": {"type": "string", "pattern": "^[A-Z]"},
           "age": {"type": "integer", "minimum": 0, "maximum": 120},
           "score": {"type": "number", "minimum": 0.5},
           "active": {"type": "boolean"},
           "size": {"type": "string", "enum": ["small", "large"]},
           "tags": {"type": "array", "items": {"type": "string"}, "minItems": 1},
           "home": {"$ref": "#/$defs/Address"}
         },
         "required": ["name", "age", "score", "active", "size", "tags", "home"]}
        """, rootName: "Response")

        let schema = try FMBridge.generationSchema(from: tree)
        // The debug description is Apple's own rendering of what it will constrain against.
        #expect(schema.debugDescription.contains("Response"))
    }

    /// Apple rejects two types sharing a name. The converter prevents this for the schemas
    /// it builds, so this asserts the fallback: the SDK's complaint reaches the caller as a
    /// bad request rather than as an opaque provider failure.
    @Test func aDuplicateTypeNameIsReportedAsAnInvalidRequest() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let duplicate = FMSchemaNode.object(name: "Thing", description: nil, properties: [])
        let tree = FMSchemaTree(root: duplicate, dependencies: [duplicate])

        #expect(throws: ArbiterError.self) {
            _ = try FMBridge.generationSchema(from: tree)
        }
    }

    @Test func aReferenceWithNoDependencyIsReportedAsAnInvalidRequest() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let tree = FMSchemaTree(
            root: .object(name: "Response", description: nil, properties: [
                FMSchemaNode.Property(
                    name: "home", description: nil, schema: .reference(name: "Missing"), isOptional: false
                ),
            ]),
            dependencies: []
        )

        #expect(throws: ArbiterError.self) {
            _ = try FMBridge.generationSchema(from: tree)
        }
    }

    // MARK: - Tools

    @Test func aBindingBecomesAToolTheModelCanBeGiven() throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let binding = AppleFMToolBinding(
            definition: ToolDefinition(
                name: "get_weather",
                description: "Current conditions",
                inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]]
            ),
            execute: { _ in "18C" }
        )

        let tool = try FMBoundTool(binding: binding)

        #expect(tool.name == "get_weather")
        #expect(tool.description == "Current conditions")
        // Stored rather than inherited: the `Arguments: Generable` default would advertise
        // `GeneratedContent`'s own schema and constrain nothing.
        #expect(tool.parameters.debugDescription.contains("city"))
    }

    /// Apple hands the executor whatever the constrained decoding produced; Arbiter's tools
    /// speak `JSONValue`, so the translation has to survive nesting and every scalar type.
    @Test func toolArgumentsReachTheExecutorAsJSONValue() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let received = ArgumentBox()
        let binding = AppleFMToolBinding(
            definition: ToolDefinition(
                name: "book",
                description: "Book a table",
                inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]]
            ),
            execute: { arguments in
                await received.set(arguments)
                return "done"
            }
        )
        let tool = try FMBoundTool(binding: binding)

        let output = try await tool.call(arguments: try GeneratedContent(
            json: #"{"city":"Tokyo","guests":2,"vip":true,"note":null,"tags":["a"]}"#
        ))

        #expect(output == "done")
        #expect(await received.value == .object([
            "city": .string("Tokyo"),
            "guests": .number(2),
            "vip": .bool(true),
            "note": .null,
            "tags": .array([.string("a")]),
        ]))
    }

    @Test func aToolWhoseInputSchemaIsUnusableIsRejected() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let binding = AppleFMToolBinding(
            definition: ToolDefinition(name: "broken", description: "", inputSchema: .string("nope")),
            execute: { _ in "" }
        )

        #expect(throws: ArbiterError.self) {
            _ = try FMBoundTool(binding: binding)
        }
    }

    /// A transcript-built session is only told about its tools through the instructions
    /// entry, so a bound tool that does not appear there is an executor the model will
    /// never call.
    @Test func boundToolsAreDeclaredInTheInstructionsEntry() throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        let tool = try FMBoundTool(binding: AppleFMToolBinding(
            definition: ToolDefinition(
                name: "get_weather", description: "Current conditions", inputSchema: ["type": "object"]
            ),
            execute: { _ in "18C" }
        ))
        let source = FMTranscript(entries: [
            .instructions(segments: [.text("Be terse.")], toolNames: ["get_weather"]),
        ])

        let transcript = try FMBridge.transcript(from: source, tools: [tool])

        guard case .instructions(let instructions)? = transcript.first else {
            Issue.record("Expected an instructions entry")
            return
        }
        #expect(instructions.toolDefinitions.map(\.name) == ["get_weather"])
    }

    @Test func contextSizeIsReadFromTheModelNotHardcoded() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        // Compared against the framework rather than a literal, so this keeps holding if
        // Apple ever ships a different context size.
        #expect(FMBridge.contextSize == SystemLanguageModel.default.contextSize)
        #expect(FMBridge.contextSize > 0)
    }
}

/// The claim session reuse rests on, checked against a real `LanguageModelSession` rather
/// than against the bridge's two directions in isolation.
@Suite("LiveFMSession on-device")
struct LiveFMSessionDeviceTests {

    /// A tool-bound session's instructions entry is built by Arbiter with empty segments and
    /// filled in with tool definitions. If the framework normalised that entry, the session
    /// would never fingerprint back to the transcript it was built from and every tool-bound
    /// conversation would silently rebuild its session on each turn.
    @Test func aToolBoundSessionReportsTheHistoryItWasBuiltWith() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        guard await AvailabilityChecker.isAppleFoundationAvailable() else { return }

        let binding = AppleFMToolBinding(
            definition: ToolDefinition(
                name: "get_weather",
                description: "Current conditions",
                inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]]
            ),
            execute: { _ in "18C" }
        )
        let transcript = FMTranscript(entries: [
            .instructions(segments: [], toolNames: ["get_weather"]),
            .prompt(segments: [.text("Weather in Tokyo?")]),
            .response(segments: [.text("18C.")]),
        ])

        let session = try LiveFMSession(
            transcript: transcript, options: AppleFMOptions(tools: [binding])
        )

        #expect(session.transcriptFingerprint == transcript.fingerprint)
    }

    @Test func aSessionWithASystemPromptReportsTheHistoryItWasBuiltWith() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        guard await AvailabilityChecker.isAppleFoundationAvailable() else { return }

        let transcript = FMTranscript(entries: [
            .instructions(segments: [.text("Be terse.")], toolNames: []),
            .prompt(segments: [.text("Capital of France?")]),
            .response(segments: [.text("Paris.")]),
        ])

        let session = try LiveFMSession(transcript: transcript, options: AppleFMOptions())

        #expect(session.transcriptFingerprint == transcript.fingerprint)
    }
}

/// Collects what a tool executor was handed, across the concurrency boundary Apple calls it on.
private actor ArgumentBox {
    private(set) var value: JSONValue?

    func set(_ value: JSONValue) {
        self.value = value
    }
}

#endif
