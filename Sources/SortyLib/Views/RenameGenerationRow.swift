import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RenameGenerationRow: View {
    @SortyHotReload var hotReload
    let originalName: String
    let suggestedName: String?
    let filePath: String?
    let isDirectory: Bool
    let isActive: Bool
    let isRevealed: Bool
    let isMostRecent: Bool

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var suggestedNameReveal = false

    var body: some View {
        let finalName = suggestedName ?? originalName
        let isUnchanged = isRevealed && finalName == originalName

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                RenameFileIcon(filePath: filePath, isDirectory: isDirectory, isUnchanged: isUnchanged)

                RenameNamePill(
                    text: originalName,
                    isPrimary: false,
                    isStruck: isRevealed && !isUnchanged,
                    isShimmering: isActive && !isRevealed
                )

                RenameShiftIndicator(isActive: isActive, isUnchanged: isUnchanged, isMostRecent: isMostRecent)

                RenameNamePill(
                    text: isRevealed ? finalName : "Waiting for suggested name...",
                    isPrimary: isRevealed,
                    isStruck: false,
                    showRevealSweep: suggestedNameReveal && isRevealed
                )
                .opacity(isRevealed ? (suggestedNameReveal ? 1 : 0) : 0.62)
                .offset(x: reduceMotion ? 0 : (suggestedNameReveal ? 0 : -8))
                .scaleEffect(isRevealed ? 1 : 0.985)
                .animation(.easeInOut(duration: 0.18), value: isRevealed)
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: suggestedNameReveal)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.purple.opacity(0.08) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isMostRecent && isRevealed ? Color.purple.opacity(0.24) : .clear, lineWidth: 1)
        )
        .compositingGroup()
        .onAppear {
            revealSuggestedNameIfNeeded()
        }
        .onChange(of: suggestedName) { _, _ in
            revealSuggestedNameIfNeeded()
        }
        .onChange(of: isRevealed) { _, _ in
            revealSuggestedNameIfNeeded()
        }
    }

    func revealSuggestedNameIfNeeded() {
        guard isRevealed else {
            suggestedNameReveal = false
            return
        }
        guard !reduceMotion else {
            suggestedNameReveal = true
            return
        }

        suggestedNameReveal = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                suggestedNameReveal = true
            }
        }
    }
}

struct RenameNamePill: View {
    @SortyHotReload var hotReload
    let text: String
    let isPrimary: Bool
    let isStruck: Bool
    var isShimmering = false
    var showRevealSweep = false

    var body: some View {
        Text(text)
            .font(.caption.weight(isPrimary ? .semibold : .regular))
            .foregroundStyle(isPrimary ? Color.purple : Color.secondary)
            .lineLimit(1)
            .strikethrough(isStruck, color: .secondary)
            .numericTextTransition(
                animationValue: text,
                animation: .easeInOut(duration: 0.28)
            )
            .textShimmer(isLoading: isShimmering, phaseOffset: 0.12, intensity: 1.18)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isPrimary ? Color.purple.opacity(0.08) : Color.secondary.opacity(0.06))
            )
            .overlay(alignment: .leading) {
                if showRevealSweep {
                    RenameGenerationRevealSweep()
                        .allowsHitTesting(false)
                }
            }
    }
}
