# Changelog

## [Unreleased]

### Added
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
