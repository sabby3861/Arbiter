// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Why Apple Foundation Models cannot be used right now.
///
/// Mirrors `SystemLanguageModel.Availability.UnavailableReason`, plus the two states that
/// enum cannot describe because they are decided before the framework is reachable at all.
/// Being a plain Arbiter enum, it compiles — and is switched over exhaustively — on every
/// platform, so a caller can branch on *why* a device is unusable without `#if canImport`.
public enum AppleFMUnavailableReason: Sendable, Equatable {
    /// The hardware does not support Apple Intelligence.
    case deviceNotEligible
    /// Supported hardware with Apple Intelligence switched off in Settings.
    case appleIntelligenceNotEnabled
    /// Enabled, but the model is still downloading or preparing — retry later.
    case modelNotReady
    /// This build has no `FoundationModels` framework to link against.
    case frameworkNotLinked
    /// The framework exists but the OS predates the API.
    case osTooOld
    /// A reason this build of Arbiter does not know: a newer OS added a case.
    case unknown
}

/// Whether Apple Foundation Models can serve a request on this device.
public enum AppleFMAvailability: Sendable, Equatable {
    case available
    case unavailable(AppleFMUnavailableReason)

    public var isAvailable: Bool {
        self == .available
    }

    /// Retrying later could plausibly succeed without the user doing anything.
    ///
    /// Only a model that is still preparing qualifies: ineligible hardware, a disabled
    /// setting and an old OS all need someone to act.
    public var isTransient: Bool {
        self == .unavailable(.modelNotReady)
    }

    /// The human-readable form used by ``AvailabilityChecker/unavailableReason()`` and by
    /// `ArbiterError.providerUnavailable`'s `reason` payload.
    ///
    /// These exact strings predate the enum and are part of the API's observable behaviour,
    /// so they are produced from it rather than replaced by it.
    public var message: String {
        switch self {
        case .available:
            "Available"
        case .unavailable(.deviceNotEligible):
            "This device does not support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence is not enabled. Enable it in Settings > Apple Intelligence & Siri"
        case .unavailable(.modelNotReady):
            "The on-device model is still downloading or preparing"
        case .unavailable(.frameworkNotLinked):
            "FoundationModels framework is not available on this platform"
        case .unavailable(.osTooOld):
            "Apple Foundation Models requires iOS 26+ / macOS 26+ / visionOS 26+"
        case .unavailable(.unknown):
            "Apple Foundation Models are not available"
        }
    }
}
