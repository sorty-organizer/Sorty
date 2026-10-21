//
//  StorageLocationPopoverContent.swift
//  Sorty
//
//  Liquid glass popover content for storage location actions.
//

import SwiftUI

package struct StorageLocationPopoverContent: View {
    @SortyHotReload private var hotReload
    let displayName: String
    let path: String
    var onChangeLocation: (() -> Void)? = nil
    var onShowInFinder: (() -> Void)? = nil
    var onCopyPath: (() -> Void)? = nil

    package init(
        displayName: String,
        path: String,
        onChangeLocation: (() -> Void)? = nil,
        onShowInFinder: (() -> Void)? = nil,
        onCopyPath: (() -> Void)? = nil
    ) {
        self.displayName = displayName
        self.path = path
        self.onChangeLocation = onChangeLocation
        self.onShowInFinder = onShowInFinder
        self.onCopyPath = onCopyPath
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AppKitImageView(
                    image: NSWorkspace.shared.icon(forFile: path),
                    size: CGSize(width: 24, height: 24)
                )
                .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    PrivacySensitivePathText(path: path, blurRadius: 8)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.bottom, 8)

            Divider()
                .padding(.bottom, 4)

            if let onChangeLocation {
                PopoverMenuButton(title: "Change Storage Location…", icon: "folder.badge.gearshape") {
                    onChangeLocation()
                }
            }

            if let onShowInFinder {
                PopoverMenuButton(title: "Show in Finder", icon: "folder") {
                    onShowInFinder()
                }
            }

            if let onCopyPath {
                PopoverMenuButton(title: "Copy Path", icon: "doc.on.doc") {
                    onCopyPath()
                }
            }
        }
        .padding(12)
        .frame(minWidth: 220)
    }
}

private struct PopoverMenuButton: View {
    @SortyHotReload private var hotReload
    let title: String
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            HapticFeedbackManager.shared.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(LocalizedStringKey(title))
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                HapticFeedbackManager.shared.selection()
            }
        }
    }
}
