# SwiftAI

**One API for every AI — cloud, on-device, and Apple Intelligence.**

SwiftAI is a unified AI runtime for Swift that lets you call any AI provider through a single, consistent interface. Write your AI code once, then swap providers — or run them all simultaneously with intelligent routing.

## Quick Start

```swift
import SwiftAI

// Keychain-stored key (recommended)
let ai = try SwiftAI {
    try $0.cloud(.anthropic(from: .keychain))
}
let response = try await ai.generate("Explain Swift concurrency in one sentence.")
```

## Multi-Provider Setup

```swift
let ai = try SwiftAI {
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

// SwiftAI picks the best available provider
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

## Smart Router

The Smart Router is SwiftAI's core innovation — a multi-factor scoring engine that picks the best provider for every request based on real-time conditions.

### How It Works

For each request, the router evaluates every registered provider across five dimensions:

| Factor | What it measures |
|--------|-----------------|
| **Capability** | Can the provider handle this task? (tool calling, vision, etc.) |
| **Quality** | How good are the results? (uses cost as proxy) |
| **Latency** | How fast is the response? (instant → slow) |
| **Privacy** | Where does data go? (on-device → third-party cloud) |
| **Cost** | How much does it cost per request? (free → expensive) |

Each factor produces a score, and the routing **strategy** applies different weights:

```swift
// Strategies and what they prioritize:
.smart               // Balanced across all factors (default)
.costOptimized       // Heavily weights cost — prefers free/cheap providers
.privacyFirst        // Heavily weights privacy — prefers on-device
.qualityFirst        // Heavily weights quality — prefers the most capable
.latencyOptimized    // Heavily weights speed — prefers the fastest
.fixed(.anthropic)   // Always use a specific provider
.priority([.ollama, .anthropic])  // Try in order, fail over to next
```

### How Smart Routing Works — Concrete Example

When you send **"Classify this text as positive/negative"**, here's how the router decides:

| Provider | Capability | Quality | Latency | Privacy | Cost | **Total** |
|----------|-----------|---------|---------|---------|------|-----------|
| Apple FM | 10 (chat ✓) | 4 (free) | 16 (fast) | 20 (on-device) | 20 (free) | **14.0** |
| MLX | 10 (chat ✓) | 4 (free) | 10 (moderate) | 20 (on-device) | 20 (free) | **12.8** |
| Anthropic | 15 (chat+tools ✓) | 16 (premium) | 16 (fast) | 5 (cloud) | 8 (mid) | **12.0** |

Result: **Apple FM wins** — it's free, fast, on-device, and sufficient for classification.

For **"Write a production-grade REST API with error handling"**, the scores shift:

| Provider | Capability | Quality | Latency | Privacy | Cost | **Total** |
|----------|-----------|---------|---------|---------|------|-----------|
| Anthropic | 15 (tools ✓) | 16 (premium) | 16 (fast) | 5 (cloud) | 8 (mid) | **12.0** |
| MLX | 10 (code ✓) | 4 (free) | 10 (moderate) | 20 (on-device) | 20 (free) | **12.8** |
| Apple FM | 10 (no code gen) | 4 (free) | 16 (fast) | 20 (on-device) | 20 (free) | **14.0** |

With `.qualityFirst` strategy, quality weight triples → **Anthropic wins** for complex tasks.

### Three-Tier Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Smart Router                         │
│  ┌─────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐  │
│  │Capability│  │  Privacy  │  │  Budget  │  │ Thermal │  │
│  │ Matcher  │  │  Guard    │  │  Check   │  │  Check  │  │
│  └─────────┘  └──────────┘  └──────────┘  └─────────┘  │
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
let ai = SwiftAI {
    $0.privacy(.strict)  // Enables PII detection (email, phone, SSN, credit card)
}
// Requests containing PII are automatically routed on-device
```

### Fallback Chain

When the top-scored provider fails, the router automatically tries alternatives:

```swift
let ai = SwiftAI {
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

SwiftAI tracks spend per provider and enforces budgets:

```swift
let ai = SwiftAI {
    $0.spendingLimit(5.00, action: .fallbackToCheaper)
}
// When budget runs low, automatically switches to cheaper/free providers
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

Drop-in UI components that work with any SwiftAI configuration.

### Chat Interface

```swift
import SwiftAI

struct ContentView: View {
    let ai: SwiftAI

    var body: some View {
        SwiftAIChatView(ai: ai)
        // Or with a system prompt:
        // SwiftAIChatView(ai: ai, systemPrompt: "You are a helpful assistant.")
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

Live feed of routing decisions — shows timestamp, selected provider, reason, fallbacks, and contributing factors. Color-coded by provider tier.

### Lifecycle Management

```swift
ContentView()
    .swiftAILifecycle(ai)
```

Automatically pauses on-device providers when the app backgrounds, responds to memory warnings by unloading models, and resumes on foreground.

## Middleware

Process requests and responses through a configurable pipeline:

```swift
let ai = SwiftAI {
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

### Logging Middleware

Structured logging with automatic credential redaction:
- API keys: `sk-ant-api03-...` → `sk-ant-***REDACTED***`
- Bearer tokens: `Bearer eyJ...` → `Bearer ***REDACTED***`
- Optional prompt text redaction for privacy-sensitive apps
- Configurable log levels: `.none`, `.minimal`, `.standard`, `.verbose`
- Output to `os.Logger` or custom destination

### Response Cache

In-memory cache to reduce API costs:
```swift
let cache = ResponseCache(maxEntries: 500, ttl: .seconds(300))
```

### Usage Analytics

Cross-session usage tracking with SwiftUI binding:
```swift
let analytics = UsageAnalytics()
let snapshot = await analytics.snapshot() // UsageSnapshot is @Observable
```

## Why SwiftAI?

### The Three-Tier Problem

Modern apps need AI from three different places:

1. **Cloud APIs** (Anthropic, OpenAI, Gemini) — most capable, but require network and cost money
2. **Local servers** (Ollama) — good for development and privacy, but need setup
3. **On-device models** (MLX, Apple Foundation Models) — instant, private, free, but less capable

Each has a different SDK, different data types, different error handling. SwiftAI unifies all three behind a single protocol, so your app code stays clean regardless of which tier you're using.

## Installation

Add SwiftAI to your project via Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/anthropics/SwiftAI.git", from: "0.1.0")
]
```

MLX support is included as an optional dependency — it compiles only on macOS and iOS with Apple Silicon. If mlx-swift is not resolved, the MLX provider gracefully reports as unavailable.

## Requirements

- Swift 6.1+
- iOS 17+ / macOS 14+ / visionOS 1+
- MLX provider: Apple Silicon (M1+) with 4GB+ RAM
- Apple FM provider: iOS 26+ / macOS 26+ with Apple Intelligence enabled

## Security

SwiftAI is designed with security defaults, not security afterthoughts.

**API key protection**: Keys are stored in the iOS Keychain by default.
Hardcoded key strings trigger a deprecation warning at compile time.

**Privacy routing**: Tag requests as `.private`, `.health`, or `.financial`
to ensure they never leave the device. The smart router enforces this.

**Spending limits**: Set monthly and per-request budget caps. When limits
are reached, SwiftAI falls back to free on-device providers automatically.

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

## License

MIT — see [LICENSE](LICENSE) for details.
