import Foundation

enum PromptContextHelper {
    static func duplicateContext(from groups: [DuplicateGroup]) -> String {
        guard !groups.isEmpty else { return "" }

        var context = "\n\nDUPLICATE FILES DETECTED:\n"
        for group in groups {
            context += "- The following files are identical (SHA-256 hash: \(group.hash)):\n"
            for file in group.files {
                context += "  • \(file.displayName) (\(file.path))\n"
            }
        }

        context += "\nRECOMMENDATION FOR DUPLICATES:\n"
        context += "1. If you suggest moving duplicates, try to consolidate them or use a 'Duplicates' folder.\n"
        context += "2. You can suggest better names for them, but keep them in mind for organization.\n"
        return context
    }
}