// Arbiter Showcase
// Copyright (c) 2026 Sanjay Kumar. MIT License.

import Foundation

struct DemoRecipe: Codable, Sendable {
    let name: String
    let cuisine: String
    let ingredients: [String]
    let steps: [String]
    let prepTimeMinutes: Int
}

struct DemoMovieReview: Codable, Sendable {
    let title: String
    let rating: Int
    let summary: String
    let pros: [String]
    let cons: [String]
}

struct DemoWeather: Codable, Sendable {
    let city: String
    let temperatureCelsius: Int
    let condition: String
    let forecast: [String]
}
