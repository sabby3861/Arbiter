# F7 — Apple Foundation Models: full native integration

Implementation plan for roadmap item F7, split into three commit-sized chunks: **F7a** (parts A–C), **F7b** (D–F), **F7c** (G–I).

## Context

`AppleFoundationProvider` uses roughly 2 of ~21 Foundation Models capabilities. Today the whole integration is `LanguageModelSession(instructions:)` → `respond(to: latestUserMessage)` → string out. Three consequences:

1. **Multi-turn history is discarded.** `latestUserMessage(from:)` sends only the last user message and builds a fresh session per call, so `ConversationSession` silently loses all context when routed on-device.
2. **Every error becomes `providerUnavailable`.** A context overflow reads as "Apple Intelligence is off", and the router's health monitor penalises a healthy provider.
3. **`supportedTasks` claims `.structuredOutput`** but generation goes through the generic "reply with only JSON" prompt in `Core/StructuredOutput.swift`. Apple's constrained decoding, `Transcript`, `GenerationOptions`, `Tool`, `contextSize` and the typed error enum are all unused.

Intended outcome: a provider that carries real history via `Transcript`, uses constrained decoding, executes tools on-device, maps Apple's typed errors onto Arbiter errors, and reports real token accounting — with the translation logic testable on any platform.

---

## Verified API ground truth

Everything below was read from the installed SDK interface, not from documentation or memory:

`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`

Environment at time of writing: macOS 26.5 (Darwin 25.5.0), Xcode 26.5. `xcodebuild -showsdks` lists **only macOS 26.5**; no OS 27 SDK is installed.

Three findings contradict the roadmap item's wording and change the plan:

| # | Roadmap item says | SDK says |
|---|---|---|
| G1 | "read `response.usage` into TokenUsage (iOS 26.4+)" | **There is no `usage` anywhere in the interface.** `LanguageModelSession.Response` is `{content, rawContent, transcriptEntries}`. The real APIs are `SystemLanguageModel.contextSize` (26.0, `@backDeployed(before: 26.4)`, currently `4096`) and five `tokenCount(for:)` overloads gated `@available(26.4)`. |
| E1 | "register tools on the session so the on-device model can call them" (implying passthrough) | `Tool.call(arguments:)` executes **inside** `respond()`. There is no API that returns tool calls to the caller. A bare `ToolDefinition` cannot be registered — an executor closure is mandatory. |
| B1 | `AppleFMOptions { adapter: SystemLanguageModel.Adapter? }` | `SystemLanguageModel.Adapter` has **no `Sendable` conformance**, so it cannot live in `providerOptions: [ProviderID: any Sendable]`; it would also force the entire options struct behind `#if canImport` + `@available(26)`. |

Other confirmed shapes used below: `Transcript.Entry` = `.instructions/.prompt/.toolCalls/.toolOutput/.response`; `Transcript.ToolOutput` is **singular** (`id`, `toolName`, `segments`); `Transcript.Instructions` carries `toolDefinitions`; `LanguageModelSession(model:tools:transcript:)` has no `instructions:` parameter, so instructions must be the transcript's first entry; `GenerationOptions(sampling:temperature:maximumResponseTokens:)`; `SamplingMode.greedy / .random(top:seed:) / .random(probabilityThreshold:seed:)`; nine `GenerationError` cases plus `ToolCallError`; `GenerationError.Refusal.explanation` is `async throws`; `DynamicGenerationSchema` inits for object / `anyOf [String]` / `anyOf [Schema]` / `arrayOf(min:max:)` / `referenceTo(name:)`; `GenerationSchema(root:dependencies:) throws`; `GenerationGuide` statics `constant/anyOf/pattern` (String), `minimum/maximum/range` (Int, Double, Float, Decimal), `minimumCount/maximumCount/count/element` (Array); `SystemLanguageModel.supportsLocale(_:)` and `.supportedLanguages`; `logFeedbackAttachment(sentiment:issues:desiredOutput:) -> Data` on the **session**; `LanguageModelSession` is a `final class`, `@unchecked Sendable`, and `session.transcript` is get-only.

**No image/vision segment type, no `LanguageModel`/`LanguageModelExecutor` protocol, and no Private Cloud Compute API exist in this SDK.** All of part I is blocked — see *Part I*.

---

## Architecture: the mock seam

The codebase already has the right precedent — `Providers/MLX/MLXChatText.swift`, a pure translation helper outside the `#if canImport(MLX)` guard, consumed from inside it, and unit-tested unconditionally. Plus closure injection for I/O in `Providers/Anthropic/AnthropicImageResolver.swift`. F7 uses both.

**Layer 1 — pure, unguarded, compiles and tests everywhere.** Arbiter-owned vocabulary with no FoundationModels symbol anywhere:

- `Providers/AppleFoundation/FMTranscript.swift` — `FMTranscriptEntry` / `FMSegment` / `FMToolCall` + `FMTranscriptBuilder.build(from:)`
- `Providers/AppleFoundation/FMSchema.swift` — `FMSchemaNode` tree + `FMSchemaConverter` *(F7b)*
- `Providers/AppleFoundation/FMErrorKind.swift` — `FMErrorKind` + `FMErrorMapper`
- `Providers/AppleFoundation/AppleFMOptions.swift` — options + `AppleFMToolBinding` *(bindings land in F7b)*
- `Providers/AppleFoundation/AppleFMAvailability.swift` — mirrored reason enum *(F7b)*
- `Providers/AppleFoundation/FMSessionRunning.swift` — the injection protocol
- `Providers/AppleFoundation/AppleFMSessionStore.swift` — `actor` session cache over `any FMSessionRunning`

**Layer 2 — guarded (`#if canImport(FoundationModels)`, `@available(iOS 26, macOS 26, visionOS 26, *)`), the single narrow boundary where Apple types are named:**

- `Providers/AppleFoundation/FMBridge.swift` — `FMTranscript ↔ Transcript`, `FMSchemaNode → GenerationSchema` *(F7b)*, `GenerationError → FMErrorKind`
- `Providers/AppleFoundation/FMToolAdapter.swift` — `AppleFMToolBinding → FoundationModels.Tool` *(F7b)*
- `Providers/AppleFoundation/LiveFMSession.swift` — `FMSessionRunning` over a real `LanguageModelSession`

**The seam.** `FMSessionRunning` speaks only Arbiter vocabulary:

```swift
protocol FMSessionRunning: Sendable {
    var isResponding: Bool { get }
    var transcriptFingerprint: String { get }
    func respond(to prompt: String, settings: FMGenerationSettings) async throws -> FMRunResult
    func stream(to prompt: String, settings: FMGenerationSettings)
        -> AsyncThrowingStream<FMStreamSnapshot, Error>
}
```

`AppleFoundationProvider` stores `let sessionFactory: @Sendable (FMTranscript, AppleFMOptions) throws -> any FMSessionRunning`, exactly as `AnthropicImageResolver` stores `load`. The production init wires `LiveFMSession`; tests inject a `MockFMSession` returning canned results or throwing canned `FMErrorKind`s. This makes the provider's own logic — overflow retry, error mapping, cache reuse, `isResponding` serialisation, stream chunk shaping — testable off-device, which the pure layer alone does not cover.

---

## F7a — Parts A, B, C

### A. Sessions & history

`FMTranscriptBuilder.build(from: AIRequest) throws -> (transcript: FMTranscript, prompt: String)`.

`respond(to:)` appends its own `Prompt` entry, so **the last user turn is the `prompt` argument and is not placed in the transcript**. Everything before it becomes the transcript.

| Arbiter | Foundation Models |
|---|---|
| `request.systemPrompt` + all `.system` messages, joined | one leading `.instructions(segments:[.text], toolNames:)` |
| `.user` + `.text` | `.prompt(segments: [.text])` |
| `.assistant` + `.text` | `.response(segments: [.text])` |
| `.assistant` + `.toolCalls([...])` | `.toolCalls([...])`, arguments carried as JSON for `GeneratedContent(json:)` |
| `.tool` / `.user` + `.toolResults([...])` | **N separate** `.toolOutput` entries (`ToolOutput` is singular). `toolName` from `ToolResult.name`, else resolved by `toolCallId` against the preceding `.toolCalls` entry |
| `.mixed([...])` | flattened part-by-part, order preserved |
| `.image` / `.document` | `invalidRequest` naming the unsupported content kind — `// TODO(F7-I)` |

Edge rules, each with a test: last message not user-text → `invalidRequest`; no user message at all → `invalidRequest`; tool results with no preceding tool calls, or an unresolvable tool name → `invalidRequest` (mirrors the Anthropic rule from F3).

`AppleFMSessionStore` — `actor`, bounded LRU (8 entries), keyed by `AppleFMOptions.conversationID`. Reuse is exact rather than bookkept: a cached session is reused only when its `transcriptFingerprint` equals the fingerprint of the transcript just built, so the session is known to already hold precisely that history. If Apple normalises entries such that the round-trip differs, reuse simply never triggers and the session is rebuilt — degraded latency, never incorrect history.

**The fingerprint must cover session-shaping identity, not just the transcript.** `LanguageModelSession` fixes `tools:` and `model:` at init and they cannot change afterwards, so a second request in the same conversation carrying different tool bindings, `useCase`, `guardrails` or `adapter` would otherwise silently reuse a session built with the *old* configuration. `AppleFMOptions.sessionIdentity` folds in those fields (and, from F7b, the sorted tool names); any mismatch discards and rebuilds.

`AppleFMOptions.prewarm` is honoured at session creation: the factory calls `session.prewarm(promptPrefix:)` — with `promptPrefixForPrewarm` wrapped as a `Prompt` when set — immediately after constructing a new session, never on a cache hit.

`isResponding` is checked before dispatch and throws `.busy`, so a concurrent call on one conversation reports honestly instead of trapping inside the framework.

### B. Options

`GenerationOptions` mapping: `request.temperature → temperature`; `request.maxTokens → maximumResponseTokens`; `request.topP → .random(probabilityThreshold:)` when no explicit sampling is set (logged at `notice`, following the F4 drop-with-notice convention); an explicit `AppleFMOptions.sampling` always wins.

```swift
public struct AppleFMOptions: Sendable {
    public var sampling: AppleFMSampling?          // .greedy | .randomTop(k:seed:) | .randomThreshold(p:seed:)
    public var useCase: AppleFMUseCase             // .general | .contentTagging
    public var guardrails: AppleFMGuardrails       // .default | .permissiveContentTransformations
    public var adapter: AppleFMAdapterSource?      // .name(String) | .fileURL(URL)
    public var prewarm: Bool
    public var promptPrefixForPrewarm: String?
    public var conversationID: String?
    public var contextOverflow: AppleFMContextOverflow  // .fail (default) | .summarizeAndRetry
}
```

Composes with F3/F4 unchanged: reached via `request.providerOptions[.appleFoundation] as? AppleFMOptions`, attached with `withProviderOptions(_:for:)`, forwarded from `RequestOptions.providerOptions` by `Arbiter.buildRequest`. Lives at `Providers/AppleFoundation/AppleFMOptions.swift`, per convention. Fields serving parts D–G (`includeSchemaInPrompt`, `locale`, `enforceLocale`, `reportTokenUsage`, `tools`) are added by the chunk that uses them, so no field ships dead.

Two deviations from the item's letter, both forced:

- **`adapter` is `AppleFMAdapterSource`, not `SystemLanguageModel.Adapter`** — the SDK type is not `Sendable`, so it cannot enter `[ProviderID: any Sendable]`. The real `Adapter` is constructed inside the guarded bridge from the name or URL, and `Adapter.AssetError` maps to `.providerUnavailable`.
- **`guardrails` added** (not in the item) because `SystemLanguageModel.Guardrails.permissiveContentTransformations` exists and is the only way to run transformation workloads without spurious guardrail violations.

**Cache-key hazard:** `Runtime/ResponseCache` folds options into the key with `String(describing:)`. Once F7b adds executor closures, a synthesised description becomes unstable, so `AppleFMOptions` carries a hand-written `CustomStringConvertible` covering the value fields (and, later, tool names only).

### C. Errors

Four new `ArbiterError` cases, each carrying `ProviderID` for consistency with the existing enum:

```swift
case contextWindowExceeded(ProviderID, limit: Int)
case refused(ProviderID, explanation: String)
case unsupportedLanguage(ProviderID, locale: String?)
case busy(ProviderID)
```

`errorDescription` and `recoverySuggestion` both switch exhaustively, as does `RetryEngine.isRetryable` — the compiler finds every site. `.busy` is retryable; the other three are not.

`FMErrorMapper` covers **all ten** SDK error shapes, two of which the roadmap item omits:

| SDK | `ArbiterError` |
|---|---|
| `exceededContextWindowSize` | `.contextWindowExceeded(.appleFoundation, limit: contextSize)` |
| `guardrailViolation` | `.contentFiltered(reason:)` |
| `refusal(Refusal, Context)` | `.refused(.appleFoundation, explanation:)` |
| `unsupportedLanguageOrLocale` | `.unsupportedLanguage(.appleFoundation, locale:)` |
| `concurrentRequests` | `.busy(.appleFoundation)` |
| `rateLimited` | `.rateLimited(.appleFoundation, retryAfter: nil)` |
| `assetsUnavailable` | `.providerUnavailable(.appleFoundation, reason:)` |
| **`unsupportedGuide`** *(item omits)* | `.invalidRequest(reason:)` |
| **`decodingFailure`** *(item omits)* | `.decodingFailed(context:)` |
| `ToolCallError` | `.invalidRequest(reason:)` naming the tool |
| `@unknown default` | `.providerUnavailable` + `logger.warning` |
| `CancellationError` | rethrown unchanged |

**`Refusal.explanation` is `async throws` and runs a generation — it is never awaited in the mapper.** The explanation string comes from `Context.debugDescription`. Fetching the full explanation is a follow-up, not part of F7.

Overflow strategy, opt-in via `contextOverflow == .summarizeAndRetry`: on `.contextWindowExceeded`, summarise the transcript entries older than the last two prompt/response pairs using a fresh same-model session, replace them with one synthesised prompt/response pair carrying the summary, and retry **once** behind an explicit flag. A second overflow throws. Tested with a mock session that throws on call 1 and succeeds on call 2 — asserting exactly two calls and a shorter second transcript.

---

## F7b — Parts D, E, F

### D. Structured output

**D1 — `ResponseFormat.structured(schema: String)` → constrained decoding.** Reuse `JSONSchemaNormalizer.parseObject(_:)` — the file's own header names this as its extension point — then a new sibling pure converter producing an `FMSchemaTree` (root node + named dependencies), which the bridge turns into `GenerationSchema(root:dependencies:)`.

Keyword table, verified against the `GenerationGuide` statics in the interface:

| JSON Schema | Foundation Models |
|---|---|
| `object` + `properties` + `required` | `DynamicGenerationSchema(name:description:properties:)`, `Property(isOptional: !required.contains(key))` |
| `string` + `enum` | `DynamicGenerationSchema(name:description:anyOf: [String])` |
| `string` + `const` | `GenerationGuide<String>.constant` |
| `string` + `pattern` | `GenerationGuide<String>.pattern(Regex)`; a pattern that fails to compile drops the guide with a `notice` rather than failing the request |
| `integer` + `minimum`/`maximum` | `GenerationGuide<Int>.minimum/.maximum/.range` |
| `number` + `minimum`/`maximum` | `GenerationGuide<Double>.…` |
| `boolean` | `DynamicGenerationSchema(type: Bool.self)` |
| `array` + `items` + `minItems`/`maxItems` | `DynamicGenerationSchema(arrayOf:minimumElements:maximumElements:)` |
| `anyOf`/`oneOf` of objects | `DynamicGenerationSchema(name:anyOf: [DynamicGenerationSchema])` |
| `$ref: "#/$defs/X"` | `DynamicGenerationSchema(referenceTo: "X")`, `X` emitted as a dependency |
| `$defs` / `definitions` | each becomes a named dependency |
| `nullable`, `type: [X, "null"]` | property `isOptional: true` |
| `additionalProperties`, `$schema`, `allOf`, `not`, `patternProperties`, `exclusiveMin/Max` | dropped with a `notice`, documented in FEATURE_STATUS |

Name uniqueness and `$ref` resolution are validated in the pure converter so a bad schema fails locally; `GenerationSchema.SchemaError` is caught at the bridge and mapped to `.invalidRequest` naming the offending schema. Cycles are handled by tracking visited names (legal via `referenceTo` + dependencies), with a depth cap of 12 on non-reference nesting.

`respond(to:schema:includeSchemaInPrompt:options:)` returns `GeneratedContent`; `.jsonString` becomes `AIResponse.content`, so the existing `Arbiter.generate(as:)` decoder receives structurally guaranteed JSON.

**D2 — native `Generable` API**, guarded, on the real provider only:

```swift
public func generate<T: Generable>(_ request: AIRequest, as type: T.Type) async throws -> T
public func streamGenerate<T: Generable>(_ request: AIRequest, as type: T.Type)
    -> AsyncThrowingStream<T.PartiallyGenerated, Error>
```

These name `Generable`, so they cannot exist in the `#else` stub. That is the one place the public surface differs by build configuration; it gets a doc comment and a FEATURE_STATUS line.

### E. Tools

**Forced by finding E1:** Apple executes tools inside `respond()`, so an executor is required:

```swift
public struct AppleFMToolBinding: Sendable {
    public let definition: ToolDefinition
    public let execute: @Sendable (JSONValue) async throws -> String
}
```

`FMToolAdapter` wraps a binding as a `FoundationModels.Tool` with `Arguments = GeneratedContent` (which is `Generable`, satisfying `ConvertibleFromGeneratedContent`) and `Output = String` (`String` is `PromptRepresentable`). `parameters` is a stored `GenerationSchema` built from `ToolDefinition.inputSchema` — already a `JSONValue`, so the converter gains a `JSONValue` entry point. A stored `parameters` property overrides the `where Arguments: Generable` extension default.

`capabilities.supportsToolCalling` becomes `true`, with honest semantics documented:

- The provider **never** emits `finishReason: .toolCall` — the loop completes in-session.
- `AIResponse.toolCalls` is populated retrospectively from the `.toolCalls` entries in the response's transcript slice; `finishReason` stays `.complete`.
- `request.tools` naming a tool with no matching binding throws `.invalidRequest` pointing at `AppleFMOptions.tools` — per the F3/F4 convention of rejecting what the model cannot honour rather than silently dropping it.

**F8 composition:** F8's agent loop must special-case this provider. It will never observe `.toolCall`, so a generic loop terminates after one round; F8 should bridge `[any ArbiterTool]` into `[AppleFMToolBinding]` and let the session run the loop. This is the largest cross-item coupling in F7.

### F. Availability & locale

`AppleFMUnavailableReason` — pure enum mirroring the SDK's three cases plus `.frameworkNotLinked`, `.osTooOld`, `.unknown`, so it compiles off-platform. `AvailabilityChecker` gains `availability() async -> AppleFMAvailability`; `isAppleFoundationAvailable()` and `unavailableReason() -> String` stay, the latter derived from the enum (source-compatible).

`providerUnavailable`'s `String` payload is deliberately left unchanged — the enum is added alongside it rather than replacing it, so no existing caller breaks.

`supportsLocale(_:)` and `supportedLanguages` are exposed on the provider (guarded; the stub returns `false` / `[]`). Proactive language checking is **opt-in** via `AppleFMOptions.enforceLocale` + `locale`, because guessing a prompt's language is unreliable until F9 adds NLTagger — checking `supportsLocale(.current)` unconditionally would reject valid requests. The reactive path always works: `unsupportedLanguageOrLocale` maps to `.unsupportedLanguage`, which the router treats as a non-retryable signal to fall back.

---

## F7c — Parts G, H; part I stubbed

### G. Accounting

Built on finding G1 — there is no `Response.usage`:

- `capabilities.maxContextTokens` reads `SystemLanguageModel.contextSize` under `#if`/`#available`, falling back to `4_096` (replacing today's hardcoded literal).
- Under `if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *)`, build `TokenUsage` from `tokenCount(for:)`: input = transcript entries sent + prompt (+ instructions/tools/schema where present); output = `tokenCount(for:)` over the transcript slice this call appended.
- Below 26.4, `usage` is `nil` — honest, and the router's existing estimator handles nil. No `chars × 0.25` fabrication.
- `tokenCount` is `async throws` and costs work: gated by `AppleFMOptions.reportTokenUsage` (default `true`); a throw from it never fails the request, it yields `usage = nil`.
- Costs stay `nil` (free, on-device), so `SpendingGuard` is unaffected either way; the win is context-window accuracy and honest router accounting.

### H. Feedback

`logFeedbackAttachment` lives on `LanguageModelSession`, so feedback needs the session that produced the response — hence H depends on A's cache:

```swift
public func feedback(forConversation id: String,
                     sentiment: AppleFMFeedbackSentiment?,
                     issues: [AppleFMFeedbackIssue] = []) async throws -> Data
```

Pure mirror enums `AppleFMFeedbackSentiment` (positive/negative/neutral) and `AppleFMFeedbackIssue` (the SDK's 8 categories + optional explanation) keep the signature compiling off-platform; the stub throws `.providerUnavailable`. No cached session for that ID → `.invalidRequest`. The `desiredOutput:` parameter needs a `Transcript.Entry` and is deferred.

### I. Blocked on the OS 27 SDK — not implemented

Verified above: the installed macOS 26.5 SDK has no image/vision segment, no `LanguageModel`/`LanguageModelExecutor` protocol, and no Private Cloud Compute API, and no OS 27 SDK is available. **All three sub-parts of I need it and cannot be compiled, let alone written.**

What F7c ships instead:

- **I-1 (image input):** the transcript builder already throws `.invalidRequest` on `.image` content; `supportsImageInput` stays `false`. One `// TODO(F7-I)` at the throw site.
- **I-2 (Private Cloud Compute):** **`ProviderID.applePrivateCloud` is deliberately not added.** `ProviderID` is a closed public enum with two exhaustive switches (`displayName`, `tier`); adding a case with no implementation behind it ships a dead provider into the public API and churns every exhaustive switch downstream for nothing. A `// TODO` comment only; the roadmap already queues this as M1.
- **I-3 (`LanguageModel` conformance):** nothing to write. Already queued as M1, explicitly marked as needing the OS 27 SDK.

Also updated in F7c: `Documentation/FEATURE_STATUS.md` (multi-turn, tool calling, constrained decoding and typed errors move Planned → Shipped with test names; vision stays Planned with the SDK reason) and the README Apple FM row and history caveat.

---

## Files at a glance

**New (pure, unguarded):** `FMTranscript.swift`, `FMErrorKind.swift`, `AppleFMOptions.swift`, `FMSessionRunning.swift`, `AppleFMSessionStore.swift` *(F7a)*; `FMSchema.swift`, `AppleFMAvailability.swift` *(F7b)* — all under `Sources/Arbiter/Providers/AppleFoundation/`.

**New (guarded):** `FMBridge.swift`, `LiveFMSession.swift` *(F7a)*; `FMToolAdapter.swift` *(F7b)* — same directory.

**Changed:** `Providers/AppleFoundation/AppleFoundationProvider.swift` (both bodies rewritten), `Providers/AppleFoundation/AvailabilityChecker.swift` *(F7b)*, `Core/ArbiterError.swift`, `Runtime/RetryEngine.swift`, `Documentation/FEATURE_STATUS.md` and `README.md` *(F7c)*.

**Reused, not modified:** `Core/JSONSchemaNormalizer.parseObject` (F4), `Core/Message.swift`'s `.toolCalls`/`.toolResults`/`allToolCalls`/`allToolResults` (F2), `AIRequest.providerOptions` + `withProviderOptions(_:for:)` (F3), the `Providers/<Name>/<Name>Options.swift` layout convention (F3/F4).

---

## Verification

Baseline: `swift build && swift test` green at 593 tests / 58 suites.

New suites use `import Testing` / `@Suite` / `@Test` / `#expect` per repo convention. The pure-layer suites are genuinely unguarded — no `#if`, no `#available` — because that layer names no Apple symbol. `AppleFoundationProviderTests` is the exception: it touches the provider type, which is `@available(26)` behind `#if canImport(FoundationModels)`, so it keeps those guards. What changes for it is the *other* axis — it runs off a mock session and so no longer needs Apple Intelligence to be enabled, which is what fixes the current situation where every meaningful assertion compiles out.

- `FMTranscriptBuilderTests` — role mapping; N tool results → N `toolOutput` entries; `toolName` fallback by `toolCallId`; `.mixed` flattening; the `invalidRequest` edges; fingerprint stability and sensitivity.
- `FMErrorMapperTests` — all ten error shapes; asserts refusal mapping never triggers a generation.
- `AppleFMOptionsTests` — `providerOptions` round-trip; `sessionIdentity` sensitivity; description stability for the response cache.
- `AppleFMSessionStoreTests` — reuse on a fingerprint match, rebuild on transcript mismatch, rebuild on identity mismatch, LRU eviction.
- `AppleFoundationProviderTests` (rewritten) — driven by a mock session through `sessionFactory`: stream chunk shaping ends with `isComplete`; overflow retries exactly once then throws; `isResponding` race → `.busy`; typed error mapping end-to-end.
- *(F7b)* `FMSchemaConverterTests` — one case per row of the D keyword table, plus `$defs`/`$ref`, a cycle, an uncompilable `pattern`, duplicate names, an unresolved `$ref`. `FMToolAdapterTests` — `JSONValue` round-trip; unbound tool name → `invalidRequest`.

Roadmap done-criteria, each pinned by a named test:

1. **Multi-turn reaches the model:** a 5-message request produces instructions + 2 prompt + 2 response entries, and the `prompt` argument equals the last user text.
2. **`@Generable` round-trips:** integration test gated on `#available(26)` + `await isAvailable`, with a small `@Generable` fixture struct *(F7b)*.
3. **Context overflow maps correctly:** a mock session throwing `exceededContextWindowSize` yields `ArbiterError.contextWindowExceeded`, **not** `.providerUnavailable`.

Availability-gated integration tests (`guard #available … else { return }` + `guard await isAvailable`) cover the real device path. Fixtures are inline Swift values in a `private enum`, matching `ToolTurnFixture` — the repo has no on-disk fixtures and `Package.swift` declares no test resources.

---

## Execution order

Three commits, each running the full cycle — `swift build && swift test` green, then an adversarial review of *only* that diff (concurrency, API contracts, edge cases, over-claims), then fixes, then commit:

1. `F7a: Apple FM transcript history, generation options, typed errors` — parts A + B + C.
2. `F7b: Apple FM constrained decoding, native tools, availability reasons` — parts D + E + F.
3. `F7c: Apple FM token accounting and feedback` — parts G + H, part I stubbed, docs updated.

The roadmap item is marked complete only after F7c.

## Decisions taken with the maintainer

1. **Part G's premise is wrong against the installed SDK** — no `Response.usage` exists; implemented via `contextSize` + `tokenCount(for:)` instead.
2. **Part E requires executor closures.** Apple runs tools in-session; `supportsToolCalling: true` does not mean `.toolCall` finish reasons. F8's loop must special-case this.
3. **`adapter` is `AppleFMAdapterSource`, not `SystemLanguageModel.Adapter`** — the SDK type is not `Sendable` and cannot enter `providerOptions`.
4. **Part I is entirely blocked** on the OS 27 SDK; `ProviderID.applePrivateCloud` deliberately not added.
5. **Public API beyond the item's letter:** four `ArbiterError` cases carrying `ProviderID`; `AppleFMOptions.guardrails`; `AppleFMToolBinding`; the `Generable` methods existing only when the framework is linked.
6. **`providerUnavailable`'s `String` payload is left unchanged** — the availability reason enum is added alongside it.
