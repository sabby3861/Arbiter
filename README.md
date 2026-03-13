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
    $0.routing(.preferLocal)
    $0.spendingLimit(5.00)
}

// SwiftAI picks the best available provider
let response = try await ai.generate("Hello!")

// Force privacy — only on-device/local providers
let options = RequestOptions(privacyRequired: true)
let privateResponse = try await ai.generate("Sensitive query", options: options)
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

## Supported Providers

| Provider | Status | Privacy | Capabilities |
|----------|--------|---------|--------------|
| Anthropic Claude | ✅ Ready | Cloud | Chat, Code, Vision, Tools |
| OpenAI GPT | ✅ Ready | Cloud | Chat, Code, Vision, Tools |
| Google Gemini | ✅ Ready | Cloud | Chat, Code, Vision, Tools |
| Ollama | ✅ Ready | Local Server | Chat, Code, Vision |
| MLX | Planned | On-Device | Chat, Code |
| Apple Foundation Models | Planned | On-Device | Chat |

## Why SwiftAI?

### The Three-Tier Problem

Modern apps need AI from three different places:

1. **Cloud APIs** (Anthropic, OpenAI, Gemini) — most capable, but require network and cost money
2. **Local servers** (Ollama) — good for development and privacy, but need setup
3. **On-device models** (MLX, Apple Foundation Models) — instant, private, free, but less capable

Each has a different SDK, different data types, different error handling. SwiftAI unifies all three behind a single protocol, so your app code stays clean regardless of which tier you're using.

### Smart Routing

SwiftAI automatically picks the best provider based on:
- **Privacy requirements** — sensitive data stays on-device
- **Cost budgets** — spending guards prevent bill shock
- **Availability** — fall back gracefully when providers are down

```swift
// Prefer local models, fall back to cloud
let ai = SwiftAI {
    $0.local(OllamaProvider())
    $0.routing(.preferLocal)
}

// Route to a specific provider
let options = RequestOptions(provider: .openAI)
let response = try await ai.generate("Hello!", options: options)
```

## Installation

Add SwiftAI to your project via Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/anthropics/SwiftAI.git", from: "0.1.0")
]
```

## Requirements

- Swift 6.1+
- iOS 17+ / macOS 14+ / visionOS 1+
- No external dependencies

## Security

- API keys stored in Keychain via `SecureKeyStorage`
- Spending guards to prevent budget overruns
- Privacy routing ensures sensitive data never leaves the device
- API keys automatically redacted from logs
- Compile-time deprecation warnings on raw API key strings

## Roadmap

- [x] Core protocol layer
- [x] Anthropic Claude provider
- [x] OpenAI provider (including compatible APIs: Groq, Together, Perplexity)
- [x] Google Gemini provider
- [x] Ollama local provider
- [x] Streaming (SSE + NDJSON)
- [x] Tool calling / function calling
- [x] Conversation session management
- [x] Spending guards
- [x] Keychain-based secure key storage
- [x] Multi-provider routing (first available, prefer local, prefer cloud, specific)
- [ ] MLX on-device provider
- [ ] Apple Foundation Models provider
- [ ] SwiftUI components

## License

MIT — see [LICENSE](LICENSE) for details.
