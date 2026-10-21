import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
// MARK: - Previews

@MainActor
enum OrganizePreviewObjects {
    static var idleOrganizer: FolderOrganizer {
        let organizer = FolderOrganizer()
        organizer.state = .idle
        return organizer
    }
    
    static var scanningOrganizer: FolderOrganizer {
        let organizer = FolderOrganizer()
        organizer.state = .scanning
        organizer.progress = 0.35
        organizer.organizationStage = "Scanning files..."
        return organizer
    }
    
    static var readyOrganizer: FolderOrganizer {
        let organizer = FolderOrganizer()
        organizer.state = .ready
        organizer.currentPlan = PreviewMocks.makeOrganizationPlan()
        return organizer
    }
    
    static var errorOrganizer: FolderOrganizer {
        let organizer = FolderOrganizer()
        organizer.state = .error(NSError(domain: "Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connection failed. Please check your API key."]))
        return organizer
    }
    
    static var readyAppState: AppState {
        let state = AppState()
        state.hasCompletedOnboarding = true
        state.selectedDirectory = URL(fileURLWithPath: "/Users/user/Downloads")
        return state
    }
}
#endif
