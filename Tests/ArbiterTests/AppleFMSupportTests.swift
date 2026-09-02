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
