// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

/// Thermal state mapped to a Sendable enum
public enum ThermalLevel: String, Sendable {
    case nominal
    case fair
    case serious
    case critical

    init(from state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }
}

/// Snapshot of device capabilities for routing decisions
public struct DeviceCapabilities: Sendable {
    public let memoryGB: Double
    public let thermalLevel: ThermalLevel
    public let processorCount: Int

    public var canRunLocalModels: Bool {
        memoryGB >= 4.0 && thermalLevel != .critical
    }

    public var recommendedLocalTier: LocalModelTier {
        switch memoryGB {
        case ..<4: return .none
        case 4..<8: return .small
        case 8..<16: return .medium
        case 16..<32: return .large
        default: return .xlarge
        }
    }

    public var isThermallyConstrained: Bool {
        thermalLevel == .serious || thermalLevel == .critical
    }
}

/// Recommended local model size based on device RAM
public enum LocalModelTier: String, Sendable, Comparable {
    case none
    case small
    case medium
    case large
    case xlarge

    private var sortOrder: Int {
        switch self {
        case .none: 0
        case .small: 1
        case .medium: 2
        case .large: 3
        case .xlarge: 4
        }
    }

    public static func < (lhs: LocalModelTier, rhs: LocalModelTier) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// Reads device hardware state for routing decisions.
struct DeviceAssessor: Sendable {
    static func assess() -> DeviceCapabilities {
        DeviceCapabilities(
            memoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            thermalLevel: ThermalLevel(from: ProcessInfo.processInfo.thermalState),
            processorCount: ProcessInfo.processInfo.processorCount
        )
    }
}
