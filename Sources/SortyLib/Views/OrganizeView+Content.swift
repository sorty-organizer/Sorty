import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Content
extension OrganizeView {
    @ViewBuilder
    var stateContent: some View {
        stateContentInner
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
    }

    var persistentWorkflowGradientOpacity: Double {
        guard appState.selectedDirectory != nil else { return 0 }
        return 1
    }

    var persistentWorkflowGradientAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : .easeInOut(duration: 0.22)
    }

    var workflowNavigationAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.1)
            : .spring(response: 0.38, dampingFraction: 0.86)
    }

    var stateContentOpacity: Double {
        if isReturningToStart { return 0 }
        return 1
    }

    var returnToStartContentOpacity: Double {
        isReturningToStart ? 1 : 0
    }

    var returnToStartContentScale: CGFloat {
        1
    }

    var returnToStartContentOffset: CGFloat {
        0
    }

    var returnToStartContent: some View {
        ReadyToOrganizeView(onStart: startOrganization, startsVisible: true)
    }

    @ViewBuilder
    var stateContentInner: some View {
        if shouldShowCompletionView {
            completionHandoffContent
        } else {
            stateContentSwitch
        }
    }

    @ViewBuilder
    var completionHandoffContent: some View {
        ZStack {
            if let plan = organizer.currentPlan {
                PreviewView(
                    plan: plan,
                    baseURL: appState.selectedDirectory ?? URL(fileURLWithPath: "/"),
                    onReturnToStart: returnToStartAfterCancellation
                )
                .opacity(isCompletionContentVisible ? 0 : 1)
                .blur(radius: completionPreviewBlur)
                .scaleEffect(isCompletionContentVisible && !reduceMotion ? 0.992 : 1)
                .allowsHitTesting(!isCompletionContentVisible)

                OrganizationCompleteView(
                    stats: plan.generationStats,
                    totalFiles: plan.suggestions.reduce(0) { $0 + $1.totalFileCount },
                    totalFolders: plan.suggestions.count,
                    renameCount: plan.suggestions.reduce(0) { $0 + $1.renameCount },
                    mode: settingsViewModel.config.mode,
                    directoryURL: appState.selectedDirectory ?? URL(fileURLWithPath: "/"),
                    onReturnToStart: returnToStartAfterCancellation
                )
                .opacity(isCompletionContentVisible ? 1 : 0)
                .scaleEffect(isCompletionContentVisible || reduceMotion ? 1 : 0.985)
                .offset(y: isCompletionContentVisible || reduceMotion ? 0 : 10)
                .allowsHitTesting(isCompletionContentVisible)
            } else {
                OrganizationCompleteView(
                    stats: nil,
                    totalFiles: 0,
                    totalFolders: 0,
                    renameCount: 0,
                    mode: settingsViewModel.config.mode,
                    directoryURL: appState.selectedDirectory ?? URL(fileURLWithPath: "/"),
                    onReturnToStart: returnToStartAfterCancellation
                )
            }
        }
        .animation(completionHandoffAnimation, value: showsCompletionContent)
    }

    var completionPreviewBlur: CGFloat {
        isCompletionContentVisible && !reduceMotion ? 2 : 0
    }

    var completionHandoffAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.42)
    }

    var shouldShowCompletionView: Bool {
        if case .completed = organizer.state { return true }
        return organizer.pinsCompletionView || showsCompletionContent
    }

    var isCompletionContentVisible: Bool {
        if case .completed = organizer.state { return true }
        return organizer.pinsCompletionView || showsCompletionContent
    }

    @ViewBuilder
    var stateContentSwitch: some View {
        if let errorViewTestRoute {
            ErrorView(
                error: errorViewTestRoute.error,
                onCancel: dismissErrorViewTestRoute,
                onRetry: dismissErrorViewTestRoute,
                onRetryWithSmarterModel: dismissErrorViewTestRoute,
                onGrantPermission: dismissErrorViewTestRoute
            )
        } else {
            organizerStateContent
        }
    }

    @ViewBuilder
    var organizerStateContent: some View {
        switch organizer.state {
        case .idle:
            if needsSetupRepair {
                SetupRepairGateView(
                    message: activeSetupRepairMessage ?? "Finish setting up your provider before organizing files.",
                    onStart: startOrganization,
                    onOpenSettings: {
                        HapticFeedbackManager.shared.selection()
                        appState.startSetupRepair(
                            message: activeSetupRepairMessage ?? "Finish setting up your provider before organizing files.",
                            navigateToSettings: true
                        )
                    }
                )
            } else {
                ReadyToOrganizeView(
                    onStart: startOrganization,
                    startsVisible: true
                )
            }
        case .scanning, .organizing, .applying:
            AnalysisView(
                onReturnToStart: returnToStartAfterCancellation,
                onLiveOrganizationStarted: noteLiveOrganizationStarted
            )
        case .ready:
            if keepsLiveOrganizationVisible {
                AnalysisView(
                    onReturnToStart: returnToStartAfterCancellation,
                    onLiveOrganizationStarted: noteLiveOrganizationStarted
                )
            } else if let plan = organizer.currentPlan {
                PreviewView(
                    plan: plan,
                    baseURL: appState.selectedDirectory!,
                    onReturnToStart: returnToStartAfterCancellation,
                    onApplyStarted: beginCompletionHandoff
                )
            } else {
                PreviewHandoffView(mode: settingsViewModel.config.mode)
            }
        case .completed:
            completionHandoffContent
        case .error(let error):
            ErrorView(
                error: error,
                canResume: organizer.canResumeOrganization,
                onResume: {
                    Task {
                        try? await organizer.resumeOrganization()
                    }
                },
                onCancel: returnToDirectorySelection,
                onRetry: {
                    HapticFeedbackManager.shared.tap()
                    withAnimation(.pageTransition) {
                        organizer.reset()
                    }
                },
                onRetryWithSmarterModel: {
                    showSmarterRetryModelPicker = true
                },
                onGrantPermission: grantFolderPermissionAndContinue
            )
        }
    }
}
