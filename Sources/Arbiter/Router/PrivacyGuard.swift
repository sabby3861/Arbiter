// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "PrivacyGuard")

/// Prevents accidental data leakage by enforcing privacy routing rules.
///
/// ```swift
/// let ai = Arbiter {
///     $0.cloud(.anthropic(from: .keychain))
///     $0.local(OllamaProvider())
///     $0.privacy(.strict)
/// }
/// ```
///
/// Detection is layered — patterns for SSNs and card numbers, `NSDataDetector` for phone
/// numbers, postal addresses and email addresses, and `NLTagger` name tagging for person,
/// organisation and place names — and an application can add its own
/// ``PrivacyClassifier``. See ``PIIDetector`` for what each layer covers.
///
/// ``strict`` additionally *fails closed*: when a layer cannot run, so that the absence of
/// a match proves nothing, the request is kept off third-party cloud providers anyway. If
/// no such provider remains, ``ArbiterError/privacyViolation(detectedTypes:reason:)`` is
/// thrown rather than the request being sent out.
public struct PrivacyGuard: Sendable {
    public var privateTags: Set<RequestTag>
    public var forceLocalOnly: Bool
    public var requireCloudConsent: Bool
    public var detectPII: Bool
    /// Whether to run the statistical name-tagging layer. Names are far more common than
    /// SSNs, so an app that only cares about identifiers can switch this off and keep the
    /// deterministic layers.
    public var detectNames: Bool
    /// Whether an inconclusive assessment forces on-device routing. On in ``strict``.
    public var failClosed: Bool
    /// An optional application-supplied detector, consulted by ``assess(_:)``.
    public var classifier: (any PrivacyClassifier)?

    public init(
        privateTags: Set<RequestTag> = [.private, .health, .financial, .personal],
        forceLocalOnly: Bool = false,
        requireCloudConsent: Bool = false,
        detectPII: Bool = false,
        detectNames: Bool = true,
        failClosed: Bool = false,
        classifier: (any PrivacyClassifier)? = nil
    ) {
        self.privateTags = privateTags
        self.forceLocalOnly = forceLocalOnly
        self.requireCloudConsent = requireCloudConsent
        self.detectPII = detectPII
        self.detectNames = detectNames
        self.failClosed = failClosed
        self.classifier = classifier
    }

    public static let standard = PrivacyGuard()

    /// Detects PII and fails closed: an assessment it cannot complete keeps the request
    /// on-device instead of letting it reach a third-party cloud.
    public static let strict = PrivacyGuard(
        forceLocalOnly: false,
        requireCloudConsent: true,
        detectPII: true,
        failClosed: true
    )

    public static let localOnly = PrivacyGuard(forceLocalOnly: true)

    /// Assess a request using every layer, including the supplied ``classifier``.
    ///
    /// Prefer this over ``inspect(_:)``: it is what the router calls, and it is the only
    /// entry point that consults a classifier.
    public func assess(_ request: AIRequest) async -> PrivacyReport {
        let scan = Self.scannableText(in: request)
        let text = scan.text
        var detection = builtInDetection(for: scan)

        if let classifier, detectPII, !text.isEmpty {
            let classification: PrivacyClassification
            do {
                classification = try await classifier.classify(text)
            } catch {
                logger.debug("Privacy classifier failed — treating its verdict as unknown")
                classification = .indeterminate
            }
            let builtInWasCertain = detection.confidence == .high && !detection.types.isEmpty
            detection.types.formUnion(classification.detectedTypes)
            // A classifier can raise the alarm but never lower it. Where the built-in
            // layers already matched something deterministically the verdict stays
            // certain; otherwise the merged confidence is the weaker of the two.
            if !builtInWasCertain {
                detection.confidence = min(detection.confidence, classification.confidence)
            }
        }

        return report(for: request, detection: detection)
    }

    /// Assess a request using only the built-in, synchronous layers.
    ///
    /// Provided for callers that cannot await — a SwiftUI body, a `Sendable` predicate.
    /// It ignores ``classifier``.
    public func inspect(_ request: AIRequest) -> PrivacyReport {
        report(for: request, detection: builtInDetection(for: Self.scannableText(in: request)))
    }

    /// Whether the request should be forced to local/on-device providers.
    func shouldForceLocal(for request: AIRequest) -> Bool {
        inspect(request).forcesOnDevice
    }
}

private extension PrivacyGuard {
    func builtInDetection(for scan: ScannedRequest) -> PIIDetector.Result {
        guard detectPII else { return PIIDetector.Result() }
        return PIIDetector(detectNames: detectNames)
            .detect(in: scan.text, hasUnscannableContent: scan.hasUnscannableContent)
    }

    func report(for request: AIRequest, detection: PIIDetector.Result) -> PrivacyReport {
        let matchedTags = request.tags.intersection(privateTags)
        let inconclusive = detectPII && failClosed && detection.confidence == .unknown
        // `failedClosed` means *this alone* is why the request is being held back, so a
        // guard that would have forced it on-device anyway does not claim it.
        let failedClosed = inconclusive
            && detection.types.isEmpty
            && matchedTags.isEmpty
            && !forceLocalOnly

        var forcesOnDevice = false
        var reasons: [String] = []
        if forceLocalOnly {
            forcesOnDevice = true
            reasons.append("local-only guard")
        }
        if !matchedTags.isEmpty {
            forcesOnDevice = true
            reasons.append("private tags")
        }
        if !detection.types.isEmpty {
            forcesOnDevice = true
            reasons.append("detected sensitive data")
        }
        if inconclusive {
            forcesOnDevice = true
            reasons.append("inconclusive detection (fail-closed)")
        }

        if forcesOnDevice {
            let reason = reasons.joined(separator: ", ")
            logger.debug("Privacy: forcing local routing — \(reason, privacy: .public)")
        }

        return PrivacyReport(
            detectedTypes: detection.types,
            matchedTags: matchedTags,
            confidence: detection.confidence,
            forcesOnDevice: forcesOnDevice,
            failedClosed: failedClosed
        )
    }

    /// The request's text, plus whether it also carries something no detector can read.
    struct ScannedRequest {
        var text: String
        /// True when the request holds an image or a document. Those are exactly the
        /// payloads a photographed passport or a scanned medical record arrive in, and the
        /// guard cannot look inside either, so a clean text verdict says nothing about the
        /// request as a whole.
        var hasUnscannableContent: Bool
    }

    /// Every piece of user text in the request, including the parts `MessageContent.text`
    /// does not surface — `.mixed` payloads, tool-call arguments and replayed thinking
    /// blocks all routinely carry the values a guard exists to catch. The text is never
    /// truncated: a length cap would be a silent fail-open for anything past it.
    static func scannableText(in request: AIRequest) -> ScannedRequest {
        var parts: [String] = []
        var unscannable = false
        if let system = request.systemPrompt { parts.append(system) }
        for message in request.messages {
            collectText(from: message.content, into: &parts, unscannable: &unscannable)
        }
        return ScannedRequest(
            text: parts.joined(separator: "\n"),
            hasUnscannableContent: unscannable
        )
    }

    static func collectText(
        from content: MessageContent,
        into parts: inout [String],
        unscannable: inout Bool
    ) {
        switch content {
        case .text(let string):
            parts.append(string)
        case .toolResults(let results):
            parts.append(contentsOf: results.map(\.content))
        case .toolCalls(let calls):
            for call in calls { collectText(from: call.arguments, into: &parts) }
        case .thinking(let blocks):
            // A replayed thinking block quotes the turn it reasoned about, values included.
            parts.append(contentsOf: blocks.map(\.text).filter { !$0.isEmpty })
        case .mixed(let nested):
            for part in nested {
                collectText(from: part, into: &parts, unscannable: &unscannable)
            }
        case .image, .document:
            unscannable = true
        }
    }

    static func collectText(from value: JSONValue, into parts: inout [String]) {
        switch value {
        case .string(let string):
            parts.append(string)
        case .number(let number):
            // A card number is the one category that arrives as a JSON number often enough
            // to matter — an SSN's pattern needs its hyphens, so a numeric one cannot match
            // whatever we do here. Values past 2^53 are excluded because a `Double` has
            // already lost their exact digits, and a rounded card number fails Luhn anyway.
            let exactIntegerLimit = 9_007_199_254_740_992.0
            if number == number.rounded(), abs(number) >= 1_000, abs(number) < exactIntegerLimit {
                parts.append(String(format: "%.0f", number))
            }
        case .array(let values):
            for nested in values { collectText(from: nested, into: &parts) }
        case .object(let object):
            for nested in object.values { collectText(from: nested, into: &parts) }
        case .bool, .null:
            break
        }
    }
}
