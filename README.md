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

> **What's actually shipped?** [Documentation/FEATURE_STATUS.md](Documentation/FEATURE_STATUS.md)
> lists every feature as Shipped / Partial / Planned with the source file and the
> test that backs it.

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

> **Note:** text history reaches every provider, Apple Foundation Models included —
> a turn routed on-device is replayed as a `Transcript`, and passing a
> `conversationID` in `AppleFMOptions` reuses one session across turns so Apple's
> KV cache survives. Tool-call turns and image-URL messages are still dropped by
> some mappers, and MLX keeps text turns only. See
> [Feature Status](Documentation/FEATURE_STATUS.md).

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

**How it works today:** `generate(_:as:)` takes one of two paths, chosen per
provider. Where the provider can constrain decoding to a schema — OpenAI strict
mode, Anthropic's `output_config.format`, Gemini's
`generationConfig.responseFormat.text`, Ollama's `format` object and Apple
Foundation Models' `GenerationSchema`, which is all of them but MLX — Arbiter
derives a JSON Schema from your `Codable` type and sends that, so the model cannot
return a shape that does not fit. Everywhere else it asks for JSON in the prompt
(setting the provider's JSON mode where one exists), describing the shape with your
`example` value when you pass one. Both paths strip markdown fences and decode with
`JSONDecoder`; a malformed reply surfaces as `ArbiterError.decodingFailed` with the
raw content attached, and a model that declines as `ArbiterError.refused`.

Two things to know. The schema is derived by asking your type to decode itself
from a recording decoder, which works for structs of primitives, optionals, arrays
and nested structs — but not for a type containing an **enum**, a dictionary or a
self-reference; those fall back to the prompt path automatically, and passing an
`example` is then the most reliable option. And because fallback can move a request
to a provider that cannot be constrained, the form is chosen for whoever actually
serves the request, not once up front. MLX takes the prompt path: it runs an
unconstrained local model and has no schema to send. On Apple FM you can also hand a Swift
`@Generable` type straight to the provider's own `generate(_:as:)`.

## Tool Execution

`run(_:tools:)` sends the conversation, runs whatever tools the model calls, feeds
the results back and repeats until it answers:

```swift
let weather = FunctionTool(
    name: "get_weather",
    description: "Current conditions for a city",
    inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]]
) { arguments, _ in
    guard case .object(let fields) = arguments,
          case .string(let city)? = fields["city"] else { return "Unknown city" }
    return try await weatherService.summary(for: city)
}

let result = try await ai.run("Weather in Paris — do I need a coat?", tools: [weather])
print(result.content)          // the model's answer
print(result.invocations)      // every call it made, and what came back
```

The calls of one turn run concurrently; set `isConcurrencySafe: false` on a tool
that must not overlap others and it runs alone, in the order the model asked. Each
tool may set a `timeout`, and a tool that throws or overruns is reported to the
model — which can then explain or try something else — rather than aborting the
run. `maxToolRounds` (8 by default) bounds the loop; hitting it ends the run with
`stoppedAtRoundLimit` set.

**Human in the loop:** a tool that returns `.requiresApproval(payload:)` suspends
the run until someone answers:

```swift
for await request in await ai.pendingApprovals {
    if userConfirms(request.payload) {
        await ai.approve(request.id)
    } else {
        await ai.deny(request.id, reason: "not now")
    }
}
```

A denial is reported to the model as the call's result, so it can carry on without
that tool. `runStream(_:tools:)` yields the same run as events — text deltas, tool
calls started, approvals requested, results — finishing with the `RunResult`.

Apple Foundation Models runs tools inside its own session, so a run routed there
executes the same tools through the same approval, timeout and reporting path and
finishes in one round.

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
// One line per configured provider, priced from that provider's own
// per-million rates against the estimated token counts. On-device
// providers report $0.
```

### Three-Tier Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  Intelligent Router                     │
│  ┌─────────┐ ┌──────────┐ ┌──────────┐ ┌────────────┐   │
│  │ Request │ │Capability│ │ Provider │ │Environment │   │
│  │ Analyser│ │ Matcher  │ │ Tracker  │ │  Checks    │   │
│  └─────────┘ └──────────┘ └──────────┘ └────────────┘   │
└──────┬──────────────┬──────────────┬───────────────┬────┘
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

The `PrivacyGuard` can also detect sensitive data automatically:

```swift
let ai = Arbiter {
    $0.privacy(.strict)  // Layered detection + fail-closed routing
}
// Requests containing sensitive data are automatically routed on-device
```

Detection runs in layers: patterns for US Social Security and payment-card
numbers (Luhn-checked), `NSDataDetector` for phone numbers, postal addresses
and email addresses, and `NLTagger` name tagging for person, organisation and
place names. An app can add its own `PrivacyClassifier` for categories Arbiter
does not know about.

Name tagging covers fewer languages than the other layers (English and French
on current macOS), so a prompt in a language it cannot handle is reported as
reduced confidence, not as unreadable — the deterministic layers are
language-independent and still run.

`.strict` fails closed: when nothing could read the request at all — no
determinable language, an image or PDF the guard cannot see inside, a classifier
that could not answer — it stays off third-party clouds anyway, and throws
`ArbiterError.privacyViolation` if no on-device or local provider is
registered. Every decision carries a `PrivacyReport` listing the
*categories* detected, never the values:

```swift
let decision = await router.route(request, policy: .smart, providers: providers, budgetRemaining: nil)
decision.privacyReport?.sortedTypes   // [emailAddress, personName]
decision.privacyReport?.confidence    // .high / .heuristic / .unknown
```

**Two paths bypass the guard, by design.** It filters candidates during `.smart`
and `.priority` routing only.

- `RequestOptions(provider:)` returns a decision before the router runs. The guard
  does not merely lose its veto — it never runs at all, so `decision.privacyReport`
  is `nil` on an explicitly-routed request. Do not rely on it for audit logging
  there.
- `.fixed` routing sends the request to the named provider whatever the assessment
  says. Here the guard *does* run and the report is attached to the decision; only
  the routing choice is overridden.

If you name a cloud provider explicitly, nothing stops you. Request middleware also
runs *after* routing on the `generate` path, so text a middleware injects is not
assessed.

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

Put a deadline on an individual request. This is Arbiter's own timeout, applied to each
attempt on top of the 30-second `URLSession` request timeout the HTTP providers configure
for themselves — there is no Arbiter-level default to override:

```swift
let options = RequestOptions(timeout: .seconds(60))
let response = try await ai.generate("Write a long essay", options: options)
```

## Retry Configuration

Configure automatic retries. A transient failure is retried against the same provider
before the request moves on to the next one, so this applies whether or not fallback is
enabled:

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
| OpenAI GPT | ✅ Ready | Cloud | Chat, Code, Vision, Tools, Embeddings |
| Google Gemini | ✅ Ready | Cloud | Chat, Code, Vision, Tools |
| Ollama | ✅ Ready | Local Server | Chat, Code, Vision, Tools, Embeddings |
| MLX | ✅ Ready | On-Device | Chat, Code, Summarization |
| Apple Foundation Models | ✅ Ready | On-Device | Chat, Summarization, Structured Output |

> **On tools:** Anthropic, OpenAI, Gemini and Ollama accept tool definitions
> (`RequestOptions(tools:)`) and Arbiter parses the tool calls back out of
> non-streaming responses into `response.toolCalls`. On all four a full
> multi-round conversation replays correctly and streamed calls surface with parsed
> arguments; OpenAI's opt-in Responses transport does not stream at all. `run(_:tools:)` runs
> the execution loop on top of that — see [Tool Execution](#tool-execution) — so
> you only run the tools yourself if you call `generate`/`chat` directly. Ollama
> behaves the same way, with one wrinkle of its own: its API attaches no id to a
> tool call, so Arbiter synthesises one per turn and its `role: "tool"` replies
> correlate by tool name. MLX reports `supportsToolCalling == false`.
>
> Apple Foundation Models is the odd one out: it reports `false` too, but only
> because the router cannot see the executors you supply. `run(_:tools:)` supplies
> them for you, so a run that lands there works.
>
> **`false` disqualifies, it does not merely penalise.** A request carrying tools
> zeroes the *whole* score of any provider reporting `supportsToolCalling == false`,
> not one term of a weighted sum, and a best score of zero routes `.unavailable` —
> which surfaces as `ArbiterError.allProvidersFailed`. Four later score *additions*
> can rescue it. Two need `.smart` routing on a device that is not thermally
> constrained: `+15` to an `.onDevice`/`.system` provider for a prompt the analyser
> calls trivial or simple, and `+10` to a provider declaring `AITask.structuredOutput`
> on a structured-output task. Two are ungated and apply under every strategy: up to
> `+15` from recorded performance once a provider has ten or more requests behind it
> for that task, and `+5` for a provider a configured health monitor has found
> healthy. So if Apple FM or MLX is the *only* registered provider, a tool request
> throws under `.privacyFirst`, `.qualityFirst`, `.costOptimized` or
> `.latencyOptimized`, under thermal pressure, or on a complex non-structured prompt
> — **while the runtime is cold and no health monitor is configured.** Add a health
> monitor, or let it accumulate ten requests, and it is served under any strategy.
> The same path applies to a request carrying an image and a provider reporting
> `supportsImageInput == false`, and `.priority` routing skips capability matching
> altogether.
>
> A mixed setup is not immune either, though it recovers. `+15` is larger than the
> gap it closes — scores normalise into roughly the 5–20 range — so under `.smart`
> on a short prompt a rescued on-device provider can rank *ahead* of a fully capable
> cloud one and be tried first. The capable provider is next in the fallback chain,
> so the run still succeeds; what it costs is a wasted attempt, and a hard failure
> if you have turned fallback off.
>
> Route explicitly with `RequestOptions(provider: .appleFoundation)` when you mean
> to be certain — that bypasses capability matching entirely. (Making this a real
> penalty rather than a disqualification is a roadmap item; it changes routing
> behaviour and is not in 0.2.) Calling `generate` directly also means binding each
> `ToolDefinition` to a closure in `AppleFMOptions.tools` yourself:
>
> ```swift
> // `weather` is an AppleFMToolBinding: a ToolDefinition plus the closure that
> // runs it, because Apple executes tools inside `respond()`.
> let weather = AppleFMToolBinding(definition: weatherTool) { arguments in
>     lookupWeather(city: arguments["city"]?.stringValue ?? "")
> }
>
> let reply = try await ai.generate(prompt, options: .init(
>     tools: [weatherTool],
>     provider: .appleFoundation,          // routing would otherwise skip it
>     providerOptions: [.appleFoundation: AppleFMOptions(tools: [weather])]
> ))
> ```
>
> Apple runs the tools inside `respond()`, so the turn comes back `.complete`,
> never `.toolCall`, and `response.toolCalls` records what already ran rather than
> what you must run. See
> [Feature Status](Documentation/FEATURE_STATUS.md) for the per-provider detail
> and [Tool Calling Guide](Documentation/ToolCallingGuide.md) for the manual
> handling pattern.
>
> **On vision:** base64 image input is mapped to each provider's format. Image
> *URLs* are passed straight through to OpenAI (which fetches them itself) and are
> downloaded and inlined for Anthropic (capped at 5 MB, tested); Gemini and Ollama
> still drop them. Only the Anthropic image path has tests, so treat the other
> Vision cells as implemented but unverified — see
> [Feature Status](Documentation/FEATURE_STATUS.md).
>
> **On streaming:** Anthropic, Gemini, Ollama, MLX and Apple Foundation Models
> report `supportsStreaming` unconditionally. OpenAI reports its *default model's*
> `supportsStreaming` — every model in the catalogue streams today, so the flag is
> always `true`, but it is model-dependent by construction and a future model that
> does not stream would flip it. OpenAI's opt-in Responses transport does not
> stream on any model.
>
> **On default models:** a provider built without a model argument — `model:` on
> the factories, `defaultModel:` on the initialisers — uses
> `.claudeSonnet5` (Anthropic), `.gpt4o` (OpenAI), `.flash25` (Gemini) and
> `llama3.2` (Ollama). The OpenAI and Gemini defaults predate their refreshed
> catalogues, and the default is what `capabilities.maxContextTokens` and the cost
> estimate the router scores on are taken from — so pass `model:` if you want a
> current model's window and price:
>
> ```swift
> try $0.cloud(.openAI(from: .keychain, model: .gpt56Terra))
> ```
>
> **✅ Ready** means the provider is implemented and wired into routing, not that
> every capability in its row is test-covered; Feature Status has the per-feature
> evidence.

## Provider Options

Each cloud provider exposes its own controls through
`RequestOptions.providerOptions`, keyed by `ProviderID`. Everything below is
optional — a request that names none of it behaves exactly as before.

```swift
let reply = try await ai.generate(prompt, options: .init(
    providerOptions: [
        .anthropic: AnthropicOptions(
            thinking: .adaptive,   // or .extended(budgetTokens:) where the model takes one
            promptCaching: AnthropicPromptCaching(breakpoints: 2)
        )
    ]
))
```

| Type | Carries |
|------|---------|
| `AnthropicOptions` | `thinking` (validated per model), `thinkingDisplay`, `promptCaching` — at most four breakpoints. Document input with citations rides on `MessageContent.document` |
| `OpenAIOptions` | `reasoningEffort` for the o-series and GPT‑5 family (validated against each model's published set), `api = .responses` to opt into the Responses transport, `structuredOutputName` |
| `GeminiOptions` | `thinking` (`thinkingLevel` on Gemini 3, `thinkingBudget` on 2.5), `includeThoughts`, `googleSearch` grounding, `safetySettings`, `cachedContent` |
| `OllamaOptions` | `keepAlive`, `think`, `numCtx` |
| `AppleFMOptions` | `sampling`, `useCase`, `guardrails`, LoRA `adapter`, `prewarm`, on-device tool bindings, `conversationID`, `contextOverflow`, `locale`/`enforceLocale`, `reportTokenUsage` |

A model's reasoning comes back in `AIResponse.reasoning` (and as `.thinking`
content when it carries a replayable signature), grounding and document citations
in `AIResponse.citations`, and cache token counts in `TokenUsage`. See
[Feature Status](Documentation/FEATURE_STATUS.md) for what each one is tested
against.

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

`AppleFMOptions` exposes the framework's own controls — sampling mode, use case,
guardrails, a LoRA adapter, prewarming, on-device tool bindings, and an opt-in
summarise-and-retry strategy for context overflow:

```swift
let options = AppleFMOptions(
    conversationID: chat.id.uuidString,   // reuse one session across turns
    contextOverflow: .summarizeAndRetry   // condense old turns instead of failing
)
let reply = try await ai.generate(prompt, options: .init(
    providerOptions: [.appleFoundation: options]
))
```

Errors are mapped individually rather than flattened: a full context window surfaces as
`ArbiterError.contextWindowExceeded`, a refusal as `.refused`, an unsupported language as
`.unsupportedLanguage`, and a busy session as `.busy` — so the router can fall back on the
ones worth falling back on and retry the ones worth retrying.

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

`ResponseCache` is a standalone component you look up and populate yourself — it is
not yet wired into `Arbiter`'s request path, so configuring one does not
automatically cache anything.

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

- Swift 6.1+ (the package declares `swift-tools-version: 6.1`)
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
numbers, postal addresses, US Social Security numbers, payment-card numbers and
person/organisation/place names before they reach cloud APIs. The pattern and
`NSDataDetector` layers score 1.00 precision and recall on the labelled corpus
in `PrivacyDetectionCorpusTests`; name tagging is statistical — 0.69 precision
and 1.00 recall measured there on macOS 26.5, with the tests enforcing floors of
0.60 and 0.90 — and every one of its misses on that corpus is a false positive,
which keeps a request on-device rather than letting one out. It can also miss a
real name, and health terms and other domain vocabularies need your own
`PrivacyClassifier`, so treat detection as a strong safety net, not a
guarantee.

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

Guides: [Getting Started](Documentation/GettingStarted.md) ·
[Providers](Documentation/ProviderGuide.md) ·
[Routing](Documentation/RoutingGuide.md) ·
[Security](Documentation/SecurityGuide.md) ·
[Tool Calling](Documentation/ToolCallingGuide.md) ·
[Feature Status](Documentation/FEATURE_STATUS.md)

## Roadmap

Checked items are implemented; see
[Feature Status](Documentation/FEATURE_STATUS.md) for the test evidence behind each
one and for the known gaps.

- [x] Core protocol layer
- [x] Anthropic Claude provider
- [x] OpenAI provider (including compatible APIs: Groq, Together, Perplexity)
- [x] Google Gemini provider
- [x] Ollama local provider
- [x] Streaming (SSE + NDJSON)
- [x] Tool definitions passthrough
- [x] Tool execution loop *(parallel calls, per-tool timeouts, human-in-the-loop approval)*
- [x] Conversation session management
- [x] Spending guards with budget enforcement
- [x] Keychain-based secure key storage
- [x] Smart Router with multi-factor scoring
- [x] Privacy Guard with layered PII detection *(patterns, NSDataDetector, NLTagger names, pluggable classifier, fail-closed `.strict`, category-only `PrivacyReport`)*
- [x] Cost tracking per provider
- [x] Fallback chain with automatic retry
- [x] Environment-aware routing (connectivity, thermal, budget)
- [x] MLX on-device provider
- [x] Apple Foundation Models provider *(transcript history, constrained decoding, on-device tools, typed errors, measured token usage)*
- [x] SwiftUI components (ChatView, ProviderPicker, UsageDashboard, RoutingDebugView)
- [x] Middleware pipeline (logging, sanitization)
- [x] Usage analytics with cross-session persistence
- [x] Lifecycle management for on-device providers *(no dedicated test yet)*
- [x] Security documentation and proxy architecture guide
- [x] Structured output (typed Codable responses; schema-constrained on OpenAI, Anthropic, Gemini, Ollama and Apple Foundation Models, prompt-based JSON on MLX)
- [x] Schema derivation from `Codable` types *(enums, dictionaries and recursive types use the prompt path)*
- [x] Request intelligence engine (complexity, task detection, cost estimation)
- [x] Adaptive routing (learns from usage patterns)
- [x] Pre-request cost estimation API
- [x] Per-request timeout configuration *(no dedicated test yet)*
- [x] Configurable retry engine
- [x] Disk-backed response cache *(standalone component — not yet wired into the request path)*
- [x] Provider health monitoring *(no dedicated test yet)*
- [x] Tool calling documentation
- [x] Response quality validation
- [x] Token budget planning
- [ ] v0.2 — MCP client support
- [ ] v0.2 — Certificate pinning for cloud providers
- [ ] v0.3 — Conversation persistence

## Contributing

Contributions are welcome! Whether it's a bug fix, new feature, documentation improvement, or test coverage — every contribution helps.

### Getting Started

1. Fork the repository
2. Create your feature branch (`git checkout -b feat/your-feature`)
3. Make your changes and add tests
4. Run the test suite (`swift test`)
5. Commit your changes and push to your fork
6. Open a Pull Request against `main`

### Ways to Contribute

- **Good First Issues** — Check out issues labelled [`good first issue`](https://github.com/sabby3861/Arbiter/labels/good%20first%20issue) for beginner-friendly tasks
- **Feature Requests** — Have an idea? Open a [feature request](https://github.com/sabby3861/Arbiter/issues/new?template=feature_request.md)
- **Bug Reports** — Found a bug? Open a [bug report](https://github.com/sabby3861/Arbiter/issues/new?template=bug_report.md)
- **Documentation** — Improvements to guides, docstrings, or examples
- **New Providers** — Add support for additional AI providers

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

## License

MIT — see [LICENSE](LICENSE) for details.

---

Built by [Sanjay Kumar](https://github.com/sabby3861) — Lead iOS Engineer, London | [Blog](https://medium.com/@sabby3861)
