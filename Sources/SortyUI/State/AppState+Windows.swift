import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

// MARK: - Auxiliary Windows
// Each method opens (or refocuses) one auxiliary window hosting its SwiftUI view.
extension AppState {
    public func showAbout() {
        // Reuse the retained window, including after it has been closed.
        if let existingWindow = aboutWindowController?.window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create a new About window
        let aboutView = AboutView(openAccreditations: { [weak self] in
            self?.showAccreditations(entryPoint: .about)
        })
        let hostingView = NSHostingView(rootView: aboutView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 510),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "About Sorty"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        if #available(macOS 26.0, *) {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        window.center()
        
        // Retain the window controller to prevent deallocation
        aboutWindowController = NSWindowController(window: window)
        aboutWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func showBugReport() {
        if let window = bugReportWindowController?.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = BugReportView(
            diagnosticConfig: { [weak self] in self?.settingsViewModel?.config },
            onClose: { [weak self] in self?.bugReportWindowController?.close() }
        )
        // Keep the window height steady while the Sentry panel opens.
        // The analytics-off window stays compact because that panel is hidden.
        let showsSentryOption = AnalyticsManager.shared.consent == .granted
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: showsSentryOption ? 620 : 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Size the window to the view so it grows with the text box and panels.
        let hostingView = NSHostingView(rootView: view)
        hostingView.sizingOptions = [.preferredContentSize]
        window.contentView = hostingView
        window.title = "Send Feedback"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        if #available(macOS 26.0, *) {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        window.center()

        bugReportWindowController = NSWindowController(window: window)
        bugReportWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        HapticFeedbackManager.shared.selection()
    }

    public func showInternetAccessPolicy(entryPoint: InternetAccessPolicyEntryPoint = .appMenu) {
        let policyView = InternetAccessPolicyView(
            showBackButton: entryPoint == .about,
            onBack: entryPoint == .about ? { [weak self] in
                self?.internetAccessPolicyWindowController?.close()
                self?.showAbout()
                HapticFeedbackManager.shared.selection()
            } : nil
        )
        let hostingView = NSHostingView(rootView: policyView)

        if let existingWindow = internetAccessPolicyWindowController?.window {
            existingWindow.contentView = hostingView
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            HapticFeedbackManager.shared.selection()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "Internet Access Policy"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        if #available(macOS 26.0, *) {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        window.center()

        internetAccessPolicyWindowController = NSWindowController(window: window)
        internetAccessPolicyWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        HapticFeedbackManager.shared.selection()
    }

    public func showAccreditations(entryPoint: AccreditationsEntryPoint = .help) {
        let accreditationsView = AccreditationsView(
            showBackButton: entryPoint == .about,
            onBack: entryPoint == .about ? { [weak self] in
                self?.accreditationsWindowController?.close()
                self?.showAbout()
                HapticFeedbackManager.shared.selection()
            } : nil
        )
        let hostingView = NSHostingView(rootView: accreditationsView)

        if let existingWindow = accreditationsWindowController?.window {
            existingWindow.contentView = hostingView
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            HapticFeedbackManager.shared.selection()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "Sorty Accreditations"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        if #available(macOS 26.0, *) {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        window.center()

        accreditationsWindowController = NSWindowController(window: window)
        accreditationsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        HapticFeedbackManager.shared.selection()
    }

    public func showThanksForUsingSorty() {
        // If window already exists and is visible, just bring it to front
        if let existingWindow = thanksWindowController?.window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            HapticFeedbackManager.shared.selection()
            return
        }

        let thanksView = ThanksForUsingSortyView()
        let hostingView = NSHostingView(rootView: thanksView)

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: ThanksForUsingSortyView.preferredWindowWidth,
                height: ThanksForUsingSortyView.preferredWindowHeight
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "Thanks for Using Sorty"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        if #available(macOS 26.0, *) {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
        window.center()

        thanksWindowController = NSWindowController(window: window)
        thanksWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        HapticFeedbackManager.shared.selection()
    }
}
