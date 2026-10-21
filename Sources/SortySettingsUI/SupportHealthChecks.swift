import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Beam

enum SupportHealthStatus: Equatable {
    case healthy
    case needsAttention
    case informational

    var icon: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .informational: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .healthy: return .green
        case .needsAttention: return .orange
        case .informational: return .blue
        }
    }

    var reportLabel: String {
        switch self {
        case .healthy: return "Healthy"
        case .needsAttention: return "Needs attention"
        case .informational: return "Information"
        }
    }
}
