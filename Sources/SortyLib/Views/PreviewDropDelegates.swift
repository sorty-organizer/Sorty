import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

// MARK: - Optimized Drop Delegates

struct OptimizedFileDropDelegate: DropDelegate {
    let targetFolderID: UUID
    let store: PreviewStore
    @Binding var draggedFile: FileItem?
    @Binding var isTargeted: Bool
    let onPlanChanged: () -> Void
    
    func dropEntered(info: DropInfo) {
        isTargeted = true
    }
    
    func dropExited(info: DropInfo) {
        isTargeted = false
    }
    
    func validateDrop(info: DropInfo) -> Bool {
        guard draggedFile != nil else { return false }
        return true
    }
    
    func performDrop(info: DropInfo) -> Bool {
        guard let file = draggedFile else { return false }
        
        store.moveFile(fileID: file.id, toFolderID: targetFolderID)
        onPlanChanged()
        draggedFile = nil
        isTargeted = false
        
        return true
    }
}

struct OptimizedUnorganizedDropDelegate: DropDelegate {
    let store: PreviewStore
    @Binding var draggedFile: FileItem?
    @Binding var isTargeted: Bool
    let onPlanChanged: () -> Void
    
    func dropEntered(info: DropInfo) {
        isTargeted = true
    }
    
    func dropExited(info: DropInfo) {
        isTargeted = false
    }
    
    func validateDrop(info: DropInfo) -> Bool {
        guard let file = draggedFile else { return false }
        return !store.plan.unorganizedFiles.contains { $0.id == file.id }
    }
    
    func performDrop(info: DropInfo) -> Bool {
        guard let file = draggedFile else { return false }
        
        store.moveFileToUnorganized(fileID: file.id)
        onPlanChanged()
        draggedFile = nil
        isTargeted = false
        
        return true
    }
}
