# Tool Calling Guide

Arbiter supports tool calling (function calling) across the cloud providers and Ollama, letting the AI invoke your Swift functions.

There are two ways to use it. `run(_:tools:)` runs the whole exchange for you — it
sends the conversation, executes the tools the model calls, feeds the results back
and repeats until it answers:

```swift
let weather = FunctionTool(
    name: "get_weather",
    description: "Get current weather for a city",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["city": .object(["type": .string("string")])]),
        "required": .array([.string("city")]),
    ])
) { arguments, _ in
    guard case .object(let fields) = arguments,
          case .string(let city)? = fields["city"] else { return "Unknown city" }
    return lookupWeather(city: city)
}

let result = try await ai.run("What's the weather in London?", tools: [weather])
print(result.content)
```

The rest of this guide covers the manual pattern — `generate`/`chat` with
`RequestOptions(tools:)` — which is what you want when your app drives the loop
itself. See the README's Tool Execution section for concurrency, per-tool
timeouts and approval.

## Quick Start

```swift
import Arbiter

let ai = try Arbiter {
    try $0.cloud(.anthropic(from: .keychain))
}

// 1. Define a tool
let weatherTool = ToolDefinition(
    name: "get_weather",
    description: "Get current weather for a city",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "city": .object([
                "type": .string("string"),
                "description": .string("City name"),
            ]),
        ]),
        "required": .array([.string("city")]),
    ])
)

// 2. Send a request with tools
let options = RequestOptions(tools: [weatherTool])
let response = try await ai.generate("What's the weather in London?", options: options)

// 3. Handle tool calls
for toolCall in response.toolCalls {
    switch toolCall.name {
    case "get_weather":
        let city = toolCall.arguments["city"]  // JSONValue
        let weatherResult = lookupWeather(city: city?.stringValue ?? "")

        // 4. Send the result back
        let messages: [Message] = [
            .user("What's the weather in London?"),
            .assistant(response.content),
            Message(role: .tool, content: .toolResults([
                ToolResult(toolCallId: toolCall.id, name: "get_weather", content: weatherResult)
            ])),
        ]
        let finalResponse = try await ai.chat(messages, options: options)
        print(finalResponse.content)

    default:
        break
    }
}

func lookupWeather(city: String) -> String {
    // Your weather API call here
    return "{\"temperature\": 18, \"condition\": \"Partly cloudy\"}"
}
```

## Multi-turn Tool Calling

For conversations that need multiple tool calls:

```swift
var messages: [Message] = [.user("Compare weather in London and Tokyo")]
let options = RequestOptions(tools: [weatherTool])

var response = try await ai.chat(messages, options: options)

while !response.toolCalls.isEmpty {
    messages.append(.assistant(response.content))

    for call in response.toolCalls {
        let result = lookupWeather(city: call.arguments["city"]?.stringValue ?? "")
        messages.append(Message(
            role: .tool,
            content: .toolResults([ToolResult(toolCallId: call.id, name: call.name, content: result)])
        ))
    }

    response = try await ai.chat(messages, options: options)
}

print(response.content) // Final answer comparing both cities
```

## Provider Support

| Provider | Tool Calling | Notes |
|----------|-------------|-------|
| Anthropic | Yes | Definitions, parallel calls, streamed call arguments and multi-round history, with `run(_:tools:)` executing the loop. |
| OpenAI | Yes | Definitions, parallel calls, streamed call arguments and multi-round history on Chat Completions, with `run(_:tools:)` executing the loop; the opt-in Responses transport maps calls and results but does not stream. |
| Gemini | Yes | Definitions, parallel calls, streamed `functionCall` parts and multi-round history, with `run(_:tools:)` executing the loop. Gemini has no tool-call finish reason of its own — a turn asking for a function finishes `STOP` — so Arbiter reports one that carries calls as `.toolCall`. Replayed turns keep each call's `id` and its `thoughtSignature`, which the API requires back unchanged. |
| Ollama | Yes | Definitions, parallel calls, `tool_calls` on both the non-streaming and NDJSON streaming paths and multi-round history, with `run(_:tools:)` executing the loop. Ollama has no tool-call finish reason of its own — a turn asking for a tool finishes `done_reason: "stop"` — so Arbiter reports one that carries calls as `.toolCall`. Ollama attaches no id to a call, so Arbiter synthesises one per turn (`ollama-call-<turn>-<index>`); replayed results correlate by `tool_name` rather than by id, so give each `ToolResult` a `name`. |
| MLX | No | On-device models lack tool support |
| Apple FM | Yes, differently | The model calls tools *inside* `respond()`, so this guide's pattern does not apply: bind each definition to an executor in `AppleFMOptions.tools` and select the provider with `RequestOptions(provider: .appleFoundation)`. The turn always finishes `.complete`, never `.toolCall`, and `response.toolCalls` records what already ran. `capabilities.supportsToolCalling` reports `false` because the router cannot see the bindings a request supplies — which **disqualifies** it from tool requests rather than merely deprioritising it; see the section below. `run(_:tools:)` binds the tools for you, so a run that does land here works and finishes in one round. |

## How routing treats `supportsToolCalling == false`

A request carrying tools **disqualifies** any provider reporting
`supportsToolCalling == false`. This is stronger than it sounds, and stronger than
earlier versions of this guide said:

1. `CapabilityMatcher.score` returns early with `baseScore: 0, adjustedScore: 0` for
   the whole provider — it does not zero one term of a weighted sum, and no weighting
   happens at all.
2. `SmartRouter.buildDecision` reports `.unavailable` unless the best adjusted score
   is greater than zero.
3. `Arbiter` turns an unavailable decision into an empty provider list and throws
   `ArbiterError.allProvidersFailed`.

A zeroed provider comes back only through a later *additive* adjustment. There are
four, in two groups.

**Gated** on the `.smart` strategy *and* a device that is not thermally constrained:

- `applyComplexityAdjustments` adds `+15` to an `.onDevice` or `.system` provider for
  a prompt the analyser calls trivial or simple.
- `applyTaskAdjustments` adds `+10` to a provider declaring `AITask.structuredOutput`
  when the detected task is structured output (Apple FM declares it; MLX does not),
  and `+10` to Anthropic on a code-generation task.

**Ungated** — these run under every strategy and under thermal pressure:

- `applyPerformanceAdjustments` adds up to `+15` (`+10` for a success rate at or above
  0.95, `+5` for latency at or below the global average), but only once that provider
  has ten or more recorded requests *for that task*.
- `applyHealthAdjustments` adds `+5` to any provider the health monitor has recorded
  as healthy — which requires `Configuration.healthCheck(.enabled(...))` and a
  completed check.

Any one of those is enough to lift a zeroed score above zero, so **the failure below
is a cold-start and no-health-monitor property, not a permanent one.** An app that
configures a health monitor, or one whose on-device provider has ten successful
requests behind it, serves the tool request under every strategy.

| Setup | Tool request |
|---|---|
| Any provider reporting `true` is registered, `.smart`, no thermal pressure, short prompt | The **rescued on-device provider can still rank first** — `+15` beats a typical normalised cloud score of ~11 — so it is tried first and the capable provider is next in the fallback chain. The run succeeds; a wasted attempt is the cost. |
| Any provider reporting `true` is registered, and no rescue fires | Routes to the capable provider. A zeroed provider scores 0 and never wins. |
| Apple FM or MLX registered **alone**, `.smart`, no thermal pressure, short prompt | Served on-device — the `+15` rescues the score. |
| Apple FM registered **alone**, `.smart`, no thermal pressure, structured-output task | Served on-device — the `+10` rescues the score. |
| Apple FM or MLX registered **alone**, with a health monitor configured, or ten or more recorded requests for the task | Served on-device under **any** strategy — the ungated `+5`/`+15` rescues the score. |
| Apple FM or MLX registered **alone**, cold, no health monitor, and any of `.privacyFirst` / `.qualityFirst` / `.costOptimized` / `.latencyOptimized`, or thermal pressure, or a complex non-structured prompt | Throws `ArbiterError.allProvidersFailed`. |

`Tool loop/aProviderReportingNoToolSupportIsPenalisedNotDisqualified` covers one row of
that table — a lone on-device provider under `.smart` on a short prompt — and its name
predates this correction. The score arithmetic behind the first row is pinned separately
by `Capability disqualification arithmetic/*`.
`SmartRouter.filterByConstraints` has no tool filter, so nothing else removes the
provider. The same path fires for `supportsImageInput == false` on any request
carrying an image.

One more exemption: **`.priority` routing never calls `CapabilityMatcher` at all.**
`SmartRouter.priorityRoute` filters by constraints and availability and takes the
first provider in your order, so none of this section applies under `.priority` — a
tool request reaches a provider reporting `false` regardless of prompt, strategy
gate or thermal state.

**The workaround is explicit routing.** `RequestOptions(provider: .appleFoundation)`
returns a decision before the router runs, so capability matching is bypassed
entirely and none of the above applies:

```swift
// Each definition needs an executor bound to it — the router cannot see these,
// which is why the provider reports `supportsToolCalling == false`.
let weather = AppleFMToolBinding(definition: weatherTool) { arguments in
    lookupWeather(city: arguments["city"]?.stringValue ?? "")
}

let reply = try await ai.generate(prompt, options: .init(
    tools: [weatherTool],
    provider: .appleFoundation,
    providerOptions: [.appleFoundation: AppleFMOptions(tools: [weather])]
))
```

`RoutingStrategy.fixed` has the same effect for a whole `Arbiter` instance.

Turning this into a genuine penalty — a large score reduction that keeps a
capable-enough provider in the running — is tracked on the roadmap. It changes
routing behaviour, so it is **not** part of 0.2.0.

## Tips

- Keep tool descriptions concise — the AI uses them to decide when to call tools
- Use specific parameter names (`city_name` not `input`)
- Always validate tool call arguments before executing
- Set a reasonable `maxTokens` — tool calling responses can be longer than expected
- The router automatically prefers providers that support tools when your request includes them
