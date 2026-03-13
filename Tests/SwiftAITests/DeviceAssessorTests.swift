// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import Testing
@testable import SwiftAI

@Suite("DeviceAssessor")
struct DeviceAssessorTests {

    @Test func assessReturnsNonZeroMemory() {
        let device = DeviceAssessor.assess()
        #expect(device.memoryGB > 0)
    }

    @Test func assessReturnsPositiveProcessorCount() {
        let device = DeviceAssessor.assess()
        #expect(device.processorCount > 0)
    }

    @Test func canRunLocalModelsRequires4GBAndNonCritical() {
        let capable = DeviceCapabilities(memoryGB: 8, thermalLevel: .nominal, processorCount: 4)
        #expect(capable.canRunLocalModels)

        let lowRam = DeviceCapabilities(memoryGB: 2, thermalLevel: .nominal, processorCount: 4)
        #expect(!lowRam.canRunLocalModels)

        let critical = DeviceCapabilities(memoryGB: 16, thermalLevel: .critical, processorCount: 8)
        #expect(!critical.canRunLocalModels)
    }

    @Test func recommendedLocalTierBasedOnMemory() {
        #expect(DeviceCapabilities(memoryGB: 2, thermalLevel: .nominal, processorCount: 2).recommendedLocalTier == .none)
        #expect(DeviceCapabilities(memoryGB: 6, thermalLevel: .nominal, processorCount: 4).recommendedLocalTier == .small)
        #expect(DeviceCapabilities(memoryGB: 12, thermalLevel: .nominal, processorCount: 8).recommendedLocalTier == .medium)
        #expect(DeviceCapabilities(memoryGB: 24, thermalLevel: .nominal, processorCount: 10).recommendedLocalTier == .large)
        #expect(DeviceCapabilities(memoryGB: 48, thermalLevel: .nominal, processorCount: 12).recommendedLocalTier == .xlarge)
    }

    @Test func isThermallyConstrainedForSeriousAndCritical() {
        #expect(!DeviceCapabilities(memoryGB: 8, thermalLevel: .nominal, processorCount: 4).isThermallyConstrained)
        #expect(!DeviceCapabilities(memoryGB: 8, thermalLevel: .fair, processorCount: 4).isThermallyConstrained)
        #expect(DeviceCapabilities(memoryGB: 8, thermalLevel: .serious, processorCount: 4).isThermallyConstrained)
        #expect(DeviceCapabilities(memoryGB: 8, thermalLevel: .critical, processorCount: 4).isThermallyConstrained)
    }

    @Test func thermalLevelFromProcessInfo() {
        #expect(ThermalLevel(from: .nominal) == .nominal)
        #expect(ThermalLevel(from: .fair) == .fair)
        #expect(ThermalLevel(from: .serious) == .serious)
        #expect(ThermalLevel(from: .critical) == .critical)
    }

    @Test func localModelTierComparable() {
        #expect(LocalModelTier.none < .small)
        #expect(LocalModelTier.small < .medium)
        #expect(LocalModelTier.medium < .large)
        #expect(LocalModelTier.large < .xlarge)
    }

    @Test func boundaryMemoryValues() {
        // Exactly at boundary values
        #expect(DeviceCapabilities(memoryGB: 4.0, thermalLevel: .nominal, processorCount: 2).recommendedLocalTier == .small)
        #expect(DeviceCapabilities(memoryGB: 8.0, thermalLevel: .nominal, processorCount: 4).recommendedLocalTier == .medium)
        #expect(DeviceCapabilities(memoryGB: 16.0, thermalLevel: .nominal, processorCount: 8).recommendedLocalTier == .large)
        #expect(DeviceCapabilities(memoryGB: 32.0, thermalLevel: .nominal, processorCount: 10).recommendedLocalTier == .xlarge)
    }
}
