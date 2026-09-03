// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
@testable import Arbiter

/// Test double for `FMSessionRunning`.
///
/// `LanguageModelSession` is `final`, has no fakeable initialiser, and refuses to run
/// without Apple Intelligence — so the provider's own logic is only reachable through the
/// injected session factory. Scripts are consumed in order, one per `respond`/`stream` call.
final class MockFMSession: FMSessionRunning, @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `lock`.
    enum Step: Sendable {
        case text(String)
        /// Chunks are yielded as cumulative snapshots by `stream`.
        case chunks([String])
        case failure(FMErrorKind)
        /// Emits snapshots and then fails, so a mid-stream failure can be exercised.
        case chunksThenFailure([String], FMErrorKind)
        /// A turn in which the model called tools before answering. `outputs` pairs with
        /// `calls` by position, so the recorded transcript grows exactly as a real
        /// session's does — call entries followed by one output entry each.
        case toolTurn(text: String, calls: [FMToolCall], outputs: [String])
        /// A plain answer that also reports measured token counts, as a real session does
        /// on an OS new enough to count them.
        case textWithUsage(String, TokenUsage)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var _prompts: [String] = []
    private var _settings: [FMGenerationSettings] = []
    private var _isResponding = false
    private var _feedback: [(sentiment: AppleFMFeedbackSentiment?, issues: [AppleFMFeedbackIssue])] = []
    /// Grows exactly as a real session's does — `respond` appends a prompt entry and a
    /// response entry — so `transcriptFingerprint` models session reuse faithfully.
    private var _liveTranscript: FMTranscript

    let transcript: FMTranscript
    let options: AppleFMOptions

    init(transcript: FMTranscript = FMTranscript(), options: AppleFMOptions = AppleFMOptions(), steps: [Step]) {
        self.transcript = transcript
        self.options = options
        self.steps = steps
        self._liveTranscript = transcript
    }

    /// Prompts seen so far, in order.
    var prompts: [String] {
        lock.withLock { _prompts }
    }

    var settings: [FMGenerationSettings] {
        lock.withLock { _settings }
    }

    /// How many generation calls this session has received.
    var callCount: Int {
        lock.withLock { _prompts.count }
    }

    var isResponding: Bool {
        lock.withLock { _isResponding }
    }

    func setResponding(_ value: Bool) {
        lock.withLock { _isResponding = value }
    }

    var transcriptFingerprint: String {
        lock.withLock { _liveTranscript.fingerprint }
    }

    private func nextStep(prompt: String, settings: FMGenerationSettings) -> Step {
        lock.withLock {
            _prompts.append(prompt)
            _settings.append(settings)
            let step = steps.isEmpty ? .text("") : steps.removeFirst()

            // A failed generation leaves the session's transcript untouched.
            let produced: String? = switch step {
            case .text(let text): text
            case .textWithUsage(let text, _): text
            case .chunks(let chunks): chunks.last ?? ""
            case .toolTurn(let text, _, _): text
            case .failure, .chunksThenFailure: nil
            }
            if let produced {
                _liveTranscript.entries.append(.prompt(segments: [.text(prompt)]))
                if case .toolTurn(_, let calls, let outputs) = step, !calls.isEmpty {
                    _liveTranscript.entries.append(.toolCalls(calls))
                    for (index, call) in calls.enumerated() {
                        _liveTranscript.entries.append(.toolOutput(
                            id: call.id,
                            toolName: call.toolName,
                            segments: [.text(index < outputs.count ? outputs[index] : "")]
                        ))
                    }
                }
                _liveTranscript.entries.append(.response(segments: [.text(produced)]))
            }
            return step
        }
    }

    func respond(to prompt: String, settings: FMGenerationSettings) async throws -> FMRunResult {
        switch nextStep(prompt: prompt, settings: settings) {
        case .text(let text):
            return FMRunResult(text: text)
        case .textWithUsage(let text, let usage):
            // Mirrors `LiveFMSession`: counting is opt-in, so a session asked not to count
            // reports nothing even when it could.
            return FMRunResult(text: text, usage: settings.reportTokenUsage ? usage : nil)
        case .chunks(let chunks):
            return FMRunResult(text: chunks.last ?? "")
        case .toolTurn(let text, let calls, _):
            return FMRunResult(text: text, toolCalls: calls)
        case .failure(let kind):
            throw FMSessionError(kind: kind)
        case .chunksThenFailure(_, let kind):
            throw FMSessionError(kind: kind)
        }
    }

    func stream(
        to prompt: String,
        settings: FMGenerationSettings
    ) -> AsyncThrowingStream<FMStreamSnapshot, Error> {
        let step = nextStep(prompt: prompt, settings: settings)
        return AsyncThrowingStream { continuation in
            switch step {
            case .text(let text):
                continuation.yield(FMStreamSnapshot(content: text))
                continuation.finish()
            case .textWithUsage(let text, let usage):
                continuation.yield(FMStreamSnapshot(content: text))
                // Counts arrive on a final snapshot with unchanged content, as they do live.
                if settings.reportTokenUsage {
                    continuation.yield(FMStreamSnapshot(content: text, usage: usage))
                }
                continuation.finish()
            case .chunks(let chunks):
                for chunk in chunks {
                    continuation.yield(FMStreamSnapshot(content: chunk))
                }
                continuation.finish()
            case .failure(let kind):
                continuation.finish(throwing: FMSessionError(kind: kind))
            case .chunksThenFailure(let chunks, let kind):
                for chunk in chunks {
                    continuation.yield(FMStreamSnapshot(content: chunk))
                }
                continuation.finish(throwing: FMSessionError(kind: kind))
            case .toolTurn(let text, let calls, _):
                // Mirrors `LiveFMSession`: the calls are only knowable once the turn ends,
                // so they arrive on a final snapshot whose content is unchanged.
                continuation.yield(FMStreamSnapshot(content: text))
                continuation.yield(FMStreamSnapshot(content: text, toolCalls: calls))
                continuation.finish()
            }
        }
    }

    /// The feedback this session was asked to file, in order.
    var feedback: [(sentiment: AppleFMFeedbackSentiment?, issues: [AppleFMFeedbackIssue])] {
        lock.withLock { _feedback }
    }

    func feedbackAttachment(
        sentiment: AppleFMFeedbackSentiment?,
        issues: [AppleFMFeedbackIssue]
    ) -> Data {
        lock.withLock { _feedback.append((sentiment, issues)) }
        return Data("mock-feedback".utf8)
    }
}

/// Records every session the provider asks for, so reuse can be asserted.
final class MockFMSessionFactory: @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `lock`.
    private let lock = NSLock()
    private var scripts: [[MockFMSession.Step]]
    private var _sessions: [MockFMSession] = []

    /// - Parameter scripts: one script per session created, in order. The last script is
    ///   reused once exhausted, so a test only scripts what it cares about.
    init(scripts: [[MockFMSession.Step]]) {
        self.scripts = scripts
    }

    var sessions: [MockFMSession] {
        lock.withLock { _sessions }
    }

    var sessionCount: Int {
        lock.withLock { _sessions.count }
    }

    var factory: FMSessionFactory {
        { [self] transcript, options in
            lock.withLock {
                let script = scripts.count > 1 ? scripts.removeFirst() : (scripts.first ?? [])
                let session = MockFMSession(transcript: transcript, options: options, steps: script)
                _sessions.append(session)
                return session
            }
        }
    }
}
