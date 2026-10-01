//
//  FileDropDelegate.swift
//  Sorty
//
//  Handles drag and drop operations for interactive plan editing
//

import Combine

/// View model for managing drag state across the preview
@MainActor
class DragDropManager: ObservableObject {
    @Published var draggedFile: FileItem?

    func startDrag(_ file: FileItem) {
        draggedFile = file
    }
}
