// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "AvailabilityChecker")

/// Checks whether Apple Foundation Models are available on the current device.
public struct AvailabilityChecker: Sendable {

    /// Check if Apple Foundation Models can be used right now.
    public static func isAppleFoundationAvailable() async -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return await FoundationModelsAvailabilityBridge.checkAvailability()
        }
        #endif
        return false
    }

    /// Returns a human-readable reason if Apple Foundation Models are unavailable.
    public static func unavailableReason() async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return await FoundationModelsAvailabilityBridge.detailedReason()
        }
        return "Apple Foundation Models requires iOS 26+ / macOS 26+ / visionOS 26+"
        #else
        return "FoundationModels framework is not available on this platform"
        #endif
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum FoundationModelsAvailabilityBridge {
    static func checkAvailability() async -> Bool {
        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            return true
        case .notAvailable, .temporarilyUnavailable:
            return false
        @unknown default:
            logger.warning("Unknown Apple FM availability state")
            return false
        }
    }

    static func detailedReason() async -> String {
        let availability = SystemLanguageModel.default.availability
        switch availability {
        case .available:
            return "Available"
        case .notAvailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This device does not support Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is not enabled. Enable it in Settings > Apple Intelligence & Siri"
            case .modelNotReady:
                return "The on-device model is still downloading or preparing"
            @unknown default:
                return "Apple Foundation Models are not available"
            }
        case .temporarilyUnavailable:
            return "Apple Foundation Models are temporarily unavailable. Try again later."
        @unknown default:
            return "Apple Foundation Models are not available"
        }
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
