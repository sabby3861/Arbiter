// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

@Suite("Managed credential providers")
struct ManagedCredentialProviderTests {
    @Test func externallyManagedCredentialsMakeCloudProvidersAvailable() async {
        let openAI = OpenAIProvider(credential: "openai")
        let anthropic = AnthropicProvider(credential: "anthropic")
        let gemini = GeminiProvider(credential: "gemini")

        #expect(await openAI.isAvailable)
        #expect(await anthropic.isAvailable)
        #expect(await gemini.isAvailable)
    }

    @Test func emptyExternallyManagedCredentialsRemainUnavailable() async {
        let openAI = OpenAIProvider(credential: "")
        let anthropic = AnthropicProvider(credential: "")
        let gemini = GeminiProvider(credential: "")

        #expect(await !openAI.isAvailable)
        #expect(await !anthropic.isAvailable)
        #expect(await !gemini.isAvailable)
    }
}
