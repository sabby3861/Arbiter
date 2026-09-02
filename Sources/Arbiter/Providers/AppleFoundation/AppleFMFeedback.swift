// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// How a person rated a response from the on-device model.
///
/// Mirrors `LanguageModelFeedback.Sentiment`. A plain Arbiter enum, so a feedback UI can be
/// written and switched over exhaustively on any platform.
public enum AppleFMFeedbackSentiment: Sendable, Equatable, CaseIterable {
    case positive
    case negative
    case neutral
}

/// Something specific that was wrong with a response.
///
/// Mirrors `LanguageModelFeedback.Issue`, whose category list is fixed by Apple; the free
/// text is optional and goes to the same place.
public struct AppleFMFeedbackIssue: Sendable, Equatable {
    /// The eight categories `LanguageModelFeedback.Issue.Category` defines.
    public enum Category: Sendable, Equatable, CaseIterable {
        case unhelpful
        case tooVerbose
        case didNotFollowInstructions
        case incorrect
        case stereotypeOrBias
        case suggestiveOrSexual
        case vulgarOrOffensive
        case triggeredGuardrailUnexpectedly
    }

    public let category: Category
    /// Optional detail in the reporter's own words.
    public let explanation: String?

    public init(category: Category, explanation: String? = nil) {
        self.category = category
        self.explanation = explanation
    }
}
