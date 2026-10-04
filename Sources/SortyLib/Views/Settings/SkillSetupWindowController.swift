import AppKit
import SwiftUI

/// Keeps setup independent of the settings window and prevents closing during an import.
@MainActor
final class SkillSetupWindowController: NSObject, ObservableObject, NSWindowDelegate {
    // The setup window must remain usable after its settings window closes.
    static let shared = SkillSetupWindowController()
    @Published private(set) var isPresented = false
    private var windowController: NSWindowController?
    private var isSaving = false

    func show(
        installer: CodexSkillInstaller, settings: SettingsViewModel,
        exclusions: ExclusionRulesManager, watchedFolders: WatchedFoldersManager,
        learnings: LearningsManager, automation: AutomationManager
    ) {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SkillSetupView(
            installer: installer,
            onClose: { [weak self] in self?.windowController?.close() },
            onSavingChanged: { [weak self] saving in
                self?.isSaving = saving
                self?.windowController?.window?.standardWindowButton(.closeButton)?.isEnabled = !saving
            }
        )
        .environmentObject(settings)
        .environmentObject(exclusions)
        .environmentObject(watchedFolders)
        .environmentObject(learnings)
        .environmentObject(automation)

        let contentSize = NSSize(width: 780, height: 620)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Set up Sorty skill"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 580)
        if #available(macOS 26.0, *) {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        let hostingView = NSHostingView(rootView: view)
        // AppKit controls the window size; longer setup steps scroll within it.
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.setContentSize(contentSize)
        window.delegate = self
        window.center()
        windowController = NSWindowController(window: window)
        windowController?.showWindow(nil)
        isPresented = true
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !isSaving }

    func windowWillClose(_ notification: Notification) {
        windowController?.window?.contentView = nil
        windowController = nil
        isPresented = false
    }
}
