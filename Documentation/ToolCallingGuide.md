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
            Message(role: .tool, content: .toolResult(
                ToolResult(toolCallId: toolCall.id, name: "get_weather", content: weatherResult)
            )),
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
            content: .toolResult(ToolResult(toolCallId: call.id, name: call.name, content: result))
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
| Apple FM | Yes, differently | The model calls tools *inside* `respond()`, so this guide's pattern does not apply: bind each definition to an executor in `AppleFMOptions.tools` and select the provider with `RequestOptions(provider: .appleFoundation)`. The turn always finishes `.complete`, never `.toolCall`, and `response.toolCalls` records what already ran. `capabilities.supportsToolCalling` reports `false` so the router scores tool requests away from a provider whose bindings it cannot see; `run(_:tools:)` binds them for you, so a run that does land here works and finishes in one round. |

The Smart Router considers tool calling support when routing: a request carrying
tools zeroes the capability term of any provider reporting `supportsToolCalling ==
false`, which pushes it below providers that report `true` without removing it from
the running — a lone on-device provider can still be chosen. Apple FM reports
`false` because the router cannot tell whether that request's tools have executors
bound. Use `RequestOptions(provider: .appleFoundation)` to reach it deliberately,
which bypasses capability matching entirely.

## Tips

- Keep tool descriptions concise — the AI uses them to decide when to call tools
- Use specific parameter names (`city_name` not `input`)
- Always validate tool call arguments before executing
- Set a reasonable `maxTokens` — tool calling responses can be longer than expected
- The router automatically prefers providers that support tools when your request includes them
