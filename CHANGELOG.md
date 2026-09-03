# Changelog

## [Unreleased] — next release is **0.2.0** (minor)

`ArbiterError` gained four cases — `contextWindowExceeded(_:limit:)`, `refused(_:explanation:)`,
`unsupportedLanguage(_:locale:)` and `busy(_:)`. Adding a case to a public enum is
source-breaking for any downstream `switch` over `ArbiterError` that has no `default:`, so
this is a minor version bump rather than a patch. Adding a `default:` (or the four new
cases) is the whole migration; no existing case changed shape.

### Added

- **Tool-execution loop.** `Arbiter.run(_:tools:maxToolRounds:options:)` sends the
  conversation, executes the tools the model calls and feeds the results back until it
  answers, returning a `RunResult` with the answer, the full conversation and a record of
  every call; `runStream` yields the same run as text-delta, tool-call-started,
  approval-requested and tool-result events, ending in the same `RunResult`. `maxToolRounds`
  (8 by default) bounds the loop, and reaching it ends the run with
  `RunResult.stoppedAtRoundLimit` set rather than looping on.
  Tools conform to the new `ArbiterTool` protocol (or use `FunctionTool`), which
  adds an `isConcurrencySafe` flag and a per-tool `timeout` to a `ToolDefinition`. Calls of
  one turn run concurrently; a tool that is not concurrency-safe runs alone while the calls
  around it keep the model's order. A tool that throws or overruns is reported to the model
  rather than ending the run. A tool returning `.requiresApproval(payload:)` suspends the
  run until `approve(_:)`/`deny(_:reason:)` answers the request published on
  `pendingApprovals`. The loop continues on `finishReason == .toolCall` only, so Apple
  Foundation Models' retrospectively-reported calls are never re-executed; tools are
  bridged into `AppleFMOptions.tools` so a run routed on-device runs them through the same
  approval, timeout and reporting path.

- **`MessageContent.thinking([ThinkingBlock])`.** Carries a thinking block's opaque
  `signature` and `redacted_thinking` payloads, so extended thinking survives a tool
  conversation: Anthropic requires them back unchanged and the loop now replays them. A
  block without a signature is dropped rather than sent to be rejected, which is what a
  streamed turn produces — combine thinking and tools through `run`, not `runStream`.

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
  falling through to a provider that could serve it. Reporting `false` is a *penalty*, not a
  veto: `CapabilityMatcher` zeroes only the capability term of a weighted score, and
  `SmartRouter.filterByConstraints` has no tool filter at all, so this provider loses a
  tool request to any provider reporting `true` but is still selected when it is the best
  candidate left — a setup registering it alone serves the request rather than reporting
  `.unavailable` (`Tool loop/aProviderReportingNoToolSupportIsPenalisedNotDisqualified`).
  Select it explicitly to be certain, which bypasses capability matching:

  ```swift
  try await ai.generate(prompt, options: .init(
      provider: .appleFoundation,
      tools: [weather.definition],
      providerOptions: [.appleFoundation: AppleFMOptions(tools: [weather])]
  ))
  ```

  `Arbiter.run(_:tools:)` supplies the bindings itself, so a run routed here works — but the
  flag still stays `false`, because routing happens before a `run` request is
  distinguishable from a bare `generate(options: .init(tools:))` carrying no executors,
  which a `true` would steer here to fail.

  Image input and Private Cloud Compute are not implemented: the installed macOS 26.5 SDK
  exposes neither, and `ProviderID.applePrivateCloud` is deliberately not added until there
  is a provider behind it.

- **Request Intelligence Engine**: `RequestAnalyser` classifies prompt complexity (trivial → expert), detects task type (classification, code generation, reasoning, etc.), and estimates output tokens before routing
- **Adaptive routing**: `ProviderPerformanceTracker` records real-world latency and success rates per provider per task type, adjusting routing scores after 10+ requests — the router gets smarter with usage
- **Pre-request cost estimation**: `Arbiter.estimateCost()` returns per-provider cost estimates without sending a request
- **Structured output**: `generate(_:as:)` and `chat(_:as:)` decode AI responses directly into typed Codable values with automatic JSON extraction and markdown fence stripping
- **ConversationSession structured output**: `session.send(_:as:using:)` for typed responses in conversations
- **Per-request timeout**: `RequestOptions(timeout:)` imposes a deadline on the whole attempt, on top of the 30-second `URLSession` request timeout each HTTP provider configures for itself
- **Retry configuration**: `Configuration.retry(maxAttempts:baseDelay:maxDelay:)` configures the RetryEngine — originally for single-provider setups; it now applies before fallback in any setup (see Changed)
- **Disk-backed response cache**: `ResponseCache(persistence: .disk)` stores cached responses in the Caches directory, auto-purged by the OS
- **Provider health monitoring**: `ProviderHealthMonitor` performs periodic availability checks with cached results, wired into SmartRouter scoring via `Configuration.healthCheck(.enabled(interval:))`
- **Tool calling documentation**: Complete end-to-end guide at `Documentation/ToolCallingGuide.md`
- **RoutingDebugView analysis display**: Shows detected complexity, task type, and per-provider cost estimates for each routing decision
- **RoutingDecision.analysis**: Full `RequestAnalysis` attached to every routing decision for transparency
- Runtime reliability layer: RetryEngine, ResponseCache, UsageAnalytics, and `FallbackChain` — the last a standalone component that nothing in the request path uses; provider failover is implemented in `Arbiter.performGenerate` itself
- Middleware pipeline: LoggingMiddleware, RequestSanitiserMiddleware
- LifecycleManager for on-device provider lifecycle (background/foreground/memory)
- SwiftUI components: ArbiterChatView, ProviderPicker, UsageDashboard, RoutingDebugView
- .swiftAILifecycle() view modifier
- Security documentation and proxy architecture guide
- RoutingDebugEntry for inspecting routing decisions
- **Response quality validator**: Detects empty, refused, truncated, and low-quality responses with automatic retry support — enable via `Configuration.responseValidation(.enabled)`
- **Token budget planner**: Prevents context window overflow by estimating token usage, suggesting fixes, and trimming conversations to fit — integrated into SmartRouter scoring and ConversationSession

### Changed

- **`generate(_:as:)` and `chat(_:as:)` use schema-constrained decoding where the provider
  supports it.** A JSON Schema is derived from the `Codable` type by the new
  `JSONSchemaBuilder` and sent to OpenAI (strict mode) and Apple Foundation Models
  (`GenerationSchema`); every other provider is asked in the prompt exactly as before. The
  form is chosen per provider *as the request is sent*, so fallback moving a request from
  one to the other stays correct. Types containing an enum, a dictionary or a
  self-reference cannot be probed and take the prompt path. A model that declines now
  throws `ArbiterError.refused` instead of `decodingFailed`.

  Gemini and Ollama are absent from the schema path because of Arbiter's own mappers, not
  their APIs: Gemini's puts the schema *string* into `responseSchema` where the API wants an
  object, and Ollama's ignores `.structured` entirely. Anthropic ships schema-constrained
  decoding too (`output_config.format`, GA — verified 2 September 2026) and its mapper sends
  nothing for `responseFormat` at all. Each joins when its mapper does; until then the
  prompt path is what works for them.

- **One execution precedence, applied everywhere: budget → privacy → health → in-provider
  retry → provider fallback** (`ExecutionPolicy`). Two behaviour changes fall out of it.
  In-provider retry used to be skipped whenever fallback was enabled; a transient failure
  now costs a retry against the same provider before it costs a provider, so a
  `Configuration.retry(...)` setup makes more attempts than it did. And a per-request
  `timeout` now applies *inside* each retry attempt rather than replacing retry, so each
  attempt gets its own deadline. The response-quality retry runs through the same execution
  path as the first attempt, so it is subject to the timeout, budget reservation and cost
  tracking it previously bypassed.

- `RoutingPolicy.maxRetries` is renamed `maxFallbackProviders` — it never retried anything.
  The old name and initialiser label still work, deprecated.

- **Token estimation counts a tool conversation.** `TokenEstimator` now reads tool-call
  arguments, tool results and replayed thinking as well as message text. `.mixed` turns
  previously scored a flat 100 tokens each, which is what an agent run is made of — so the
  budget guard and the context-window check were both reading a multi-round run as almost
  free.

- **A run that binds tools gets its own Apple Foundation Models session.** A cached session
  keeps the tools it was constructed with, and `sessionIdentity` cannot see a closure, so
  reusing one across two runs would have executed the second run's calls through the first
  run's executor. Passing a `conversationID` to a tool-carrying `run` therefore trades
  Apple's KV cache between turns for correct bookkeeping; a tool-free run is unaffected.

### Fixed
- Middleware now applied to both generate and streaming request paths
- ArbiterChatView retry button works correctly after failed requests
- Client-side rate limit no longer reports as Anthropic-specific error
- Response cache keys include topP and tool definitions
- Retry backoff with jitter no longer exceeds configured maxDelay
