import AppKit
import SwiftUI
import UserNotifications
import Permiso

package struct PermissionAnimatedIcon: View {
    @SortyHotReload private var hotReload
    let type: PermissionType
    let state: PermissionState
    let grantAnimationTrigger: Int
    var size: CGFloat = 23

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var folderFlapRotation = 0.0
    @State private var folderBackOpacity = 0.0
    @State private var folderOpenTask: Task<Void, Never>?
    @State private var gearRotation = 0.0
    @State private var bellRotation = 0.0
    @State private var bellRingTask: Task<Void, Never>?

    package init(
        type: PermissionType,
        state: PermissionState,
        grantAnimationTrigger: Int,
        size: CGFloat = 23
    ) {
        self.type = type
        self.state = state
        self.grantAnimationTrigger = grantAnimationTrigger
        self.size = size
    }

    private var isReady: Bool {
        state == .granted || state == .restartRequired
    }

    @ViewBuilder
    package var body: some View {
        Group {
            switch type {
            case .filesAndFolders:
                ZStack {
                    Image(systemName: "folder.fill")
                        .font(.system(size: size, weight: .semibold))
                        .opacity(folderBackOpacity)
                        .scaleEffect(x: 0.96, y: 0.88, anchor: .bottom)
                        .offset(y: -1)

                    Image(systemName: "folder.fill")
                        .font(.system(size: size, weight: .semibold))
                        .rotation3DEffect(
                            .degrees(folderFlapRotation),
                            axis: (x: 1, y: 0, z: 0),
                            anchor: .bottom,
                            perspective: 0.6
                        )
                }
                .frame(width: size * 1.18, height: size * 1.18)

            case .fullDiskAccess:
                Image(systemName: isReady ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: size, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(
                        .bounce,
                        options: .speed(0.9),
                        value: reduceMotion ? 0 : grantAnimationTrigger
                    )
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.68),
                        value: state
                    )

            case .automation:
                ZStack {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: size * 0.65, weight: .semibold))
                        .rotationEffect(.degrees(gearRotation))
                        .offset(x: size * -0.22, y: size * 0.17)

                    Image(systemName: "gearshape.fill")
                        .font(.system(size: size * 0.52, weight: .semibold))
                        .rotationEffect(.degrees(-gearRotation * 1.25))
                        .offset(x: size * 0.26, y: size * -0.22)
                }
                .frame(width: size * 1.18, height: size * 1.18)

            case .notifications:
                Image(systemName: "bell.fill")
                    .font(.system(size: size, weight: .semibold))
                    .rotationEffect(.degrees(bellRotation), anchor: .top)
            }
        }
        .onChange(of: grantAnimationTrigger) { oldValue, newValue in
            guard newValue != oldValue, !reduceMotion else { return }
            playGrantAnimation()
        }
        .onDisappear {
            folderOpenTask?.cancel()
            bellRingTask?.cancel()
        }
    }

    private func playGrantAnimation() {
        switch type {
        case .filesAndFolders:
            openAndCloseFolder()

        case .automation:
            withAnimation(.easeInOut(duration: 0.72)) {
                gearRotation += 360
            }

        case .notifications:
            ringBell()

        case .fullDiskAccess:
            break
        }
    }

    private func openAndCloseFolder() {
        folderOpenTask?.cancel()
        folderOpenTask = Task { @MainActor in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.68)) {
                folderFlapRotation = -42
                folderBackOpacity = 0.48
            }

            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }

            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                folderFlapRotation = 0
                folderBackOpacity = 0
            }
        }
    }

    private func ringBell() {
        bellRingTask?.cancel()
        bellRingTask = Task { @MainActor in
            let swings: [(angle: Double, duration: Double)] = [
                (-19, 0.09),
                (17, 0.12),
                (-13, 0.105),
                (9, 0.095),
                (-5, 0.085),
                (0, 0.11)
            ]

            for swing in swings {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: swing.duration)) {
                    bellRotation = swing.angle
                }
                try? await Task.sleep(for: .seconds(swing.duration))
            }
        }
    }
}
