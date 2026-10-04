import SwiftUI

struct SortySkillSettingsView: View {
    @SortyHotReload private var hotReload

    private let exampleRequest = "Use the Sorty skill to preview how you'd organize my Downloads folder with my preferences."

    var body: some View {
        VStack(spacing: 16) {
            CodexSkillInstallerCard()

            SettingsCard(title: "Use Sorty with Your Agent", icon: "text.bubble", color: .indigo) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Organize folders, rename files, find exact duplicates, and review plans using the Sorty preferences you share during setup.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Try a first request")
                        .font(.subheadline.weight(.semibold))
                    Text(exampleRequest)
                        .font(.callout)
                        .textSelection(.enabled)
                    CopyButtonWithAnimation(content: exampleRequest, label: "Copy Request", labelFont: .body, tint: .primary)
                        .buttonStyle(.sortyBordered())
                        .accessibilityIdentifier("settings.sorty-skill.copy-request")
                    Text("Ask for a preview to review the proposed moves before applying them. Saved folders do not automatically organize themselves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsCard(title: "What You Share", icon: "checklist", color: .green) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose individual naming preferences, exclusions, saved folders, and Learnings in setup. Review your selection before importing it.")
                    Text("Shared Learnings become readable files your agent can use. Credentials, app permissions, and session history stay in Sorty.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsCard(title: "Keep Preferences Current", icon: "arrow.triangle.2.circlepath", color: .blue) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("After changing preferences in Sorty, use Import Settings to update the installed skill. Choose what to share again each time.")
                    Text("The skill uses your agent's model and file access. Finder integration, background watching, and widgets remain available in the Sorty app.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
