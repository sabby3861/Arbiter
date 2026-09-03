# Arbiter Provider Guide

Arbiter supports six providers across cloud, local, and system tiers. This guide covers setup for each one.

## Cloud Providers

### Anthropic

The highest-quality option for complex reasoning and long-form content.

- **Get a key**: [console.anthropic.com](https://console.anthropic.com)
- **Models**: `.claudeSonnet5` (default), `.claudeOpus5`, `.claudeFable51`, `.claudeHaiku45`.
  The models Anthropic still lists as Active while marking them legacy are here too:
  `.claudeFable5`, `.claudeOpus48`, `.claudeOpus47`, `.claudeOpus46`, `.claudeOpus45`,
  `.claudeSonnet46`, `.claudeSonnet45`. `AnthropicModel.isLegacy` tells them apart, and
  `AIRequest.model` takes a raw string for anything not listed.
- **Pricing**: $2 / $10 per million input / output tokens (Sonnet 5); $5 / $25 (Opus 5),
  $10 / $50 (Fable 5.1), $1 / $5 (Haiku 4.5)

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
- **Models**: `.gpt56Sol`, `.gpt56Terra`, `.gpt56Luna`, `.gpt5`, `.gpt5Mini`, `.gpt5Nano`,
  `.gpt41`, `.gpt41Mini`, `.gpt4o`, `.gpt4oMini`, `.o3`, `.o4Mini`, `.o3Mini`, `.o1`,
  `.gpt4Turbo`
- **Default model**: `.gpt4o`, which predates the current line-up — pass
  `model:` to route and price against a newer one (see the note below)
- **Pricing**: $4 / $20 per million input / output tokens (GPT‑5.6 Sol); $2 / $12 (Terra),
  $0.20 / $1.20 (Luna); $2.50 / $10 for the `.gpt4o` default

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
- **Models**: `.flash38`, `.flash37`, `.flash36`, `.flash35`, `.flashLite35`, `.flashLite31`, `.pro31Preview`, `.flash25`, `.flashLite25`, `.pro25`
- **Default model**: `.flash25`, which predates the current line-up — pass
  `model:` to route and price against a newer one (see the note below)
- **Pricing**: Free tier available; paid tier varies by model. The 3.6/3.7/3.8 Flash
  rate ($0.75 in / $3.75 out) is promotional through 31 December 2026 and doubles the
  next day; 3.5 Flash is on the standard $1.50 / $9.00 and does not change. The Pro
  models bill prompts over 200K tokens at a higher rate than
  `GeminiModel.costPerMillionInput` reports

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

### A note on default models

Every provider factory takes an optional `model:` (the provider initialisers spell it
`defaultModel:`). It is used for any request that does
not name a model of its own — and, more importantly, it is where
`capabilities.maxContextTokens` and the per-token costs the smart router scores on
come from. Anthropic's default moved forward with its catalogue; OpenAI's (`.gpt4o`)
and Gemini's (`.flash25`) did not, so a request routed under those defaults is scored
against a model a generation or more behind:

```swift
let ai = try Arbiter {
    try $0.cloud(.anthropic(from: .keychain))                              // .claudeSonnet5
    try $0.cloud(.openAI(from: .keychain, model: .gpt56Terra))
    try $0.cloud(.gemini(from: .keychain, model: .flash38))
}
```

Ollama's default is the model string `"llama3.2"`; pass any model you have pulled.

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
