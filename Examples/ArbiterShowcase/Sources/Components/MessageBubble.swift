// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                bubbleContent
                if message.role == .assistant, !message.isLoading {
                    metadataLine
                }
            }

            if message.role != .user { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.isLoading {
            LoadingDots()
                .padding(12)
                .background(.regularMaterial, in: bubbleShape)
        } else {
            Text(message.content)
                .font(.body)
                .foregroundStyle(message.role == .user ? .white : .primary)
                .padding(12)
                .background(bubbleBackground, in: bubbleShape)
                .overlay {
                    if message.role == .error {
                        bubbleShape.stroke(.red.opacity(0.5), lineWidth: 1.5)
                    }
                }
        }
    }

    @ViewBuilder
    private var metadataLine: some View {
        if let provider = message.provider {
            HStack(spacing: 4) {
                Circle()
                    .fill(Theme.providerColor(provider))
                    .frame(width: 6, height: 6)
                Text(metadataText(provider: provider))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metadataText(provider: String) -> String {
        var parts = ["via \(provider)"]
        if let latency = message.latency { parts.append(latency) }
        if let tokens = message.tokens { parts.append("\(tokens) tokens") }
        return parts.joined(separator: " · ")
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16)
    }

    private var bubbleBackground: AnyShapeStyle {
        switch message.role {
        case .user:
            AnyShapeStyle(LinearGradient(
                colors: [.blue, .blue.opacity(0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        case .assistant:
            AnyShapeStyle(.regularMaterial)
        case .error:
            AnyShapeStyle(Color.red.opacity(0.08))
        }
    }
}
