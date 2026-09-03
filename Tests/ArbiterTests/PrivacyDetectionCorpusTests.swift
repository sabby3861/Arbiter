// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import Arbiter

/// A labelled corpus for the layered PII detector.
///
/// Deterministic categories (email, phone, address, SSN, card) are asserted case by case:
/// they come from patterns and `NSDataDetector`, and a miss there is a bug. Name
/// categories come from `NLTagger`, whose output shifts between OS releases, so those are
/// held to aggregate precision/recall floors instead of per-case equality. Both sets of
/// numbers are printed so a run's real scores land in the test log.
struct PIICase {
    let text: String
    /// Ground truth for the deterministic layers.
    let deterministic: Set<PIIType>
    /// Ground truth for the statistical name layer.
    let names: Set<PIIType>
    let note: String

    init(_ text: String, deterministic: Set<PIIType> = [], names: Set<PIIType> = [], note: String = "") {
        self.text = text
        self.deterministic = deterministic
        self.names = names
        self.note = note
    }
}

enum PIICorpus {
    static let deterministicTypes: Set<PIIType> = [
        .emailAddress, .phoneNumber, .postalAddress,
        .socialSecurityNumber, .creditCardNumber,
    ]
    static let nameTypes: Set<PIIType> = [.personName, .organizationName, .placeName]

    static let cases: [PIICase] = [
        // — Email —
        PIICase("Contact me at user@example.com", deterministic: [.emailAddress]),
        PIICase("Send the invoice to billing@acme.co.uk please", deterministic: [.emailAddress]),
        PIICase("Forward this thread to j.doe+work@mail.example.org", deterministic: [.emailAddress]),

        // — Phone —
        PIICase("Call me at 555-123-4567", deterministic: [.phoneNumber]),
        PIICase("My number is +1 (415) 555-0132", deterministic: [.phoneNumber]),
        PIICase("Ring the office on (212) 555-8891 after nine", deterministic: [.phoneNumber]),

        // — Postal address —
        PIICase(
            "I live at 1 Infinite Loop, Cupertino, CA 95014",
            deterministic: [.postalAddress],
            names: [.placeName],
            note: "the city is a genuine place name; the state code is tagged as an organisation, which is a miss"
        ),
        PIICase(
            "Ship it to 350 Fifth Avenue, New York, NY 10118",
            deterministic: [.postalAddress],
            names: [.placeName]
        ),

        // — SSN —
        PIICase("SSN is 123-45-6789", deterministic: [.socialSecurityNumber]),
        PIICase("Her social security number is 987-65-4320.", deterministic: [.socialSecurityNumber]),

        // — Payment card —
        PIICase("Card: 4111 1111 1111 1111", deterministic: [.creditCardNumber]),
        PIICase("Pay with 5500 0000 0000 0004, expiry next June", deterministic: [.creditCardNumber]),
        PIICase("Charge 3782 822463 10005 instead", deterministic: [.creditCardNumber], note: "15-digit Amex"),

        // — Mixed —
        PIICase(
            "Email sam@example.com or call 555-987-6543 about the 4012 8888 8888 1881 charge",
            deterministic: [.emailAddress, .phoneNumber, .creditCardNumber]
        ),

        // — Names only —
        PIICase("Barack Obama visited Paris with Microsoft executives", names: [.personName, .placeName, .organizationName]),
        PIICase("Ask Sarah Whitfield to review the draft", names: [.personName]),
        PIICase("Draft a note to Priya Raghunathan about the delay", names: [.personName]),
        PIICase("I work at Acme Corporation in Berlin", names: [.organizationName, .placeName]),

        // — Clean: nothing personal at all —
        PIICase("What is the weather today?"),
        PIICase("Summarize this article in three bullet points."),
        PIICase("Explain how a hash map works."),
        PIICase("Write a Swift function that sorts an array of integers"),
        PIICase("Translate 'good morning' to Spanish"),
        PIICase("Compare REST and GraphQL for a mobile client"),
        PIICase("The meeting moved to nine tomorrow morning"),
        PIICase("Order number 1234567890123456 was shipped", note: "16 digits, fails Luhn — not a card"),
        PIICase("Reference 9876543210987654 in the ticket", note: "16 digits, fails Luhn"),
        PIICase("The build takes 45 minutes on this machine"),
        PIICase("Visit https://example.com/docs for the guide", note: "an https link is not personal data"),
        PIICase("Rewrite this paragraph to be shorter and clearer"),
    ]
}

/// Precision/recall over one category.
struct DetectionScore {
    var truePositives = 0
    var falsePositives = 0
    var falseNegatives = 0

    var precision: Double {
        let denominator = truePositives + falsePositives
        return denominator == 0 ? 1.0 : Double(truePositives) / Double(denominator)
    }

    var recall: Double {
        let denominator = truePositives + falseNegatives
        return denominator == 0 ? 1.0 : Double(truePositives) / Double(denominator)
    }
}

@Suite("PrivacyGuard detection corpus")
struct PrivacyDetectionCorpusTests {
    let detector = PIIDetector()

    @Test("Deterministic categories are found exactly, case by case")
    func deterministicLayersAreExact() {
        for testCase in PIICorpus.cases {
            let found = detector.detect(in: testCase.text).types
                .intersection(PIICorpus.deterministicTypes)
            #expect(
                found == testCase.deterministic,
                "\(testCase.text) — expected \(testCase.deterministic.map(\.rawValue).sorted()), got \(found.map(\.rawValue).sorted())"
            )
        }
    }

    @Test("Precision and recall over the labelled corpus meet their floors")
    func precisionAndRecall() {
        var scores: [PIIType: DetectionScore] = [:]
        var deterministicOverall = DetectionScore()
        var nameOverall = DetectionScore()

        for testCase in PIICorpus.cases {
            let detected = detector.detect(in: testCase.text).types
            let expected = testCase.deterministic.union(testCase.names)

            for type in PIICorpus.deterministicTypes.union(PIICorpus.nameTypes) {
                let isExpected = expected.contains(type)
                let isDetected = detected.contains(type)
                guard isExpected || isDetected else { continue }

                var score = scores[type] ?? DetectionScore()
                let isName = PIICorpus.nameTypes.contains(type)
                if isExpected && isDetected {
                    score.truePositives += 1
                    if isName { nameOverall.truePositives += 1 } else { deterministicOverall.truePositives += 1 }
                } else if isDetected {
                    score.falsePositives += 1
                    if isName { nameOverall.falsePositives += 1 } else { deterministicOverall.falsePositives += 1 }
                } else {
                    score.falseNegatives += 1
                    if isName { nameOverall.falseNegatives += 1 } else { deterministicOverall.falseNegatives += 1 }
                }
                scores[type] = score
            }
        }

        print("PII detection over \(PIICorpus.cases.count) labelled prompts")
        for type in PIIType.builtIn {
            guard let score = scores[type] else { continue }
            print(String(
                format: "  %-22@ precision %.2f  recall %.2f  (tp %d, fp %d, fn %d)",
                type.rawValue as NSString, score.precision, score.recall,
                score.truePositives, score.falsePositives, score.falseNegatives
            ))
        }
        print(String(
            format: "  %-22@ precision %.2f  recall %.2f",
            "DETERMINISTIC" as NSString, deterministicOverall.precision, deterministicOverall.recall
        ))
        print(String(
            format: "  %-22@ precision %.2f  recall %.2f",
            "NAMES (NLTagger)" as NSString, nameOverall.precision, nameOverall.recall
        ))

        // Deterministic layers are exact on this corpus and are held to it.
        #expect(deterministicOverall.precision == 1.0)
        #expect(deterministicOverall.recall == 1.0)
        // Name tagging is statistical and drifts between OS releases, so the floors sit
        // below what this corpus measures today — precision 0.69, recall 1.00 on macOS 15
        // — and a model update does not turn into a red build. The precision misses are
        // real and worth knowing: the tagger reads the state codes "CA" and "NY" as
        // organisations, the language "Spanish" as a place, and a sentence-initial
        // "Charge" as an organisation. They cost routing headroom, never privacy: every
        // one is a false *positive*, which keeps a request on-device.
        #expect(nameOverall.precision >= 0.60)
        #expect(nameOverall.recall >= 0.90)
    }

    @Test("A clean prompt is a confident 'nothing found', not an unknown")
    func cleanPromptIsConfident() {
        let result = detector.detect(in: "Explain how a hash map works.")
        #expect(result.types.isEmpty)
        #expect(result.confidence == .high)
    }

    @Test("A name-only hit is reported as heuristic, a pattern hit as high")
    func confidenceReflectsTheLayerThatFired() {
        let names = detector.detect(in: "Ask Sarah Whitfield to review the draft")
        #expect(names.types.contains(.personName))
        #expect(names.confidence == .heuristic)

        let pattern = detector.detect(in: "SSN is 123-45-6789")
        #expect(pattern.types == [.socialSecurityNumber])
        #expect(pattern.confidence == .high)
    }

    @Test("Text with no determinable language cannot be cleared by the name layer")
    func undeterminableLanguageIsUnknown() {
        let result = detector.detect(in: "🙂 🙂 🙂 🙂")
        #expect(result.types.isEmpty)
        #expect(result.confidence == .unknown)
    }

    @Test("Switching off name detection leaves the deterministic layers confident")
    func nameDetectionCanBeDisabled() {
        let quiet = PIIDetector(detectNames: false)
        let result = quiet.detect(in: "Barack Obama visited Paris")
        #expect(result.types.isEmpty)
        #expect(result.confidence == .high)

        let stillFound = quiet.detect(in: "🙂 🙂 🙂 emailing user@example.com")
        #expect(stillFound.types == [.emailAddress])
        #expect(stillFound.confidence == .high)
    }

    @Test("An SSN is reported as an SSN, not as the phone number the data detector sees")
    func overlappingMatchesResolveToTheSpecificType() {
        let result = detector.detect(in: "SSN is 123-45-6789")
        #expect(result.types.contains(.socialSecurityNumber))
        #expect(!result.types.contains(.phoneNumber))
    }
}
