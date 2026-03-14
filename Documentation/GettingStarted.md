# SwiftAI Getting Started

Go from an empty Xcode project to a working AI chat in under 10 minutes.

## 1. Add SwiftAI via Swift Package Manager

In Xcode: **File > Add Package Dependencies**, then paste:

```
https://github.com/sabby3861/SwiftAI.git
```

Set the version to **0.1.0** (or "Up to Next Major").

## 2. Import SwiftAI

```swift
import SwiftAI
```

## 3. Store Your API Key

SwiftAI keeps keys in the Keychain. Store your key once (e.g., during onboarding or from a server-provided token):

```swift
try SecureKeyStorage.store(key: "your-key", for: .anthropic)
```

## 4. Create a Provider

Pick the provider that fits your use case:

**Anthropic** (cloud, best quality):
```swift
let provider = try AnthropicProvider(keyStorage: .anthropic)
```

**OpenAI** (cloud):
```swift
let provider = try OpenAIProvider(keyStorage: .openAI)
```

**Ollama** (local, free — requires [ollama](https://ollama.com) running locally):
```swift
let provider = OllamaProvider()
```

## 5. Create a SwiftAI Instance

```swift
let ai = try SwiftAI {
    try $0.cloud(.anthropic(from: .keychain))
}
```

That single call sets up the provider, loads your Keychain key, and configures the smart router.

## 6. Option A: Drop-In Chat UI

For a complete chat interface with zero effort, use `SwiftAIChatView`:

```swift
import SwiftUI
import SwiftAI

@main
struct MyApp: App {
    let ai: SwiftAI

    init() {
        // In a real app, handle the error appropriately
        self.ai = (try? SwiftAI {
            try $0.cloud(.anthropic(from: .keychain))
        }) ?? SwiftAI(provider: OllamaProvider())
    }

    var body: some Scene {
        WindowGroup {
            SwiftAIChatView(ai: ai)
        }
    }
}
```

This gives you a full conversation UI with streaming responses, message history, and a text input field.

## 7. Option B: Call the API Directly

For programmatic access, use `ai.generate()`:

```swift
let response = try await ai.generate("Explain quantum computing")
// response.content contains the generated text
```

### Streaming Responses

```swift
for try await chunk in ai.stream("Tell me a story") {
    // chunk.delta contains the incremental text
}
```

### With Conversation History

```swift
let messages: [Message] = [
    .system("You are a helpful coding assistant."),
    .user("How do I sort an array in Swift?")
]

let response = try await ai.chat(messages)
```

## 8. Full Minimal Example

```swift
import SwiftUI
import SwiftAI

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ChatDemoView()
        }
    }
}

struct ChatDemoView: View {
    @State private var response = "Thinking..."

    var body: some View {
        Text(response)
            .padding()
            .task {
                do {
                    let ai = try SwiftAI {
                        try $0.cloud(.anthropic(from: .keychain))
                    }
                    let result = try await ai.generate("Say hello in 3 languages")
                    response = result.content
                } catch {
                    response = "Error: \(error.localizedDescription)"
                }
            }
    }
}
```

## Next Steps

- **[ProviderGuide.md](ProviderGuide.md)** — Setup details for every supported provider (Anthropic, OpenAI, Gemini, Ollama, MLX, Apple Foundation Models)
- **[RoutingGuide.md](RoutingGuide.md)** — How smart routing picks the best provider for each request
- **[SecurityGuide.md](SecurityGuide.md)** — API key protection, privacy routing, PII detection, and production hardening
