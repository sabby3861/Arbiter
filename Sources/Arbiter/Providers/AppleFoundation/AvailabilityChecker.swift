// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.arbiter", category: "AvailabilityChecker")

/// Checks whether Apple Foundation Models are available on the current device.
public struct AvailabilityChecker: Sendable {

    /// Availability, with the reason attached when the answer is no.
    ///
    /// Prefer this over the two derived helpers below: `.modelNotReady` is worth retrying
    /// and the rest are not, which a `Bool` cannot say and a `String` can only imply.
    public static func availability() async -> AppleFMAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return await FoundationModelsAvailabilityBridge.availability()
        }
        return .unavailable(.osTooOld)
        #else
        return .unavailable(.frameworkNotLinked)
        #endif
    }

    /// Check if Apple Foundation Models can be used right now.
    public static func isAppleFoundationAvailable() async -> Bool {
        await availability().isAvailable
    }

    /// Returns a human-readable reason if Apple Foundation Models are unavailable.
    public static func unavailableReason() async -> String {
        await availability().message
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum FoundationModelsAvailabilityBridge {
    /// The one place the SDK's availability enum is read. Everything above this translates
    /// Arbiter's mirror instead, and so compiles and is tested off-platform.
    static func availability() async -> AppleFMAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled:
                return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady:
                return .unavailable(.modelNotReady)
            @unknown default:
                logger.warning("Unknown Apple FM unavailability reason")
                return .unavailable(.unknown)
            }
        @unknown default:
            logger.warning("Unknown Apple FM availability state")
            return .unavailable(.unknown)
        }
    }

    /// The model reports the languages it was trained on, and rejects a prompt in any
    /// other one at generation time. Exposed here so `AppleFoundationProvider` can offer a
    /// proactive check without naming a `FoundationModels` type in its own signature.
    static func supportsLocale(_ locale: Locale, options: AppleFMOptions) -> Bool {
        guard let model = try? FMBridge.model(for: options) else {
            // The model could not even be built — an adapter that will not load. That is a
            // provider-level failure with its own error, and reporting it as an unsupported
            // language here would mislabel it, so the check abstains.
            return true
        }
        return model.supportsLocale(locale)
    }

    static var supportedLanguages: Set<Locale.Language> {
        SystemLanguageModel.default.supportedLanguages
    }
}
#endif

#if canImport(SwiftUI)
import SwiftUI

/// SwiftUI view modifier that gates content on Apple Foundation Models availability.
///
/// ```swift
/// Text("AI-powered feature")
///     .appleFoundationAvailable {
///         Text("Requires Apple Intelligence")
///     }
/// ```
public struct AppleFoundationAvailabilityModifier<Fallback: View>: ViewModifier {
    @State private var isAvailable = false
    private let fallback: () -> Fallback

    public init(@ViewBuilder fallback: @escaping () -> Fallback) {
        self.fallback = fallback
    }

    public func body(content: Content) -> some View {
        Group {
            if isAvailable {
                content
            } else {
                fallback()
            }
        }
        .task {
            isAvailable = await AvailabilityChecker.isAppleFoundationAvailable()
        }
    }
}

extension View {
    /// Conditionally show this view based on Apple Foundation Models availability.
    ///
    /// ```swift
    /// Text("AI Feature")
    ///     .appleFoundationAvailable {
    ///         Text("Requires Apple Intelligence")
    ///     }
    /// ```
    public func appleFoundationAvailable<V: View>(
        @ViewBuilder otherwise: @escaping () -> V
    ) -> some View {
        modifier(AppleFoundationAvailabilityModifier(fallback: otherwise))
    }
}
#endif
