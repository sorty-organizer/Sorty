import SwiftUI
import WidgetKit

private struct SortyWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: SortyWidgetSnapshot
}

private struct SortyWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SortyWidgetEntry {
        SortyWidgetEntry(
            date: Date(),
            snapshot: SortyWidgetSnapshot(
                generatedAt: Date(),
                totalSessions: 12,
                totalFilesOrganized: 248,
                successCount: 10,
                failedCount: 2,
                activeWatchedFolderCount: 3,
                enabledStorageLocationCount: 2,
                lastRunDate: Date().addingTimeInterval(-1800),
                lastRunFolderName: "Downloads",
                lastRunFilesOrganized: 36,
                lastRunStatus: .completed
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SortyWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SortyWidgetEntry>) -> Void) {
        let entry = currentEntry()
        completion(Timeline(entries: [entry], policy: .never))
    }

    private func currentEntry() -> SortyWidgetEntry {
        SortyWidgetEntry(date: Date(), snapshot: SortyWidgetSnapshotStore.load())
    }
}

private struct SortyOverviewWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family

    let entry: SortyWidgetEntry

    var body: some View {
        switch family {
        case .systemMedium:
            mediumWidget
        default:
            smallWidget
        }
    }

    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sorty")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text(entry.snapshot.totalFilesOrganized.formatted())
                        .font(.system(size: 28, weight: .bold, design: .rounded))

                    Text("files organized")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: statusSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: 0)

            if let lastRunFolderName = entry.snapshot.lastRunFolderName {
                Label(lastRunFolderName, systemImage: "folder")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                if let lastRunDate = entry.snapshot.lastRunDate {
                    Text(lastRunDate, style: .relative)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Open Sorty to sync your latest activity.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(URL(string: "sorty://organize"))
        .containerBackground(backgroundGradient, for: .widget)
    }

    private var mediumWidget: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sorty Overview")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    metricCard(
                        title: "Files",
                        value: entry.snapshot.totalFilesOrganized.formatted(),
                        symbol: "doc.text.magnifyingglass"
                    )

                    metricCard(
                        title: "Watched",
                        value: entry.snapshot.activeWatchedFolderCount.formatted(),
                        symbol: "eye"
                    )

                    metricCard(
                        title: "Storage",
                        value: entry.snapshot.enabledStorageLocationCount.formatted(),
                        symbol: "externaldrive"
                    )
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Latest Run")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer(minLength: 8)
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                }

                latestRunCard

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    widgetLink(title: "Organize", systemImage: "sparkles", urlString: "sorty://organize")
                    widgetLink(title: "History", systemImage: "clock.arrow.circlepath", urlString: "sorty://history")
                }
            }
        }
        .containerBackground(backgroundGradient, for: .widget)
    }

    private var latestRunCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lastRunFolderName = entry.snapshot.lastRunFolderName {
                Text(lastRunFolderName)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .lineLimit(1)

                if let lastRunFilesOrganized = entry.snapshot.lastRunFilesOrganized {
                    Text("\(lastRunFilesOrganized.formatted()) files in the most recent session")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let lastRunDate = entry.snapshot.lastRunDate {
                    Text(lastRunDate, style: .relative)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No runs yet")
                    .font(.system(size: 18, weight: .bold, design: .rounded))

                Text("Launch Sorty and run your first organization to populate the widget.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func metricCard(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
        }
    }

    private func widgetLink(title: String, systemImage: String, urlString: String) -> some View {
        Link(destination: URL(string: urlString)!) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white.opacity(0.12), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var statusSymbol: String {
        switch entry.snapshot.lastRunStatus {
        case .completed:
            return "checkmark.seal.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled:
            return "xmark.circle.fill"
        case .undo, .partiallyUndone:
            return "arrow.uturn.backward.circle.fill"
        case .duplicatesCleanup:
            return "doc.on.doc.fill"
        case .skipped:
            return "arrowshape.turn.up.right.circle.fill"
        case nil:
            return "sparkles"
        }
    }

    private var statusColor: Color {
        switch entry.snapshot.lastRunStatus {
        case .completed:
            return .green
        case .failed:
            return .orange
        case .cancelled:
            return .secondary
        case .undo, .partiallyUndone:
            return .yellow
        case .duplicatesCleanup:
            return .blue
        case .skipped:
            return .mint
        case nil:
            return .cyan
        }
    }

    private var backgroundGradient: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.15, blue: 0.25),
                Color(red: 0.03, green: 0.34, blue: 0.43),
                Color(red: 0.11, green: 0.09, blue: 0.18)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct SortyOverviewWidget: Widget {
    let kind = SortyWidgetSnapshotStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SortyWidgetProvider()) { entry in
            SortyOverviewWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Sorty Overview")
        .description("Check your recent organization activity and jump back into Sorty.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct SortyWidgets: WidgetBundle {
    var body: some Widget {
        SortyOverviewWidget()
    }
}
