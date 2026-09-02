# Tool Calling Guide

Arbiter supports tool calling (function calling) across cloud providers, letting the AI invoke your Swift functions.

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
| Anthropic | Yes | Definitions, parallel calls, streamed call arguments and multi-round history. You run the tools yourself — there is no execution loop. |
| OpenAI | Yes | Definitions, parallel calls, streamed call arguments and multi-round history on Chat Completions; the opt-in Responses transport maps calls and results but does not stream. You run the tools yourself — there is no execution loop. |
| Gemini | Yes | Full support via function declarations |
| Ollama | No | Not supported by Ollama API |
| MLX | No | On-device models lack tool support |
| Apple FM | Yes, differently | The model calls tools *inside* `respond()`, so this guide's pattern does not apply: bind each definition to an executor in `AppleFMOptions.tools` and select the provider with `RequestOptions(provider: .appleFoundation)`. The turn always finishes `.complete`, never `.toolCall`, and `response.toolCalls` records what already ran. `capabilities.supportsToolCalling` reports `false` so the router does not send tool requests to a provider whose bindings it cannot see. |

The Smart Router automatically considers tool calling support when routing.
If your request includes tools, providers without tool support are disqualified —
Apple FM included, since the router cannot tell whether that request's tools have
executors bound. Reach it with `RequestOptions(provider: .appleFoundation)`, which
bypasses capability matching.

## Tips

- Keep tool descriptions concise — the AI uses them to decide when to call tools
- Use specific parameter names (`city_name` not `input`)
- Always validate tool call arguments before executing
- Set a reasonable `maxTokens` — tool calling responses can be longer than expected
- The router automatically prefers providers that support tools when your request includes them
