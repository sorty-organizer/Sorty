//
//  FolderThumbnailView.swift
//  Sorty
//
//  SwiftUI view component for displaying folder thumbnails.
//  Shows Finder-style folder previews with content thumbnails.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A view that displays a folder thumbnail with async loading
public struct FolderThumbnailView: View {
    @SortyHotReload private var hotReload
    let url: URL
    let size: CGSize
    let loadDelay: Duration

    @State private var thumbnail: NSImage?
    @State private var isLoading = true

    private static let systemFolderIcon: NSImage = {
        copiedIcon(NSWorkspace.shared.icon(for: .folder))
    }()
    
    private static func copiedIcon(_ icon: NSImage) -> NSImage {
        (icon.copy() as? NSImage) ?? icon
    }
    
    public init(
        url: URL,
        size: CGSize = CGSize(width: 40, height: 40),
        loadDelay: Duration = .zero
    ) {
        self.url = url
        self.size = size
        self.loadDelay = loadDelay
    }
    
    public var body: some View {
        AppKitImageView(
            image: thumbnail ?? Self.systemFolderIcon,
            size: size
        )
        .frame(width: size.width, height: size.height)
        .task(id: url) {
            do {
                try await Task.sleep(for: loadDelay)
            } catch {
                return
            }
            isLoading = true
            let resolvedThumbnail = await FileThumbnailProvider.shared.thumbnail(for: url, size: size)
            guard !Task.isCancelled else { return }
            thumbnail = resolvedThumbnail
            isLoading = false
        }
    }
}

/// Compact folder thumbnail for tree views
public struct CompactFolderThumbnail: View {
    @SortyHotReload private var hotReload
    let url: URL?
    let folderName: String
    let size: CGFloat
    let fileCount: Int
    
    @State private var thumbnail: NSImage?
    
    private static let systemFolderIcon: NSImage = {
        copiedIcon(NSWorkspace.shared.icon(for: .folder))
    }()
    
    private static func copiedIcon(_ icon: NSImage) -> NSImage {
        (icon.copy() as? NSImage) ?? icon
    }
    
    public init(url: URL?, folderName: String, size: CGFloat = 20, fileCount: Int = 0) {
        self.url = url
        self.folderName = folderName
        self.size = size
        self.fileCount = fileCount
    }
    
    public var body: some View {
        AppKitImageView(
            image: thumbnail ?? Self.systemFolderIcon,
            size: CGSize(width: size, height: size)
        )
        .frame(width: size, height: size)
        .task(id: url) {
            guard let url = url else { return }
            let resolvedThumbnail = await FileThumbnailProvider.shared.thumbnail(
                for: url,
                size: CGSize(width: size, height: size)
            )
            guard !Task.isCancelled else { return }
            thumbnail = resolvedThumbnail
        }
    }
}

/// Actual macOS folder icon for new folders (using cached system icon)

// MARK: - Preview

#if DEBUG
struct FolderThumbnailView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            FolderThumbnailView(
                url: URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"),
                size: CGSize(width: 64, height: 64)
            )
            
            FolderThumbnailView(
                url: URL(fileURLWithPath: NSHomeDirectory() + "/Documents"),
                size: CGSize(width: 40, height: 40)
            )
            
            CompactFolderThumbnail(
                url: URL(fileURLWithPath: NSHomeDirectory() + "/Desktop"),
                folderName: "Desktop"
            )
        }
        .padding()
    }
}
#endif
