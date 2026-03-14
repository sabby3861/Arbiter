// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI

extension View {
    /// Manage SwiftAI lifecycle (background/foreground)
    ///
    /// Attach this modifier to your root view to automatically pause on-device
    /// providers when the app backgrounds and resume them on foreground.
    ///
    /// ```swift
    /// ContentView()
    ///     .swiftAILifecycle(ai)
    /// ```
    public func swiftAILifecycle(_ ai: SwiftAI) -> some View {
        modifier(SwiftAILifecycleModifier(ai: ai))
    }
}

private struct SwiftAILifecycleModifier: ViewModifier {
    let ai: SwiftAI
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
