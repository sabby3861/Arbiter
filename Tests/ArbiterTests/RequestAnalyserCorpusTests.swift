// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

/// A classifier whose verdict the test dictates.
struct StubTaskClassifier: TaskClassifier {
    enum Behaviour: Sendable {
        case verdict(TaskClassification)
        case silent
        case failure
    }

    let behaviour: Behaviour

    func classify(_ text: String) async throws -> TaskClassification? {
        switch behaviour {
        case .verdict(let classification): return classification
        case .silent: return nil
        case .failure: throw ArbiterError.invalidRequest(reason: "classifier unavailable")
        }
    }
}

struct TaskCase {
    let prompt: String
    let expected: DetectedTask

    init(_ prompt: String, _ expected: DetectedTask) {
        self.prompt = prompt
        self.expected = expected
    }
}

@Suite("RequestAnalyser corpus")
struct RequestAnalyserCorpusTests {
    let analyser = RequestAnalyser()

    /// Labelled prompts, three or more per task the analyser can name from wording alone.
    /// `.structuredOutput` is absent: it comes from the response format, not the text.
    static let corpus: [TaskCase] = [
        TaskCase("Classify this review as positive or negative", .classification),
        TaskCase("Is this email spam, yes or no?", .classification),
        TaskCase("What is the sentiment of this message?", .classification),

        TaskCase("Extract the invoice number from this receipt", .extraction),
        TaskCase("List all the dates mentioned in the contract", .extraction),
        TaskCase("Pull out every product name from the description", .extraction),

        TaskCase("Translate this paragraph to French", .translation),
        TaskCase("Translate 'good morning' into Japanese", .translation),
        TaskCase("Say this in Spanish for a formal audience", .translation),

        TaskCase("Summarize the attached meeting notes", .summarization),
        TaskCase("Give me a TLDR of this thread", .summarization),
        TaskCase("Recap what happened in the last release", .summarization),

        TaskCase("Write a function that reverses a linked list", .codeGeneration),
        TaskCase("Refactor this view controller to use async/await", .codeGeneration),
        TaskCase("Debug why my SwiftUI list flickers on reload", .codeGeneration),
        TaskCase("Implement rate limiting for the upload endpoint", .codeGeneration),

        TaskCase("Explain why the deployment keeps failing", .reasoning),
        TaskCase("Compare Postgres and SQLite for an offline-first app", .reasoning),
        TaskCase("Walk me through the trade-offs of actor isolation", .reasoning),
        TaskCase("Evaluate whether we should migrate off Redis", .reasoning),

        TaskCase("Write an essay about the history of typography", .longGeneration),
        TaskCase("Write a report on last quarter's churn", .longGeneration),
        TaskCase("Give me a detailed guide to sourdough starters", .longGeneration),

        TaskCase("Write a haiku about winter light", .shortGeneration),
        TaskCase("Draft a two-line apology to a customer", .shortGeneration),
        TaskCase("Generate a tagline for a coffee subscription", .shortGeneration),
        TaskCase("Suggest a name for my terminal app", .shortGeneration),

        TaskCase("Hello, how are you today?", .conversation),
        TaskCase("Thanks, that helped a lot", .conversation),
        TaskCase("Good morning! Any news?", .conversation),

        // Prompts with none of the trigger words, where only the lexical layer can help.
        TaskCase("Turn these notes into a checklist", .shortGeneration),
        TaskCase("Polish the wording of my bio", .shortGeneration),
        TaskCase("Make this email sound friendlier", .shortGeneration),
        TaskCase("Shorten this to under 200 characters", .shortGeneration),
        TaskCase("Rename these folders sensibly", .shortGeneration),
        TaskCase("Who won the 1998 World Cup?", .conversation),
        TaskCase("Any idea what broke the build?", .conversation),
    ]

    @Test("Task detection precision and recall over the labelled corpus")
    func taskDetectionScores() {
        var scores: [DetectedTask: DetectionScore] = [:]
        var correct = 0
        var mistakes: [String] = []

        for testCase in Self.corpus {
            let detected = analyser.analyse(AIRequest.chat(testCase.prompt)).detectedTask
            if detected == testCase.expected {
                correct += 1
                scores[testCase.expected, default: DetectionScore()].truePositives += 1
            } else {
                scores[testCase.expected, default: DetectionScore()].falseNegatives += 1
                scores[detected, default: DetectionScore()].falsePositives += 1
                mistakes.append("\(testCase.prompt) → \(detected.rawValue) (expected \(testCase.expected.rawValue))")
            }
        }

        let accuracy = Double(correct) / Double(Self.corpus.count)
        print("Task detection over \(Self.corpus.count) labelled prompts — accuracy \(String(format: "%.2f", accuracy))")
        for task in scores.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let score = scores[task]!
            print(String(
                format: "  %-18@ precision %.2f  recall %.2f  (tp %d, fp %d, fn %d)",
                task.rawValue as NSString, score.precision, score.recall,
                score.truePositives, score.falsePositives, score.falseNegatives
            ))
        }
        for mistake in mistakes { print("  miss: \(mistake)") }

        // Floors sit below what the corpus measures today, so a Natural Language model
        // update does not turn into a red build.
        #expect(accuracy >= 0.80)
    }

    // MARK: - Lexical layer

    @Test("A multi-sentence request outranks the same words in one sentence")
    func structureRaisesComplexity() {
        let single = analyser.analyse(AIRequest.chat("Rename the folder and move the files across"))
        let manyParts = analyser.analyse(AIRequest.chat(
            "Rename the folder. Move the files across. Check nothing broke. Tell me what changed."
        ))
        #expect(manyParts.complexity > single.complexity)
    }

    @Test("A short single-sentence request is never bumped")
    func shortRequestIsNotBumped() {
        let signals = LexicalSignals.analyse("Translate 'hello' to French")
        #expect(signals.sentenceCount == 1)
        // Asserted at the bump itself, so this cannot pass merely because the task table
        // already puts translation at `.simple`.
        for tier in [ComplexityTier.trivial, .simple, .moderate] {
            #expect(analyser.structuralBump(tier, signals: signals) == tier)
        }
        #expect(analyser.analyse(AIRequest.chat("Translate 'hello' to French")).complexity <= .simple)
    }

    // MARK: - The system prompt is not the user's request

    @Test("A long system prompt does not raise the complexity of a short request")
    func systemPromptDoesNotInflateComplexity() {
        let bare = AIRequest.chat("Translate 'hello' to French")
        var withSystem = bare
        withSystem.systemPrompt = "You are a helpful assistant. Answer concisely. "
            + "Do not invent facts. Cite sources when possible. Always be polite."
        #expect(analyser.analyse(withSystem).complexity == analyser.analyse(bare).complexity)
    }

    @Test("A system prompt does not stand in for the user's opening word")
    func systemPromptDoesNotHijackTheImperativeCheck() {
        var request = AIRequest.chat("Turn these notes into a checklist")
        request.systemPrompt = "You are a helpful assistant."
        #expect(analyser.analyse(request).detectedTask == .shortGeneration)
    }

    @Test("A system prompt still counts towards keyword detection")
    func systemPromptStillReachesTheKeywordLayer() {
        var request = AIRequest.chat("Do this for me")
        request.systemPrompt = "Summarize whatever the user sends."
        #expect(analyser.analyse(request).detectedTask == .summarization)
    }

    @Test("A pile of questions raises complexity")
    func manyQuestionsRaiseComplexity() {
        let one = analyser.analyse(AIRequest.chat("Which database should I pick?"))
        let several = analyser.analyse(AIRequest.chat(
            "Which database should I pick? How do I migrate? What breaks first?"
        ))
        #expect(several.complexity > one.complexity)
    }

    @Test("The structural bump never exceeds one tier and never reaches expert")
    func bumpIsBounded() {
        let signals = LexicalSignals.analyse(
            "One. Two. Three. Four. Five. Six. Seven. Eight. Nine. Ten."
        )
        #expect(analyser.structuralBump(.trivial, signals: signals) == .simple)
        #expect(analyser.structuralBump(.simple, signals: signals) == .moderate)
        #expect(analyser.structuralBump(.moderate, signals: signals) == .complex)
        #expect(analyser.structuralBump(.complex, signals: signals) == .complex)
        #expect(analyser.structuralBump(.expert, signals: signals) == .expert)
    }

    @Test("An unrecognised imperative is a generation request, not conversation")
    func imperativeFallsBackToShortGeneration() {
        #expect(analyser.analyse(AIRequest.chat("Turn these notes into a checklist")).detectedTask == .shortGeneration)
        #expect(analyser.analyse(AIRequest.chat("Polish the wording of my bio")).detectedTask == .shortGeneration)
    }

    @Test("A greeting stays conversation")
    func greetingStaysConversation() {
        #expect(analyser.analyse(AIRequest.chat("Hello, how are you?")).detectedTask == .conversation)
        #expect(analyser.analyse(AIRequest.chat("Thanks, that helped")).detectedTask == .conversation)
    }

    // MARK: - Fenced code

    @Test("Fenced code is measured but kept out of the prose counts")
    func fencedCodeIsSplitOut() {
        let text = """
        What's wrong here?
        ```swift
        let x = 1
        let y = 2
        print(x + y)
        ```
        """
        let (prose, fenced) = LexicalSignals.splitFencedCode(text)
        #expect(fenced == 3)
        #expect(!prose.contains("let x"))
        #expect(prose.contains("What's wrong here?"))

        let signals = LexicalSignals.analyse(text)
        #expect(signals.hasCodeFence)
        #expect(signals.sentenceCount == 1, "the snippet's three lines are not three sentences")
    }

    @Test("An unterminated fence takes the rest of the text as code")
    func unterminatedFenceIsStillCode() {
        let (prose, fenced) = LexicalSignals.splitFencedCode("Look:\n```\nlet a = 1\nlet b = 2")
        #expect(fenced == 2)
        #expect(prose.trimmingCharacters(in: .whitespacesAndNewlines) == "Look:")
    }

    @Test("A large pasted snippet raises complexity on its own")
    func largeSnippetRaisesComplexity() {
        let snippet = (1...25).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let signals = LexicalSignals.analyse("Have a look:\n```swift\n\(snippet)\n```")
        #expect(signals.fencedCodeLineCount == 25)
        #expect(analyser.structuralBump(.simple, signals: signals) == .moderate)
    }

    // MARK: - Classifier hook

    @Test("A confident classifier decides the task")
    func confidentClassifierWins() async {
        let classifier = StubTaskClassifier(
            behaviour: .verdict(TaskClassification(task: .summarization, confidence: 0.9))
        )
        let result = await analyser.analyse(
            AIRequest.chat("Write a function that reverses a linked list"),
            classifier: classifier
        )
        #expect(result.detectedTask == .summarization)
    }

    @Test("An unsure classifier leaves the heuristics in charge")
    func unsureClassifierIsIgnored() async {
        let classifier = StubTaskClassifier(
            behaviour: .verdict(TaskClassification(task: .summarization, confidence: 0.4))
        )
        let result = await analyser.analyse(
            AIRequest.chat("Write a function that reverses a linked list"),
            classifier: classifier
        )
        #expect(result.detectedTask == .codeGeneration)
    }

    @Test("A silent or failing classifier changes nothing")
    func silentAndFailingClassifiersAreHarmless() async {
        for behaviour in [StubTaskClassifier.Behaviour.silent, .failure] {
            let result = await analyser.analyse(
                AIRequest.chat("Summarize the attached meeting notes"),
                classifier: StubTaskClassifier(behaviour: behaviour)
            )
            #expect(result.detectedTask == .summarization)
        }
    }

    @Test("No classifier at all behaves exactly like the synchronous analysis")
    func noClassifierMatchesSyncPath() async {
        let request = AIRequest.chat("Explain why the deployment keeps failing")
        let asynchronous = await analyser.analyse(request, classifier: nil)
        #expect(asynchronous == analyser.analyse(request))
    }

    @Test("A response schema outranks even a confident classifier")
    func structuredOutputBeatsTheClassifier() async {
        var request = AIRequest.chat("Write a haiku about winter light")
        request.responseFormat = .json
        let result = await analyser.analyse(
            request,
            classifier: StubTaskClassifier(
                behaviour: .verdict(TaskClassification(task: .conversation, confidence: 1.0))
            )
        )
        #expect(result.detectedTask == .structuredOutput)
    }

    @Test("The router consults a configured classifier")
    func routerUsesTheClassifier() async {
        let router = SmartRouter(
            connectivityCheck: { .wifi },
            deviceAssessment: { DeviceCapabilities(memoryGB: 16, thermalLevel: .nominal, processorCount: 8) },
            taskClassifier: StubTaskClassifier(
                behaviour: .verdict(TaskClassification(task: .translation, confidence: 0.95))
            ),
            performanceTracker: .inMemory()
        )
        let decision = await router.route(
            AIRequest.chat("Write a function that reverses a linked list"),
            policy: .smart,
            providers: [MockProvider(id: .anthropic), MockLocalProvider()],
            budgetRemaining: nil
        )
        #expect(decision.analysis?.detectedTask == .translation)
    }
}
