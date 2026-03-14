# SwiftAI Security Guide

## Why API Keys in Mobile Apps Are Risky

Any API key shipped inside an iOS/macOS binary can be extracted through decompilation tools like `class-dump`, `Hopper`, or even simple `strings` inspection. **Never ship production API keys in your app binary.**

SwiftAI provides `SecureKeyStorage` (Keychain) to protect keys at rest, but the key still has to arrive on the device somehow. For production apps, use a server-side proxy.

## Recommended: Server-Side Proxy

The safest approach is to never send your real API key to the device at all. Instead, run a lightweight proxy server that holds the real key.

### How It Works

```
┌─────────────┐    proxy token     ┌──────────────┐   real API key   ┌───────────────┐
│  Your App   │ ───────────────▶   │  Your Server │ ──────────────▶  │  Anthropic    │
│  (SwiftAI)  │ ◀───────────────   │  (Proxy)     │ ◀──────────────  │  OpenAI, etc. │
└─────────────┘    AI response     └──────────────┘   AI response    └───────────────┘
```

### SwiftAI Configuration with Proxy

```swift
// Store your proxy token in the Keychain
try SecureKeyStorage.store(key: "your-proxy-token", for: .anthropic)

let ai = try SwiftAI {
    $0.cloud(try AnthropicProvider(
        keyStorage: .anthropic,
        baseURL: URL(string: "https://your-server.com/api/anthropic")
    ))
}
```

Your server holds the real API key. The app never sees it.

### Example Proxy Server (Vapor)

```swift
import Vapor

func routes(_ app: Application) throws {
    app.post("api", "anthropic", "**") { req -> Response in
        // Validate the proxy token from the app
        guard let token = req.headers.bearerAuthorization?.token,
              isValidProxyToken(token) else {
            throw Abort(.unauthorized)
        }

        // Forward to Anthropic with the real API key
        let anthropicURL = "https://api.anthropic.com" + req.url.path.replacingOccurrences(of: "/api/anthropic", with: "")
        var headers = req.headers
        headers.replaceOrAdd(name: "x-api-key", value: Environment.get("ANTHROPIC_API_KEY")!)

        return try await req.client.post(URI(string: anthropicURL), headers: headers) { proxyReq in
            proxyReq.body = req.body.data
        }
    }
}
```

### Managed Alternative: AIProxy

[AIProxy](https://www.aiproxy.pro) is a managed proxy service that handles key protection, rate limiting, and analytics. SwiftAI works with AIProxy out of the box:

```swift
// Store your AIProxy token in the Keychain
try SecureKeyStorage.store(key: "aiproxy-token", for: .openAI)

let ai = try SwiftAI {
    $0.cloud(try OpenAIProvider(
        keyStorage: .openAI,
        baseURL: URL(string: "https://api.aiproxy.pro/v1")
    ))
}
```

## Security Features in SwiftAI

### 1. Keychain Storage (Default)

```swift
// Store key in Keychain (do this once, e.g., from a server-provided token)
try SecureKeyStorage.store(key: apiKey, for: .anthropic)

// Use Keychain key (recommended)
let ai = try SwiftAI {
    try $0.cloud(.anthropic(from: .keychain))
}
```

### 2. Privacy Routing

Tag requests that must stay on-device. The smart router enforces this:

```swift
let response = try await ai.generate("Analyze my health data", options: RequestOptions(
    tags: [.health, .private],
    privacyRequired: true
))
// This request will NEVER be sent to a cloud provider
```

### 3. Spending Guards

```swift
let ai = SwiftAI {
    $0.cloud(anthropicProvider)
    $0.local(ollamaProvider)
    $0.spendingLimit(5.00, action: .fallbackToCheaper)
    // When budget is reached, routes to free local providers
}
```

### 4. PII Detection

```swift
let ai = SwiftAI {
    $0.cloud(anthropicProvider)
    $0.privacy(.strict)  // Scans for emails, SSNs, phone numbers, credit cards
}
// Requests containing PII are blocked from cloud providers
```

### 5. Request Sanitization

```swift
let ai = SwiftAI {
    $0.cloud(anthropicProvider)
    $0.middleware(RequestSanitiserMiddleware(
        maxPromptLength: 50_000,
        sanitiseInjections: true,
        requestsPerMinute: 30
    ))
}
```

### 6. Redacted Logging

```swift
let ai = SwiftAI {
    $0.cloud(anthropicProvider)
    $0.middleware(LoggingMiddleware(
        logLevel: .standard,
        redactKeys: true,     // API keys auto-redacted
        redactPrompts: true   // Prompt text replaced with [REDACTED: N chars]
    ))
}
```

## Production Checklist

1. **Use a server-side proxy** for all cloud API calls
2. **Store keys in Keychain** via `SecureKeyStorage`, never in code or plists
3. **Enable `.privacy(.strict)`** for apps handling personal data
4. **Set spending limits** to prevent runaway costs
5. **Add `RequestSanitiserMiddleware`** to catch injection attempts
6. **Enable `LoggingMiddleware`** with `redactKeys: true` (default)
7. **Tag sensitive requests** with `.private`, `.health`, or `.financial`
8. **Review App Transport Security** settings in your `Info.plist`
