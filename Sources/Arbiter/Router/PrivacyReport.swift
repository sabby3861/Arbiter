// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// A category of sensitive data that ``PrivacyGuard`` can recognise in a request.
///
/// Modelled as a string wrapper rather than a closed enum so an application's own
/// classifier can report categories Arbiter does not ship with (`PIIType("patientID")`)
/// without a library change.
public struct PIIType: Sendable, Hashable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    /// An email address, recognised by `NSDataDetector` as a `mailto:` link.
    public static let emailAddress = PIIType("emailAddress")
    /// A telephone number, recognised by `NSDataDetector`.
    public static let phoneNumber = PIIType("phoneNumber")
    /// A postal address, recognised by `NSDataDetector`.
    public static let postalAddress = PIIType("postalAddress")
    /// A US Social Security Number, recognised by pattern.
    public static let socialSecurityNumber = PIIType("socialSecurityNumber")
    /// A payment card number, recognised by pattern and a Luhn checksum.
    public static let creditCardNumber = PIIType("creditCardNumber")
    /// A person's name, recognised by `NLTagger`'s name-type scheme. Statistical.
    public static let personName = PIIType("personName")
    /// An organisation's name, recognised by `NLTagger`'s name-type scheme. Statistical.
    public static let organizationName = PIIType("organizationName")
    /// A place name, recognised by `NLTagger`'s name-type scheme. Statistical.
    public static let placeName = PIIType("placeName")

    /// The categories detected by Arbiter's own layers, in report order.
    public static let builtIn: [PIIType] = [
        .emailAddress, .phoneNumber, .postalAddress,
        .socialSecurityNumber, .creditCardNumber,
        .personName, .organizationName, .placeName,
    ]

    /// Whether this category comes from one of Arbiter's deterministic layers (a pattern
    /// or `NSDataDetector`) rather than a statistical one.
    ///
    /// A category Arbiter does not ship with is *not* deterministic: it comes from an
    /// application classifier whose method is unknown here, and the safe assumption about
    /// an unknown method is that it can be wrong.
    public var isDeterministic: Bool {
        switch self {
        case .emailAddress, .phoneNumber, .postalAddress,
             .socialSecurityNumber, .creditCardNumber: true
        default: false
        }
    }
}

/// How much weight a ``PrivacyReport``'s verdict carries.
///
/// The distinction exists so `.strict` can fail closed: a guard that could not run one of
/// its layers reports `.unknown`, which is *not* the same as reporting "nothing found".
public enum PrivacyDetectionConfidence: String, Sendable, Hashable, Codable, Comparable {
    /// Every layer ran, and either a deterministic layer matched or nothing matched at all.
    case high
    /// Only statistical (name-tagging or classifier) evidence supports the verdict — or a
    /// statistical layer could not run for this text while the deterministic layers came
    /// back clean, which is not the same as a confident clean.
    case heuristic
    /// Nothing could read this request: its language could not be determined at all, it
    /// carries content the guard cannot see inside (a PDF, an image), or a supplied
    /// classifier failed. Nothing can be concluded from the absence of matches. This is
    /// what a fail-closed guard acts on.
    case unknown

    private var sortOrder: Int {
        switch self {
        case .unknown: 0
        case .heuristic: 1
        case .high: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// What a privacy assessment found, and what it did about it.
///
/// The report names *categories only*. It never carries the matched text, offsets, or
/// counts, so it is safe to log, attach to a ``RoutingDecision``, or show in a debug view.
public struct PrivacyReport: Sendable, Equatable, Hashable {
    /// The categories of sensitive data detected. Never the values themselves.
    public let detectedTypes: Set<PIIType>
    /// The request tags that matched the guard's private-tag set.
    public let matchedTags: Set<RequestTag>
    /// How much the verdict can be relied on. See ``PrivacyDetectionConfidence``.
    public let confidence: PrivacyDetectionConfidence
    /// Whether the guard required this request to stay off third-party cloud providers.
    public let forcesOnDevice: Bool
    /// Whether `forcesOnDevice` is true *only* because detection confidence was
    /// `.unknown` under a fail-closed guard — i.e. nothing was found, but the guard
    /// could not prove nothing is there.
    public let failedClosed: Bool

    public init(
        detectedTypes: Set<PIIType> = [],
        matchedTags: Set<RequestTag> = [],
        confidence: PrivacyDetectionConfidence = .high,
        forcesOnDevice: Bool = false,
        failedClosed: Bool = false
    ) {
        self.detectedTypes = detectedTypes
        self.matchedTags = matchedTags
        self.confidence = confidence
        self.forcesOnDevice = forcesOnDevice
        self.failedClosed = failedClosed
    }

    /// Whether any category of sensitive data was detected.
    public var containsPII: Bool { !detectedTypes.isEmpty }

    /// Detected categories in a stable order — built-ins first, then custom ones
    /// alphabetically — so reports render and compare predictably.
    public var sortedTypes: [PIIType] {
        let builtIn = PIIType.builtIn.filter(detectedTypes.contains)
        let custom = detectedTypes.subtracting(PIIType.builtIn).sorted { $0.rawValue < $1.rawValue }
        return builtIn + custom
    }

    /// A one-line, value-free summary suitable for logs and debug views.
    public var summary: String {
        var parts: [String] = []
        if !sortedTypes.isEmpty {
            parts.append("detected: \(sortedTypes.map(\.rawValue).joined(separator: ", "))")
        }
        if !matchedTags.isEmpty {
            parts.append("tags: \(matchedTags.map(\.rawValue).sorted().joined(separator: ", "))")
        }
        parts.append("confidence: \(confidence.rawValue)")
        if failedClosed { parts.append("failed closed") }
        return parts.joined(separator: "; ")
    }
}

/// What a ``PrivacyClassifier`` concluded about a piece of text.
public struct PrivacyClassification: Sendable, Equatable {
    public let detectedTypes: Set<PIIType>
    public let confidence: PrivacyDetectionConfidence

    public init(detectedTypes: Set<PIIType>, confidence: PrivacyDetectionConfidence = .high) {
        self.detectedTypes = detectedTypes
        self.confidence = confidence
    }

    /// A conclusive "nothing found".
    public static let clean = PrivacyClassification(detectedTypes: [], confidence: .high)

    /// The classifier could not reach a verdict. Under a fail-closed guard this routes
    /// the request on-device rather than letting it through.
    public static let indeterminate = PrivacyClassification(detectedTypes: [], confidence: .unknown)
}

/// An application-supplied detector consulted alongside Arbiter's built-in layers.
///
/// It receives the request's full text, so it must run **on device**. A classifier that
/// calls a remote service defeats the guard it is plugged into: the text reaches a third
/// party before routing has decided whether it may.
///
/// Use it for keyword lists, an embedding model, or an on-device classifier that knows
/// about categories Arbiter cannot recognise (patient identifiers, internal case numbers).
/// A classifier that throws is treated as ``PrivacyClassification/indeterminate`` — it can
/// never *weaken* a verdict the built-in layers already reached.
public protocol PrivacyClassifier: Sendable {
    func classify(_ text: String) async throws -> PrivacyClassification
}
