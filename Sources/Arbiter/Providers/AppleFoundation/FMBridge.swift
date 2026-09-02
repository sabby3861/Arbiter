// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// The single boundary where Arbiter's transcript vocabulary meets Apple's.
///
/// Everything either side of this file is testable without the framework; this file is
/// deliberately thin, mechanical and free of decisions, so what cannot be tested off-device
/// is also the part with nothing to get wrong.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum FMBridge {
    /// The model's context window. `contextSize` is back-deployed to OS 26.0, so this is
    /// always the live value rather than a hardcoded 4096.
    static var contextSize: Int {
        SystemLanguageModel.default.contextSize
    }

    // MARK: - Arbiter -> FoundationModels

    /// - Parameter tools: the tools this session will be built with. Their definitions are
    ///   attached to the leading `instructions` entry, because that is where the framework
    ///   itself puts them when it builds a transcript from `LanguageModelSession(tools:)` —
    ///   a transcript-built session with no definitions in its instructions would register
    ///   executors the model was never told about.
    static func transcript(from source: FMTranscript, tools: [any Tool] = []) throws -> Transcript {
        let definitions = tools.map { Transcript.ToolDefinition(tool: $0) }
        return Transcript(entries: try source.entries.map { try entry(from: $0, toolDefinitions: definitions) })
    }

    private static func entry(
        from source: FMTranscriptEntry,
        toolDefinitions: [Transcript.ToolDefinition]
    ) throws -> Transcript.Entry {
        switch source {
        case .instructions(let segments, _):
            // The entry's own `toolNames` are Arbiter's record of which tools this history
            // was produced with; what the session needs is the full definition, which only
            // the bound tools carry.
            return .instructions(Transcript.Instructions(
                segments: try segments.map(segment(from:)),
                toolDefinitions: toolDefinitions
            ))

        case .prompt(let segments):
            return .prompt(Transcript.Prompt(segments: try segments.map(segment(from:))))

        case .response(let segments):
            return .response(Transcript.Response(
                assetIDs: [],
                segments: try segments.map(segment(from:))
            ))

        case .toolCalls(let calls):
            return .toolCalls(Transcript.ToolCalls(try calls.map { call in
                Transcript.ToolCall(
                    id: call.id,
                    toolName: call.toolName,
                    arguments: try generatedContent(json: call.argumentsJSON)
                )
            }))

        case .toolOutput(let id, let toolName, let segments):
            return .toolOutput(Transcript.ToolOutput(
                id: id,
                toolName: toolName,
                segments: try segments.map(segment(from:))
            ))
        }
    }

    private static func segment(from source: FMSegment) throws -> Transcript.Segment {
        switch source {
        case .text(let text):
            return .text(Transcript.TextSegment(content: text))
        case .structured(let source, let json):
            return .structure(Transcript.StructuredSegment(
                source: source,
                content: try generatedContent(json: json)
            ))
        }
    }

    private static func generatedContent(json: String) throws -> GeneratedContent {
        do {
            return try GeneratedContent(json: json)
        } catch {
            throw ArbiterError.invalidRequest(
                reason: "Could not revive tool arguments from JSON: \(error.localizedDescription)"
            )
        }
    }

    static func generationOptions(from settings: FMGenerationSettings) -> GenerationOptions {
        GenerationOptions(
            sampling: settings.sampling.map(samplingMode(from:)),
            temperature: settings.temperature,
            maximumResponseTokens: settings.maximumResponseTokens
        )
    }

    private static func samplingMode(from source: AppleFMSampling) -> GenerationOptions.SamplingMode {
        switch source {
        case .greedy:
            .greedy
        case .randomTop(let k, let seed):
            .random(top: k, seed: seed)
        case .randomThreshold(let probability, let seed):
            .random(probabilityThreshold: probability, seed: seed)
        }
    }

    /// Builds Apple's schema from the tree the pure converter produced.
    ///
    /// Every decision was made upstream; what remains is the construction Apple validates —
    /// duplicate type names and undefined references — which is reported as a bad request,
    /// since that is what it is.
    static func generationSchema(from tree: FMSchemaTree) throws -> GenerationSchema {
        do {
            return try GenerationSchema(
                root: dynamicSchema(from: tree.root),
                dependencies: tree.dependencies.map(dynamicSchema(from:))
            )
        } catch let error as GenerationSchema.SchemaError {
            throw ArbiterError.invalidRequest(
                reason: "Apple Foundation Models rejected the schema: \(error.localizedDescription)"
            )
        }
    }

    private static func dynamicSchema(from node: FMSchemaNode) -> DynamicGenerationSchema {
        switch node {
        case .object(let name, let description, let properties):
            return DynamicGenerationSchema(
                name: name,
                description: description,
                properties: properties.map {
                    DynamicGenerationSchema.Property(
                        name: $0.name,
                        description: $0.description,
                        schema: dynamicSchema(from: $0.schema),
                        isOptional: $0.isOptional
                    )
                }
            )

        case .stringEnum(let name, let description, let choices):
            return DynamicGenerationSchema(name: name, description: description, anyOf: choices)

        case .anyOf(let name, let description, let choices):
            return DynamicGenerationSchema(
                name: name, description: description, anyOf: choices.map(dynamicSchema(from:))
            )

        case .array(let item, let minimum, let maximum):
            return DynamicGenerationSchema(
                arrayOf: dynamicSchema(from: item),
                minimumElements: minimum,
                maximumElements: maximum
            )

        case .reference(let name):
            return DynamicGenerationSchema(referenceTo: name)

        case .string(let constant, let pattern):
            var guides: [GenerationGuide<String>] = []
            if let constant {
                guides.append(.constant(constant))
            } else if let pattern, let regex = try? Regex(pattern) {
                // The converter already dropped patterns that will not compile; this second
                // attempt is what makes the failure impossible rather than merely unlikely.
                guides.append(.pattern(regex))
            }
            return DynamicGenerationSchema(type: String.self, guides: guides)

        case .integer(let minimum, let maximum):
            return DynamicGenerationSchema(type: Int.self, guides: bounds(minimum, maximum))

        case .number(let minimum, let maximum):
            return DynamicGenerationSchema(type: Double.self, guides: bounds(minimum, maximum))

        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        }
    }

    /// A closed range needs both ends, so a half-open bound stays a single guide. An
    /// inverted range is treated as a lower bound only: `ClosedRange` traps when its bounds
    /// cross, and trapping on a caller's bad schema is never the right answer.
    ///
    /// Written twice because `GenerationGuide`'s numeric statics are declared per concrete
    /// type — there is no protocol tying them together to be generic over.
    private static func bounds(_ minimum: Int?, _ maximum: Int?) -> [GenerationGuide<Int>] {
        switch (minimum, maximum) {
        case (let low?, let high?) where low <= high: [.range(low...high)]
        case (let low?, _): [.minimum(low)]
        case (nil, let high?): [.maximum(high)]
        case (nil, nil): []
        }
    }

    private static func bounds(_ minimum: Double?, _ maximum: Double?) -> [GenerationGuide<Double>] {
        switch (minimum, maximum) {
        case (let low?, let high?) where low <= high: [.range(low...high)]
        case (let low?, _): [.minimum(low)]
        case (nil, let high?): [.maximum(high)]
        case (nil, nil): []
        }
    }

    static func model(for options: AppleFMOptions) throws -> SystemLanguageModel {
        let guardrails: SystemLanguageModel.Guardrails = switch options.guardrails {
        case .default: .default
        case .permissiveContentTransformations: .permissiveContentTransformations
        }

        guard let adapterSource = options.adapter else {
            let useCase: SystemLanguageModel.UseCase = switch options.useCase {
            case .general: .general
            case .contentTagging: .contentTagging
            }
            return SystemLanguageModel(useCase: useCase, guardrails: guardrails)
        }

        do {
            let adapter = switch adapterSource {
            case .name(let name): try SystemLanguageModel.Adapter(name: name)
            case .fileURL(let url): try SystemLanguageModel.Adapter(fileURL: url)
            }
            return SystemLanguageModel(adapter: adapter, guardrails: guardrails)
        } catch {
            // An adapter that will not load is a provider-level unavailability, not a bad
            // request: the same request succeeds against the stock model.
            throw ArbiterError.providerUnavailable(
                .appleFoundation,
                reason: "Could not load adapter: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - FoundationModels -> Arbiter

    /// Reads a live session's transcript back into Arbiter's vocabulary.
    ///
    /// Used only for fingerprinting, so entry identifiers and prompt options are dropped —
    /// including them would make every comparison fail, since the forward direction mints
    /// fresh identifiers.
    static func transcript(from source: Transcript) -> FMTranscript {
        FMTranscript(entries: source.map(entry(from:)))
    }

    private static func entry(from source: Transcript.Entry) -> FMTranscriptEntry {
        switch source {
        case .instructions(let instructions):
            .instructions(
                segments: instructions.segments.map(segment(from:)),
                toolNames: instructions.toolDefinitions.map(\.name)
            )
        case .prompt(let prompt):
            .prompt(segments: prompt.segments.map(segment(from:)))
        case .response(let response):
            .response(segments: response.segments.map(segment(from:)))
        case .toolCalls(let calls):
            .toolCalls(calls.map {
                FMToolCall(id: $0.id, toolName: $0.toolName, argumentsJSON: $0.arguments.jsonString)
            })
        case .toolOutput(let output):
            .toolOutput(
                id: output.id,
                toolName: output.toolName,
                segments: output.segments.map(segment(from:))
            )
        @unknown default:
            // A transcript entry this build does not understand must not silently compare
            // equal to anything, or session reuse could replay the wrong history.
            .response(segments: [.text("\u{0}unknown-entry-\(UUID().uuidString)")])
        }
    }

    private static func segment(from source: Transcript.Segment) -> FMSegment {
        switch source {
        case .text(let text):
            .text(text.content)
        case .structure(let structured):
            .structured(source: structured.source, json: structured.content.jsonString)
        @unknown default:
            .text("\u{0}unknown-segment-\(UUID().uuidString)")
        }
    }

    /// Classifies a thrown error into Arbiter's mirror enum.
    ///
    /// `GenerationError.Refusal.explanation` is `async throws` and runs a *generation*, so
    /// it is never awaited here — the refusal's context description is used instead.
    /// `CancellationError` is returned as `nil` so callers rethrow it untouched.
    static func errorKind(for error: any Error) -> FMErrorKind? {
        if error is CancellationError { return nil }

        if let toolCallError = error as? LanguageModelSession.ToolCallError {
            // Apple wraps whatever the executor threw, cancellation included. Unwrapped
            // first, or a tool that was cancelled would be reported as a bad request and
            // the cancellation would never reach the caller.
            if toolCallError.underlyingError is CancellationError { return nil }
            return .toolCallFailed(
                toolName: toolCallError.tool.name,
                description: toolCallError.underlyingError.localizedDescription
            )
        }

        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return .unknown(error.localizedDescription)
        }

        switch generationError {
        case .exceededContextWindowSize(let context):
            return .contextWindowExceeded(context.debugDescription)
        case .assetsUnavailable(let context):
            return .assetsUnavailable(context.debugDescription)
        case .guardrailViolation(let context):
            return .guardrailViolation(context.debugDescription)
        case .unsupportedGuide(let context):
            return .unsupportedGuide(context.debugDescription)
        case .unsupportedLanguageOrLocale(let context):
            return .unsupportedLanguage(context.debugDescription)
        case .decodingFailure(let context):
            return .decodingFailure(context.debugDescription)
        case .rateLimited(let context):
            return .rateLimited(context.debugDescription)
        case .concurrentRequests(let context):
            return .concurrentRequests(context.debugDescription)
        case .refusal(_, let context):
            return .refusal(context.debugDescription)
        @unknown default:
            return .unknown(generationError.localizedDescription)
        }
    }
}

#endif
