# Changelog

## [Unreleased] — next release is **0.2.0** (minor)

`ArbiterError` gained four cases — `contextWindowExceeded(_:limit:)`, `refused(_:explanation:)`,
`unsupportedLanguage(_:locale:)` and `busy(_:)`. Adding a case to a public enum is
source-breaking for any downstream `switch` over `ArbiterError` that has no `default:`, so
this is a minor version bump rather than a patch. Adding a `default:` (or the four new
cases) is the whole migration; no existing case changed shape.

### Added

- **Apple Foundation Models — full native integration.** Conversation history now reaches
  the on-device model as a `Transcript` instead of only the latest user message, and
  `AppleFMOptions.conversationID` reuses one `LanguageModelSession` across turns so Apple's
  KV cache survives. `ResponseFormat.structured(schema:)` is compiled to a
  `GenerationSchema` and enforced by constrained decoding; `generate(_:as:)` and
  `streamGenerate(_:as:)` take a Swift `@Generable` type directly. Errors map to the typed
  `ArbiterError` cases above rather than all becoming `providerUnavailable`, and
  `AppleFMOptions.contextOverflow = .summarizeAndRetry` condenses older turns and retries
  once — the condensed history is then adopted for the rest of the conversation, so a
  summary is paid for once rather than every turn. `capabilities.maxContextTokens` reads
  the model's own `contextSize`, and token usage is *measured* with
  `SystemLanguageModel.tokenCount(for:)` on OS 26.4+ (Apple publishes no usage on its
  responses; below 26.4 `usage` is `nil` rather than estimated).
  `AvailabilityChecker.availability()` returns a typed reason, and
  `AppleFoundationProvider.feedback(forConversation:sentiment:issues:)` builds a
  `LanguageModelFeedback` attachment.

  **Tool semantics differ from the cloud providers, by design.** Apple executes tools
  *inside* `respond()` — there is no API that hands a pending call back — so a tool must be
  supplied with its executor via `AppleFMOptions.tools`, the turn always finishes
  `.complete` and never `.toolCall`, and `AIResponse.toolCalls` is a record of calls that
  have already run rather than calls for you to run. An agent loop must branch on
  `finishReason`, not on `toolCalls` being non-empty, or it will re-execute what the device
  already did.

  `capabilities.supportsToolCalling` stays `false`, because the router cannot inspect
  `providerOptions` and so cannot know whether a given request's tools have executors
  bound; reporting `true` would steer every tool request on-device, where a request whose
  tools are unbound fails with `invalidRequest` and stops the fallback chain instead of
  falling through to a provider that could serve it. `CapabilityMatcher` treats the flag as
  a hard disqualification, so a request carrying `tools` never selects this provider
  automatically — reach it by selecting it, which bypasses capability matching:

  ```swift
  try await ai.generate(prompt, options: .init(
      provider: .appleFoundation,
      tools: [weather.definition],
      providerOptions: [.appleFoundation: AppleFMOptions(tools: [weather])]
  ))
  ```

  The flag flips when the runtime's tool-execution loop can supply the bindings itself.

  Image input and Private Cloud Compute are not implemented: the installed macOS 26.5 SDK
  exposes neither, and `ProviderID.applePrivateCloud` is deliberately not added until there
  is a provider behind it.

- **Request Intelligence Engine**: `RequestAnalyser` classifies prompt complexity (trivial → expert), detects task type (classification, code generation, reasoning, etc.), and estimates output tokens before routing
- **Adaptive routing**: `ProviderPerformanceTracker` records real-world latency and success rates per provider per task type, adjusting routing scores after 10+ requests — the router gets smarter with usage
- **Pre-request cost estimation**: `Arbiter.estimateCost()` returns per-provider cost estimates without sending a request
- **Structured output**: `generate(_:as:)` and `chat(_:as:)` decode AI responses directly into typed Codable values with automatic JSON extraction and markdown fence stripping
- **ConversationSession structured output**: `session.send(_:as:using:)` for typed responses in conversations
- **Per-request timeout**: `RequestOptions(timeout:)` overrides the default 30-second timeout
- **Retry configuration**: `Configuration.retry(maxAttempts:baseDelay:maxDelay:)` configures the RetryEngine for single-provider setups
- **Disk-backed response cache**: `ResponseCache(persistence: .disk)` stores cached responses in the Caches directory, auto-purged by the OS
- **Provider health monitoring**: `ProviderHealthMonitor` performs periodic availability checks with cached results, wired into SmartRouter scoring via `Configuration.healthCheck(.enabled(interval:))`
- **Tool calling documentation**: Complete end-to-end guide at `Documentation/ToolCallingGuide.md`
- **RoutingDebugView analysis display**: Shows detected complexity, task type, and per-provider cost estimates for each routing decision
- **RoutingDecision.analysis**: Full `RequestAnalysis` attached to every routing decision for transparency
- Runtime reliability layer: FallbackChain, RetryEngine, ResponseCache, UsageAnalytics
- Middleware pipeline: LoggingMiddleware, RequestSanitiserMiddleware
- LifecycleManager for on-device provider lifecycle (background/foreground/memory)
- SwiftUI components: ArbiterChatView, ProviderPicker, UsageDashboard, RoutingDebugView
- .swiftAILifecycle() view modifier
- Security documentation and proxy architecture guide
- RoutingDebugEntry for inspecting routing decisions
- **Response quality validator**: Detects empty, refused, truncated, and low-quality responses with automatic retry support — enable via `Configuration.responseValidation(.enabled)`
- **Token budget planner**: Prevents context window overflow by estimating token usage, suggesting fixes, and trimming conversations to fit — integrated into SmartRouter scoring and ConversationSession

### Fixed
- Middleware now applied to both generate and streaming request paths
- ArbiterChatView retry button works correctly after failed requests
- Client-side rate limit no longer reports as Anthropic-specific error
- Response cache keys include topP and tool definitions
- Retry backoff with jitter no longer exceeds configured maxDelay
