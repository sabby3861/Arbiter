# Changelog

## [0.2.0] — 2026-09-03

**Migration.** Several public enums changed shape, so this is a minor version bump rather
than a patch.

- **`ArbiterError` gained six cases** — `overloaded(_:)`, `contextWindowExceeded(_:limit:)`,
  `refused(_:explanation:)`, `unsupportedLanguage(_:locale:)`, `busy(_:)` and
  `privacyViolation(detectedTypes:reason:)`. No existing case changed shape, so a
  `default:` (or the six new cases) is the whole migration for a `switch` over it.
- **`MessageContent` is a source break a `default:` does not fix.** The single-value cases
  `.toolCall(ToolCall)` and `.toolResult(ToolResult)` were *removed* and replaced by
  `.toolCalls([ToolCall])` and `.toolResults([ToolResult])`, so a turn can carry parallel
  calls. Deprecated static shims of the old names keep *construction* compiling —
  `MessageContent.toolCall(call)` still works — but a pattern match, `case .toolCall(let c):`,
  no longer compiles at all: rewrite it as `case .toolCalls(let calls):`. The enum also
  gained `.document(DocumentSource)` and `.thinking([ThinkingBlock])`.
- **`FinishReason` gained three cases** — `stopSequence`, `refusal` and `pauseTurn`. A
  `switch` over it needs the same treatment as `ArbiterError`.
- **`AnthropicModel`, `OpenAIModel` and `GeminiModel` were re-cut around the current
  line-ups**, so an exhaustive `switch` over any of the three needs the new cases (the
  per-provider entries under Added list them). Only `AnthropicModel` lost anything, and only one
  model: `.claude4Opus` is gone outright, because the ID it carried
  (`claude-opus-4-20250918`) names no model Anthropic has ever published. The other two
  old spellings were renames that kept their raw values — `.claude4Sonnet` →
  `.claudeSonnet4` (now deprecated and retired) and `.claude45Haiku` → `.claudeHaiku45`
  (still in the current lineup). `OpenAIModel` and `GeminiModel` only gained cases. `AIRequest.model` is a free-form
  string, so a model none of them names is still callable — it just does not get per-model
  rules.

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
  falling through to a provider that could serve it.

  **Correcting an earlier statement in this file: reporting `false` disqualifies, it does
  not merely penalise.** `CapabilityMatcher.score` does not zero one term of a weighted
  sum — it returns early with a score of 0 for the whole provider the moment a required
  capability is missing, before any weighting happens. `SmartRouter.buildDecision` then
  reports `.unavailable` for a best score of 0, and `Arbiter` turns that into
  `ArbiterError.allProvidersFailed`. Only a later *additive* adjustment brings a zeroed
  provider back. Two are gated on the `.smart` strategy and a device that is not thermally
  constrained — `applyComplexityAdjustments`' `+15` for an `.onDevice`/`.system` provider on
  a trivial or simple prompt, and `applyTaskAdjustments`' `+10` for a provider declaring
  `AITask.structuredOutput` on a structured-output task (Apple Foundation Models declares
  it; MLX does not). Two more are **ungated** and run under every strategy:
  `applyPerformanceAdjustments` contributes up to `+15` once a provider has ten or more
  recorded requests for the task, and `applyHealthAdjustments` contributes `+5` for any
  provider a configured health monitor has recorded as healthy. Any one of them lifts the
  score above zero. So the failure is a **cold-start, no-health-monitor** property: a setup
  registering Apple Foundation Models or MLX *alone* throws `allProvidersFailed` on a
  tool-carrying request under `.privacyFirst`, `.qualityFirst`, `.costOptimized` or
  `.latencyOptimized`, under thermal pressure, or on a complex non-structured prompt — but
  only while it is cold and unmonitored. `SmartRouter.filterByConstraints` has no tool
  filter, so nothing else is at work, and `.priority` routing skips `CapabilityMatcher`
  entirely, so none of this applies there.
  `Tool loop/aProviderReportingNoToolSupportIsDisqualifiedThenRescuedUnderSmartOnAShortPrompt`
  pins the one configuration that is rescued, not the general case; the score arithmetic
  itself is pinned by `Capability disqualification arithmetic/*`. The identical path fires
  for `supportsImageInput == false` on any request carrying an image.

  Turning this into a genuine penalty — a heavy score reduction rather than a
  disqualification, so a capable-enough provider stays in the running — is a roadmap item.
  It is a routing behaviour change and is deliberately **not** in 0.2.0.

  Until then, select the provider explicitly, which bypasses capability matching entirely:

  ```swift
  let weather = AppleFMToolBinding(definition: weatherTool) { arguments in
      lookupWeather(city: arguments["city"]?.stringValue ?? "")
  }

  try await ai.generate(prompt, options: .init(
      tools: [weatherTool],
      provider: .appleFoundation,
      providerOptions: [.appleFoundation: AppleFMOptions(tools: [weather])]
  ))
  ```

  `Arbiter.run(_:tools:)` supplies the bindings itself, so a run routed here works — but the
  flag still stays `false`, because routing happens before a `run` request is
  distinguishable from a bare `generate(options: .init(tools:))` carrying no executors,
  which a `true` would steer here to fail. A mixed setup is *not* immune, and it is worth
  being precise about why. Weighted scores normalise into roughly the 5–20 range, so the
  `+15` rescue is not a tie-breaker: a zeroed on-device provider rescued by it scores 15,
  ahead of a fully capable cloud provider on the same tool request (11.5 for a
  `$2`/`$10` third-party cloud model under `.balanced` weights —
  `Capability disqualification arithmetic/theOnDeviceBoostCanOutrankAFullyCapableCloudProvider`).
  So under `.smart` on a short prompt, the request is *attempted* on-device first. What
  recovers it is the fallback chain, not the score: the capable provider is next in the
  decision's alternatives, `performGenerate` falls over to it on any error, and a `run`
  routed on-device works anyway because it binds the executors. The costs are a wasted
  attempt, and a hard failure if fallback is switched off
  (`RoutingPolicy.fallbackEnabled == false`, which sets the attempt limit to one).

  Image input and Private Cloud Compute are not implemented: the installed macOS 26.5 SDK
  exposes neither, and `ProviderID.applePrivateCloud` is deliberately not added until there
  is a provider behind it.

- **Anthropic: thinking, prompt caching, documents and retry signals.** New
  `AnthropicOptions`, passed through `RequestOptions.providerOptions`, carries
  `thinking` (adaptive, or a fixed `budget_tokens`, validated against what each model
  accepts, with a `display` setting because current models omit the thinking text by
  default) and `promptCaching`, which places up to four `cache_control` breakpoints.
  `cache_control` token counts are parsed into `TokenUsage.cacheCreationInputTokens` /
  `cacheReadInputTokens` and priced into the cost estimate, so caching cannot hide spend
  from the budget guard. `MessageContent.document` sends a base64 PDF and `citations`
  blocks are parsed into `AIResponse.citations`. A 429 now carries its `Retry-After` delay
  and a 529 maps to the new retryable `ArbiterError.overloaded`. Multi-round tool history
  replays correctly, streamed `input_json_delta` arguments surface as completed calls, and
  URL images are downloaded and inlined rather than dropped. The model catalogue was
  replaced with the current lineup — `claude-sonnet-5` (now the default), `claude-opus-5`,
  `claude-fable-5-1` and `claude-haiku-4-5-20251001` — and now also carries the models
  Anthropic still lists as Active while marking them legacy: `claude-fable-5`,
  `claude-opus-4-8`, `-4-7`, `-4-6`, `claude-opus-4-5-20251101`, `claude-sonnet-4-6` and
  `claude-sonnet-4-5-20250929`, each with its own window, output cap, price, thinking mode
  and whether it accepts sampling controls. `AnthropicModel.isLegacy` reports which group a
  model is in.

- **OpenAI: strict structured outputs, reasoning models, Responses API, embeddings.**
  `ResponseFormat.structured(schema:)` is sent as
  `{"type":"json_schema","json_schema":{name,strict,schema}}`, normalised for strict mode by
  the new shared `JSONSchemaNormalizer`. Reasoning models are detected from the raw model ID:
  they take `max_completion_tokens`, drop sampling controls, and accept
  `OpenAIOptions.reasoningEffort`, validated against each model's published set.
  `OpenAIOptions.api = .responses` opts into the Responses transport (input items,
  `instructions`, flat tools, `text.format`, `max_output_tokens`, `reasoning.effort`);
  Chat Completions stays the default, and the Responses transport does not stream.
  Streaming gained `OpenAIStreamState`, which accumulates `delta.tool_calls` by index and
  captures the usage-only trailing chunk. A `refusal` field maps to `FinishReason.refusal`.
  The new `EmbeddingProvider` protocol is implemented over `POST /v1/embeddings`, and the
  model catalogue was replaced with the current line-up.

- **Gemini: v1beta, schema objects, thinking, grounding.** Requests go to `/v1beta`, which
  v1 needed for thinking configuration, the current tool set and any model past 2.5.
  `ResponseFormat.structured` reaches the API as a schema *object* under
  `generationConfig.responseFormat.text`. New `GeminiOptions` carries `thinking`
  (`thinkingLevel` on Gemini 3, `thinkingBudget` on the 2.5 series, validated per model so a
  mismatch throws locally rather than reaching a guaranteed 400), Google Search grounding,
  `safetySettings` and a `cachedContent` name. Thought summaries land in
  `reasoning`/`thinking` instead of the answer, `groundingMetadata` becomes
  `AIResponse.citations`, `functionCall` parts are parsed while streaming, and a turn replays
  with each call's `id` and `thoughtSignature` intact. A `STOP` that carries function calls
  is reported as `FinishReason.toolCall`, which Gemini never sends and the agent loop needs.
  The model catalogue was replaced from live docs.

- **Ollama: native tools, schema output, `keep_alive` / `think` / `num_ctx`, embeddings.**
  `tools` are sent in the documented function shape and `message.tool_calls` is read on both
  the non-streaming and NDJSON paths, so `supportsToolCalling` is now `true`. Ollama attaches
  no call id, so Arbiter synthesises `ollama-call-<turn>-<index>`. `.structured(schema:)` goes
  to `format` as a schema object. New `OllamaOptions(keepAlive:think:numCtx:)`;
  `message.thinking` lands in `AIResponse.reasoning`. `/api/embed` is implemented behind
  `EmbeddingProvider` — the model must be named, since a chat model cannot embed and the
  server has no default. A 404 becomes `modelNotFound` carrying the model name and a 503
  becomes `overloaded`.

- **Layered detection of sensitive data.** `PrivacyGuard`'s four regexes are replaced by
  `PIIDetector`: patterns for US Social Security numbers and payment cards (a Luhn check
  keeps a 16-digit order number from reading as a card), `NSDataDetector` for phone
  numbers, postal addresses and email addresses, and `NLTagger` name tagging for person,
  organisation and place names. A detector match overlapping a pattern match is dropped, so
  an SSN is reported as an SSN rather than as the phone number `NSDataDetector` reads it
  as. Detection now covers text `MessageContent.text` never surfaced — `.mixed` parts,
  tool-call arguments, tool results and replayed thinking blocks — and an image or PDF is
  recorded as content the guard could not read rather than passed over silently. An
  application can add its own `PrivacyClassifier` for categories Arbiter does not ship
  with; it receives the request's text, so it must run on device.

  Measured on the labelled corpus in `PrivacyDetectionCorpusTests` (macOS 26.5; CI runs on
  GitHub's unpinned `macos-latest`, so a run there may score differently): the pattern
  and `NSDataDetector` layers score 1.00 precision and 1.00 recall over 30 prompts; name
  tagging scores 0.69 and 1.00, with the tests enforcing floors of 0.60 and 0.90. Name
  tagging covers few languages (English and French on current macOS), so a prompt in a
  language it cannot handle is reported as reduced confidence rather than as unreadable —
  the deterministic layers are language-independent and still run.

- **`RoutingDecision.privacyReport`.** Every decision made under a `PrivacyGuard` carries a
  `PrivacyReport`: the categories detected, the request tags that matched, a
  `PrivacyDetectionConfidence`, and whether routing was constrained. Categories only — the
  report never carries a matched value, so it is safe to log or show in a debug view.
  `PrivacyGuard.assess(_:)` (async, consults the classifier) and `inspect(_:)` (synchronous,
  built-in layers only) return the same report directly.

- **On-device task-classifier hook.** `TaskClassifier` lets an on-device classifier — Apple
  Foundation Models' `.contentTagging` is the intended one — name a request's task before
  `RequestAnalyser`'s heuristics do, registered with `Configuration.taskClassification(_:)`.
  A verdict below 0.6 confidence, a `nil`, or a thrown error leaves the heuristics in
  charge, and a response schema outranks both. Arbiter ships the hook, not an adapter.

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
  `JSONSchemaBuilder` and sent to **all five schema-capable providers** — OpenAI (strict
  mode), Anthropic (`output_config.format`, `type: "json_schema"`), Gemini
  (`generationConfig.responseFormat.text`), Ollama (`format` as a schema object) and Apple
  Foundation Models (`GenerationSchema`). MLX is asked in the prompt: it runs an
  unconstrained local model and has no schema to send. The form is chosen per provider *as
  the request is sent*, so fallback moving a request between the two paths stays correct.
  Types containing an enum, a dictionary or a self-reference cannot be probed and take the
  prompt path. A model that declines now throws `ArbiterError.refused` instead of
  `decodingFailed`. The schema is passed through a per-provider pass of
  `JSONSchemaNormalizer` on the way out, because the five dialects differ in what they
  accept. On Ollama the JSON instruction stays in the prompt beside the schema, as Ollama's
  own guidance asks.

- **One execution precedence, applied everywhere: budget → privacy → health → in-provider
  retry → provider fallback** (`ExecutionPolicy`). Two behaviour changes fall out of it.
  In-provider retry used to be skipped whenever fallback was enabled; a transient failure
  now costs a retry against the same provider before it costs a provider, so a
  `Configuration.retry(...)` setup makes more attempts than it did. And a per-request
  `timeout` now applies *inside* each retry attempt rather than replacing retry, so each
  attempt gets its own deadline. The response-quality retry runs through the same execution
  path as the first attempt, so it is subject to the timeout, budget reservation and cost
  tracking it previously bypassed.

- **`PrivacyGuard.strict` now fails closed.** When nothing could read a request — an image
  or a PDF the guard cannot see inside, text with no determinable language, a
  `PrivacyClassifier` that could not answer — the assessment reports
  `PrivacyDetectionConfidence.unknown` and the request is kept off third-party cloud
  providers rather than let through. An app that registers only cloud providers therefore
  gets `ArbiterError.privacyViolation(detectedTypes:reason:)` thrown on requests `.strict`
  used to send, most visibly any request carrying an image or a document. Register an
  on-device or local provider, or construct the guard with `failClosed: false` to keep the
  previous behaviour. Fail-closed deliberately does *not* fire for a language the name
  tagger does not cover, or `.strict` would block every Spanish or Japanese prompt.

  The guard filters candidates during `.smart` and `.priority` routing. Naming a provider
  with `RequestOptions(provider:)` or `.fixed` routing still goes where it is told — the
  report is attached to the decision, but the caller's choice stands.

- **`PrivacyGuard.detectNames` defaults to `true`.** Any existing
  `PrivacyGuard(detectPII: true)` — including `.strict` — now treats person, organisation
  and place names as sensitive, so prompts that merely mention someone by name route
  on-device where they previously reached the cloud. Pass `detectNames: false` for the
  deterministic layers alone.

- **Complexity and task detection read the prompt's structure, not just its keywords.**
  `RequestAnalyser` measures sentences, verbs, clause markers, questions and fenced code
  with `NLTagger`, and raises a request one complexity tier — never more, never past
  `.complex` — when its shape is harder than its length and task label suggest: four or
  more sentences, three or more questions, a dense multi-clause instruction, or a pasted
  snippet of 20+ lines. A tier shift moves routing between the on-device and cloud
  boosts, so borderline requests may be routed differently than in 0.1. An unrecognised
  imperative ("turn these notes into a checklist") is now `shortGeneration` rather than
  `conversation`. Structural signals are measured on the conversation only — a system
  prompt is the app's own boilerplate and would otherwise bump every request under it.

- `RoutingPolicy.maxRetries` is renamed `maxFallbackProviders` — it never retried anything.
  The old name and initialiser label still work, deprecated.

- **Providers declare the tasks they actually serve.** `OpenAIProvider` and
  `OllamaProvider` now list `AITask.embedding` in `capabilities.supportedTasks`, which no
  provider declared even though both implement `EmbeddingProvider`; and `OllamaProvider`
  lists `.imageUnderstanding`, which it had omitted while `supportsImageInput` said `true`.
  Both are corrections to what a provider *says about itself*, not to what it does:
  `supportedTasks` has one consumer in the whole runtime — the structured-output score
  boost — and image eligibility is gated on the boolean, so no routing changes.

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
- **The spending guard no longer fails open under `.fallbackToCheaper`.** When that limit
  action was set and a request would breach the budget, the guard declined to reserve and
  the runtime sent the request anyway — it reached a paid provider unreserved, so real
  money was spent without being counted against the limit, and every later request was
  priced against a total that was too low. The refusal is now acted on: the request moves
  to the cheapest of its remaining fallback candidates whose estimated cost still fits,
  and is reserved and billed against *that* provider. If none fits — including when
  `fallbackEnabled` is off and there are no candidates behind the first — the request is
  refused with `budgetExceeded` (or `dailyLimitExceeded`, whichever limit stopped it)
  rather than sent. A provider refused on cost is neither recorded as having failed nor
  counted against `maxFallbackProviders`, since it was never called.
  `SpendingGuard.reserveBudget(estimatedCost:)` is unchanged for callers — it still returns
  `nil` under `.fallbackToCheaper` — but that `nil` means "refused", never "free to
  proceed".
- **Budget-exhausted streaming reports the routing outcome, not the limit.** Under a
  scored strategy (`.smart` and the other strategies that rank candidates), an exhausted
  budget now removes cloud providers from the routing decision itself, where a prompt
  classified as complex could previously win one of them back. In the case that produced
  — budget exhausted, complex prompt, only cloud providers registered — `stream` now
  fails with `allProvidersFailed`, the absence of a usable provider, rather than
  `budgetExceeded`. Callers matching on `budgetExceeded` to detect it should match
  `allProvidersFailed` as well. Unaffected: `.priority` (including the default
  `.firstAvailable`), `.fixed` and `RequestOptions(provider:)`, which do not score
  candidates and so never applied the exclusion — there the spending guard is still what
  reports the limit.
- Middleware now applied to both generate and streaming request paths
- ArbiterChatView retry button works correctly after failed requests
- Client-side rate limit no longer reports as Anthropic-specific error
- Response cache keys include topP and tool definitions
- Retry backoff with jitter no longer exceeds configured maxDelay
