// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Structural facts about a prompt, derived from `NLTagger`'s lexical classes rather than
/// from keyword lists.
///
/// Keywords answer "what did the user ask for"; these signals answer "how much is being
/// asked". A prompt with eight sentences and a dozen verbs is a harder job than a
/// four-word one that happens to contain the same keyword, and that difference is what
/// separates a trivial routing tier from a complex one.
///
/// Fenced code is measured but excluded from the prose counts — a three-line snippet
/// tokenises as four "sentences" and would otherwise inflate every structural signal.
struct LexicalSignals: Sendable, Equatable {
    /// Sentences in the prose, excluding fenced code blocks.
    var sentenceCount: Int = 0
    /// Words in the prose, excluding fenced code blocks.
    var wordCount: Int = 0
    var verbCount: Int = 0
    var nounCount: Int = 0
    /// Conjunctions and prepositions — a proxy for subordinate clauses, and so for how
    /// many conditions the model has to hold at once.
    var clauseMarkerCount: Int = 0
    var questionCount: Int = 0
    /// Lines inside ``` fences.
    var fencedCodeLineCount: Int = 0
    var hasCodeFence: Bool { fencedCodeLineCount > 0 }
    /// Whether the first word of the prose is a verb — "write a…", "summarise this…".
    var startsWithVerb: Bool = false
    /// Whether the lexical layer ran. False on a platform without the Natural Language
    /// frameworks, or for text whose language could not be determined; the counts that
    /// depend on tagging are zero in that case, and callers must not read a zero as
    /// "no verbs".
    var taggingAvailable: Bool = false

    /// Analyse `text`, splitting fenced code from prose first.
    static func analyse(_ text: String) -> LexicalSignals {
        var signals = LexicalSignals()
        let (prose, fencedLines) = splitFencedCode(text)
        signals.fencedCodeLineCount = fencedLines

        let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        signals.questionCount = prose.filter { $0 == "?" }.count
        guard !trimmed.isEmpty else { return signals }

        #if canImport(NaturalLanguage)
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(trimmed)
        let language = recogniser.dominantLanguage

        let sentenceTokeniser = NLTokenizer(unit: .sentence)
        sentenceTokeniser.string = trimmed
        sentenceTokeniser.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { _, _ in
            signals.sentenceCount += 1
            return true
        }

        guard let language,
              NLTagger.availableTagSchemes(for: .word, language: language).contains(.lexicalClass)
        else {
            signals.wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
            return signals
        }

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = trimmed
        tagger.setLanguage(language, range: trimmed.startIndex..<trimmed.endIndex)

        var isFirstWord = true
        tagger.enumerateTags(
            in: trimmed.startIndex..<trimmed.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, _ in
            signals.wordCount += 1
            switch tag {
            case .verb:
                signals.verbCount += 1
                if isFirstWord { signals.startsWithVerb = true }
            case .noun:
                signals.nounCount += 1
            case .conjunction, .preposition:
                signals.clauseMarkerCount += 1
            default:
                break
            }
            isFirstWord = false
            return true
        }
        signals.taggingAvailable = true
        #else
        signals.wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        signals.sentenceCount = trimmed.split(whereSeparator: { ".!?".contains($0) }).count
        #endif

        return signals
    }

    /// Split ``` fenced blocks out of `text`, returning the prose and the number of code
    /// lines removed. An unterminated fence takes everything after it as code, which is
    /// what a half-pasted snippet actually is.
    static func splitFencedCode(_ text: String) -> (prose: String, fencedLines: Int) {
        guard text.contains("```") else { return (text, 0) }
        var prose: [Substring] = []
        var fencedLines = 0
        var insideFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if insideFence {
                fencedLines += 1
            } else {
                prose.append(line)
            }
        }
        return (prose.joined(separator: "\n"), fencedLines)
    }
}

/// What an on-device task classifier concluded about a prompt.
public struct TaskClassification: Sendable, Equatable {
    public let task: DetectedTask
    /// 0…1. A classification below ``RequestAnalyser/classifierConfidenceThreshold`` is
    /// ignored in favour of the built-in heuristics.
    public let confidence: Double

    public init(task: DetectedTask, confidence: Double) {
        self.task = task
        self.confidence = confidence
    }
}

/// An on-device classifier consulted by ``RequestAnalyser`` before its own heuristics.
///
/// The intended implementation is Apple Foundation Models' `.contentTagging` use case,
/// which returns topic and action tags for a prompt; Arbiter ships the hook rather than
/// the adapter, because `.contentTagging` needs an OS 26 session that the analyser — a
/// synchronous, always-available component — cannot depend on. A classifier that throws,
/// or that returns `nil`, leaves the heuristics in charge.
///
/// It receives the request's text, and the router consults it whatever the privacy
/// assessment concluded, so it must run **on device**: a classifier backed by a remote
/// service would send the text of a request the guard has just marked private.
public protocol TaskClassifier: Sendable {
    func classify(_ text: String) async throws -> TaskClassification?
}
