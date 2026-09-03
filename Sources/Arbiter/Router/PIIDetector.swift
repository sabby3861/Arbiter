// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// The layered PII detector behind ``PrivacyGuard``.
///
/// Three layers run over the same text, cheapest and most certain first:
///
/// 1. **Patterns** — US Social Security Numbers, and payment card numbers validated with
///    a Luhn checksum so a 16-digit order number is not mistaken for a card.
/// 2. **`NSDataDetector`** — phone numbers, postal addresses and `mailto:` links. This
///    replaces the old hand-rolled email/phone regexes; it understands international
///    formats and multi-line addresses that a pattern cannot. Matches that overlap a
///    layer-1 hit are dropped, because the detector reads an SSN as a phone number.
/// 3. **`NLTagger` name tagging** — person, organisation and place names. Statistical, so
///    hits are reported as ``PrivacyDetectionConfidence/heuristic``.
///
/// The name layer's coverage is narrower than the other two. `.nameType` ships for only a
/// handful of languages — English and French on current macOS; Spanish, German, Italian,
/// Japanese, Chinese, Portuguese, Russian and Turkish are *not* covered — and
/// `NLLanguageRecognizer` guesses badly on very short strings ("hi" comes back as
/// Catalan). So a language the tagger cannot handle is reported as
/// ``PrivacyDetectionConfidence/heuristic``, not `.unknown`: the deterministic layers are
/// language-independent and did run, and treating it as unknown would make a fail-closed
/// guard block every Spanish prompt and every two-word English one. `.unknown` is reserved
/// for text nothing could read — no determinable language at all, or content the guard
/// cannot see inside (a PDF, an image).
///
/// `NSRegularExpression` and its `NSDataDetector` subclass are immutable and safe to share
/// across threads once built, so both are compiled once. `NLTagger` is neither `Sendable`
/// nor documented as thread-safe, so one is created per call.
struct PIIDetector: Sendable {
    /// The outcome of a single detection pass: categories, and how much they can be trusted.
    struct Result: Sendable, Equatable {
        var types: Set<PIIType> = []
        var confidence: PrivacyDetectionConfidence = .high
    }

    /// Whether to run the statistical name-tagging layer.
    ///
    /// Switching it off is an explicit choice to ignore names, so a clean result is still
    /// reported as ``PrivacyDetectionConfidence/high`` — the caller asked for the
    /// deterministic layers, and those were conclusive.
    var detectNames: Bool = true

    /// What the name layer managed on this text.
    enum NameLayerOutcome: Equatable {
        case ran(Set<PIIType>)
        /// The language was identified, but `NLTagger` has no name scheme for it.
        case languageUnsupported
        /// No dominant language could be identified, so nothing read this text.
        case languageUndeterminable
    }

    /// - Parameter hasUnscannableContent: the request also carries something the guard
    ///   cannot read — a PDF, an image. Nothing found in the text says nothing about those.
    func detect(in text: String, hasUnscannableContent: Bool = false) -> Result {
        guard !text.isEmpty else {
            return Result(types: [], confidence: hasUnscannableContent ? .unknown : .high)
        }

        var types: Set<PIIType> = []
        let patternMatches = Self.patternMatches(in: text)
        for match in patternMatches { types.insert(match.type) }

        let patternRanges = patternMatches.map(\.range)
        types.formUnion(Self.dataDetectorMatches(in: text, excluding: patternRanges))

        var nameOutcome = NameLayerOutcome.ran([])
        if detectNames {
            nameOutcome = Self.nameMatches(in: text)
            if case .ran(let names) = nameOutcome { types.formUnion(names) }
        }

        return Result(
            types: types,
            confidence: confidence(
                for: types, nameOutcome: nameOutcome, hasUnscannableContent: hasUnscannableContent
            )
        )
    }

    private func confidence(
        for types: Set<PIIType>,
        nameOutcome: NameLayerOutcome,
        hasUnscannableContent: Bool
    ) -> PrivacyDetectionConfidence {
        // Content nothing could read outranks everything: the text may be clean and the
        // attachment may not be.
        if hasUnscannableContent { return .unknown }
        // A deterministic hit is certain whatever the statistical layer managed.
        if types.contains(where: { $0.isDeterministic }) { return .high }

        switch nameOutcome {
        case .languageUndeterminable:
            return .unknown
        case .languageUnsupported:
            // The deterministic layers ran and found nothing; the name layer could not run
            // at all, so this is not a confident clean either.
            return .heuristic
        case .ran:
            return types.isEmpty ? .high : .heuristic
        }
    }
}

// MARK: - Layer 1: patterns

private extension PIIDetector {
    struct PatternMatch {
        let type: PIIType
        let range: NSRange
    }

    /// US SSN, and a loose card-shaped run of 13–19 digits that a Luhn check then confirms.
    static let patterns: [(type: PIIType, regex: NSRegularExpression)] = {
        let sources: [(PIIType, String)] = [
            (.socialSecurityNumber, #"\b\d{3}-\d{2}-\d{4}\b"#),
            (.creditCardNumber, #"\b(?:\d[ -]?){12,18}\d\b"#),
        ]
        return sources.compactMap { type, source in
            guard let regex = try? NSRegularExpression(pattern: source) else { return nil }
            return (type, regex)
        }
    }()

    static func patternMatches(in text: String) -> [PatternMatch] {
        let range = NSRange(text.startIndex..., in: text)
        var matches: [PatternMatch] = []
        for (type, regex) in patterns {
            for result in regex.matches(in: text, range: range) {
                guard let matched = Range(result.range, in: text) else { continue }
                if type == .creditCardNumber, !isLuhnValid(String(text[matched])) { continue }
                matches.append(PatternMatch(type: type, range: result.range))
            }
        }
        return matches
    }

    /// The Luhn checksum every major card network's numbers satisfy. Without it the
    /// card pattern fires on any long digit run — order numbers, IDs, hashes.
    static func isLuhnValid(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard digits.count >= 13, digits.count <= 19 else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset.isMultiple(of: 2) {
                sum += digit
            } else {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            }
        }
        return sum.isMultiple(of: 10)
    }
}

// MARK: - Layer 2: NSDataDetector

private extension PIIDetector {
    /// `.date` is deliberately absent: "what is the weather today?" is a date match and
    /// is not personal information.
    static let dataDetector: NSDataDetector? = {
        let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .address, .link]
        return try? NSDataDetector(types: types.rawValue)
    }()

    static func dataDetectorMatches(in text: String, excluding ranges: [NSRange]) -> Set<PIIType> {
        guard let detector = dataDetector else { return [] }
        var types: Set<PIIType> = []
        let full = NSRange(text.startIndex..., in: text)
        detector.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            // The detector reads "123-45-6789" as a phone number; the SSN pattern already
            // claimed that span and named it correctly.
            guard !ranges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return }
            switch match.resultType {
            case .phoneNumber:
                types.insert(.phoneNumber)
            case .address:
                types.insert(.postalAddress)
            case .link:
                // Only mail links are personal information; an https link is not.
                if match.url?.scheme?.lowercased() == "mailto" { types.insert(.emailAddress) }
            default:
                break
            }
        }
        return types
    }
}

// MARK: - Layer 3: NLTagger name types

private extension PIIDetector {
    static func nameMatches(in text: String) -> NameLayerOutcome {
        #if canImport(NaturalLanguage)
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(text)
        guard let language = recogniser.dominantLanguage else { return .languageUndeterminable }
        guard NLTagger.availableTagSchemes(for: .word, language: language).contains(.nameType) else {
            return .languageUnsupported
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.setLanguage(language, range: text.startIndex..<text.endIndex)

        var types: Set<PIIType> = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .omitOther, .joinNames]
        ) { tag, _ in
            switch tag {
            case .personalName: types.insert(.personName)
            case .organizationName: types.insert(.organizationName)
            case .placeName: types.insert(.placeName)
            default: break
            }
            return true
        }
        return .ran(types)
        #else
        // No Natural Language framework on this platform: the layer did not run, and
        // saying so is what stops a clean result from looking confident.
        return .languageUnsupported
        #endif
    }
}
