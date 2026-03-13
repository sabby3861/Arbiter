// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("PrivacyGuard")
struct PrivacyGuardTests {
    @Test func standardGuardAllowsNormalRequests() {
        let guard_ = PrivacyGuard.standard
        let request = AIRequest.chat("What is Swift?")
        #expect(!guard_.shouldForceLocal(for: request))
    }

    @Test func localOnlyForcesAllRequestsLocal() {
        let guard_ = PrivacyGuard.localOnly
        let request = AIRequest.chat("Anything at all")
        #expect(guard_.shouldForceLocal(for: request))
    }

    @Test func privateTagForcesLocal() {
        let guard_ = PrivacyGuard.standard
        let request = AIRequest.chat("My data").withTags([.private])
        #expect(guard_.shouldForceLocal(for: request))
    }

    @Test func healthTagForcesLocal() {
        let guard_ = PrivacyGuard.standard
        let request = AIRequest.chat("Blood pressure").withTags([.health])
        #expect(guard_.shouldForceLocal(for: request))
    }

    @Test func financialTagForcesLocal() {
        let guard_ = PrivacyGuard.standard
        let request = AIRequest.chat("Bank balance").withTags([.financial])
        #expect(guard_.shouldForceLocal(for: request))
    }

    @Test func personalTagForcesLocal() {
        let guard_ = PrivacyGuard.standard
        let request = AIRequest.chat("My diary").withTags([.personal])
        #expect(guard_.shouldForceLocal(for: request))
    }

    @Test func customTagNotInDefaultSet() {
        let guard_ = PrivacyGuard.standard
        let request = AIRequest.chat("Hello").withTags([RequestTag("custom")])
        #expect(!guard_.shouldForceLocal(for: request))
    }

    @Test func customTagInCustomSet() {
        let guard_ = PrivacyGuard(privateTags: [RequestTag("secret")])
        let request = AIRequest.chat("Hello").withTags([RequestTag("secret")])
        #expect(guard_.shouldForceLocal(for: request))
    }

    // MARK: - PII detection

    @Test func detectsEmailAddress() {
        let guard_ = PrivacyGuard(detectPII: true)
        let request = AIRequest.chat("Contact me at user@example.com")
        #expect(guard_.shouldForceLocal(for: request))
    }

    @Test func detectsPhoneNumber() {
        let guard_ = PrivacyGuard(detectPII: true)
        let request = AIRequest.chat("Call me at 555-123-4567")
        #expect(guard_.shouldForceLocal(for: request))
    }

    @Test func detectsSSN() {
        let guard_ = PrivacyGuard(detectPII: true)
        let request = AIRequest.chat("SSN is 123-45-6789")
        #expect(guard_.shouldForceLocal(for: request))
    }

    @Test func detectsCreditCard() {
        let guard_ = PrivacyGuard(detectPII: true)
        let request = AIRequest.chat("Card: 4111 1111 1111 1111")
        #expect(guard_.shouldForceLocal(for: request))
    }

    @Test func noPIIAllowsCloud() {
        let guard_ = PrivacyGuard(detectPII: true)
        let request = AIRequest.chat("What is the weather today?")
        #expect(!guard_.shouldForceLocal(for: request))
    }

    @Test func piiDetectionDisabledByDefault() {
        let guard_ = PrivacyGuard.standard
        let request = AIRequest.chat("Contact user@example.com")
        #expect(!guard_.shouldForceLocal(for: request))
    }

    @Test func strictModePIIDetection() {
        let guard_ = PrivacyGuard.strict
        let request = AIRequest.chat("Email: user@example.com")
        #expect(guard_.shouldForceLocal(for: request))
    }

    // MARK: - System prompt PII

    @Test func detectsPIIInSystemPrompt() {
        let guard_ = PrivacyGuard(detectPII: true)
        let request = AIRequest.chat("Help me").withSystem("User SSN: 123-45-6789")
        #expect(guard_.shouldForceLocal(for: request))
    }
}
