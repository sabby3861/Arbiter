// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Testing
import Foundation
@testable import SwiftAI

@Suite("ResponseCache")
struct ResponseCacheTests {
    private func makeResponse(content: String = "cached") -> AIResponse {
        AIResponse(
            id: "test-\(UUID().uuidString)",
            content: content,
            model: "test-model",
            provider: .anthropic
        )
    }

    @Test("Cache hit returns stored response")
    func cacheHit() async {
        let cache = ResponseCache(maxEntries: 100, ttl: .seconds(60))
        let request = AIRequest.chat("Hello")
        let response = makeResponse()

        await cache.set(request: request, provider: .anthropic, response: response)
        let cached = await cache.get(request: request, provider: .anthropic)

        #expect(cached?.content == "cached")
    }

    @Test("Cache miss returns nil")
    func cacheMiss() async {
        let cache = ResponseCache(maxEntries: 100, ttl: .seconds(60))
        let request = AIRequest.chat("Unknown prompt")

        let cached = await cache.get(request: request, provider: .anthropic)
        #expect(cached == nil)
    }

    @Test("Different providers have separate cache entries")
    func differentProviders() async {
        let cache = ResponseCache(maxEntries: 100, ttl: .seconds(60))
        let request = AIRequest.chat("Hello")

        await cache.set(request: request, provider: .anthropic, response: makeResponse(content: "anthropic"))
        await cache.set(request: request, provider: .openAI, response: makeResponse(content: "openai"))

        let anthropic = await cache.get(request: request, provider: .anthropic)
        let openAI = await cache.get(request: request, provider: .openAI)

        #expect(anthropic?.content == "anthropic")
        #expect(openAI?.content == "openai")
    }

    @Test("Evicts oldest entries when at capacity")
    func eviction() async {
        let cache = ResponseCache(maxEntries: 2, ttl: .seconds(60))

        let request1 = AIRequest.chat("First")
        let request2 = AIRequest.chat("Second")
        let request3 = AIRequest.chat("Third")

        await cache.set(request: request1, provider: .anthropic, response: makeResponse(content: "first"))
        await cache.set(request: request2, provider: .anthropic, response: makeResponse(content: "second"))
        await cache.set(request: request3, provider: .anthropic, response: makeResponse(content: "third"))

        let count = await cache.count
        #expect(count <= 2)

        let third = await cache.get(request: request3, provider: .anthropic)
        #expect(third?.content == "third")
    }

    @Test("Clear removes all entries")
    func clear() async {
        let cache = ResponseCache(maxEntries: 100, ttl: .seconds(60))
        let request = AIRequest.chat("Hello")

        await cache.set(request: request, provider: .anthropic, response: makeResponse())
        await cache.clear()

        let count = await cache.count
        #expect(count == 0)
    }

    @Test("Same prompt with different parameters produces different cache keys")
    func differentParameters() async {
        let cache = ResponseCache(maxEntries: 100, ttl: .seconds(60))

        let request1 = AIRequest.chat("Hello").withTemperature(0.0)
        let request2 = AIRequest.chat("Hello").withTemperature(1.0)

        await cache.set(request: request1, provider: .anthropic, response: makeResponse(content: "deterministic"))
        let cached = await cache.get(request: request2, provider: .anthropic)

        #expect(cached == nil)
    }
}
