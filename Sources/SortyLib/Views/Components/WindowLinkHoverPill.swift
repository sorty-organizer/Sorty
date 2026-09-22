import SwiftUI
import AppKit

@MainActor
final class WindowLinkHoverState: ObservableObject, @unchecked Sendable {
    @Published private(set) var hoveredURL: URL?
    @Published private(set) var isCommandPressed = false

    private let hoverHandoffGraceNanoseconds: UInt64 = 120_000_000
    private var activeHoverURLs: [UUID: URL] = [:]
    private var hoverOrder: [UUID] = []
    private var flagsMonitor: Any?
    private var pendingHideTask: Task<Void, Never>?

    init() {}

    func clearAllHover() {
        cancelPendingHideTask()
        activeHoverURLs.removeAll()
        hoverOrder.removeAll()
        hoveredURL = nil
        isCommandPressed = false
        removeFlagsMonitor()
    }

    func setHovering(_ hovering: Bool, url: URL, sourceID: UUID) {
        guard url.scheme?.lowercased().hasPrefix("http") == true else {
            return
        }

        if hovering {
            cancelPendingHideTask()
            activeHoverURLs[sourceID] = url
            hoverOrder.removeAll { $0 == sourceID }
            hoverOrder.append(sourceID)
            hoveredURL = url
            installFlagsMonitorIfNeeded()
            isCommandPressed = Self.commandPressed(in: NSEvent.modifierFlags)
            return
        }

        activeHoverURLs.removeValue(forKey: sourceID)
        hoverOrder.removeAll { $0 == sourceID }

        if let nextURL = hoverOrder.last.flatMap({ activeHoverURLs[$0] }) {
            cancelPendingHideTask()
            hoveredURL = nextURL
            return
        }

        scheduleHideAfterHandoffGracePeriod()
    }

    private func scheduleHideAfterHandoffGracePeriod() {
        cancelPendingHideTask()
        let delay = hoverHandoffGraceNanoseconds

        pendingHideTask = Task { @MainActor [weak self, delay] in
            try? await Task.sleep(nanoseconds: delay)
            self?.applyPendingHideIfNeeded()
        }
    }

    private func applyPendingHideIfNeeded() {
        pendingHideTask = nil

        guard activeHoverURLs.isEmpty else {
            return
        }

        hoveredURL = nil
        isCommandPressed = false
        removeFlagsMonitor()
    }

    private func cancelPendingHideTask() {
        pendingHideTask?.cancel()
        pendingHideTask = nil
    }

    private func installFlagsMonitorIfNeeded() {
        guard flagsMonitor == nil else { return }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            guard self.hoveredURL != nil else { return event }
            self.isCommandPressed = Self.commandPressed(in: event.modifierFlags)
            return event
        }
    }

    private func removeFlagsMonitor() {
        guard let flagsMonitor else { return }
        NSEvent.removeMonitor(flagsMonitor)
        self.flagsMonitor = nil
    }

    private static func commandPressed(in flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }
}

private struct WindowLinkHoverUpdateKey: EnvironmentKey {
    static let defaultValue: @Sendable (Bool, URL, UUID) -> Void = { _, _, _ in }
}

extension EnvironmentValues {
    var windowLinkHoverUpdate: @Sendable (Bool, URL, UUID) -> Void {
        get { self[WindowLinkHoverUpdateKey.self] }
        set { self[WindowLinkHoverUpdateKey.self] = newValue }
    }
}

private struct TrackHoveredURLModifier: ViewModifier {
    @Environment(\.windowLinkHoverUpdate) private var hoverUpdate

    let url: URL

    @State private var sourceID = UUID()

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverUpdate(hovering, url, sourceID)
            }
            .onDisappear {
                hoverUpdate(false, url, sourceID)
            }
    }
}

extension View {
    func trackHoveredURL(_ url: URL) -> some View {
        modifier(TrackHoveredURLModifier(url: url))
    }

    func windowLinkHoverPillHost() -> some View {
        modifier(WindowLinkHoverPillHostModifier())
    }
}

private struct WindowLinkHoverPillHostModifier: ViewModifier {
    @StateObject private var hoverState = WindowLinkHoverState()

    func body(content: Content) -> some View {
        ZStack {
            content
            WindowLinkHoverPillOverlay(hoverState: hoverState)
        }
        .environment(\.windowLinkHoverUpdate) { hovering, url, sourceID in
            MainActor.assumeIsolated {
                hoverState.setHovering(hovering, url: url, sourceID: sourceID)
            }
        }
        .onDisappear {
            hoverState.clearAllHover()
        }
    }
}

struct WindowLinkHoverPillOverlay: View {
    @SortyHotReload private var hotReload
    @ObservedObject var hoverState: WindowLinkHoverState

    var body: some View {
        VStack {
            Spacer()

            HStack {
                if let url = hoverState.hoveredURL {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.blue.opacity(0.95))

                            Text(labelText(for: url))
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .numericTextTransition(animationValue: labelText(for: url))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: 999, style: .continuous)
                                .fill(Color.blue.opacity(0.12))
                                .systemLiquidGlassBackground(cornerRadius: 999)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 999, style: .continuous)
                                .stroke(Color.blue.opacity(0.22), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 420, alignment: .leading)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
                }

                Spacer()
            }
            .padding(.leading, 16)
            .padding(.bottom, 16)
        }
        .allowsHitTesting(hoverState.hoveredURL != nil)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: hoverState.hoveredURL != nil)
        .animation(.easeInOut(duration: 0.12), value: hoverState.isCommandPressed)
        .zIndex(1100)
    }

    private func labelText(for url: URL) -> String {
        if hoverState.isCommandPressed {
            return "Open \(url.absoluteString) in your default browser."
        }

        return compactURLText(for: url)
    }

    private func compactURLText(for url: URL) -> String {
        if let host = url.host, !host.isEmpty {
            var text = host
            if let port = url.port {
                text += ":\(port)"
            }
            if !url.path.isEmpty {
                text += url.path
            }
            if let query = url.query, !query.isEmpty {
                text += "?\(query)"
            }
            if let fragment = url.fragment, !fragment.isEmpty {
                text += "#\(fragment)"
            }
            return text
        }

        return url.absoluteString
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }
}
