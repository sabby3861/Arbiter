// SwiftAI — Unified AI Runtime for Swift
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI
import SwiftAI
import os

private let logger = Logger(subsystem: "com.swiftai.examples", category: "OnDeviceOnly")

@main
struct OnDeviceApp: App {
    var body: some Scene {
        WindowGroup {
            OnDeviceRootView()
        }
    }
}

struct OnDeviceRootView: View {
    @State private var loadState: LoadState = .loading

    var body: some View {
        NavigationStack {
            contentForState
                .navigationTitle("On-Device AI")
                .task { await prepareRuntime() }
        }
    }

    @ViewBuilder
    private var contentForState: some View {
        switch loadState {
        case .loading:
            loadingView
        case .ready(let ai):
            readyView(ai: ai)
        case .unsupported(let reason):
            unsupportedView(reason: reason)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Loading on-device model...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private func readyView(ai: SwiftAI) -> some View {
        VStack(spacing: 0) {
            privacyBanner
            SwiftAIChatView(ai: ai, systemPrompt: "You are a helpful on-device assistant.")
                .swiftAILifecycle(ai)
        }
    }

    private var privacyBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.green)
            Text("100% on-device")
                .fontWeight(.medium)
            Text("No data leaves your device")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.green.opacity(0.1))
    }

    private func unsupportedView(reason: String) -> some View {
        ContentUnavailableView {
            Label("Not Available", systemImage: "exclamationmark.triangle")
        } description: {
            Text(reason)
        }
    }

    private func prepareRuntime() async {
        #if canImport(MLX)
        logger.info("MLX available, configuring on-device provider")
        let ai = SwiftAI { config in
            config.local(MLXProvider(.auto))
            config.privacy(.localOnly)
            config.routing(.preferLocal)
        }
        let available = await ai.registeredProviders.first?.isAvailable ?? false
        if available {
            loadState = .ready(ai)
        } else {
            loadState = .unsupported(
                "This device does not support on-device ML inference. "
                + "Apple Silicon Mac or recent iPhone/iPad required."
            )
        }
        #else
        logger.warning("MLX framework not available on this platform")
        loadState = .unsupported(
            "MLX is not available on this platform. "
            + "On-device inference requires Apple Silicon."
        )
        #endif
    }
}

private enum LoadState {
    case loading
    case ready(SwiftAI)
    case unsupported(String)
}
