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
| Anthropic | Yes | Full support via Claude API |
| OpenAI | Yes | Full support via function calling API |
| Gemini | Yes | Full support via function declarations |
| Ollama | No | Not supported by Ollama API |
| MLX | No | On-device models lack tool support |
| Apple FM | No | Foundation Models API does not expose tools |

The Smart Router automatically considers tool calling support when routing.
If your request includes tools, providers without tool support are disqualified.

## Tips

- Keep tool descriptions concise — the AI uses them to decide when to call tools
- Use specific parameter names (`city_name` not `input`)
- Always validate tool call arguments before executing
- Set a reasonable `maxTokens` — tool calling responses can be longer than expected
- The router automatically prefers providers that support tools when your request includes them
