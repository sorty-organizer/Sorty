import AppKit
import SwiftUI

struct CodexSkillInstallerCard: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var installer = CodexSkillInstaller()
    @State private var isConfirmingRemoval = false
    @State private var isConfirmingReplacement = false
    @State private var isHoveringShowExisting = false
    @State private var importSheet: SkillSheet?

    private enum SkillSheet: Int, Identifiable {
        case setup
        var id: Int { rawValue }
    }

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

                Text("Bring your naming preferences, exclusions, watched folders, and Learnings into your agent.")
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
                Button("Show in Finder") {
                    installer.revealExistingSkill()
                }
            }
        }
        .task {
            await installer.refresh()
        }
        .sheet(item: $importSheet) { _ in
            SkillImportSheet(installer: installer)
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
        .confirmationDialog(
            "Replace the existing Sorty skill?",
            isPresented: $isConfirmingReplacement
        ) {
            Button("Replace Skill", role: .destructive, action: replace)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates the installed Sorty skill. Imported settings are preserved.")
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
            Button("Install Skill", action: install)
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
            }
        case .conflict:
            VStack(alignment: .center, spacing: 6) {
                Button("Replace Skill") {
                    isConfirmingReplacement = true
                }
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
        case .conflict: "Another Sorty skill is installed. Replace it or review it first."
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
        importSheet = .setup
    }

    private func replace() {
        Task {
            await installer.replace()
            if case .installed = installer.state { importSheet = .setup }
            AccessibilityNotification.Announcement(statusText).post()
        }
    }

    private func remove() {
        Task {
            await installer.remove()
            AccessibilityNotification.Announcement(statusText).post()
        }
    }
}

private struct SkillImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var revealAudio = WelcomeRevealAudio()
    @State private var hasAppeared = false
    @State private var isRevealing = true
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var exclusions: ExclusionRulesManager
    @EnvironmentObject private var watchedFolders: WatchedFoldersManager
    @EnvironmentObject private var learnings: LearningsManager
    @EnvironmentObject private var automation: AutomationManager
    @ObservedObject var installer: CodexSkillInstaller
    @State private var options: [SkillImportOption] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    Text("Import into your skill")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Spacer()
                    Button(allSelected ? "Deselect All" : "Select All") {
                        Task {
                            if allSelected { selected.removeAll() }
                            else {
                                if learnings.isLocked || learnings.currentProfile == nil { await unlockLearnings() }
                                selected = Set(options.map(\.selectionID))
                            }
                            HapticFeedbackManager.shared.selection()
                        }
                    }
                    .buttonStyle(.sortyBordered(size: .small))
                    .accessibilityIdentifier("skill-import.select-all")
                    .disabled(isLoading || isSaving)
                }
                Text("Choose what to bring from Sorty. You can tell your agent what to do for each task.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: reduceMotion || hasAppeared ? 0 : 8)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: hasAppeared)

            ScrollView {
                VStack(spacing: 12) {
                    SettingsCard(title: "Skill location", icon: "folder", color: .indigo) {
                        HStack {
                            Text(installer.destinationURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Spacer()
                            Button("Choose…", action: chooseLocation)
                                .buttonStyle(.sortyBordered(size: .small))
                                .accessibilityIdentifier("skill-import.choose-location")
                        }
                    }
                    ForEach(Array(SkillImportOption.Section.allCases.enumerated()), id: \.element) { index, section in
                        importSection(section)
                            .animatedAppearance(delay: Double(index) * 0.05)
                    }
                    Text("Selected Learnings are stored as readable files in the skill. Your agent can use them in future requests. Watched folders are saved without starting background automation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("skill-import.error")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .disabled(isLoading || isSaving)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: reduceMotion || hasAppeared ? 0 : 12)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85).delay(0.08), value: hasAppeared)
            Divider()
            HStack {
                if isLoading || isSaving {
                    ProgressView().controlSize(.small)
                    Text(isSaving ? "Importing…" : "Loading settings…").font(.caption)
                } else {
                    Text("\(options.filter { selected.contains($0.selectionID) }.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.sortyBordered(size: .small))
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("Import Selected", action: importSelected)
                    .buttonStyle(.sortyProminent(size: .small))
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || isLoading || isSaving)
                    .accessibilityIdentifier("skill-import.confirm")
            }
            .padding(24)
            .animatedAppearance(delay: 0.15)
        }
        .frame(width: 620, height: 650)
        .background {
            if !reduceTransparency {
                AnimatedGradientBackground(revealed: hasAppeared, motionEnabled: isRevealing)
                    .opacity(hasAppeared ? 0.65 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: hasAppeared)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .modifier(WindowGlassBackground())
        .accessibilityIdentifier("skill-import.sheet")
        .interactiveDismissDisabled(isSaving)
        .task {
            revealAudio.playRevealSwell()
            hasAppeared = true
            do {
                try await Task.sleep(for: .milliseconds(1500))
            } catch { return }
            isRevealing = false
        }
        .onDisappear { revealAudio.stop() }
        .task {
            await settings.loadPersistedState()
            await exclusions.loadPersistedState()
            await watchedFolders.loadPersistedState()
            refreshOptions()
            isLoading = false
        }
    }

    private var allSelected: Bool {
        !options.isEmpty && options.allSatisfy { selected.contains($0.selectionID) }
    }

    private func importSection(_ section: SkillImportOption.Section) -> some View {
        let rows = options.filter { $0.section == section }
        let identifiers = Set(rows.map(\.selectionID))
        let sectionSelected = !identifiers.isEmpty && identifiers.isSubset(of: selected)
        return SettingsCard(title: section.rawValue, icon: section.icon, color: .indigo, headerAccessory: {
            if !rows.isEmpty {
                Button(sectionSelected ? "Deselect All" : "Select All") {
                    if sectionSelected { selected.subtract(identifiers) }
                    else { selected.formUnion(identifiers) }
                    HapticFeedbackManager.shared.selection()
                }
                .buttonStyle(.sortyBordered(size: .small))
                .accessibilityIdentifier("skill-import.select-all.\(section.rawValue)")
            }
        }) {
            if rows.isEmpty {
                if section == .learnings && (learnings.isLocked || learnings.currentProfile == nil) {
                    Button("Include Learnings") { Task { await unlockLearnings() } }
                        .buttonStyle(.sortyBordered(size: .small))
                        .accessibilityIdentifier("skill-import.unlock-learnings")
                } else {
                    Text("Nothing saved yet.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { option in
                        Toggle(isOn: Binding(
                            get: { selected.contains(option.selectionID) },
                            set: { value in
                                if value { selected.insert(option.selectionID) }
                                else { selected.remove(option.selectionID) }
                                HapticFeedbackManager.shared.selection()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title).font(.subheadline)
                                Text(option.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("skill-import.option.\(option.id)")
                    }
                }
            }
        }
    }

    private func refreshOptions() {
        do {
            options = try SkillImportOption.options(
                config: settings.config, openFolder: automation.autoSelectOrganizedFolders,
                exclusions: exclusions.rules, exceptions: exclusions.naturalLanguageExceptions,
                folders: watchedFolders.folders, learnings: learnings.isLocked ? nil : learnings.currentProfile
            )
        } catch { errorMessage = error.localizedDescription }
    }

    private func unlockLearnings() async {
        isLoading = true
        defer { isLoading = false }
        guard await SecurityManager.shared.authenticateForSensitiveAction(reason: "Authenticate to import your Learnings into the skill.") else { return }
        await learnings.unlock()
        refreshOptions()
        if let error = learnings.error { errorMessage = error }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = installer.destinationURL.deletingLastPathComponent()
        panel.message = "Choose the folder where your agent loads skills. Sorty creates a sorty folder inside it."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        installer.selectedSkillsDirectory = directory
        Task { await installer.refresh(trackUsage: false) }
    }

    private func importSelected() {
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            if options.contains(where: { $0.section == .learnings && selected.contains($0.selectionID) }) {
                guard await SecurityManager.shared.authenticateForSensitiveAction(reason: "Authenticate to import your Learnings into the skill.") else { return }
            }
            if installer.state == .available || installer.state == .failed {
                await installer.install()
            }
            guard case .installed = installer.state else {
                errorMessage = "This location has a different skill. Cancel and update it first, or choose another location."
                return
            }
            do {
                try await installer.importSettings(options: options, selected: selected)
                AccessibilityNotification.Announcement("Settings imported into your skill").post()
                if let sound = NSSound(named: "Glass") {
                    sound.volume = 0.20
                    sound.play()
                }
                NotificationManager.shared.showHUDInfo(
                    title: "Skill ready",
                    message: "Your selected settings are saved in the skill.",
                    icon: "checkmark.seal.fill",
                    iconColor: .mint,
                    identifier: "skill-import-complete"
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                HapticFeedbackManager.shared.error()
            }
        }
    }
}
