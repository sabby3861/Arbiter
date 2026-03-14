# SwiftAI Routing Guide

SwiftAI's smart router automatically picks the best provider for each request. This guide explains how routing decisions are made and how to control them.

## Scoring System

Every registered provider is scored on five factors for each incoming request. Each factor is scored 0-20, giving a maximum total score of 100:

| Factor | What It Measures |
|--------|-----------------|
| **Capability** | Can the provider handle this request type? (e.g., vision, long context, code) |
| **Quality** | Expected output quality based on model benchmarks and historical performance |
| **Latency** | Time to first token — local providers score higher than cloud |
| **Privacy** | On-device providers score 20; cloud providers score lower, especially with sensitive tags |
| **Cost** | Free providers score 20; expensive providers score lower based on estimated token cost |

The provider with the highest total score wins the request.

## Routing Strategies

Control how the router weights these factors:

### Balanced (Default)

```swift
let ai = try SwiftAI {
    try $0.cloud(.anthropic(from: .keychain))
    $0.local(OllamaProvider())
    $0.routing(.smart)  // This is the default
}
```

All five factors weighted equally.

### Cost Optimized

```swift
$0.routing(RoutingPolicy(strategy: .costOptimized))
```

Applies **3x weight on cost**. Prefers free local providers; only routes to cloud when local providers lack the required capability.

### Privacy First

```swift
$0.routing(.preferLocal)  // shorthand for .privacyFirst strategy
```

Applies **3x weight on privacy**. Strongly prefers on-device providers. Cloud providers are only used when no local option can handle the request.

### Quality First

```swift
$0.routing(.preferCloud)  // shorthand for .qualityFirst strategy
```

Applies **3x weight on quality**. Routes to the highest-quality model available, regardless of cost or latency.

### Latency Optimized

```swift
$0.routing(RoutingPolicy(strategy: .latencyOptimized))
```

Applies **3x weight on latency**. Picks the fastest provider — usually a local model or Apple Foundation Models.

### Fixed Provider

```swift
$0.routing(.specific(.anthropic))
```

Always routes to one specific provider. No scoring, no fallback. Fails if the provider is unavailable.

### Priority Order

```swift
$0.routing(RoutingPolicy(strategy: .priority([.ollama, .anthropic])))
```

Tries providers in the specified order. Uses the first one that is available and capable of handling the request.

## Real Routing Decisions

Here is how the router handles common scenarios with a full multi-provider setup:

| Request | Winner | Why |
|---------|--------|-----|
| "Classify this text" | Apple FM | Free, fast, sufficient quality for simple classification |
| "Write a 2000-word essay" | Anthropic | Best quality score for long-form content generation |
| "Analyze my health data" + `.private` tag | MLX | Privacy tag forces on-device routing; MLX has best local quality |
| "Quick chat, offline" | MLX or Apple FM | No network available, cloud providers excluded automatically |

## How Fallback Works

When the top-scoring provider fails (network error, rate limit, model overloaded), the router automatically tries the next provider in score order.

```
Request arrives
  → Score all providers
  → Try #1 (Anthropic, score 87) → 429 Rate Limited
  → Try #2 (OpenAI, score 82)    → Success ✓
```

Fallback is enabled by default. You can configure it:

```swift
let ai = try SwiftAI {
    try $0.cloud(.anthropic(from: .keychain))
    try $0.cloud(.openAI(from: .keychain))
    $0.local(OllamaProvider())
    $0.routing(.smart)  // fallbackEnabled is true by default, maxRetries is 2
}
```

To disable fallback, use `.fixed(.anthropic)` — only the specified provider is tried. If it fails, the request fails.

## Spending Limits

Set a budget to control cloud costs. When spending approaches the limit, cloud provider scores drop to zero and requests route to free local providers automatically.

```swift
let ai = try SwiftAI {
    try $0.cloud(.anthropic(from: .keychain))
    $0.local(OllamaProvider())
    $0.local(MLXProvider(.auto))

    $0.spendingLimit(5.00, action: .fallbackToCheaper)
}
```

The `.fallbackToCheaper` action means: when the budget runs low, cloud scores drop to zero and the router falls back to free local providers instead of failing outright.

## Full Multi-Provider Example

A production-ready setup with smart routing, spending limits, and privacy controls:

```swift
import SwiftAI

let ai = try SwiftAI {
    // Cloud providers — best quality, paid
    try $0.cloud(.anthropic(from: .keychain))
    try $0.cloud(.openAI(from: .keychain))
    try $0.cloud(.gemini(from: .keychain))

    // Local providers — free, private, offline-capable
    $0.local(OllamaProvider())
    $0.local(MLXProvider(.auto))

    // System provider — free, private, no setup
    $0.system(AppleFoundationProvider())

    // Routing strategy (fallback enabled by default)
    $0.routing(.smart)

    // Budget guard
    $0.spendingLimit(5.00, action: .fallbackToCheaper)

    // Privacy enforcement
    $0.privacy(.strict)
}

// Simple request — router picks the best provider
let response = try await ai.generate("Summarize this article")

// Privacy-sensitive request — guaranteed on-device
let privateResponse = try await ai.generate(
    "Analyze my health records",
    options: RequestOptions(tags: [.health, .private], privacyRequired: true)
)
```

With this setup, SwiftAI handles provider selection, fallback, cost control, and privacy enforcement automatically. You write one `ai.generate()` call and the router does the rest.
