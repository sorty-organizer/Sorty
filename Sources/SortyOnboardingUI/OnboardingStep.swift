import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - Onboarding Step Enum

public struct OnboardingStepValidationResult: Equatable, Sendable {
    public let canAdvance: Bool
    public let message: String?

    public init(canAdvance: Bool, message: String? = nil) {
        self.canAdvance = canAdvance
        self.message = message
    }

    public static let valid = OnboardingStepValidationResult(canAdvance: true)

    public static func blocked(_ message: String) -> OnboardingStepValidationResult {
        OnboardingStepValidationResult(canAdvance: false, message: message)
    }
}

public struct OnboardingStepValidationContext: Equatable, Sendable {
    public let providerSetupStatus: ProviderSetupStatus
    public let hasRequiredPermissions: Bool

    public init(
        providerSetupStatus: ProviderSetupStatus,
        hasRequiredPermissions: Bool
    ) {
        self.providerSetupStatus = providerSetupStatus
        self.hasRequiredPermissions = hasRequiredPermissions
    }
}

enum OnboardingStep: Int, CaseIterable {
    case provider = 0
    case permissions = 1
    case workflow = 2
    case completion = 3

    var title: String {
        switch self {
        case .provider: return "AI Provider"
        case .permissions: return "Permissions"
        case .workflow: return "Workflow"
        case .completion: return "Ready!"
        }
    }

    @MainActor
    var next: OnboardingStep {
        let active = OnboardingStep.allCases
        guard let currentIndex = active.firstIndex(of: self) else { return self }
        let nextIndex = min(currentIndex + 1, active.count - 1)
        return active[nextIndex]
    }

    @MainActor
    var previous: OnboardingStep {
        let active = OnboardingStep.allCases
        guard let currentIndex = active.firstIndex(of: self) else { return self }
        let prevIndex = max(currentIndex - 1, 0)
        return active[prevIndex]
    }
}

extension OnboardingStep {
    func synchronousValidation(in context: OnboardingStepValidationContext)
        -> OnboardingStepValidationResult
    {
        switch self {
        case .provider:
            if context.providerSetupStatus.isReady {
                return .valid
            }
            return .blocked(context.providerSetupStatus.message)
        case .permissions:
            if context.hasRequiredPermissions {
                return .valid
            }
            return .blocked("Grant Files & Folders access before continuing.")
        case .workflow, .completion:
            return .valid
        }
    }

    func validateAdvance(in context: OnboardingStepValidationContext) async
        -> OnboardingStepValidationResult
    {
        synchronousValidation(in: context)
    }
}
