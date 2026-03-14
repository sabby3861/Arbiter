// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// A single message in a conversation
public struct Message: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let role: Role
    public let content: MessageContent

    public init(id: UUID = UUID(), role: Role, content: MessageContent) {
        self.id = id
        self.role = role
        self.content = content
    }

    /// Convenience initializer for simple text messages
    public static func user(_ text: String) -> Message {
        Message(role: .user, content: .text(text))
    }

    public static func assistant(_ text: String) -> Message {
        Message(role: .assistant, content: .text(text))
    }

    public static func system(_ text: String) -> Message {
        Message(role: .system, content: .text(text))
    }
}

/// Who sent the message
public enum Role: String, Sendable, Codable, Hashable {
    case system
    case user
    case assistant
    case tool
}

/// The payload of a message
public enum MessageContent: Sendable, Equatable {
    case text(String)
    case image(ImageSource)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case mixed([MessageContent])

    /// Extract plain text content, if available
    public var text: String? {
        switch self {
        case .text(let string): string
        case .toolResult(let result): result.content
        default: nil
        }
    }

    /// Whether this content contains an image
    public var isImage: Bool {
        switch self {
        case .image: true
        case .mixed(let parts): parts.contains(where: \.isImage)
        default: false
        }
    }
}

/// Where an image comes from
public enum ImageSource: Sendable, Equatable, Codable {
    case url(URL)
    case base64(data: String, mimeType: String)
}

/// A request from the model to call a tool
public struct ToolCall: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// The result of a tool invocation
public struct ToolResult: Sendable, Equatable, Codable {
    public let toolCallId: String
    /// The function name that produced this result.
    /// Required by some providers (e.g. Gemini) to correlate responses.
    public let name: String?
    public let content: String

    public init(toolCallId: String, name: String? = nil, content: String) {
        self.toolCallId = toolCallId
        self.name = name
        self.content = content
    }
}

/// Describes a tool the model can call
public struct ToolDefinition: Sendable, Equatable, Codable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

extension MessageContent: Codable {
    enum CodingKeys: String, CodingKey {
        case type, text, image, toolCall, toolResult, parts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            self = .image(try container.decode(ImageSource.self, forKey: .image))
        case "toolCall":
            self = .toolCall(try container.decode(ToolCall.self, forKey: .toolCall))
        case "toolResult":
            self = .toolResult(try container.decode(ToolResult.self, forKey: .toolResult))
        case "mixed":
            self = .mixed(try container.decode([MessageContent].self, forKey: .parts))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown MessageContent type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let string):
            try container.encode("text", forKey: .type)
            try container.encode(string, forKey: .text)
        case .image(let source):
            try container.encode("image", forKey: .type)
            try container.encode(source, forKey: .image)
        case .toolCall(let call):
            try container.encode("toolCall", forKey: .type)
            try container.encode(call, forKey: .toolCall)
        case .toolResult(let result):
            try container.encode("toolResult", forKey: .type)
            try container.encode(result, forKey: .toolResult)
        case .mixed(let parts):
            try container.encode("mixed", forKey: .type)
            try container.encode(parts, forKey: .parts)
        }
    }
}

extension Message: Codable {
    enum CodingKeys: String, CodingKey {
        case id, role, content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(MessageContent.self, forKey: .content)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
    }
}
