// MARK: - HeatmapLevel.swift
// Pure heatmap intensity model shared by the app, widget, and tests.

import Foundation

/// Heatmap color levels based on quartile distribution.
enum HeatmapLevel: Int, CaseIterable, Equatable {
    case none = 0
    case firstQuartile = 1
    case secondQuartile = 2
    case thirdQuartile = 3
    case fourthQuartile = 4
}
