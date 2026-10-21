import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Beam

struct SupportHealthCheck: Identifiable {
    let id: String
    let title: String
    let detail: String
    let status: SupportHealthStatus
    let actionTitle: String?
    let destination: SettingsFocusTarget?
}

struct SupportHealthCheckRow: View {
    @SortyHotReload private var hotReload
    let check: SupportHealthCheck
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(check.status.color)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(check.title)
                    .font(.subheadline.weight(.semibold))

                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(check.title), \(check.status.reportLabel)")
            .accessibilityHint(check.detail)

            Spacer(minLength: 8)

            if let actionTitle = check.actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.sortyBordered(intent: .info, size: .small))
            }
        }
        .padding(10)
        .background(check.status.color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
