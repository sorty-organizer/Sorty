import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Waveform icon whose repeating breathe is gated on Reduce Motion and
/// window activation instead of running unconditionally.
struct BreatheWaveformIcon: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Image(systemName: "waveform")
            .font(.callout)
            .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
            .symbolEffect(
                .breathe,
                options: reduceMotion || controlActiveState == .inactive ? .nonRepeating : .repeating
            )
    }
}

struct RenameGenerationRevealSweep: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var progress: CGFloat = -0.35

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)

            LinearGradient(
                colors: [
                    .clear,
                    .white.opacity(0.22),
                    Color.purple.opacity(0.17),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(width * 0.26, 22), height: geometry.size.height * 1.8)
            .blur(radius: reduceTransparency ? 0 : 2.2)
            .offset(x: width * progress)
            .blendMode(.plusLighter)
            .onAppear {
                progress = -0.35
                withAnimation(.easeOut(duration: 0.58)) {
                    progress = 1.12
                }
            }
        }
        .clipped()
    }
}

struct RenameFileIcon: View {
    @SortyHotReload private var hotReload
    let filePath: String?
    let isDirectory: Bool
    let isUnchanged: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let filePath {
                let url = URL(fileURLWithPath: filePath)
                if isDirectory {
                    FolderThumbnailView(url: url, size: CGSize(width: 22, height: 22))
                } else {
                    FileThumbnailView(url: url, size: CGSize(width: 22, height: 22))
                }
            } else {
                AppKitImageView(
                    image: AnalysisIconProvider.icon(for: .data),
                    size: CGSize(width: 22, height: 22),
                    opacity: 0.72
                )
                .frame(width: 22, height: 22)
            }

            Image(systemName: isUnchanged ? "equal.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isUnchanged ? Color.secondary : Color.green)
                .symbolReplaceTransition(animationValue: isUnchanged)
                .background(Circle().fill(Color(NSColor.windowBackgroundColor)))
                .offset(x: 3, y: 3)
        }
        .frame(width: 28, height: 24)
    }
}

struct RenameShiftIndicator: View {
    @SortyHotReload private var hotReload
    let isActive: Bool
    let isUnchanged: Bool
    /// Only the most-recent row pulses; older rows render static so a long
    /// stream does not accumulate one repeatForever each.
    var isMostRecent = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var shouldPulse: Bool {
        isActive && isMostRecent && !reduceMotion
    }

    var body: some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(Color.secondary.opacity(0.16))
                .frame(width: 16, height: 2)

            Image(systemName: isUnchanged ? "equal" : "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isUnchanged ? Color.secondary : Color.purple)
                .symbolReplaceTransition(animationValue: isUnchanged)
                .scaleEffect(isActive && pulse ? 1.12 : 1)

            Capsule()
                .fill((isUnchanged ? Color.secondary : Color.purple).opacity(0.18))
                .frame(width: 16, height: 2)
        }
        .frame(width: 56)
        .onAppear {
            guard shouldPulse else { return }
            withAnimation(.smooth(duration: 0.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: isActive) { _, active in
            if active, shouldPulse {
                withAnimation(.smooth(duration: 0.5).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.smooth(duration: 0.2)) {
                    pulse = false
                }
            }
        }
        .onChange(of: isMostRecent) { _, _ in
            if shouldPulse {
                withAnimation(.smooth(duration: 0.5).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.smooth(duration: 0.2)) {
                    pulse = false
                }
            }
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            guard shouldReduceMotion else { return }
            withAnimation(nil) {
                pulse = false
            }
        }
    }
}

/// Mid-organization progress card using Beam's reference playground samples.
