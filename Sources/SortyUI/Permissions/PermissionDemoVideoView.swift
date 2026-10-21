import AppKit
import AVFoundation
import SwiftUI
import UserNotifications
import Permiso

struct PermissionDemoVideoView: View {
    @SortyHotReload private var hotReload
    let permission: PermissionType
    let resourceName: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black

            if let videoURL, !reduceMotion {
                LoopingPermissionVideoView(url: videoURL)
            } else {
                // Static poster under Reduce Motion: no AVPlayerLooper runs.
                permissionDemoFallback
            }
        }
        .accessibilityLabel("\(permission.educationTitle) permission demo video")
    }

    private var videoURL: URL? {
        SortyResources.bundle.url(forResource: resourceName, withExtension: "mp4")
    }

    private var permissionDemoFallback: some View {
        VStack(spacing: 14) {
            Image(systemName: permission.icon)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))

            Text(permission.educationTitle)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.10))
                .clipShape(Capsule(style: .continuous))
        }
    }
}

extension PermissionType {
    var demoVideoResourceName: String? {
        switch self {
        case .filesAndFolders:
            return "files-and-folders-demo"
        case .fullDiskAccess:
            return "full-disk-access-demo"
        case .automation:
            return "automation-demo"
        case .notifications:
            return nil
        }
    }
}

struct LoopingPermissionVideoView: NSViewRepresentable {
    @SortyHotReload private var hotReload
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.configure(url: url, playerView: view)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        context.coordinator.configure(url: url, playerView: nsView)
    }

    static func dismantleNSView(_ nsView: PlayerLayerView, coordinator: Coordinator) {
        coordinator.stop()
        nsView.playerLayer.player = nil
    }

    @MainActor
    final class Coordinator {
        private var currentURL: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private weak var playerView: PlayerLayerView?
        private var observers: [NSObjectProtocol] = []

        func configure(url: URL, playerView: PlayerLayerView) {
            self.playerView = playerView
            let playerLayer = playerView.playerLayer
            if currentURL == url, let player {
                if playerLayer.player !== player {
                    playerLayer.player = player
                }
                return
            }

            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = true
            queuePlayer.actionAtItemEnd = .none

            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            player = queuePlayer
            currentURL = url
            playerLayer.player = queuePlayer
            queuePlayer.play()
            installActivityObserversIfNeeded()
        }

        func stop() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            player?.pause()
            player?.removeAllItems()
            player = nil
            looper = nil
            currentURL = nil
        }

        private func installActivityObserversIfNeeded() {
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.player?.pause() }
                },
                center.addObserver(
                    forName: NSApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.refreshPlayback()
                    }
                },
                center.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.refreshPlayback() }
                },
                center.addObserver(
                    forName: NSWindow.didMiniaturizeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.player?.pause() }
                },
                center.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.refreshPlayback() }
                }
            ]
        }

        /// Plays only when the app is active and the hosting window is
        /// visible, unoccluded, and unminiaturized; pauses otherwise.
        private func refreshPlayback() {
            guard let window = playerView?.window else {
                player?.pause()
                return
            }
            let isRunnable = NSApplication.shared.isActive
                && window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
            if isRunnable {
                player?.play()
            } else {
                player?.pause()
            }
        }
    }
}

final class PlayerLayerView: NSView {
    override var wantsUpdateLayer: Bool { true }

    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
