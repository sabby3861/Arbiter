// Arbiter — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI

extension View {
    /// Manage Arbiter lifecycle for on-device providers.
    ///
    /// Attach this modifier to your root view to automatically unload
    /// on-device models when the system reports memory pressure.
    ///
    /// ```swift
    /// ContentView()
    ///     .swiftAILifecycle(ai)
    /// ```
    public func swiftAILifecycle(_ ai: Arbiter) -> some View {
        modifier(ArbiterLifecycleModifier(ai: ai))
    }
}

private struct ArbiterLifecycleModifier: ViewModifier {
    let ai: Arbiter
    @State private var lifecycleManager: LifecycleManager?

    func body(content: Content) -> some View {
        content
            .onAppear {
                let manager = LifecycleManager(providers: ai.registeredProviders)
                manager.startMonitoring()
                lifecycleManager = manager
            }
            .onDisappear {
                lifecycleManager?.stopMonitoring()
                lifecycleManager = nil
            }
    }
}
