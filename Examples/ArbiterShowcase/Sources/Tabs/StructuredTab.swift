// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import SwiftUI
import Arbiter
import os

private let logger = Logger(subsystem: "com.arbiter.showcase", category: "StructuredTab")

struct StructuredTab: View {
    @Environment(AppState.self) private var appState
    @State private var selectedType = OutputType.recipe
    @State private var recipe: DemoRecipe?
    @State private var review: DemoMovieReview?
    @State private var weather: DemoWeather?
    @State private var rawJSON = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var skeletonOpacity: Double = 0.15

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.sectionSpacing) {
                    typePicker
                    generateButton
                    if isLoading { skeletonCard }
                    if let errorMessage { errorCard(errorMessage) }
                    resultContent
                    if !rawJSON.isEmpty { jsonDisclosure }
                }
                .padding()
            }
            .navigationTitle("Structured Output")
            .inlineTitle()
        }
    }

    private var typePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(OutputType.allCases, id: \.self) { type in
                    typeCard(type)
                }
            }
            .padding(.horizontal)
        }
    }

    private func typeCard(_ type: OutputType) -> some View {
        Button {
            selectedType = type
            clearResults()
        } label: {
            VStack(spacing: 8) {
                Text(type.emoji).font(.largeTitle)
                Text(type.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: 100, height: 90)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(selectedType == type ? .blue : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25), value: selectedType)
    }

    private var generateButton: some View {
        Button {
            Task { await generate() }
        } label: {
            HStack {
                if isLoading { ProgressView().tint(.white) }
                else { Image(systemName: "sparkles") }
                Text("Generate")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isLoading ? .gray : .blue, in: RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isLoading)
    }

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 6)
                    .fill(.gray.opacity(skeletonOpacity))
                    .frame(height: 14)
                    .frame(maxWidth: index == 0 ? 200 : (index == 3 ? 160 : .infinity), alignment: .leading)
            }
        }
        .cardStyle()
        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isLoading)
    }

    @ViewBuilder
    private var resultContent: some View {
        if let recipe { recipeCard(recipe) }
        if let review { reviewCard(review) }
        if let weather { weatherCard(weather) }
    }

    private func generate() async {
        isLoading = true
        errorMessage = nil
        clearResults()
        skeletonOpacity = 0.3
        defer { isLoading = false }

        do {
            try await generateSelectedType()
            appState.addLog(LogEntry(
                icon: "doc.text", title: "Structured Output",
                detail: "Generated \(selectedType.label)", color: .purple
            ))
            logger.info("Generated structured \(selectedType.label)")
        } catch {
            errorMessage = error.localizedDescription
            appState.addLog(LogEntry(
                icon: "exclamationmark.triangle", title: "Structured Error",
                detail: error.localizedDescription, color: .red
            ))
            logger.error("Structured output error: \(error.localizedDescription)")
        }
    }

    private func generateSelectedType() async throws {
        switch selectedType {
        case .recipe:
            let result: DemoRecipe = try await appState.ai.generate(
                "Create a quick Italian dinner recipe under 30 minutes",
                as: DemoRecipe.self,
                example: DemoRecipe(name: "", cuisine: "", ingredients: [], steps: [], prepTimeMinutes: 0)
            )
            recipe = result
            rawJSON = encodeJSON(result)
        case .review:
            let result: DemoMovieReview = try await appState.ai.generate(
                "Write a review of the movie Inception",
                as: DemoMovieReview.self,
                example: DemoMovieReview(title: "", rating: 0, summary: "", pros: [], cons: [])
            )
            review = result
            rawJSON = encodeJSON(result)
        case .weather:
            let result: DemoWeather = try await appState.ai.generate(
                "Describe the current weather in San Francisco",
                as: DemoWeather.self,
                example: DemoWeather(city: "", temperatureCelsius: 0, condition: "", forecast: [])
            )
            weather = result
            rawJSON = encodeJSON(result)
        }
        let estimatedTokens = max(rawJSON.count / 4, 100)
        appState.recordUsage(
            provider: "Unknown", tokens: estimatedTokens,
            cost: Double(estimatedTokens) * 0.00001, latency: 0
        )
    }

    private func clearResults() {
        recipe = nil
        review = nil
        weather = nil
        rawJSON = ""
        errorMessage = nil
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private extension StructuredTab {
    func recipeCard(_ recipe: DemoRecipe) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recipe.name).font(.title3.bold())
            HStack(spacing: 8) {
                badgePill(recipe.cuisine, icon: "fork.knife")
                badgePill("\(recipe.prepTimeMinutes) min", icon: "clock")
            }
            Divider()
            Text("Ingredients").font(.subheadline.bold())
            ForEach(recipe.ingredients, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\u{2022}").foregroundStyle(.secondary)
                    Text(item).font(.subheadline)
                }
            }
            Divider()
            Text("Steps").font(.subheadline.bold())
            ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.subheadline.bold())
                        .foregroundStyle(.blue)
                        .frame(width: 24, alignment: .trailing)
                    Text(step).font(.subheadline)
                }
            }
        }
        .cardStyle()
    }

    func reviewCard(_ review: DemoMovieReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(review.title).font(.title3.bold())
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= review.rating ? "star.fill" : "star")
                        .foregroundStyle(star <= review.rating ? .yellow : .gray.opacity(0.3))
                        .font(.subheadline)
                }
            }
            Text(review.summary).font(.subheadline).foregroundStyle(.secondary)
            Divider()
            labelledList(title: "Pros", items: review.pros, icon: "checkmark", color: .green)
            labelledList(title: "Cons", items: review.cons, icon: "xmark", color: .red)
        }
        .cardStyle()
    }

    func weatherCard(_ weather: DemoWeather) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(weather.city).font(.title3.bold())
                    Label(weather.condition, systemImage: weatherIcon(weather.condition))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(weather.temperatureCelsius)\u{00B0}")
                    .font(.system(size: 48, weight: .thin, design: .rounded))
            }
            if !weather.forecast.isEmpty {
                Divider()
                Text("Forecast").font(.subheadline.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(weather.forecast, id: \.self) { day in
                            Text(day)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    func errorCard(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await generate() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.red.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(.red.opacity(0.3), lineWidth: 1))
    }

    var jsonDisclosure: some View {
        DisclosureGroup("Raw JSON") {
            ScrollView(.horizontal) {
                Text(rawJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .cardStyle()
    }

    func badgePill(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.blue.opacity(0.1), in: Capsule())
    }

    func labelledList(title: String, items: [String], icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold()).foregroundStyle(color)
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: icon)
                    .font(.subheadline)
                    .foregroundStyle(color.opacity(0.8))
            }
        }
    }

    func weatherIcon(_ condition: String) -> String {
        let lower = condition.lowercased()
        if lower.contains("rain") { return "cloud.rain" }
        if lower.contains("cloud") { return "cloud.sun" }
        if lower.contains("snow") { return "cloud.snow" }
        if lower.contains("thunder") { return "cloud.bolt" }
        return "sun.max"
    }
}

private enum OutputType: CaseIterable {
    case recipe, review, weather

    var label: String {
        switch self {
        case .recipe: "Recipe"
        case .review: "Review"
        case .weather: "Weather"
        }
    }

    var emoji: String {
        switch self {
        case .recipe: "\u{1F373}"
        case .review: "\u{1F3AC}"
        case .weather: "\u{2600}\u{FE0F}"
        }
    }
}
