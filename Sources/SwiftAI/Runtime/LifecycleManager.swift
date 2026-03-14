// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation
import os

private let logger = Logger(subsystem: "com.swiftai", category: "LifecycleManager")

/// Manages app lifecycle events for on-device AI providers.
///
/// Automatically pauses local inference when the app backgrounds,
/// responds to memory pressure by unloading models, and resumes
/// when the app returns to the foreground.
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
        #elseif os(macOS)
        setupAppKitObservers()
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
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        logger.info("UIKit lifecycle monitoring started")
    }

    @objc func onBackground() { handleBackground() }
    @objc func onForeground() { handleForeground() }
    @objc func onMemoryWarning() { handleMemoryWarning() }
}
#endif

#if os(macOS)
import AppKit

private extension LifecycleManager {
    func setupAppKitObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onBackground),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(onForeground),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        logger.info("AppKit lifecycle monitoring started")
    }

    @objc func onBackground() { handleBackground() }
    @objc func onForeground() { handleForeground() }
}
#endif

private extension LifecycleManager {
    func handleBackground() {
        logger.info("App entering background — pausing local providers")
        for provider in localProviders {
            if let pausable = provider as? PausableProvider {
                pausable.pause()
            }
        }
    }

    func handleForeground() {
        logger.info("App entering foreground — resuming local providers")
        for provider in localProviders {
            if let pausable = provider as? PausableProvider {
                pausable.resume()
            }
        }
    }

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

/// A provider that can pause and resume inference
public protocol PausableProvider: AIProvider {
    func pause()
    func resume()
}

/// A provider that can unload its model from memory
public protocol UnloadableProvider: AIProvider {
    func unloadModel()
}
