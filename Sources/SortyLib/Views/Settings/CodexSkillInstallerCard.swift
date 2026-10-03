import AppKit
import SwiftUI

struct CodexSkillInstallerCard: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var installer = CodexSkillInstaller()
    @State private var isConfirmingRemoval = false
    @State private var isHoveringShowExisting = false
    @StateObject private var setupWindow = SkillSetupWindowController.shared
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var exclusions: ExclusionRulesManager
    @EnvironmentObject private var watchedFolders: WatchedFoldersManager
    @EnvironmentObject private var learnings: LearningsManager
    @EnvironmentObject private var automation: AutomationManager

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 28, height: 28)
                .background(.indigo.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Sorty skill")
                        .font(.subheadline.weight(.semibold))
                    Text("Experimental")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.1), in: Capsule())
                }

                Text("Let your agent organize files with your Sorty preferences. Setup walks you through what to share.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if installer.state != .available {
                    Label(statusText, systemImage: statusImage)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }

            Spacer(minLength: 12)

            actionView
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            if installer.state == .conflict {
                Button("Remove Existing Skill", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .accessibilityIdentifier("experimental.codex-skill.remove")
                .disabled(setupWindow.isPresented)
                Button("Show in Finder") {
                    installer.revealExistingSkill()
                }
            }
        }
        .task {
            await installer.refresh()
        }
        .confirmationDialog(
            "Remove the Sorty skill?",
            isPresented: $isConfirmingRemoval
        ) {
            Button("Remove Skill", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the installed skill and its imported settings. Your app data stays unchanged.")
        }
    }

    @ViewBuilder
    private var actionView: some View {
        switch installer.state {
        case .checking, .installing, .replacing, .removing:
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 86, minHeight: 28)
                .accessibilityLabel(progressLabel)
        case .available, .failed:
            Button("Set Up Skill…", action: install)
                .buttonStyle(.sortyProminent(size: .small))
                .accessibilityIdentifier("experimental.codex-skill.install")
        case .installed:
            VStack(spacing: 6) {
                Button("Import Settings…", action: install)
                    .buttonStyle(.sortyProminent(size: .small))
                    .accessibilityIdentifier("experimental.skill.import-settings")
                Button("Remove Skill", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .buttonStyle(.sortyBordered(intent: .destructive, size: .small))
                .accessibilityIdentifier("experimental.codex-skill.remove")
                .disabled(setupWindow.isPresented)
            }
        case .conflict:
            VStack(alignment: .center, spacing: 6) {
                Button("Review Setup…", action: install)
                .buttonStyle(.sortyProminent(intent: .warning, size: .small))
                .accessibilityIdentifier("experimental.codex-skill.replace")

                Button {
                    HapticFeedbackManager.shared.tap()
                    installer.revealExistingSkill()
                } label: {
                    Text("Show Existing Skill")
                        .overlay(alignment: .trailing) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .offset(
                                    x: reduceMotion || isHoveringShowExisting ? 14 : 11,
                                    y: reduceMotion || isHoveringShowExisting ? 0 : 3
                                )
                                .scaleEffect(reduceMotion || isHoveringShowExisting ? 1 : 0.75)
                                .opacity(isHoveringShowExisting ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82),
                    value: isHoveringShowExisting
                )
                .onHover { hovering in
                    if hovering {
                        HapticFeedbackManager.shared.selection()
                    }
                    isHoveringShowExisting = hovering
                }
                .accessibilityIdentifier("experimental.codex-skill.open-folder")
            }
        case .unavailable:
            Button("Check Again") {
                Task { await installer.refresh(trackUsage: false) }
            }
            .buttonStyle(.sortyBordered(size: .small))
            .accessibilityIdentifier("experimental.codex-skill.retry")
        }
    }

    private var statusText: String {
        switch installer.state {
        case .checking: "Checking skill…"
        case .available: "Ready to install"
        case .installing: "Installing…"
        case .replacing: "Replacing existing skill…"
        case .removing: "Removing…"
        case .installed: "Skill installed"
        case .conflict: "Another Sorty skill is installed. Review setup before replacing it."
        case .unavailable: "The bundled skill is unavailable in this build"
        case .failed: "Installation failed"
        }
    }

    private var progressLabel: String {
        switch installer.state {
        case .checking: "Checking skill"
        case .installing: "Installing skill"
        case .replacing: "Replacing skill"
        case .removing: "Removing skill"
        default: "Updating skill"
        }
    }

    private var statusImage: String {
        switch installer.state {
        case .installed: "checkmark.circle.fill"
        case .conflict, .unavailable, .failed: "exclamationmark.triangle.fill"
        default: "circle.dotted"
        }
    }

    private var statusColor: Color {
        switch installer.state {
        case .installed: .green
        case .conflict, .unavailable, .failed: .orange
        default: .secondary
        }
    }

    private func install() {
        HapticFeedbackManager.shared.tap()
        setupWindow.show(
            installer: installer, settings: settings, exclusions: exclusions,
            watchedFolders: watchedFolders, learnings: learnings, automation: automation
        )
    }

    private func remove() {
        Task {
            await installer.remove()
            AccessibilityNotification.Announcement(statusText).post()
        }
    }
}
