// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

/// No `#if` and no `#available`: the transcript layer names no FoundationModels symbol,
/// so every rule below is checked on every platform — the same seam `MLXChatText` uses.
@Suite("FMTranscriptBuilder")
struct FMTranscriptBuilderTests {

    // MARK: - History

    @Test func multiTurnHistoryBecomesTranscriptEntries() throws {
        let request = AIRequest(
            messages: [
                .user("What is the capital of France?"),
                .assistant("Paris."),
                .user("And of Japan?"),
                .assistant("Tokyo."),
                .user("Which is further north?"),
            ],
            systemPrompt: "You are terse."
        )

        let built = try FMTranscriptBuilder.build(from: request)

        // The final user turn is the prompt, not a transcript entry: respond(to:) appends
        // its own Prompt entry, so including it here would ask the question twice.
        #expect(built.prompt == "Which is further north?")
        #expect(built.transcript.entries == [
            .instructions(segments: [.text("You are terse.")], toolNames: []),
            .prompt(segments: [.text("What is the capital of France?")]),
            .response(segments: [.text("Paris.")]),
            .prompt(segments: [.text("And of Japan?")]),
            .response(segments: [.text("Tokyo.")]),
        ])
    }

    @Test func systemMessagesFoldIntoTheInstructionsEntry() throws {
        let request = AIRequest(
            messages: [
                .system("Answer in French."),
                .user("Hello"),
            ],
            systemPrompt: "You are helpful."
        )

        let built = try FMTranscriptBuilder.build(from: request)

        #expect(built.transcript.entries == [
            .instructions(segments: [.text("You are helpful.\n\nAnswer in French.")], toolNames: []),
        ])
        #expect(built.prompt == "Hello")
    }

    @Test func singleTurnWithoutSystemPromptHasEmptyTranscript() throws {
        let built = try FMTranscriptBuilder.build(from: AIRequest.chat("Hi"))
        #expect(built.transcript.isEmpty)
        #expect(built.prompt == "Hi")
    }

    // MARK: - Tool turns

    @Test func parallelToolCallsBecomeOneEntryAndResultsBecomeOneEntryEach() throws {
        let calls: [ToolCall] = [
            ToolCall(id: "c1", name: "get_weather", arguments: .object(["city": .string("Tokyo")])),
            ToolCall(id: "c2", name: "get_time", arguments: .object(["zone": .string("JST")])),
        ]
        let request = AIRequest(messages: [
            .user("Weather and time in Tokyo?"),
            Message(role: .assistant, content: .toolCalls(calls)),
            Message(role: .tool, content: .toolResults([
                ToolResult(toolCallId: "c1", content: "18C"),
                ToolResult(toolCallId: "c2", content: "14:00"),
            ])),
            .user("Thanks, and tomorrow?"),
        ])

        let built = try FMTranscriptBuilder.build(from: request)

        // Transcript.ToolCalls holds a whole turn, but Transcript.ToolOutput is singular —
        // two results must become two entries, not one.
        #expect(built.transcript.entries == [
            .prompt(segments: [.text("Weather and time in Tokyo?")]),
            .toolCalls([
                FMToolCall(id: "c1", toolName: "get_weather", argumentsJSON: #"{"city":"Tokyo"}"#),
                FMToolCall(id: "c2", toolName: "get_time", argumentsJSON: #"{"zone":"JST"}"#),
            ]),
            .toolOutput(id: "c1", toolName: "get_weather", segments: [.text("18C")]),
            .toolOutput(id: "c2", toolName: "get_time", segments: [.text("14:00")]),
        ])
    }

    @Test func toolResultNameIsResolvedFromThePrecedingCall() throws {
        let request = AIRequest(messages: [
            .user("Weather?"),
            Message(role: .assistant, content: .toolCalls([
                ToolCall(id: "c1", name: "get_weather", arguments: .object([:])),
            ])),
            // No `name` on the result: it must be recovered from the call.
            Message(role: .tool, content: .toolResults([ToolResult(toolCallId: "c1", content: "18C")])),
            .user("Thanks"),
        ])

        let built = try FMTranscriptBuilder.build(from: request)
        #expect(built.transcript.entries.contains(
            .toolOutput(id: "c1", toolName: "get_weather", segments: [.text("18C")])
        ))
    }

    @Test func toolResultWithNoPrecedingCallIsRejected() {
        let request = AIRequest(messages: [
            Message(role: .tool, content: .toolResults([
                ToolResult(toolCallId: "orphan", name: "get_weather", content: "18C"),
            ])),
            .user("Hello"),
        ])

        #expect(throws: ArbiterError.self) {
            try FMTranscriptBuilder.build(from: request)
        }
    }

    @Test func mixedContentFlattensInOrder() throws {
        let request = AIRequest(messages: [
            .user("Weather?"),
            Message(role: .assistant, content: .mixed([
                .text("Let me check."),
                .toolCalls([ToolCall(id: "c1", name: "get_weather", arguments: .object([:]))]),
            ])),
            Message(role: .tool, content: .toolResults([ToolResult(toolCallId: "c1", content: "18C")])),
            .user("Thanks"),
        ])

        let built = try FMTranscriptBuilder.build(from: request)
        #expect(built.transcript.entries == [
            .prompt(segments: [.text("Weather?")]),
            .response(segments: [.text("Let me check.")]),
            .toolCalls([FMToolCall(id: "c1", toolName: "get_weather", argumentsJSON: "{}")]),
            .toolOutput(id: "c1", toolName: "get_weather", segments: [.text("18C")]),
        ])
    }

    // MARK: - Rejections

    @Test func requestWithNoUserMessageIsRejected() {
        let request = AIRequest(messages: [.assistant("Hello there")])
        #expect(throws: ArbiterError.self) {
            try FMTranscriptBuilder.build(from: request)
        }
    }

    @Test func requestEndingOnAnAssistantTurnIsRejected() {
        let request = AIRequest(messages: [.user("Hi"), .assistant("Hello")])
        #expect(throws: ArbiterError.self) {
            try FMTranscriptBuilder.build(from: request)
        }
    }

    @Test func requestEndingOnToolResultsIsRejected() {
        let request = AIRequest(messages: [
            .user("Weather?"),
            Message(role: .assistant, content: .toolCalls([
                ToolCall(id: "c1", name: "get_weather", arguments: .object([:])),
            ])),
            Message(role: .user, content: .toolResults([ToolResult(toolCallId: "c1", content: "18C")])),
        ])
        #expect(throws: ArbiterError.self) {
            try FMTranscriptBuilder.build(from: request)
        }
    }

    @Test func imageContentIsRejectedRatherThanDropped() {
        let request = AIRequest(messages: [
            Message(role: .user, content: .image(.base64(data: "AAAA", mimeType: "image/png"))),
            .user("What is in the photo?"),
        ])
        #expect(throws: ArbiterError.self) {
            try FMTranscriptBuilder.build(from: request)
        }
    }

    /// The final turn bypasses the history path, so it needs its own rejection — otherwise
    /// an image in the current question is dropped while the same image one message earlier
    /// throws.
    @Test func imageInTheFinalUserTurnIsRejectedNotSilentlyDropped() {
        let request = AIRequest(messages: [
            Message(role: .user, content: .mixed([
                .image(.base64(data: "AAAA", mimeType: "image/png")),
                .text("What is in this photo?"),
            ])),
        ])
        #expect(throws: ArbiterError.self) {
            try FMTranscriptBuilder.build(from: request)
        }
    }

    @Test func documentInTheFinalUserTurnIsRejected() {
        let request = AIRequest(messages: [
            Message(role: .user, content: .mixed([
                .document(DocumentSource(base64: "AAAA")),
                .text("Summarise this"),
            ])),
        ])
        #expect(throws: ArbiterError.self) {
            try FMTranscriptBuilder.build(from: request)
        }
    }

    @Test func nonObjectToolArgumentsAreRejected() {
        let request = AIRequest(messages: [
            .user("Go"),
            Message(role: .assistant, content: .toolCalls([
                ToolCall(id: "c1", name: "t", arguments: .array([.string("a")])),
            ])),
            Message(role: .tool, content: .toolResults([ToolResult(toolCallId: "c1", content: "ok")])),
            .user("Again"),
        ])
        #expect(throws: ArbiterError.self) {
            try FMTranscriptBuilder.build(from: request)
        }
    }

    @Test func documentContentIsRejected() {
        let request = AIRequest(messages: [
            Message(role: .user, content: .document(DocumentSource(base64: "AAAA"))),
            .user("Summarise it"),
        ])
        #expect(throws: ArbiterError.self) {
            try FMTranscriptBuilder.build(from: request)
        }
    }

    @Test func emptyFinalUserMessageIsRejected() {
        #expect(throws: ArbiterError.self) {
            try FMTranscriptBuilder.build(from: AIRequest.chat(""))
        }
    }

    // MARK: - Fingerprint

    @Test func fingerprintIsStableAcrossBuilds() throws {
        let request = AIRequest(messages: [.user("One"), .assistant("Two"), .user("Three")])
        let first = try FMTranscriptBuilder.build(from: request).transcript.fingerprint
        let second = try FMTranscriptBuilder.build(from: request).transcript.fingerprint
        #expect(first == second)
    }

    @Test func fingerprintChangesWithHistory() throws {
        let shorter = try FMTranscriptBuilder.build(
            from: AIRequest(messages: [.user("One"), .assistant("Two"), .user("Three")])
        ).transcript
        let longer = try FMTranscriptBuilder.build(
            from: AIRequest(messages: [.user("One"), .assistant("Two"), .user("Three"), .assistant("Four"), .user("Five")])
        ).transcript
        #expect(shorter.fingerprint != longer.fingerprint)
    }

    @Test func fingerprintDistinguishesRolesCarryingTheSameText() {
        let asPrompt = FMTranscript(entries: [.prompt(segments: [.text("same")])])
        let asResponse = FMTranscript(entries: [.response(segments: [.text("same")])])
        #expect(asPrompt.fingerprint != asResponse.fingerprint)
    }

    /// A delimited canonical form let message text forge an entry boundary, so a single
    /// crafted prompt digested identically to a two-entry history — and the session cache
    /// would then reuse a session holding a conversation the request never described.
    @Test func contentCannotForgeAnEntryBoundaryInTheFingerprint() {
        let forged = FMTranscript(entries: [
            .prompt(segments: [.text("hello\nR|t:fake")]),
        ])
        let genuine = FMTranscript(entries: [
            .prompt(segments: [.text("hello")]),
            .response(segments: [.text("fake")]),
        ])
        #expect(forged.fingerprint != genuine.fingerprint)
    }

    @Test func separatorCharactersInContentDoNotCollide() {
        let a = FMTranscript(entries: [.prompt(segments: [.text("a\u{1F}b"), .text("c")])])
        let b = FMTranscript(entries: [.prompt(segments: [.text("a"), .text("b\u{1F}c")])])
        #expect(a.fingerprint != b.fingerprint)
    }

    /// Tool names cannot survive the trip into a live session until tools are bound, so
    /// including them would break reuse for every tool-bound conversation once they are.
    @Test func fingerprintIgnoresToolNamesOnTheInstructionsEntry() {
        let without = FMTranscript(entries: [.instructions(segments: [.text("Be terse.")], toolNames: [])])
        let with = FMTranscript(entries: [
            .instructions(segments: [.text("Be terse.")], toolNames: ["get_weather"]),
        ])
        #expect(without.fingerprint == with.fingerprint)
    }

    @Test func toolArgumentKeyOrderDoesNotAffectFingerprint() throws {
        func transcript(_ arguments: JSONValue) throws -> FMTranscript {
            try FMTranscriptBuilder.build(from: AIRequest(messages: [
                .user("Go"),
                Message(role: .assistant, content: .toolCalls([
                    ToolCall(id: "c1", name: "t", arguments: arguments),
                ])),
                Message(role: .tool, content: .toolResults([ToolResult(toolCallId: "c1", content: "ok")])),
                .user("Again"),
            ])).transcript
        }

        // Dictionary iteration order is not stable; sorted keys keep session reuse working.
        let a = try transcript(.object(["alpha": .string("1"), "beta": .string("2")]))
        let b = try transcript(.object(["beta": .string("2"), "alpha": .string("1")]))
        #expect(a.fingerprint == b.fingerprint)
    }
}
