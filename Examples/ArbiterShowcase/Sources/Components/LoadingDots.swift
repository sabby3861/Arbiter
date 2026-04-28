// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI

struct LoadingDots: View {
    @State private var activeDot = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 8, height: 8)
                    .opacity(activeDot == index ? 1.0 : 0.3)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                activeDot = (activeDot + 1) % 3
            }
        }
        .animation(.easeInOut(duration: 0.3), value: activeDot)
    }
}
