# Arbiter — Feature Status

An honest, code-verified map of what Arbiter actually does today.

**Status meanings**

- **Shipped** — implemented and covered by a passing test in `Tests/ArbiterTests`.
- **Partial** — implemented, but narrower than the name suggests, or not covered by a dedicated test. The gap is named in the Evidence column.
- **Planned** — not implemented.

Evidence cites the implementing source file and the test that exercises it. Tests use
[swift-testing](https://github.com/swiftlang/swift-testing); a test is named either by its
function name or, where the suite uses display names, by the string in `@Test("…")`.

Last verified: 1 Sep 2026 · branch `fix/audit-v2` · `swift build && swift test` green (538 tests in 58 suites).

---

## Providers

| Feature | Status | Evidence (file + test name) |
|---|---|---|
| Anthropic — chat, code, summarization, translation | Shipped | `Providers/Anthropic/AnthropicProvider.swift`, `AnthropicMapper.swift` — `AnthropicMapperTests/buildSimpleRequestBody`, `parseSuccessResponse`, `buildMultiTurnRequest` |
| Anthropic — streaming (SSE) | Shipped | `AnthropicMapper.parseStreamEvent` — `AnthropicMapperTests/parseStreamContentDelta`, `parseStreamAccumulation`, `parseStreamMessageDeltaWithUsage`; streamed tool calls in `Anthropic — streaming tool input/streamedToolCallSurfacesWithParsedArguments` |
| Anthropic — vision (image input) | Shipped | `AnthropicMapper.imageContentBlock` maps `.base64`; `AnthropicImageResolver` downloads `.url` images and inlines them, rejecting oversized or unsupported files — `Anthropic — URL image resolution/urlImagesAreDownloadedAndInlined`, `inlinedImagesReachTheRequestBody`, `oversizedImagesAreRejected` |
| Anthropic — tool calling | Partial | Definitions sent (`AnthropicMapperTests/buildRequestWithTools`); parallel `tool_use` blocks parsed (`parseResponseWithToolUse`); multi-round history replays with results merged into one user turn and orphan results rejected (`Anthropic — tool history/multiRoundToolConversationReplays`, `resultsFromSeparateTurnsMergeIntoOneUserMessage`, `toolResultWithoutPrecedingCallIsRejected`); streamed `input_json_delta` arguments surface as completed calls (`Anthropic — streaming tool input/streamedToolCallSurfacesWithParsedArguments`). Still no execution loop — the caller runs the tools. (F8) |
| Anthropic — extended/adaptive thinking (single-turn) | Partial | The `thinking` parameter is built and validated per model, `display` is settable, and thinking text is parsed into `AIResponse.reasoning` — `Anthropic — advanced request options/adaptiveThinkingIsSentForCurrentModels`, `thinkingBudgetIsRejectedOnAdaptiveOnlyModels`, `Anthropic — review follow-ups/thinkingDisplayIsSentWhenRequested`, `Anthropic — response parsing/thinkingBlocksSurfaceAsReasoning`. **Thinking cannot be replayed:** the API requires a thinking block's opaque `signature` back unchanged on the next request of a tool-use conversation, and `MessageContent` has no case that can carry it — so thinking combined with a multi-round tool loop will be rejected on the second request. Single-turn thinking works. |
| Anthropic — prompt caching | Shipped | `AnthropicOptions.promptCaching` places up to four `cache_control` breakpoints; cache token counts parsed into `TokenUsage` — `Anthropic — advanced request options/promptCachingMarksSystemAndRecentMessages`, `promptCachingNeverExceedsFourBreakpoints`, `Anthropic — response parsing/cacheTokenCountsAreParsed` |
| Anthropic — document input + citations | Shipped | `.document` content maps to a base64 `document` block; `citations` blocks parsed into `AIResponse.citations` — `Anthropic — advanced request options/documentContentIsSentAsABase64DocumentBlock`, `Anthropic — response parsing/citationBlocksAreParsed` |
| Anthropic — retry signals (429 `Retry-After`, 529) | Shipped | `AnthropicProvider.mapHTTPError` — `Anthropic — HTTP errors/retryAfterSecondsBecomeTheRetryDelay`, `overloadedStatusMapsToARetryableError` |
| OpenAI — chat, code, summarization, translation | Shipped | `Providers/OpenAI/OpenAIProvider.swift`, `OpenAIMapper.swift` — `OpenAIMapperTests/buildSimpleRequest`, `parseSuccessResponse` |
| OpenAI — streaming (SSE) | Shipped | `OpenAIMapper.parseStreamEvent` — `OpenAIMapperTests/parseStreamContentDelta`, `parseStreamFinishReason`, `parseStreamDoneEvent` |
| OpenAI — vision (image input) | Partial | `OpenAIMapper.buildImageContentParts` — no image mapping test. |
| OpenAI — tool calling | Partial | Definitions sent (`OpenAIMapperTests/buildRequestWithTools`), calls parsed from non-streaming responses (`parseResponseWithToolCalls`). Streaming ignores `delta.tool_calls`; a `.toolCall` message maps to one call per message, so parallel calls cannot round-trip. No round-trip test. |
| OpenAI-compatible hosts (Groq, Together, Perplexity) | Partial | `OpenAIProvider` accepts a custom base URL; no test exercises a non-OpenAI host. |
| Gemini — chat, code, summarization, translation | Shipped | `Providers/Gemini/GeminiProvider.swift`, `GeminiMapper.swift` — `GeminiMapperTests/buildSimpleRequest`, `parseSuccessResponse`, `assistantMappedAsModel` |
| Gemini — streaming | Shipped | `GeminiMapper.parseStreamEvent` — `GeminiMapperTests/parseStreamDelta`, `parseStreamFinish` |
| Gemini — vision (image input) | Partial | `GeminiMapper` maps `.base64` to `inlineData`; `.url` images are skipped. No image mapping test. |
| Gemini — tool calling | Partial | Definitions sent (`GeminiMapperTests/buildRequestWithTools`), `functionCall` parsed from non-streaming responses (`parseResponseWithToolCall`). Streaming drops `functionCall` parts. No round-trip test. |
| Ollama — chat, code, summarization, translation | Shipped | `Providers/Ollama/OllamaProvider.swift`, `OllamaMapper.swift` — `OllamaMapperTests/buildSimpleChatBody`, `parseNonStreamingResponse` |
| Ollama — streaming (NDJSON) | Shipped | `OllamaMapper.parseStreamLine` — `OllamaMapperTests/parseStreamingChunk`, `parseStreamAccumulation`, `parseStreamingDone` |
| Ollama — vision (image input) | Partial | `capabilities.supportsImageInput` is `true` and `OllamaMapper` sends `.base64` images in `images`; `.url` images are replaced with empty content. `supportedTasks` omits `.imageUnderstanding`, but `CapabilityMatcher` gates image requests on `supportsImageInput`, so Ollama stays eligible for vision requests. No image mapping test. |
| Ollama — tool calling | Planned | `OllamaProvider.capabilities.supportsToolCalling == false`; no `tools` mapping. (F6) |
| MLX — on-device chat, code, summarization | Partial | `Providers/MLX/MLXProvider.swift` (real path under `#if canImport(MLX) && canImport(MLXLLM)`, stub otherwise) — `MLXProviderTests/providerHasCorrectId`, `providerCapabilitiesAreOnDevice`, `stubProviderReportsUnavailable`. Tests exercise the stub path and configuration; generation itself is untested in CI. |
| MLX — device-aware model registry | Shipped | `MLXModelRegistry.swift` — `MLXModelRegistryTests/registryRecommendsTinyModelForSmallDevice`, `registryRecommendsMediumModelForMediumDevice`, `registryRecommendsLargeModelForLargeDevice` |
| MLX — memory-pressure unload (`UnloadableProvider`) | Partial | `MLXProvider` conforms to `UnloadableProvider`; `Runtime/LifecycleManager.swift` drives it. No test. |
| MLX — tool calling / vision | Planned | `MLXProviderTests/providerDoesNotSupportToolCalling`, `providerDoesNotSupportImageInput` |
| Apple Foundation Models — chat, summarization, translation | Partial | `Providers/AppleFoundation/AppleFoundationProvider.swift` — `AppleFoundationProviderTests/providerSupportsChatAndSummarization`, `providerCapabilitiesAreOnDevice`. Only the availability/stub path is testable off-device (`stubProviderReportsUnavailable`). |
| Apple Foundation Models — multi-turn history | Planned | `AppleFoundationProvider.latestUserMessage` sends only the most recent user message and creates a fresh `LanguageModelSession` per call; no `Transcript` is built. (F7-A) |
| Apple Foundation Models — tool calling | Planned | `capabilities.supportsToolCalling == false` — `AppleFoundationProviderTests/providerDoesNotSupportToolCalling` |
| Apple Foundation Models — vision | Planned | `AppleFoundationProviderTests/providerDoesNotSupportImageInput` |
| Apple Foundation Models — native constrained decoding (`@Generable`) | Planned | `capabilities.supportedTasks` includes `.structuredOutput`, but generation goes through the shared prompt-based path in `Core/StructuredOutput.swift`. (F7-D) |
| Apple Foundation Models — typed error mapping | Planned | Every error except `CancellationError` becomes `ArbiterError.providerUnavailable` in both `generate` and `performStream`. (F7-C) |
| Apple Foundation Models — availability check | Shipped | `AvailabilityChecker.swift` — `AvailabilityCheckerTests/availabilityCheckReturnsBoolean`, `unavailableReasonReturnsString` |

## Core

| Feature | Status | Evidence (file + test name) |
|---|---|---|
| Unified `AIProvider` protocol / unified response type | Shipped | `Core/AIProvider.swift`, `Core/AIResponse.swift` — `UnifiedResponseTests/allProvidersProduceAIResponse`, `allProvidersProduceStreamChunks` |
| Unified streaming chunks | Shipped | `Core/AIStreamChunk.swift` — `UnifiedResponseTests/allProvidersProduceStreamChunks`, `ArbiterTests/streamResponse` |
| Request builder | Shipped | `Core/AIRequest.swift` — `AIRequestTests/chatBuilderCreatesUserMessage`, `builderChaining`, `builderIsImmutable` |
| Message model (text, image, tool call, tool result, mixed) | Partial | `Core/Message.swift` — `MessageTests/textMessageCodableRoundTrip`, `toolCallCodable`, `toolResultCodable`. `.toolCall` holds a single call, so parallel tool calls cannot be represented. (F2) |
| `JSONValue` | Shipped | `Core/JSONValue.swift` — `JSONValueTests/objectRoundtrip`, `nestedStructureRoundtrip`, `equatableAndHashable` |
| Structured output (typed `Codable` responses) | Partial | `Core/StructuredOutput.swift` + `Arbiter.generate(_:as:)`. Prompt-instructed JSON: the request sets `responseFormat = .json`, the type (or an example value) is described in the prompt, and the reply is parsed with `JSONDecoder` after markdown-fence stripping. Not schema-constrained decoding. `StructuredOutputTests/"Full generate<T> with MockProvider returning valid JSON"`, `"Decode strips markdown fences"`, `"Decode throws decodingFailed with raw content on bad JSON"` |
| `ResponseFormat.json` wire mapping | Shipped | `OpenAIMapperTests/buildRequestWithJSONMode`, `GeminiMapperTests/jsonModeConfig`, `OllamaMapperTests/buildRequestWithJSONFormat` |
| `ResponseFormat.structured(schema:)` wire mapping | Planned | Accepted by the public API but never reaches a provider correctly: `OpenAIMapper.mapResponseFormat` and `GeminiMapper.applyResponseFormat` send the schema as a *string* where the API expects an object (and OpenAI's required `name`/`strict` keys are absent); `AnthropicMapper` ignores `responseFormat` entirely; `OllamaMapper` only handles `.json`. (F4, F5, F6) |
| Error taxonomy | Shipped | `Core/ArbiterError.swift` — `ArbiterErrorTests/allCasesHaveRecoverySuggestion` and per-case description tests |
| Provider error mapping | Shipped | `ProviderErrorTests/openAIContentFilterFinishReason`, `geminiSafetyFilter`, `anthropicToolUseStopReason`, `ollamaStreamInvalidJSON` |
| Token estimation | Shipped | `TokenEstimator` in `Core/AIRequest.swift` — `TokenEstimatorTests/estimateTokensForMessages`. Character-based approximation (1 token ≈ 4 characters), not a real tokenizer. |
| Token budget planning | Shipped | `Core/TokenBudgetPlanner.swift` — `TokenBudgetPlannerTests/"Long request exceeds small context window"`, `"trimToFit removes oldest messages first"` |
| Tool-execution loop (run tools, feed results back) | Planned | No loop exists; `Arbiter` returns `response.toolCalls` to the caller. (F8) |

## Routing

| Feature | Status | Evidence (file + test name) |
|---|---|---|
| Smart Router with multi-factor scoring | Shipped | `Router/SmartRouter.swift`, `CapabilityMatcher.swift` — `SmartRouterTests/smartRouteSelectsBestProvider`, `smartRoutePopulatesCandidateScores`, `CapabilityMatcherTests/balancedWeightsProducePositiveScore` |
| Routing strategies (cost / privacy / quality / latency / fixed / priority) | Shipped | `SmartRouterTests/costOptimizedPrefersFreeTier`, `qualityFirstPrefersExpensiveProvider`, `latencyOptimizedPrefersFastProvider`, `fixedRouteSelectsSpecificProvider`, `priorityRouteRespectsOrder` |
| Request analysis (complexity, task, output size) | Partial | `Router/RequestAnalyser.swift` — `RequestAnalyserTests/"'Is this positive or negative?' → trivial, classification"`, `"'Write a Swift function that sorts' → complex, codeGeneration"`, `"Code with code fences detected"`. Detection is keyword/length heuristics, not a model. (F9) |
| Pre-request cost estimation | Shipped | `Arbiter.estimateCost` — `CostEstimateTests/"Estimates include all registered providers"`, `"wouldBeSelected is true for exactly one provider"` |
| Adaptive routing from recorded performance | Shipped | `Router/ProviderPerformanceTracker.swift` — `ProviderPerformanceTrackerTests/"High success rate gives positive adjustment"`, `"Minimum sample size of 10 before adjustments activate"`, `"Data persists across tracker instances"`; `SmartRouterTests/routerPrefersProviderWithHigherSuccessRate` |
| Environment-aware routing (offline, thermal, budget) | Shipped | `SmartRouterTests/offlineRemovesCloudProviders`, `thermalPressurePrefersCloud`, `budgetExhaustedRemovesCloud`; `ThreeTierRoutingTests/offlineFallsBackToLocalProviders` |
| Device assessment | Shipped | `Router/DeviceAssessor.swift` — `DeviceAssessorTests/canRunLocalModelsRequires4GBAndNonCritical`, `recommendedLocalTierBasedOnMemory` |
| Context-window filtering | Shipped | `SmartRouterTests/smartRouteExcludesProviderWhenRequestExceedsContext` |
| Privacy tag routing (`.private`, `.health`, `.financial`, `.personal`, custom) | Shipped | `Router/PrivacyGuard.swift` — `PrivacyGuardTests/healthTagForcesLocal`, `financialTagForcesLocal`, `customTagInCustomSet`; `IntegrationTests/tagsRouteToLocalProvider`, `tagsWithOnlyCloudFails` |
| PII detection | Partial | `PrivacyGuard` uses four regexes — email, phone, SSN, credit card: `PrivacyGuardTests/detectsEmailAddress`, `detectsPhoneNumber`, `detectsSSN`, `detectsCreditCard`, `detectsPIIInSystemPrompt`. Names, addresses and health terms are not detected, so `.strict` fails open for them. (F9) |
| Fallback chain | Shipped | `Runtime/FallbackChain.swift` — `FallbackChainTests/"Falls back to secondary on primary failure"`, `"Does not fallback on permanent errors"`, `"Respects maxFallbacks limit"`; `IntegrationTests/streamingFallbackToSecondProvider` |
| Provider health monitoring | Partial | `Router/ProviderHealthMonitor.swift`, wired via `Configuration.healthCheck` and consumed by `SmartRouter`. No test covers it. |

## Runtime & security

| Feature | Status | Evidence (file + test name) |
|---|---|---|
| Cost tracking per provider | Shipped | `Router/CostTracker.swift` — `CostTrackerTests/recordUsageAccumulatesSpend`, `perProviderSpendTracking`, `estimateRequestCostCalculation` |
| Spending guard (per-request, daily, monthly, fallback action) | Shipped | `Security/SpendingGuard.swift` — `SpendingGuardAdvancedTests/perRequestLimitBlocks`, `dailyRequestLimitThrowsDailyLimitExceeded`, `fallbackToCheaperActionFallsBack`, `reservationFinalizationAdjustsTotal`; `ConcurrencyTests/spendingGuardAtomicReservation` |
| Keychain key storage | Shipped | `Security/SecureKeyStorage.swift` — `SecureKeyStorageTests/storeAndRetrieveRoundtrip`, `overwriteExistingKey`, `deleteRemovesKey` |
| Retry engine (exponential backoff, `Retry-After`) | Shipped | `Runtime/RetryEngine.swift` — `RetryEngineTests/"Retries on transient failure then succeeds"`, `"Backoff delay increases exponentially"`, `"Rate limit uses Retry-After header"` |
| Per-request timeout | Partial | `Arbiter.withTimeout` applies `RequestOptions.timeout`. Only the error description is tested (`ArbiterErrorTests/timeoutHasDescription`); no test exercises an actual timeout. |
| Cancellation propagation | Shipped | `ConcurrencyTests/taskCancellationPropagates`, `streamCancellationStopsYielding`, `spendingGuardReservationReleaseOnCancel` |
| Response validation / quality retry | Shipped | `Runtime/ResponseValidator.swift` — `ResponseValidatorTests/"Refused response detected at start of content"`, `"Truncated response detected on maxTokens without punctuation"`, `"Very short response triggers retryRecommended"`; `ArbiterTests/validationEnabledRejectsRefusedResponse`, `customValidatorIsUsed` |
| Response cache (memory + disk) | Partial | `Runtime/ResponseCache.swift` — `ResponseCacheTests/"Cache hit returns stored response"`, `"Evicts oldest entries when at capacity"`, `"Disk cache persists across instances"`. The type is fully tested but nothing in `Sources/Arbiter` references it: it is a standalone component you drive yourself, not an automatic cache in the request path. |
| Usage analytics with cross-session persistence | Shipped | `Runtime/UsageAnalytics.swift` — `UsageAnalyticsTests/"Summary groups by provider"`, `"Snapshot provides current and previous month data"` |
| Lifecycle management (unload on memory pressure) | Partial | `Runtime/LifecycleManager.swift` + `UnloadableProvider`. Only the SwiftUI modifier's initialisation is tested (`ViewCompilationTests/"Lifecycle modifier takes Arbiter instance"`); the unload path has no test. |
| Middleware pipeline | Partial | `Middleware/AIMiddleware.swift` — `ViewCompilationTests/"Configuration supports middleware"` only registers middlewares on a `Configuration`; the individual middlewares are tested in isolation below, but `Arbiter.applyRequestMiddleware` is exercised by no test. |
| Request sanitiser (length + injection patterns) | Shipped | `Middleware/RequestSanitiserMiddleware.swift` — `RequestSanitiserMiddlewareTests/"Rejects prompt exceeding max length"`, `"Detects injection patterns"`, `"Rejects empty prompt"` |
| Request sanitiser (rate limiting) | Partial | The `RateLimiter` actor is only constructed when `requestsPerMinute` is non-nil; no test passes that argument. |
| Logging middleware with credential redaction | Shipped | `Middleware/LoggingMiddleware.swift` — `LoggingMiddlewareTests/"Redacts API keys"`, `"Redacts bearer tokens"`, `"Redacts OpenAI-style keys"` |
| Conversation session (multi-turn, `@Observable`) | Partial | `Session/ConversationSession.swift` — `ConversationSessionTests/multiTurnConversation`, `sendAppendsUserAndAssistantMessages`, `trimToFitTokenWindowRemovesOldMessages`, `streamingAppendsAssistantMessage`. History is dropped when a turn is routed to Apple Foundation Models (see the provider row above). |

## SwiftUI

| Feature | Status | Evidence (file + test name) |
|---|---|---|
| `ArbiterChatView` | Partial | `UI/ArbiterChatView.swift` — `ViewCompilationTests/"ArbiterChatView initializes with AI instance"`, `"ArbiterChatView initializes with system prompt"`. Initialisation only; rendering and streaming behaviour are untested. |
| `ProviderPicker` | Partial | `UI/ProviderPicker.swift` — `ViewCompilationTests/"ProviderPicker initializes with Arbiter instance"`, `"Arbiter exposes registeredProviders for ProviderPicker"`. Initialisation only. |
| `UsageDashboard` | Partial | `UI/UsageDashboard.swift` — `ViewCompilationTests/"UsageDashboard initializes with analytics"`. Initialisation only. |
| `RoutingDebugView` | Partial | `UI/RoutingDebugView.swift` — `ViewCompilationTests/"RoutingDebugView initializes with SmartRouter"`, `"RoutingDebugEntry captures routing decision"`. Initialisation only. |
| Availability modifier (`appleFoundationAvailable`) | Partial | `UI/ArbiterLifecycleModifier.swift`, `AvailabilityChecker.swift`. Compilation only. |

## Planned (not implemented)

| Feature | Status | Evidence (file + test name) |
|---|---|---|
| Tool-execution loop with parallel calls and approval | Planned | Roadmap F8 |
| Native schema-constrained output per provider | Planned | Roadmap F4 (OpenAI strict), F5 (Gemini `responseSchema`), F6 (Ollama `format`), F7-D (Apple FM `DynamicGenerationSchema`) |
| Streamed tool calls | Partial | Shipped for Anthropic (`Anthropic — streaming tool input`); roadmap F4 (OpenAI), F5 (Gemini) |
| Embeddings | Planned | Roadmap F4, F6 |
| MCP client support | Planned | Roadmap v0.2 |
| Certificate pinning | Planned | Roadmap v0.2 |
| Conversation persistence | Planned | Roadmap v0.3 |
