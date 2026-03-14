// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "LifecycleManager")

/// Manages app lifecycle events for on-device AI providers.
///
/// Responds to memory pressure by unloading models from providers
/// that conform to ``UnloadableProvider``.
@MainActor
public final class LifecycleManager {
    private let providers: [any AIProvider]
    private var isMonitoring = false

    public init(providers: [any AIProvider]) {
        self.providers = providers
    }

    /// Start listening for lifecycle events. Call from your app's root view.
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        #if canImport(UIKit) && !os(macOS)
        setupUIKitObservers()
        #endif
    }

    /// Stop listening for lifecycle events
    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        NotificationCenter.default.removeObserver(self)
        logger.debug("Lifecycle monitoring stopped")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

#if canImport(UIKit) && !os(macOS)
import UIKit

private extension LifecycleManager {
    func setupUIKitObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        logger.info("Lifecycle monitoring started — watching for memory warnings")
    }

    @objc func onMemoryWarning() { handleMemoryWarning() }
}
#endif

private extension LifecycleManager {
    func handleMemoryWarning() {
        logger.warning("Memory warning — requesting model unload from local providers")
        for provider in localProviders {
            if let unloadable = provider as? UnloadableProvider {
                unloadable.unloadModel()
            }
        }
    }

    var localProviders: [any AIProvider] {
        providers.filter {
            $0.id.tier == .onDevice || $0.id.tier == .localServer || $0.id.tier == .system
        }
    }
}

/// A provider that can unload its model from memory to free resources.
///
/// Conform to this protocol to enable automatic model unloading
/// when the system reports memory pressure.
///
/// ```swift
/// extension MyProvider: UnloadableProvider {
///     func unloadModel() {
///         // Clear cached model data
///     }
/// }
/// ```
public protocol UnloadableProvider: AIProvider {
    func unloadModel()
}
