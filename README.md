# SwiftAI

**One API for every AI — cloud, on-device, and Apple Intelligence.**

SwiftAI is a unified AI runtime for Swift that lets you call any AI provider through a single, consistent interface. Write your AI code once, then swap providers — or run them all simultaneously with intelligent routing.

## Quick Start

```swift
import SwiftAI

let ai = SwiftAI(provider: AnthropicProvider(apiKey: "your-key"))
let response = try await ai.generate("Explain Swift concurrency in one sentence.")
print(response.content)
```

## Multi-Provider Vision

```swift
let ai = SwiftAI {
    $0.cloud(AnthropicProvider(apiKey: anthropicKey))
    // $0.cloud(OpenAIProvider(apiKey: openAIKey))       // Coming soon
    // $0.local(OllamaProvider())                        // Coming soon
    // $0.system(AppleFoundationProvider())               // Coming soon
    $0.routing(.preferLocal)
    $0.spendingLimit(5.00)
}

// SwiftAI picks the best available provider
let response = try await ai.generate("Hello!")

// Force privacy — only on-device providers
let options = RequestOptions(privacyRequired: true)
let privateResponse = try await ai.generate("Sensitive query", options: options)
```

## Streaming

```swift
let stream = ai.stream("Write a haiku about Swift.")
for try await chunk in stream {
    print(chunk.delta, terminator: "")
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

| Provider | Status | Privacy | Type |
|----------|--------|---------|------|
| Anthropic Claude | ✅ Ready | Cloud | Chat, Code, Vision, Tools |
| OpenAI GPT | 🔜 Next | Cloud | Chat, Code, Vision, Tools |
| Google Gemini | 🔜 Planned | Cloud | Chat, Code, Vision |
| Ollama | 🔜 Planned | Local Server | Chat, Code |
| MLX | 🔜 Planned | On-Device | Chat, Code |
| Apple Foundation Models | 🔜 Planned | On-Device | Chat |

## Why SwiftAI?

### The Three-Tier Problem

Modern apps need AI from three different places:

1. **Cloud APIs** (Anthropic, OpenAI) — most capable, but require network and cost money
2. **Local servers** (Ollama) — good for development and privacy, but need setup
3. **On-device models** (MLX, Apple Foundation Models) — instant, private, free, but less capable

Each has a different SDK, different data types, different error handling. SwiftAI unifies all three behind a single protocol, so your app code stays clean regardless of which tier you're using.

### Smart Routing (Coming Soon)

SwiftAI will automatically pick the best provider based on:
- **Privacy requirements** — sensitive data stays on-device
- **Cost budgets** — spending guards prevent bill shock
- **Latency needs** — prefer local for real-time interactions
- **Capability matching** — route to providers that support the task
- **Availability** — fall back gracefully when providers are down

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

## Roadmap

- [x] Core protocol layer
- [x] Anthropic Claude provider
- [x] Streaming with SSE parsing
- [x] Conversation session management
- [x] Spending guards
- [ ] OpenAI provider
- [ ] Gemini provider
- [ ] Ollama provider
- [ ] MLX on-device provider
- [ ] Apple Foundation Models provider
- [ ] Smart routing engine
- [ ] SwiftUI components

## License

MIT — see [LICENSE](LICENSE) for details.
