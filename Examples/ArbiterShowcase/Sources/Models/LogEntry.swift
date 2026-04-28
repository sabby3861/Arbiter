// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp = Date()
    let icon: String
    let title: String
    let detail: String
    let color: Color
}
