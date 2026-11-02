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
        case .healthy: return SortyDesignSystem.Colors.success
        case .needsAttention: return SortyDesignSystem.Colors.warning
        case .informational: return SortyDesignSystem.Colors.info
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
