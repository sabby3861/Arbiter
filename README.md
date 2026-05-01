# Arbiter

[![CI](https://github.com/sabby3861/Arbiter/actions/workflows/ci.yml/badge.svg)](https://github.com/sabby3861/Arbiter/actions/workflows/ci.yml)
[![Swift 6.1](https://img.shields.io/badge/Swift-6.1-F05138.svg?style=flat&logo=swift)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%20|%20macOS%2014%20|%20visionOS%201-blue.svg)](https://developer.apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![SPM Compatible](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager/)

**One API for every AI — cloud, on-device, and Apple Intelligence.**

<p align="center">
  <img src="Assets/demo.gif" alt="Arbiter Demo" width="280">
</p>

Arbiter is a unified AI runtime for Swift that lets you call any AI provider through a single, consistent interface. Write your AI code once, then swap providers — or run them all simultaneously with intelligent routing.

## Quick Start

```swift
import Arbiter

let ai = try Arbiter {
    try $0.cloud(.anthropic(from: .keychain))
}

// Simple generation
let response = try await ai.generate("Explain quantum computing")

// Or drop in a full chat UI
ArbiterChatView(ai: ai)
```

## Multi-Provider Setup

```swift
let ai = try Arbiter {
    try $0.cloud(.anthropic(from: .keychain))
    try $0.cloud(.openAI(from: .keychain))
    try $0.cloud(.gemini(from: .keychain))
    $0.local(OllamaProvider())
    $0.local(MLXProvider(.auto))
    $0.system(AppleFoundationProvider())
    $0.routing(.smart)
    $0.spendingLimit(5.00)
    $0.privacy(.strict)
}

// Arbiter picks the best available provider
let response = try await ai.generate("Hello!")

// Tag sensitive requests — forces on-device routing
let options = RequestOptions(tags: [.health])
let privateResponse = try await ai.generate("Summarize my lab results", options: options)
```

## Streaming

```swift
let stream = ai.stream("Write a haiku about Swift.")
for try await chunk in stream {
    // chunk.delta contains the incremental text
}
```

## Conversations

```swift
@State private var session = ConversationSession(systemPrompt: "You are a helpful assistant.")

// In your SwiftUI view:
try await session.send("What is SwiftUI?", using: ai)
// session.messages is @Observable — your UI updates automatically
```

## Structured Output

Generate typed Swift values directly — no manual JSON parsing:

```swift
struct Recipe: Codable {
    let name: String
    let ingredients: [String]
}

// Simple — works for most types
let recipe: Recipe = try await ai.generate("Pasta recipe", as: Recipe.self)

// With example — most reliable for complex types
let recipe: Recipe = try await ai.generate(
    "Pasta recipe",
    as: Recipe.self,
    example: Recipe(name: "", ingredients: [])
)
```

Works with conversations too:

```swift
let analysis: SentimentResult = try await session.send(
    "Analyse this review: 'Great product!'",
    as: SentimentResult.self,
    example: SentimentResult(sentiment: "", score: 0),
    using: ai
)
```

## Intelligent Routing

Arbiter's router doesn't just match capabilities — it analyses the actual request to determine complexity, intent, and optimal routing. No other library does this.

```swift
// Arbiter analyses your request and routes intelligently:

// Simple classification → Apple FM (free, fast, sufficient)
let sentiment = try await ai.generate("Is this positive? 'Great product!'")

// Complex reasoning → Claude (best quality for hard tasks)
let analysis = try await ai.generate("Compare microservices vs monolith...")

// Code generation → Cloud provider with best code capability
let code = try await ai.generate("Write a binary search in Swift")

// All automatic. No manual routing. The router learns and improves.
```

### How It Works

The **RequestAnalyser** examines every prompt before routing:

1. **Complexity classification** — trivial, simple, moderate, complex, or expert
2. **Task detection** — classification, code generation, reasoning, translation, etc.
3. **Output estimation** — predicts response size based on task type
4. **Cost estimation** — calculates expected cost per provider

This analysis feeds into the Smart Router's scoring engine:

| Factor | What it measures |
|--------|-----------------|
| **Capability** | Can the provider handle this task? (tool calling, vision, etc.) |
| **Quality** | How good are the results? (uses cost as proxy) |
| **Latency** | How fast is the response? (instant → slow) |
| **Privacy** | Where does data go? (on-device → third-party cloud) |
| **Cost** | How much does it cost per request? (free → expensive) |
| **Complexity** | Simple tasks boost free providers; complex tasks boost cloud |
| **Performance** | Historical success rate and latency per provider |

Each factor produces a score, and the routing **strategy** applies different weights:

```swift
.smart               // Balanced across all factors (default)
.costOptimized       // Heavily weights cost — prefers free/cheap providers
.privacyFirst        // Heavily weights privacy — prefers on-device
.qualityFirst        // Heavily weights quality — prefers the most capable
.latencyOptimized    // Heavily weights speed — prefers the fastest
.fixed(.anthropic)   // Always use a specific provider
.priority([.ollama, .anthropic])  // Try in order, fail over to next
```

### Adaptive Routing

The router gets **smarter the more you use it**. The `ProviderPerformanceTracker` records real-world metrics for every request:

- **Success rate** per provider per task type
- **Latency** compared to the global average
- **Token throughput** for cost efficiency

After 10+ requests, the tracker starts adjusting routing scores:
- High success rate (>95%) → +10 score bonus
- Low success rate (<70%) → -20 score penalty
- Faster than average → +5 latency bonus
- Much slower (>2x average) → -10 penalty

Performance data persists across app launches via UserDefaults.

### Cost Estimation

Know what a request will cost **before sending it**:

```swift
let estimates = await ai.estimateCost("Write a detailed essay about AI")
for estimate in estimates {
    print("\(estimate.provider): $\(estimate.estimatedCost)")
}
// Anthropic: $0.0031
// OpenAI: $0.0024
// Gemini: $0.0012
// MLX: $0.0000
```

### Three-Tier Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  Intelligent Router                      │
│  ┌─────────┐ ┌──────────┐ ┌──────────┐ ┌────────────┐  │
│  │ Request  │ │Capability│ │ Provider │ │Environment │  │
│  │ Analyser │ │ Matcher  │ │ Tracker  │ │  Checks    │  │
│  └─────────┘ └──────────┘ └──────────┘ └────────────┘  │
└──────┬──────────────┬──────────────┬───────────────┬─────┘
       │              │              │               │
┌──────▼──────┐┌──────▼──────┐┌──────▼──────┐┌──────▼──────┐
│   Tier 1    ││   Tier 2    ││   Tier 3    ││   Tier 4    │
│  Apple FM   ││    MLX      ││   Ollama    ││   Cloud     │
│ Free, Fast  ││Free, Medium ││Free, Local  ││ Paid, Best  │
│  Limited    ││   Good      ││   Good      ││   Quality   │
└─────────────┘└─────────────┘└─────────────┘└─────────────┘
```

### Environment-Aware Adjustments

After scoring, the router adjusts for real-time conditions:

- **Offline?** Cloud providers are automatically removed
- **Thermal pressure?** Local model scores are halved (prefers cloud to avoid overheating)
- **Budget exhausted?** Cloud provider scores drop to zero

### Privacy Routing

Tag requests with privacy classifications to enforce routing rules:

```swift
// These tags force on-device routing automatically
let options = RequestOptions(tags: [.health])
let response = try await ai.generate("Analyze my blood pressure trends", options: options)

// Built-in tags: .private, .health, .financial, .personal
// Or define your own: RequestTag("legal")
```

The `PrivacyGuard` can also detect PII automatically:

```swift
let ai = Arbiter {
    $0.privacy(.strict)  // Enables PII detection (email, phone, SSN, credit card)
}
// Requests containing PII are automatically routed on-device
```

### Fallback Chain

When the top-scored provider fails, the router automatically tries alternatives:

```swift
let ai = Arbiter {
    $0.cloud(anthropicProvider)
    $0.cloud(openAIProvider)
    $0.local(OllamaProvider())
    $0.local(MLXProvider(.auto))
    $0.system(AppleFoundationProvider())
    $0.routing(.smart)  // fallbackEnabled is true by default
}
// If Anthropic is down → tries OpenAI → Ollama → MLX → Apple FM
```

### Cost Tracking

Arbiter tracks spend per provider and enforces budgets:

```swift
let ai = Arbiter {
    $0.spendingLimit(5.00, action: .fallbackToCheaper)
}
// When budget runs low, automatically switches to cheaper/free providers
```

## Per-Request Timeout

Override the default 30-second timeout for individual requests:

```swift
let options = RequestOptions(timeout: .seconds(60))
let response = try await ai.generate("Write a long essay", options: options)
```

## Retry Configuration

Configure automatic retries for single-provider setups:

```swift
let ai = Arbiter {
    $0.cloud(anthropicProvider)
    $0.retry(maxAttempts: 3, baseDelay: .milliseconds(500), maxDelay: .seconds(30))
}
```

## Provider Health Monitoring

Enable periodic availability checks to avoid routing to unhealthy providers:

```swift
let ai = Arbiter {
    $0.cloud(anthropicProvider)
    $0.local(OllamaProvider())
    $0.healthCheck(.enabled(interval: .minutes(5)))
}
```

## Supported Providers

| Provider | Status | Privacy | Capabilities |
|----------|--------|---------|--------------|
| Anthropic Claude | ✅ Ready | Cloud | Chat, Code, Vision, Tools |
| OpenAI GPT | ✅ Ready | Cloud | Chat, Code, Vision, Tools |
| Google Gemini | ✅ Ready | Cloud | Chat, Code, Vision, Tools |
| Ollama | ✅ Ready | Local Server | Chat, Code, Vision |
| MLX | ✅ Ready | On-Device | Chat, Code, Summarization |
| Apple Foundation Models | ✅ Ready | On-Device | Chat, Summarization, Tools |

## On-Device Providers

### MLX (Apple Silicon)

Runs open-source models locally via [mlx-swift](https://github.com/ml-explore/mlx-swift). Zero network, zero cost, complete privacy.

```swift
// Auto-select best model for this device
$0.local(MLXProvider(.auto))

// Or pick a specific model
$0.local(MLXProvider(.model("mlx-community/Qwen2.5-7B-Instruct-4bit")))
```

The MLX model registry automatically recommends models based on device RAM:

| Device RAM | Recommended Models | Parameters |
|-----------|-------------------|------------|
| 4-8 GB | SmolLM2, Qwen 2.5 0.5-3B, Llama 3.2 1-3B | 360M – 3B |
| 8-16 GB | Qwen 2.5 7B, Llama 3.1 8B, Mistral 7B, Gemma 2 9B | 7B – 9B |
| 16-32 GB | Qwen 2.5 14B, Mistral Nemo 12B | 12B – 14B |
| 32+ GB | Qwen 2.5 32B, Llama 3.3 70B | 32B – 70B |

### Apple Foundation Models

Uses Apple's built-in on-device model via the FoundationModels framework. Requires iOS 26+ / macOS 26+ with Apple Intelligence enabled.

```swift
$0.system(AppleFoundationProvider())
```

Check availability in SwiftUI:

```swift
Text("AI Feature")
    .appleFoundationAvailable {
        Text("Requires Apple Intelligence")
    }
```

## SwiftUI Components

Drop-in UI components that work with any Arbiter configuration.

### Chat Interface

```swift
import Arbiter

struct ContentView: View {
    let ai: Arbiter

    var body: some View {
        ArbiterChatView(ai: ai)
        // Or with a system prompt:
        // ArbiterChatView(ai: ai, systemPrompt: "You are a helpful assistant.")
    }
}
```

Features: message bubbles, streaming animation, provider badge on each response, error handling with retry button, dark mode support.

### Provider Picker

```swift
ProviderPicker(ai: ai) { selectedProvider in
    // Override routing for this session
}
```

Lists configured providers with real-time availability status and tier badges (Cloud/Local/On-Device/System).

### Usage Dashboard

```swift
UsageDashboard(analytics: analytics)
```

Shows total requests, tokens used, estimated cost, per-provider breakdown with bar charts, and month-over-month comparison.

### Routing Debug View

```swift
RoutingDebugView(router: ai.smartRouter)
```

Live feed of routing decisions — shows timestamp, selected provider, reason, fallbacks, contributing factors, detected complexity, detected task type, and estimated costs per provider.

### Lifecycle Management

```swift
ContentView()
    .swiftAILifecycle(ai)
```

Automatically unloads on-device models when the system reports memory pressure, freeing RAM for your app.

## Middleware

Process requests and responses through a configurable pipeline:

```swift
let ai = Arbiter {
    $0.cloud(anthropicProvider)
    $0.middleware(LoggingMiddleware(logLevel: .standard))
    $0.middleware(RequestSanitiserMiddleware(requestsPerMinute: 30))
}
```

### Request Sanitiser

Protects against prompt injection and abuse:
- Blocks prompts exceeding maximum length
- Detects known injection patterns ("ignore previous instructions", etc.)
- Rate limiting per minute
- Rejects empty or whitespace-only prompts

> **Note:** `MLXProvider` conforms to `UnloadableProvider` — on memory warnings,
> `LifecycleManager` automatically unloads cached models to free RAM.
> Implement `UnloadableProvider` on your own providers for the same behaviour.

### Logging Middleware

Structured logging with automatic credential redaction:
- API keys: `sk-ant-api03-...` → `sk-ant-***REDACTED***`
- Bearer tokens: `Bearer eyJ...` → `Bearer ***REDACTED***`
- Optional prompt text redaction for privacy-sensitive apps
- Configurable log levels: `.none`, `.minimal`, `.standard`, `.verbose`
- Output to `os.Logger` or custom destination

### Response Cache

In-memory or disk-backed cache to reduce API costs:
```swift
let cache = ResponseCache(maxEntries: 500, ttl: .seconds(300))
let diskCache = ResponseCache(maxEntries: 1000, ttl: .seconds(600), persistence: .disk)
```

### Usage Analytics

Cross-session usage tracking with SwiftUI binding:
```swift
let analytics = UsageAnalytics()
let snapshot = await analytics.snapshot() // UsageSnapshot is @Observable
```

## Why Arbiter?

### The Three-Tier Problem

Modern apps need AI from three different places:

1. **Cloud APIs** (Anthropic, OpenAI, Gemini) — most capable, but require network and cost money
2. **Local servers** (Ollama) — good for development and privacy, but need setup
3. **On-device models** (MLX, Apple Foundation Models) — instant, private, free, but less capable

Each has a different SDK, different data types, different error handling. Arbiter unifies all three behind a single protocol, so your app code stays clean regardless of which tier you're using.

## Installation

Add Arbiter to your project via Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/sabby3861/Arbiter.git", from: "0.1.0")
]
```

MLX support is included as an optional dependency — it compiles only on macOS and iOS with Apple Silicon. If mlx-swift is not resolved, the MLX provider gracefully reports as unavailable.

## Requirements

- Swift 6.0+
- iOS 17+ / macOS 14+ / visionOS 1+
- Xcode 16+
- MLX provider: Apple Silicon (M1+) with 4GB+ RAM
- Apple Foundation Models: iOS 26+ / macOS 26+ with Apple Intelligence enabled

## Security

Arbiter is designed with security defaults, not security afterthoughts.

**API key protection**: Keys are stored in the iOS Keychain by default.
Hardcoded key strings trigger a deprecation warning at compile time.

**Privacy routing**: Tag requests as `.private`, `.health`, or `.financial`
to ensure they never leave the device. The smart router enforces this.

**Spending limits**: Set monthly and per-request budget caps. When limits
are reached, Arbiter falls back to free on-device providers automatically.

**PII detection**: Optional prompt scanning catches email addresses, phone
numbers, and other patterns before they reach cloud APIs.

**Redacted logging**: API keys and sensitive headers are automatically
redacted in all log output.

**Request sanitization**: Built-in middleware catches prompt injection attempts
and enforces rate limits.

For production apps, we strongly recommend:
1. Use `SecureKeyStorage` (Keychain) instead of hardcoded API keys
2. Set up a server-side proxy for API calls (your key stays on your server)
3. Enable `.privacy(.strict)` for any app handling personal data
4. Set spending limits with `SpendingGuard`
5. Add `RequestSanitiserMiddleware` to catch injection attempts

See our [Security Guide](Documentation/SecurityGuide.md) for detailed best practices.

## Examples

Ready-to-run example projects in the [`Examples/`](Examples/) directory:

| Project | Description |
|---------|-------------|
| [BasicChat](Examples/BasicChat/) | Zero to working AI chat in under 15 lines of code |
| [MultiProvider](Examples/MultiProvider/) | Smart routing across Anthropic + OpenAI + Ollama with cost controls |
| [OnDeviceOnly](Examples/OnDeviceOnly/) | 100% on-device inference with MLX — no network required |
| [SmartRouting](Examples/SmartRouting/) | Live routing controls with debug view and usage dashboard |

Each example has its own `Package.swift` — clone, add your API key, and run.

## API Documentation

API docs are available via DocC:

```bash
swift package generate-documentation
```

## Roadmap

- [x] Core protocol layer
- [x] Anthropic Claude provider
- [x] OpenAI provider (including compatible APIs: Groq, Together, Perplexity)
- [x] Google Gemini provider
- [x] Ollama local provider
- [x] Streaming (SSE + NDJSON)
- [x] Tool calling / function calling
- [x] Conversation session management
- [x] Spending guards with budget enforcement
- [x] Keychain-based secure key storage
- [x] Smart Router with multi-factor scoring
- [x] Privacy Guard with PII detection
- [x] Cost tracking per provider
- [x] Fallback chain with automatic retry
- [x] Environment-aware routing (connectivity, thermal, budget)
- [x] MLX on-device provider
- [x] Apple Foundation Models provider
- [x] SwiftUI components (ChatView, ProviderPicker, UsageDashboard, RoutingDebugView)
- [x] Middleware pipeline (logging, sanitization, caching)
- [x] Usage analytics with cross-session persistence
- [x] Lifecycle management for on-device providers
- [x] Security documentation and proxy architecture guide
- [x] Structured output (typed Codable responses)
- [x] Request intelligence engine (complexity, task detection, cost estimation)
- [x] Adaptive routing (learns from usage patterns)
- [x] Pre-request cost estimation API
- [x] Per-request timeout configuration
- [x] Configurable retry engine
- [x] Disk-backed response cache
- [x] Provider health monitoring
- [x] Tool calling documentation
- [x] Response quality validation
- [x] Token budget planning
- [ ] v0.2 — MCP client support
- [ ] v0.2 — Certificate pinning for cloud providers
- [ ] v0.3 — Conversation persistence
- [ ] v0.3 — Function calling abstraction

## License

MIT — see [LICENSE](LICENSE) for details.

---

Built by [Sanjay Kumar](https://github.com/sabby3861) — Lead iOS Engineer, London | [Blog](https://medium.com/@sabby3861)
