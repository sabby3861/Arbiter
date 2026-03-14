// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

// Replace YOUR_API_KEY with your Anthropic key.
// In production, use SecureKeyStorage (Keychain) instead of hardcoded keys.

import SwiftUI
import SwiftAI
import os

private let logger = Logger(subsystem: "com.swiftai.examples", category: "BasicChat")

@main
struct BasicChatApp: App {
    private let ai: SwiftAI

    init() {
        logger.info("Launching BasicChat example")
        self.ai = SwiftAI(provider: Self.makeProvider())
    }

    private static func makeProvider() -> AnthropicProvider {
        // The hardcoded-key initializer is deprecated; use keychain storage in production.
        AnthropicProvider(apiKey: "YOUR_API_KEY") // swiftlint:disable:this deprecated
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SwiftAIChatView(ai: ai)
                    .navigationTitle("BasicChat")
            }
        }
    }
}
