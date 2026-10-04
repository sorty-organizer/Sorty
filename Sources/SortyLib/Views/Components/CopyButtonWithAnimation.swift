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
    
    @State private var showCheckmark = false
    @State private var resetTask: Task<Void, Never>?
    
    public init(content: String, label: String? = nil, copyIcon: String = "doc.on.doc", iconSize: CGFloat = 13, labelFont: Font = .caption) {
        self.content = content
        self.label = label
        self.copyIcon = copyIcon
        self.iconSize = iconSize
        self.labelFont = labelFont
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
                .foregroundStyle(showCheckmark ? Color.green : Color.secondary)
                .accessibilityHidden(true)
                
                if let label {
                    Text(label)
                        .font(labelFont)
                        .foregroundStyle(showCheckmark ? .green : .secondary)
                }
            }
        }
        .accessibilityLabel(label ?? "Copy")
        .accessibilityValue(showCheckmark ? "Copied" : "")
        .accessibilityIdentifier("CopyButtonWithAnimation")
        .onDisappear {
            resetTask?.cancel()
        }
    }
    
    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        
        HapticFeedbackManager.shared.tap()
        
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            showCheckmark = true
        }
        
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                showCheckmark = false
            }
        }
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
