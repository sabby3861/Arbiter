# Arbiter Provider Guide

Arbiter supports six providers across cloud, local, and system tiers. This guide covers setup for each one.

## Cloud Providers

### Anthropic

The highest-quality option for complex reasoning and long-form content.

- **Get a key**: [console.anthropic.com](https://console.anthropic.com)
- **Models**: `.claude4Sonnet`, `.claude4Opus`, `.claude45Haiku`
- **Pricing**: ~$3 per million input tokens, ~$15 per million output tokens (Sonnet)

```swift
// Store key once
try SecureKeyStorage.store(key: "sk-ant-...", for: .anthropic)

// Create Arbiter with Anthropic
let ai = try Arbiter {
    try $0.cloud(.anthropic(from: .keychain))
}
```

### OpenAI

Broad model selection with strong general-purpose performance.

- **Get a key**: [platform.openai.com](https://platform.openai.com)
- **Models**: `.gpt4o`, `.gpt4oMini`, `.gpt4Turbo`
- **Pricing**: ~$2.50 per million input tokens, ~$10 per million output tokens

```swift
// Store key once
try SecureKeyStorage.store(key: "sk-...", for: .openAI)

// Create Arbiter with OpenAI
let ai = try Arbiter {
    try $0.cloud(.openAI(from: .keychain))
}
```

### Gemini

Google's models with a generous free tier for experimentation.

- **Get a key**: [aistudio.google.com](https://aistudio.google.com)
- **Models**: `.flash25`, `.pro25`
- **Pricing**: Free tier available; paid tier varies by model

```swift
// Store key once
try SecureKeyStorage.store(key: "AI...", for: .gemini)

// Create Arbiter with Gemini
let ai = try Arbiter {
    try $0.cloud(.gemini(from: .keychain))
}
```

## Local Providers

### Ollama

Run open-source models locally. Free, private, and works offline once a model is downloaded.

- **Install**: Download from [ollama.com](https://ollama.com), then pull a model:
  ```bash
  ollama pull llama3.2
  ```
- **Models**: Any model from the Ollama library (llama3.2, mistral, phi3, etc.)
- **Pricing**: Free
- **Requirements**: Ollama must be running locally (`ollama serve`)

```swift
// No key needed
let ai = Arbiter {
    $0.local(OllamaProvider())
}
```

### MLX

Apple's machine learning framework for running models natively on Apple Silicon. Automatic model selection based on available memory.

- **Setup**: No manual setup required — models are downloaded automatically
- **Models**: Auto-selected based on device capabilities
- **Pricing**: Free
- **Requirements**: Apple Silicon (M1 or later), 4GB+ RAM

```swift
// No key needed, auto model selection
let ai = Arbiter {
    $0.local(MLXProvider(.auto))
}
```

## System Providers

### Apple Foundation Models

Apple's built-in on-device models, integrated with Apple Intelligence.

- **Setup**: No setup required — uses the system's built-in models
- **Models**: System-managed
- **Pricing**: Free
- **Requirements**: iOS 26+ (or macOS 26+), Apple Intelligence capable device

```swift
// No key, no download, just works
let ai = Arbiter {
    $0.system(AppleFoundationProvider())
}
```

## Multi-Provider Setup

The real power of Arbiter is combining providers. The smart router picks the best one for each request:

```swift
let ai = try Arbiter {
    // Cloud providers (best quality, requires network)
    try $0.cloud(.anthropic(from: .keychain))
    try $0.cloud(.openAI(from: .keychain))
    try $0.cloud(.gemini(from: .keychain))

    // Local providers (free, private, works offline)
    $0.local(OllamaProvider())
    $0.local(MLXProvider(.auto))

    // System provider (free, private, no setup)
    $0.system(AppleFoundationProvider())
}
```

With this configuration, Arbiter automatically routes each request to the best available provider based on capability, quality, latency, privacy, and cost. See [RoutingGuide.md](RoutingGuide.md) for details.

## Provider Comparison

| Provider | Tier | Key Required | Cost | Offline | Privacy |
|----------|------|-------------|------|---------|---------|
| Anthropic | Cloud | Yes | Paid | No | Data sent to cloud |
| OpenAI | Cloud | Yes | Paid | No | Data sent to cloud |
| Gemini | Cloud | Yes | Free tier | No | Data sent to cloud |
| Ollama | Local | No | Free | Yes | On-device |
| MLX | Local | No | Free | Yes | On-device |
| Apple FM | System | No | Free | Yes | On-device |
