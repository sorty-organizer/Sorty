import AppKit
import AVFoundation
import SwiftUI
import UserNotifications
import Permiso

package struct PermissionEducationView: View {
    @SortyHotReload private var hotReload
    let pages: [PermissionType]
    let onFinish: () -> Void
    @State private var currentPage = 0

    package init(pages: [PermissionType], onFinish: @escaping () -> Void) {
        self.pages = pages
        self.onFinish = onFinish
    }

    private var page: PermissionType {
        pages[min(currentPage, max(pages.count - 1, 0))]
    }

    package var body: some View {
        ZStack(alignment: .bottom) {
            educationPage(page)
                .id(page.id)
                .transition(.opacity.combined(with: .scale(scale: 1.01)))

            if pages.count > 1 {
                pageIndicator
                    .padding(.bottom, 8)
            }
        }
        .systemLiquidGlassPopover(cornerRadius: 12)
        .animation(.easeOut(duration: 0.18), value: currentPage)
    }

    private func educationPage(_ permission: PermissionType) -> some View {
        VStack(spacing: 0) {
            permissionHero(permission)
                .frame(width: 640, height: 360)

            VStack(spacing: 8) {
                Text(permission.educationTitle)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(permission.educationDescription)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)

                HStack(spacing: 10) {
                    if currentPage > 0 {
                        Button {
                            HapticFeedbackManager.shared.selection()
                            currentPage -= 1
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(.sortySecondary(size: .regular))
                    }

                    Button {
                        HapticFeedbackManager.shared.selection()
                        if currentPage == pages.count - 1 {
                            onFinish()
                        } else {
                            currentPage += 1
                        }
                    } label: {
                        Label(currentPage == pages.count - 1 ? "Done" : "Continue", systemImage: currentPage == pages.count - 1 ? "checkmark" : "chevron.right")
                            .symbolReplaceTransition(animationValue: currentPage)
                    }
                    .buttonStyle(.sortyPrimary(size: .regular))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 10)
            }
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .frame(width: 640)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func permissionHero(_ permission: PermissionType) -> some View {
        if let resourceName = permission.demoVideoResourceName {
            PermissionDemoVideoView(permission: permission, resourceName: resourceName)
        } else {
            permissionExplanationHero(permission)
        }
    }

    private func permissionExplanationHero(_ permission: PermissionType) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor),
                    permission.color.opacity(0.22),
                    Color(nsColor: .windowBackgroundColor),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 14) {
                Image(systemName: permission.icon)
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.86))

                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(permission.color)
                    Text(permission.educationTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.82))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.08))
                .clipShape(Capsule(style: .continuous))
            }
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(pages.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == currentPage ? Color.primary.opacity(0.82) : Color.secondary.opacity(0.28))
                    .frame(width: index == currentPage ? 22 : 7, height: 7)
            }
        }
        .accessibilityLabel("Page \(currentPage + 1) of \(pages.count)")
    }
}

package struct AutomationPermissionRecoveryView: View {
    @SortyHotReload private var hotReload
    let onFinish: () -> Void
    private let resetCommand = "tccutil reset AppleEvents com.sorty.app"
    @StateObject private var resetCommandCopyFeedback = CopyFeedback()
    private var hasCopiedResetCommand: Bool { resetCommandCopyFeedback.isCopied }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Sorty isn't listed", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)

            Text(
                "macOS did not register Sorty's request to control Finder. The Automation pane cannot add it manually."
            )
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Quit Sorty.")
                Text("2. Run this in Terminal:")
                HStack(spacing: 8) {
                    Text(resetCommand)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)

                    Spacer(minLength: 0)

                    Button {
                        resetCommandCopyFeedback.copy(resetCommand,
                            animation: reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72),
                            resetAnimation: reduceMotion ? nil : .easeOut(duration: 0.18),
                            haptic: { HapticFeedbackManager.shared.success() })
                    } label: {
                        Image(systemName: hasCopiedResetCommand ? "checkmark" : "doc.on.doc")
                            .symbolReplaceTransition(animationValue: hasCopiedResetCommand)
                            .symbolEffect(.bounce, value: hasCopiedResetCommand)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy repair command")
                    .accessibilityLabel("Copy repair command")
                    .accessibilityHint("Copies the Terminal command to restore the Automation permission entry")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("3. Reopen Sorty and choose Enable again.")
            }
            .font(.body)

            HStack {
                Spacer()

                Button("Done") {
                    HapticFeedbackManager.shared.selection()
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
