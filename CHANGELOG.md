# Changelog

## [Unreleased]

### Added
- **Request Intelligence Engine**: `RequestAnalyser` classifies prompt complexity (trivial → expert), detects task type (classification, code generation, reasoning, etc.), and estimates output tokens before routing
- **Adaptive routing**: `ProviderPerformanceTracker` records real-world latency and success rates per provider per task type, adjusting routing scores after 10+ requests — the router gets smarter with usage
- **Pre-request cost estimation**: `SwiftAI.estimateCost()` returns per-provider cost estimates without sending a request
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
- SwiftUI components: SwiftAIChatView, ProviderPicker, UsageDashboard, RoutingDebugView
- .swiftAILifecycle() view modifier
- Security documentation and proxy architecture guide
- RoutingDebugEntry for inspecting routing decisions

### Fixed
- Middleware now applied to both generate and streaming request paths
- SwiftAIChatView retry button works correctly after failed requests
- Client-side rate limit no longer reports as Anthropic-specific error
- Response cache keys include topP and tool definitions
- Retry backoff with jitter no longer exceeds configured maxDelay
