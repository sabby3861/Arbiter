// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

/// A classifier whose verdict the test dictates.
struct StubPrivacyClassifier: PrivacyClassifier {
    enum Behaviour: Sendable {
        case verdict(PrivacyClassification)
        case failure
    }

    let behaviour: Behaviour

    func classify(_ text: String) async throws -> PrivacyClassification {
        switch behaviour {
        case .verdict(let classification): return classification
        case .failure: throw ArbiterError.invalidRequest(reason: "classifier unavailable")
        }
    }
}

@Suite("PrivacyGuard hardening")
struct PrivacyHardeningTests {

    // MARK: - Fail-closed

    @Test("Strict fails closed when the classifier cannot reach a verdict")
    func strictFailsClosedOnIndeterminateClassifier() async {
        var guard_ = PrivacyGuard.strict
        guard_.classifier = StubPrivacyClassifier(behaviour: .verdict(.indeterminate))

        let report = await guard_.assess(AIRequest.chat("Explain how a hash map works."))
        #expect(report.detectedTypes.isEmpty)
        #expect(report.confidence == .unknown)
        #expect(report.forcesOnDevice)
        #expect(report.failedClosed)
    }

    @Test("A classifier that throws is treated as inconclusive, not as clean")
    func throwingClassifierIsInconclusive() async {
        var guard_ = PrivacyGuard.strict
        guard_.classifier = StubPrivacyClassifier(behaviour: .failure)

        let report = await guard_.assess(AIRequest.chat("Explain how a hash map works."))
        #expect(report.confidence == .unknown)
        #expect(report.forcesOnDevice)
    }

    @Test("A guard that does not fail closed lets an inconclusive request through")
    func failOpenGuardAllowsInconclusiveRequest() async {
        var guard_ = PrivacyGuard(detectPII: true, failClosed: false)
        guard_.classifier = StubPrivacyClassifier(behaviour: .verdict(.indeterminate))

        let report = await guard_.assess(AIRequest.chat("Explain how a hash map works."))
        #expect(report.confidence == .unknown)
        #expect(!report.forcesOnDevice)
        #expect(!report.failedClosed)
    }

    @Test("Text whose language cannot be determined fails closed under strict")
    func undeterminableLanguageFailsClosed() async {
        let report = await PrivacyGuard.strict.assess(AIRequest.chat("🙂 🙂 🙂 🙂"))
        #expect(report.confidence == .unknown)
        #expect(report.forcesOnDevice)
        #expect(report.failedClosed)
    }

    @Test("A conclusive classifier verdict leaves confidence intact")
    func conclusiveClassifierKeepsConfidence() async {
        var guard_ = PrivacyGuard.strict
        guard_.classifier = StubPrivacyClassifier(behaviour: .verdict(.clean))

        let report = await guard_.assess(AIRequest.chat("Explain how a hash map works."))
        #expect(report.confidence == .high)
        #expect(!report.forcesOnDevice)
    }

    @Test("A deterministic hit stays certain even when the classifier is unsure")
    func deterministicHitOutranksAnUnsureClassifier() async {
        var guard_ = PrivacyGuard.strict
        guard_.classifier = StubPrivacyClassifier(behaviour: .verdict(.indeterminate))

        let report = await guard_.assess(AIRequest.chat("SSN is 123-45-6789"))
        #expect(report.detectedTypes.contains(.socialSecurityNumber))
        #expect(report.confidence == .high)
        #expect(report.forcesOnDevice)
        #expect(!report.failedClosed, "the guard did not need to fail closed — it found something")
    }

    // MARK: - Custom classifier categories

    @Test("A classifier can report a category Arbiter does not ship with")
    func classifierReportsCustomCategory() async {
        let patientID = PIIType("patientID")
        var guard_ = PrivacyGuard(detectPII: true)
        guard_.classifier = StubPrivacyClassifier(
            behaviour: .verdict(PrivacyClassification(detectedTypes: [patientID]))
        )

        let report = await guard_.assess(AIRequest.chat("Look up record 88213 for the ward round"))
        #expect(report.detectedTypes.contains(patientID))
        #expect(report.forcesOnDevice)
        #expect(report.sortedTypes.last == patientID, "custom categories sort after the built-ins")
    }

    @Test("The classifier is only consulted when PII detection is on")
    func classifierIsSkippedWhenDetectionIsOff() async {
        var guard_ = PrivacyGuard.standard
        guard_.classifier = StubPrivacyClassifier(
            behaviour: .verdict(PrivacyClassification(detectedTypes: [.emailAddress]))
        )

        let report = await guard_.assess(AIRequest.chat("Anything"))
        #expect(report.detectedTypes.isEmpty)
        #expect(!report.forcesOnDevice)
    }

    // MARK: - The report never carries values

    @Test("A report names categories and tags, never the matched values")
    func reportCarriesNoValues() async {
        let secrets = ["user@example.com", "123-45-6789", "4111 1111 1111 1111", "Sarah Whitfield"]
        let prompt = "Mail user@example.com, SSN 123-45-6789, card 4111 1111 1111 1111, ask Sarah Whitfield"
        let report = await PrivacyGuard.strict.assess(AIRequest.chat(prompt).withTags([.health]))

        #expect(report.containsPII)
        #expect(report.matchedTags == [.health])

        let rendered = [
            report.summary,
            String(describing: report),
            report.sortedTypes.map(\.rawValue).joined(separator: " "),
        ].joined(separator: " ")
        for secret in secrets {
            #expect(!rendered.contains(secret), "report leaked \(secret)")
        }
        // Not even a fragment: no run of digits from the SSN or the card survives.
        #expect(!rendered.contains("123"))
        #expect(!rendered.contains("4111"))
    }

    // MARK: - What counts as request text

    @Test("PII inside mixed content and tool-call arguments is detected")
    func detectionReachesEveryPartOfTheRequest() async {
        let guard_ = PrivacyGuard(detectPII: true, detectNames: false)

        let mixed = AIRequest(messages: [
            Message(role: .user, content: .mixed([
                .text("Here is the file"),
                .text("my email is user@example.com"),
            ])),
        ])
        let mixedReport = await guard_.assess(mixed)
        #expect(mixedReport.detectedTypes.contains(.emailAddress))

        let toolCall = AIRequest(messages: [
            Message(role: .assistant, content: .toolCalls([
                ToolCall(
                    id: "call_1",
                    name: "lookup_customer",
                    arguments: .object(["ssn": .string("123-45-6789")])
                ),
            ])),
        ])
        let toolReport = await guard_.assess(toolCall)
        #expect(toolReport.detectedTypes.contains(.socialSecurityNumber))

        let toolResult = AIRequest(messages: [
            Message(role: .tool, content: .toolResults([
                ToolResult(toolCallId: "call_1", content: "card on file: 4111 1111 1111 1111"),
            ])),
        ])
        let resultReport = await guard_.assess(toolResult)
        #expect(resultReport.detectedTypes.contains(.creditCardNumber))
    }

    // MARK: - Fail-closed does not mean fail-often

    @Test("A language the name tagger does not cover is not treated as unreadable")
    func unsupportedLanguageDoesNotFailClosed() async {
        // `.nameType` covers only a few languages; treating the rest as unknown would make
        // `.strict` block every Spanish, German or Japanese prompt outright.
        for prompt in [
            "Escribe un poema sobre el mar",
            "Schreibe eine kurze Zusammenfassung",
            "海について短い詩を書いてください",
        ] {
            let report = await PrivacyGuard.strict.assess(AIRequest.chat(prompt))
            #expect(report.confidence != .unknown, "\(prompt) was treated as unreadable")
            #expect(!report.forcesOnDevice, "\(prompt) was blocked")
        }
    }

    @Test("A two-word English prompt is not blocked by a language misidentification")
    func shortPromptIsNotBlocked() async {
        for prompt in ["hi", "OK", "thanks!"] {
            let report = await PrivacyGuard.strict.assess(AIRequest.chat(prompt))
            #expect(!report.forcesOnDevice, "\(prompt) was blocked")
        }
    }

    @Test("Content the guard cannot read leaves the verdict unknown")
    func unscannableContentIsUnknown() async {
        let image = AIRequest(messages: [
            Message(role: .user, content: .mixed([
                .text("What is in this photo?"),
                .image(.base64(data: "AAAA", mimeType: "image/png")),
            ])),
        ])
        let imageReport = await PrivacyGuard.strict.assess(image)
        #expect(imageReport.confidence == .unknown)
        #expect(imageReport.forcesOnDevice, "a fail-closed guard does not send an unread image out")
        #expect(imageReport.failedClosed)

        let document = AIRequest(messages: [
            Message(role: .user, content: .document(DocumentSource(base64: "AAAA"))),
        ])
        let documentReport = await PrivacyGuard.strict.assess(document)
        #expect(documentReport.confidence == .unknown)
        #expect(documentReport.forcesOnDevice)

        // A guard that is not fail-closed still reports the uncertainty without acting.
        let permissive = await PrivacyGuard(detectPII: true).assess(image)
        #expect(permissive.confidence == .unknown)
        #expect(!permissive.forcesOnDevice)
    }

    @Test("A replayed thinking block is scanned like any other text")
    func thinkingBlocksAreScanned() async {
        let request = AIRequest(messages: [
            Message(role: .assistant, content: .thinking([
                ThinkingBlock(text: "The customer gave 4111 1111 1111 1111 earlier."),
            ])),
        ])
        let report = await PrivacyGuard(detectPII: true, detectNames: false).assess(request)
        #expect(report.detectedTypes.contains(.creditCardNumber))
    }

    @Test("A card number that arrives as a JSON number is still found")
    func numericToolArgumentIsScanned() async {
        let request = AIRequest(messages: [
            Message(role: .assistant, content: .toolCalls([
                ToolCall(
                    id: "call_1",
                    name: "charge_card",
                    arguments: .object(["card": .number(4_111_111_111_111_111)])
                ),
            ])),
        ])
        let report = await PrivacyGuard(detectPII: true, detectNames: false).assess(request)
        #expect(report.detectedTypes.contains(.creditCardNumber))
    }

    @Test("A tagged request does not claim it failed closed")
    func tagsOutrankTheFailClosedFlag() async {
        let request = AIRequest.chat("🙂 🙂 🙂").withTags([.health])
        let report = await PrivacyGuard.strict.assess(request)
        #expect(report.forcesOnDevice)
        #expect(report.matchedTags == [.health])
        #expect(!report.failedClosed, "the tag alone would have forced this on-device")
    }

    @Test("A local-only guard does not claim it failed closed either")
    func localOnlyDoesNotClaimFailClosed() async {
        let report = await PrivacyGuard.localOnly.assess(AIRequest.chat("🙂 🙂 🙂"))
        #expect(report.forcesOnDevice)
        #expect(!report.failedClosed)
    }

    @Test("The synchronous inspection ignores the classifier but keeps the built-in layers")
    func synchronousInspectionSkipsTheClassifier() {
        var guard_ = PrivacyGuard(detectPII: true)
        guard_.classifier = StubPrivacyClassifier(
            behaviour: .verdict(PrivacyClassification(detectedTypes: [PIIType("custom")]))
        )

        let report = guard_.inspect(AIRequest.chat("Contact user@example.com"))
        #expect(report.detectedTypes == [.emailAddress])
        #expect(guard_.shouldForceLocal(for: AIRequest.chat("Contact user@example.com")))
    }
}

@Suite("Privacy routing")
struct PrivacyRoutingTests {
    static let online: @Sendable () async -> ConnectivityState = { .wifi }
    static let normalDevice: @Sendable () -> DeviceCapabilities = {
        DeviceCapabilities(memoryGB: 16, thermalLevel: .nominal, processorCount: 8)
    }

    func router(privacy: PrivacyGuard?) -> SmartRouter {
        SmartRouter(
            privacyGuard: privacy,
            connectivityCheck: Self.online,
            deviceAssessment: Self.normalDevice,
            performanceTracker: .inMemory()
        )
    }

    func cloudProvider() -> MockProvider {
        MockProvider(id: .anthropic, capabilities: ProviderCapabilities(
            supportedTasks: [.chat], maxContextTokens: 200_000,
            supportsStreaming: true, supportsToolCalling: true, supportsImageInput: true,
            costPerMillionInputTokens: 3.0, costPerMillionOutputTokens: 15.0,
            estimatedLatency: .fast, privacyLevel: .thirdPartyCloud
        ))
    }

    @Test("The decision carries a report naming what was detected")
    func decisionCarriesPrivacyReport() async {
        let router = router(privacy: PrivacyGuard(detectPII: true, detectNames: false))
        let providers: [any AIProvider] = [cloudProvider(), MockLocalProvider()]
        let request = AIRequest.chat("Email the invoice to billing@acme.co.uk")

        let decision = await router.route(
            request, policy: .smart, providers: providers, budgetRemaining: nil
        )
        #expect(decision.selectedProvider == .mlx, "a detected email keeps the request off the cloud")
        #expect(decision.privacyReport?.detectedTypes == [.emailAddress])
        #expect(decision.privacyReport?.forcesOnDevice == true)
    }

    @Test("A clean request is reported as clean and still reaches the cloud")
    func cleanRequestIsReportedAndRouted() async {
        // Names off: the assertion is about a *clean* verdict, and the statistical layer
        // reads sentence-initial words as organisations often enough to make this flaky.
        let router = router(privacy: PrivacyGuard(detectPII: true, detectNames: false))
        let providers: [any AIProvider] = [cloudProvider(), MockLocalProvider()]
        let request = AIRequest.chat("Write a 2000-word essay about distributed systems")

        let decision = await router.route(
            request, policy: .smart, providers: providers, budgetRemaining: nil
        )
        #expect(decision.privacyReport?.containsPII == false)
        #expect(decision.privacyReport?.forcesOnDevice == false)
        #expect(decision.selectedProvider == .anthropic)
    }

    @Test("With nowhere private to run, the decision is unavailable and says why")
    func noPrivateProviderMakesTheDecisionUnavailable() async {
        let router = router(privacy: PrivacyGuard(detectPII: true, detectNames: false))
        let providers: [any AIProvider] = [cloudProvider()]
        let request = AIRequest.chat("My SSN is 123-45-6789")

        let decision = await router.route(
            request, policy: .smart, providers: providers, budgetRemaining: nil
        )
        #expect(!decision.isAvailable)
        #expect(decision.privacyReport?.detectedTypes == [.socialSecurityNumber])
        #expect(decision.reason.contains("privacy"))
    }

    @Test("Without a guard there is no report at all")
    func noGuardMeansNoReport() async {
        let router = router(privacy: nil)
        let providers: [any AIProvider] = [cloudProvider()]

        let decision = await router.route(
            AIRequest.chat("My SSN is 123-45-6789"),
            policy: .smart, providers: providers, budgetRemaining: nil
        )
        #expect(decision.privacyReport == nil)
        #expect(decision.selectedProvider == .anthropic)
    }
}

@Suite("Privacy violation errors")
struct PrivacyViolationTests {
    func cloudOnlyArbiter(privacy: PrivacyGuard) -> Arbiter {
        Arbiter {
            $0.cloud(MockProvider(id: .anthropic))
            $0.privacy(privacy)
            $0.routing(.smart)
        }
    }

    @Test("Detected PII with no private provider throws, naming the categories only")
    func detectedPIIThrowsPrivacyViolation() async {
        let ai = cloudOnlyArbiter(privacy: PrivacyGuard(detectPII: true, detectNames: false))

        await #expect(throws: ArbiterError.self) {
            try await ai.generate("My SSN is 123-45-6789")
        }

        do {
            _ = try await ai.generate("My SSN is 123-45-6789")
            Issue.record("expected the guard to block the request")
        } catch let error as ArbiterError {
            guard case .privacyViolation(let types, let reason) = error else {
                Issue.record("expected privacyViolation, got \(error)")
                return
            }
            #expect(types == [.socialSecurityNumber])
            #expect(reason == "sensitive data detected")
            #expect(error.errorDescription?.contains("123-45-6789") == false)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("A fail-closed guard blocks even when nothing was detected")
    func failClosedThrowsWithNoDetectedTypes() async {
        var privacy = PrivacyGuard.strict
        privacy.classifier = StubPrivacyClassifier(behaviour: .verdict(.indeterminate))
        let ai = cloudOnlyArbiter(privacy: privacy)

        do {
            _ = try await ai.generate("Explain how a hash map works.")
            Issue.record("expected the fail-closed guard to block the request")
        } catch let error as ArbiterError {
            guard case .privacyViolation(let types, let reason) = error else {
                Issue.record("expected privacyViolation, got \(error)")
                return
            }
            #expect(types.isEmpty)
            #expect(reason.contains("inconclusive"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("A tagged request with nowhere private to run reports the tag")
    func taggedRequestThrowsNamingTheTag() async {
        let ai = cloudOnlyArbiter(privacy: .standard)

        do {
            _ = try await ai.generate("Anything", options: RequestOptions(tags: [.health]))
            Issue.record("expected the tag to block the request")
        } catch let error as ArbiterError {
            guard case .privacyViolation(let types, let reason) = error else {
                Issue.record("expected privacyViolation, got \(error)")
                return
            }
            #expect(types.isEmpty)
            #expect(reason.contains("health"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("Streaming is blocked the same way")
    func streamingThrowsPrivacyViolation() async {
        let ai = cloudOnlyArbiter(privacy: PrivacyGuard(detectPII: true, detectNames: false))

        do {
            for try await _ in ai.stream("My SSN is 123-45-6789") {}
            Issue.record("expected the guard to block the stream")
        } catch let error as ArbiterError {
            guard case .privacyViolation = error else {
                Issue.record("expected privacyViolation, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("An ordinary routing failure is still allProvidersFailed, not a privacy violation")
    func nonPrivacyFailureKeepsItsOwnError() async {
        let ai = Arbiter {
            $0.cloud(MockProvider(id: .anthropic, available: false))
            $0.privacy(PrivacyGuard(detectPII: true, detectNames: false))
            $0.routing(.smart)
        }

        do {
            _ = try await ai.generate("Write a haiku about the sea")
            Issue.record("expected routing to fail")
        } catch let error as ArbiterError {
            guard case .allProvidersFailed = error else {
                Issue.record("expected allProvidersFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("A private provider that is merely down is not reported as a privacy violation")
    func downLocalProviderIsAProviderFailure() async {
        let ai = Arbiter {
            $0.cloud(MockProvider(id: .anthropic))
            $0.local(MockProvider(id: .mlx, available: false, capabilities: ProviderCapabilities(
                supportedTasks: [.chat], maxContextTokens: 8_000,
                supportsStreaming: true, supportsToolCalling: false, supportsImageInput: false,
                costPerMillionInputTokens: nil, costPerMillionOutputTokens: nil,
                estimatedLatency: .fast, privacyLevel: .onDevice
            )))
            $0.privacy(PrivacyGuard(detectPII: true, detectNames: false))
            $0.routing(.smart)
        }

        do {
            _ = try await ai.generate("My SSN is 123-45-6789")
            Issue.record("expected routing to fail")
        } catch let error as ArbiterError {
            guard case .allProvidersFailed = error else {
                Issue.record("expected allProvidersFailed — a private provider is registered, it is down — got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("A local-only guard with nowhere local to run says so plainly")
    func localOnlyGuardExplainsItself() async {
        let ai = cloudOnlyArbiter(privacy: .localOnly)

        do {
            _ = try await ai.generate("Write a haiku about the sea")
            Issue.record("expected the guard to block the request")
        } catch let error as ArbiterError {
            guard case .privacyViolation(let types, let reason) = error else {
                Issue.record("expected privacyViolation, got \(error)")
                return
            }
            #expect(types.isEmpty)
            #expect(reason == "the guard restricts this request to on-device providers")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("A privacy violation is not retryable")
    func privacyViolationIsNotRetryable() {
        let engine = RetryEngine(maxRetries: 3)
        #expect(!engine.isRetryable(ArbiterError.privacyViolation(
            detectedTypes: [.emailAddress], reason: "sensitive data detected"
        )))
    }
}
