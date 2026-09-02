// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

@Suite("FMErrorMapper")
struct FMErrorMapperTests {

    /// The headline regression this fixes: an overflow used to surface as
    /// "Apple Intelligence is off", so the caller could not tell a full context window from
    /// a disabled feature and had no way to react by trimming.
    @Test func contextOverflowIsNotProviderUnavailable() {
        let mapped = FMErrorMapper.arbiterError(
            for: .contextWindowExceeded("transcript too long"),
            contextLimit: 4_096
        )
        guard case .contextWindowExceeded(let provider, let limit) = mapped else {
            Issue.record("Expected contextWindowExceeded, got \(mapped)")
            return
        }
        #expect(provider == .appleFoundation)
        #expect(limit == 4_096)
    }

    @Test func guardrailViolationBecomesContentFiltered() {
        guard case .contentFiltered(let reason) = FMErrorMapper.arbiterError(
            for: .guardrailViolation("unsafe"), contextLimit: 4_096
        ) else {
            Issue.record("Expected contentFiltered")
            return
        }
        #expect(reason == "unsafe")
    }

    @Test func refusalCarriesItsExplanation() {
        guard case .refused(let provider, let explanation) = FMErrorMapper.arbiterError(
            for: .refusal("I will not do that"), contextLimit: 4_096
        ) else {
            Issue.record("Expected refused")
            return
        }
        #expect(provider == .appleFoundation)
        #expect(explanation == "I will not do that")
    }

    @Test func concurrentRequestsBecomesBusyAndIsRetryable() {
        let mapped = FMErrorMapper.arbiterError(for: .concurrentRequests("in flight"), contextLimit: 4_096)
        guard case .busy(let provider) = mapped else {
            Issue.record("Expected busy")
            return
        }
        #expect(provider == .appleFoundation)
        #expect(RetryEngine().isRetryable(mapped))
    }

    @Test func unsupportedLanguageIsNotRetryableSoTheRouterFallsBack() {
        let mapped = FMErrorMapper.arbiterError(
            for: .unsupportedLanguage("Context(debugDescription: ...)"), contextLimit: 4_096
        )
        guard case .unsupportedLanguage(let provider, let locale) = mapped else {
            Issue.record("Expected unsupportedLanguage")
            return
        }
        #expect(provider == .appleFoundation)
        // The framework reports a debug description, not a locale identifier, so the
        // locale stays nil rather than rendering "does not support the locale 'Context(...)'".
        #expect(locale == nil)
        #expect(!RetryEngine().isRetryable(mapped))
    }

    @Test func rateLimitedMapsWithoutARetryAfter() {
        guard case .rateLimited(let provider, let retryAfter) = FMErrorMapper.arbiterError(
            for: .rateLimited("slow down"), contextLimit: 4_096
        ) else {
            Issue.record("Expected rateLimited")
            return
        }
        #expect(provider == .appleFoundation)
        // The on-device model publishes no Retry-After equivalent.
        #expect(retryAfter == nil)
    }

    @Test func assetsUnavailableBecomesProviderUnavailable() {
        guard case .providerUnavailable(let provider, let reason) = FMErrorMapper.arbiterError(
            for: .assetsUnavailable("model downloading"), contextLimit: 4_096
        ) else {
            Issue.record("Expected providerUnavailable")
            return
        }
        #expect(provider == .appleFoundation)
        #expect(reason == "model downloading")
    }

    /// Both omitted from the item's own mapping table; the SDK defines them, so they are
    /// mapped rather than falling through to `unknown`.
    @Test func unsupportedGuideAndDecodingFailureHaveTheirOwnMappings() {
        guard case .invalidRequest = FMErrorMapper.arbiterError(
            for: .unsupportedGuide("regex not supported"), contextLimit: 4_096
        ) else {
            Issue.record("Expected invalidRequest for unsupportedGuide")
            return
        }
        guard case .decodingFailed = FMErrorMapper.arbiterError(
            for: .decodingFailure("bad json"), contextLimit: 4_096
        ) else {
            Issue.record("Expected decodingFailed for decodingFailure")
            return
        }
    }

    @Test func toolCallFailureNamesTheTool() {
        guard case .invalidRequest(let reason) = FMErrorMapper.arbiterError(
            for: .toolCallFailed(toolName: "get_weather", description: "timed out"),
            contextLimit: 4_096
        ) else {
            Issue.record("Expected invalidRequest")
            return
        }
        #expect(reason.contains("get_weather"))
        #expect(reason.contains("timed out"))
    }

    @Test func unknownErrorsDegradeToProviderUnavailable() {
        guard case .providerUnavailable = FMErrorMapper.arbiterError(
            for: .unknown("something new"), contextLimit: 4_096
        ) else {
            Issue.record("Expected providerUnavailable")
            return
        }
    }

    @Test func newErrorsAllDescribeThemselves() {
        let errors: [ArbiterError] = [
            .contextWindowExceeded(.appleFoundation, limit: 4_096),
            .refused(.appleFoundation, explanation: "no"),
            .unsupportedLanguage(.appleFoundation, locale: "ga-IE"),
            .unsupportedLanguage(.appleFoundation, locale: nil),
            .busy(.appleFoundation),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
    }
}

@Suite("AppleFMOptions")
struct AppleFMOptionsTests {

    @Test func optionsRoundTripThroughProviderOptions() throws {
        let options = AppleFMOptions(sampling: .greedy, conversationID: "chat-1")
        let request = AIRequest.chat("Hi").withProviderOptions(options, for: .appleFoundation)

        let recovered = try #require(request.providerOptions[.appleFoundation] as? AppleFMOptions)
        #expect(recovered.sampling == .greedy)
        #expect(recovered.conversationID == "chat-1")
    }

    /// A session bakes in its model and tools, so these fields must force a rebuild.
    @Test func sessionIdentityTracksSessionShapingFields() {
        let base = AppleFMOptions()
        #expect(AppleFMOptions(useCase: .contentTagging).sessionIdentity != base.sessionIdentity)
        #expect(AppleFMOptions(guardrails: .permissiveContentTransformations).sessionIdentity != base.sessionIdentity)
        #expect(AppleFMOptions(adapter: .name("tagger")).sessionIdentity != base.sessionIdentity)
        #expect(AppleFMOptions(adapter: .name("other")).sessionIdentity
                != AppleFMOptions(adapter: .name("tagger")).sessionIdentity)
    }

    /// Sampling and prewarming are per-call, not baked into the session, so they must not
    /// invalidate a cached one.
    @Test func sessionIdentityIgnoresPerCallFields() {
        let base = AppleFMOptions()
        #expect(AppleFMOptions(sampling: .greedy).sessionIdentity == base.sessionIdentity)
        #expect(AppleFMOptions(prewarm: true).sessionIdentity == base.sessionIdentity)
        #expect(AppleFMOptions(contextOverflow: .summarizeAndRetry).sessionIdentity == base.sessionIdentity)
    }

    /// `ResponseCache` keys on `String(describing:)`, so the description must be stable
    /// and must separate options that would produce different answers.
    @Test func descriptionIsStableAndDistinguishing() {
        let a = AppleFMOptions(sampling: .greedy, conversationID: "chat-1")
        let b = AppleFMOptions(sampling: .greedy, conversationID: "chat-1")
        #expect(a.description == b.description)
        #expect(a.description != AppleFMOptions(sampling: .randomTop(k: 5), conversationID: "chat-1").description)
        #expect(a.description != AppleFMOptions(sampling: .greedy, conversationID: "chat-2").description)
    }

    /// A session's tools are fixed at construction, so a turn carrying a different tool set
    /// must not reuse the session built for the previous one.
    @Test func sessionIdentityTracksBoundTools() {
        let weather = binding(named: "get_weather")
        let clock = binding(named: "get_time")

        #expect(AppleFMOptions(tools: [weather]).sessionIdentity != AppleFMOptions().sessionIdentity)
        #expect(AppleFMOptions(tools: [weather]).sessionIdentity
                != AppleFMOptions(tools: [weather, clock]).sessionIdentity)
        // Sorted: listing the same tools in a different order describes the same session.
        #expect(AppleFMOptions(tools: [weather, clock]).sessionIdentity
                == AppleFMOptions(tools: [clock, weather]).sessionIdentity)
    }

    /// A tool's whole contract shapes the session, not just its name: a turn that keeps the
    /// name but changes the description or the schema is describing a different tool, and
    /// reusing the session would keep advertising the old one.
    @Test func sessionIdentityTracksAToolsContractNotJustItsName() {
        let base = AppleFMOptions(tools: [binding(named: "get_weather")])

        let redescribed = AppleFMOptions(tools: [AppleFMToolBinding(
            definition: ToolDefinition(
                name: "get_weather", description: "Now with wind", inputSchema: ["type": "object"]
            ),
            execute: { _ in "" }
        )])
        let reschemad = AppleFMOptions(tools: [AppleFMToolBinding(
            definition: ToolDefinition(
                name: "get_weather",
                description: "",
                inputSchema: [
                    "type": "object",
                    "properties": ["city": ["type": "string"], "days": ["type": "integer"]],
                ]
            ),
            execute: { _ in "" }
        )])

        #expect(base.sessionIdentity != redescribed.sessionIdentity)
        #expect(base.sessionIdentity != reschemad.sessionIdentity)
    }

    /// The reason the description is hand-written: a synthesised one renders the tool's
    /// schema dictionary in per-process order, so the same request would key differently
    /// between runs and never hit the response cache. Two separately built but identical
    /// bindings — distinct closures included — must describe identically.
    @Test func descriptionIsStableAcrossDistinctToolClosures() {
        let a = AppleFMOptions(tools: [binding(named: "get_weather")])
        let b = AppleFMOptions(tools: [binding(named: "get_weather")])
        #expect(a.description == b.description)
        #expect(a.description != AppleFMOptions(tools: [binding(named: "get_time")]).description)
        // The schema is digested rather than rendered, so no dictionary description leaks in.
        #expect(!a.description.contains("properties"))
    }

    @Test func descriptionSeparatesSchemaAndLocaleSettings() {
        let base = AppleFMOptions()
        #expect(AppleFMOptions(includeSchemaInPrompt: false).description != base.description)
        #expect(AppleFMOptions(locale: Locale(identifier: "fr_FR"), enforceLocale: true).description
                != base.description)
        // A locale nobody is enforcing changes nothing about the answer.
        #expect(AppleFMOptions(locale: Locale(identifier: "fr_FR")).description == base.description)
    }

    private func binding(named name: String) -> AppleFMToolBinding {
        AppleFMToolBinding(
            definition: ToolDefinition(
                name: name,
                description: "",
                inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]]
            ),
            execute: { _ in "" }
        )
    }

    @Test func explicitSamplingWinsOverTopP() {
        let request = AIRequest.chat("Hi").withTopP(0.5)
        let settings = FMGenerationSettings(request: request, options: AppleFMOptions(sampling: .greedy))
        #expect(settings.sampling == .greedy)
    }

    @Test func outOfRangeTopPIsIgnoredRatherThanPassedToTheModel() {
        for topP in [-0.5, 1.5] {
            let settings = FMGenerationSettings(
                request: AIRequest.chat("Hi").withTopP(topP), options: AppleFMOptions()
            )
            #expect(settings.sampling == nil)
        }
    }

    @Test func schemaSettingsFollowTheOptions() {
        let tree = FMSchemaTree(root: .boolean, dependencies: [])
        let settings = FMGenerationSettings(
            request: AIRequest.chat("Hi"),
            options: AppleFMOptions(includeSchemaInPrompt: false),
            schema: tree
        )
        #expect(settings.schema == tree)
        #expect(settings.includeSchemaInPrompt == false)
    }

    @Test func topPBecomesNucleusSamplingWhenNoSamplingIsSet() {
        let request = AIRequest.chat("Hi").withTopP(0.5).withTemperature(0.3).withMaxTokens(128)
        let settings = FMGenerationSettings(request: request, options: AppleFMOptions())
        #expect(settings.sampling == .randomThreshold(probability: 0.5))
        #expect(settings.temperature == 0.3)
        #expect(settings.maximumResponseTokens == 128)
    }
}

@Suite("AppleFMSessionStore")
struct AppleFMSessionStoreTests {

    private func transcript(_ text: String) -> FMTranscript {
        FMTranscript(entries: [.prompt(segments: [.text(text)])])
    }

    @Test func sessionIsReusedWhenItAlreadyHoldsTheHistory() async throws {
        let store = AppleFMSessionStore()
        let history = transcript("one")
        let factory = MockFMSessionFactory(scripts: [[]])

        _ = try await store.session(
            conversationID: "chat", transcript: history, identity: "id",
            make: { try factory.factory(history, AppleFMOptions()) }
        )
        _ = try await store.session(
            conversationID: "chat", transcript: history, identity: "id",
            make: { try factory.factory(history, AppleFMOptions()) }
        )

        #expect(factory.sessionCount == 1)
    }

    @Test func sessionIsRebuiltWhenTheHistoryMoved() async throws {
        let store = AppleFMSessionStore()
        let factory = MockFMSessionFactory(scripts: [[]])

        for text in ["one", "two"] {
            let history = transcript(text)
            _ = try await store.session(
                conversationID: "chat", transcript: history, identity: "id",
                make: { try factory.factory(history, AppleFMOptions()) }
            )
        }

        #expect(factory.sessionCount == 2)
    }

    /// The bug this guards: tools and the model are fixed at session construction, so
    /// reusing across an identity change would silently run the old configuration.
    @Test func sessionIsRebuiltWhenTheSessionIdentityChanges() async throws {
        let store = AppleFMSessionStore()
        let history = transcript("one")
        let factory = MockFMSessionFactory(scripts: [[]])

        for identity in ["general", "contentTagging"] {
            _ = try await store.session(
                conversationID: "chat", transcript: history, identity: identity,
                make: { try factory.factory(history, AppleFMOptions()) }
            )
        }

        #expect(factory.sessionCount == 2)
    }

    @Test func noConversationIDMeansNoCaching() async throws {
        let store = AppleFMSessionStore()
        let history = transcript("one")
        let factory = MockFMSessionFactory(scripts: [[]])

        for _ in 0..<3 {
            _ = try await store.session(
                conversationID: nil, transcript: history, identity: "id",
                make: { try factory.factory(history, AppleFMOptions()) }
            )
        }

        #expect(factory.sessionCount == 3)
    }

    @Test func leastRecentlyUsedConversationIsEvicted() async throws {
        let store = AppleFMSessionStore(capacity: 2)
        let history = transcript("one")
        let factory = MockFMSessionFactory(scripts: [[]])

        func acquire(_ id: String) async throws {
            _ = try await store.session(
                conversationID: id, transcript: history, identity: "id",
                make: { try factory.factory(history, AppleFMOptions()) }
            )
        }

        try await acquire("a")
        try await acquire("b")
        try await acquire("a")  // "a" is now the most recent, so "b" is next to go.
        try await acquire("c")  // Evicts "b".
        #expect(factory.sessionCount == 3)

        try await acquire("a")  // Still cached.
        #expect(factory.sessionCount == 3)

        try await acquire("b")  // Evicted, so rebuilt.
        #expect(factory.sessionCount == 4)
    }

    @Test func discardForcesARebuild() async throws {
        let store = AppleFMSessionStore()
        let history = transcript("one")
        let factory = MockFMSessionFactory(scripts: [[]])

        _ = try await store.session(
            conversationID: "chat", transcript: history, identity: "id",
            make: { try factory.factory(history, AppleFMOptions()) }
        )
        await store.discard(conversationID: "chat")
        _ = try await store.session(
            conversationID: "chat", transcript: history, identity: "id",
            make: { try factory.factory(history, AppleFMOptions()) }
        )

        #expect(factory.sessionCount == 2)
    }
}

@Suite("AppleFMAvailability")
struct AppleFMAvailabilityTests {

    /// The strings predate the enum and are part of `providerUnavailable`'s payload, so
    /// they are produced from it rather than replaced by it.
    @Test func everyReasonHasItsEstablishedMessage() {
        #expect(AppleFMAvailability.available.message == "Available")
        #expect(AppleFMAvailability.unavailable(.deviceNotEligible).message
                == "This device does not support Apple Intelligence")
        #expect(AppleFMAvailability.unavailable(.appleIntelligenceNotEnabled).message
                == "Apple Intelligence is not enabled. Enable it in Settings > Apple Intelligence & Siri")
        #expect(AppleFMAvailability.unavailable(.modelNotReady).message
                == "The on-device model is still downloading or preparing")
        #expect(AppleFMAvailability.unavailable(.osTooOld).message
                == "Apple Foundation Models requires iOS 26+ / macOS 26+ / visionOS 26+")
        #expect(AppleFMAvailability.unavailable(.frameworkNotLinked).message
                == "FoundationModels framework is not available on this platform")
        #expect(AppleFMAvailability.unavailable(.unknown).message
                == "Apple Foundation Models are not available")
    }

    /// Only a model that is still preparing is worth waiting for; the rest need someone to
    /// change something.
    @Test func onlyAPreparingModelIsTransient() {
        #expect(AppleFMAvailability.unavailable(.modelNotReady).isTransient)
        for reason: AppleFMUnavailableReason in [
            .deviceNotEligible, .appleIntelligenceNotEnabled, .frameworkNotLinked, .osTooOld, .unknown,
        ] {
            #expect(!AppleFMAvailability.unavailable(reason).isTransient)
        }
        #expect(!AppleFMAvailability.available.isTransient)
    }

    @Test func availabilityAgreesWithTheDerivedHelpers() async {
        let availability = await AvailabilityChecker.availability()
        #expect(await AvailabilityChecker.isAppleFoundationAvailable() == availability.isAvailable)
        #expect(await AvailabilityChecker.unavailableReason() == availability.message)
    }

    @Test func aBuildWithoutTheFrameworkReportsWhy() async {
        #if !canImport(FoundationModels)
        #expect(await AvailabilityChecker.availability() == .unavailable(.frameworkNotLinked))
        #endif
    }
}
