//
//  CopyButtonWithAnimation.swift
//  Sorty
//
//  Reusable copy button that shows a checkmark animation after copying
//

import AppKit
import SwiftUI

public struct CopyButtonWithAnimation: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let content: String
    var label: String?
    var copyIcon: String = "doc.on.doc"
    var iconSize: CGFloat = 13
    var labelFont: Font = .caption
    var tint: Color = .secondary
    
    @StateObject private var feedback = CopyFeedback()
    private var showCheckmark: Bool { feedback.isCopied }
    
    public init(content: String, label: String? = nil, copyIcon: String = "doc.on.doc", iconSize: CGFloat = 13, labelFont: Font = .caption, tint: Color = .secondary) {
        self.content = content
        self.label = label
        self.copyIcon = copyIcon
        self.iconSize = iconSize
        self.labelFont = labelFont
        self.tint = tint
    }
    
    public var body: some View {
        Button {
            copyToClipboard()
        } label: {
            HStack(spacing: 4) {
                ZStack {
                    Image(systemName: copyIcon)
                        .resizable()
                        .scaledToFit()
                        .opacity(showCheckmark ? 0 : 1)
                    Image(systemName: "checkmark")
                        .resizable()
                        .scaledToFit()
                        .opacity(showCheckmark ? 1 : 0)
                }
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(showCheckmark ? Color.green : tint)
                .accessibilityHidden(true)
                
                if let label {
                    Text(label)
                        .font(labelFont)
                        .foregroundStyle(showCheckmark ? .green : tint)
                }
            }
        }
        .accessibilityLabel(label ?? "Copy")
        .accessibilityValue(showCheckmark ? "Copied" : "")
        .accessibilityIdentifier("CopyButtonWithAnimation")
        .onDisappear {
            feedback.cancel()
        }
    }
    
    private func copyToClipboard() {
        feedback.copy(content, animation: reduceMotion ? nil : .easeInOut(duration: 0.15),
                      resetAnimation: reduceMotion ? nil : .easeInOut(duration: 0.15))
    }
}

#Preview("Copy Button") {
    VStack(spacing: 16) {
        CopyButtonWithAnimation(content: "Hello World")
        CopyButtonWithAnimation(content: "Hello World", label: "Copy")
        CopyButtonWithAnimation(content: "/path/to/file", label: "Copy Path", copyIcon: "folder")
    }
    .padding()
}

/// Clipboard feedback shared by copy controls; callers own styling and animation.
@MainActor
final class CopyFeedback: ObservableObject {
    @Published private(set) var isCopied = false
    private var resetTask: Task<Void, Never>?

    func copy(_ text: String, duration: Duration = .seconds(1.5),
              animation: Animation? = nil, resetAnimation: Animation? = nil,
              haptic: () -> Void = { HapticFeedbackManager.shared.tap() }) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { return }
        haptic()
        resetTask?.cancel()
        withAnimation(animation) { isCopied = true }
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            withAnimation(resetAnimation) { self.isCopied = false }
        }
    }

    func cancel() {
        resetTask?.cancel()
        resetTask = nil
        isCopied = false
    }
}
