//
//  PreviewStatsView.swift
//  Sorty
//
//  Stats display component with "Stats for Nerds" collapsible section
//

import AppKit
import SwiftUI

struct PreviewStatsView: View {
    @SortyHotReload private var hotReload
    let stats: GenerationStats?
    let showStatsForNerds: Bool
    let estimatedTimeRemaining: TimeInterval?
    let currentFile: Int
    let totalFiles: Int
    let stage: String
    
    @AppStorage("statsForNerdsExpanded") private var isExpanded = false
    @State private var isHovering = false
    
    var body: some View {
        VStack(spacing: 0) {
            if let stats = stats, showStatsForNerds {
                // Collapsible stats row
                HStack(spacing: 12) {
                    Button(action: toggleExpandedStats) {
                        HStack(spacing: 12) {
                        Image(systemName: "chart.bar.doc.horizontal")
                            .font(.system(size: 12))
                            .foregroundStyle(.purple)
                        
                        Text("Stats for Nerds")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .symbolReplaceTransition(animationValue: isExpanded)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse detailed generation metrics" : "Expand for detailed generation metrics")
                    .accessibilityLabel("Stats for nerds. \(isExpanded ? "Collapse" : "Expand") for details")
                    .accessibilityIdentifier("statsForNerdsToggle")

                    Spacer(minLength: 0)

                    // Summary pills
                    HStack(spacing: 12) {
                        if stats.estimatedTimeSaved > 0 {
                            NerdStatPill(
                                title: "Estimated Time Saved",
                                icon: "clock.arrow.circlepath",
                                value: GenerationStats.formatDuration(stats.estimatedTimeSaved),
                                unit: nil,
                                color: .orange
                            )
                        }

                        if let fileCount = stats.filesScanned ?? (totalFiles > 0 ? totalFiles : nil) {
                            NerdStatPill(title: "Files Reviewed", icon: "doc.text.magnifyingglass", value: GenerationStats.formatCount(fileCount), unit: "files", color: .indigo)
                        }

                        if let totalContextTokens = stats.totalContextTokens {
                            NerdStatPill(title: "Context", icon: "sum", value: GenerationStats.formatCount(totalContextTokens), unit: "ctx", color: .teal)
                        } else {
                            NerdStatPill(title: "Response", icon: "text.bubble", value: GenerationStats.formatCount(stats.responseTokens), unit: "resp", color: .teal)
                        }

                        NerdStatPill(title: "AI Time", icon: "clock.fill", value: GenerationStats.formatDuration(stats.duration), unit: nil, color: .blue)

                        if stats.hasBillableCost {
                            NerdStatPill(title: "Estimated Cost", icon: "dollarsign.circle", value: GenerationStats.formatCost(stats.computedCost), unit: nil, color: .green)
                        }
                        
                        // Time remaining estimate
                        if let estimatedTime = estimatedTimeRemaining, estimatedTime > 0 {
                            NerdStatPill(
                                title: "Time Remaining",
                                icon: "hourglass",
                                value: GenerationStats.formatDuration(estimatedTime),
                                unit: "left",
                                color: .purple
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.05 : 0))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                )
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovering = hovering
                    }
                }
                
                // Expanded detailed stats
                if isExpanded {
                    Divider()
                        .padding(.horizontal, 16)
                    
                    detailedStatsView(stats: stats)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            } else if !showStatsForNerds && estimatedTimeRemaining != nil {
                // Simple progress with time estimate when stats are hidden
                HStack {
                    Spacer()
                    if let estimatedTime = estimatedTimeRemaining {
                        Label(GenerationStats.formatDuration(estimatedTime) + " remaining", systemImage: "hourglass")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .numericTextTransition(animationValue: estimatedTime)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contextMenu {
            if let stats = stats {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(statsSummaryText(stats), forType: .string)
                    HapticFeedbackManager.shared.success()
                } label: {
                    Label("Copy Stats", systemImage: "doc.on.clipboard")
                }
            }
        }
    }

    private func toggleExpandedStats() {
        HapticFeedbackManager.shared.selection()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExpanded.toggle()
        }
    }

    private func statsSummaryText(_ stats: GenerationStats) -> String {
        var lines: [String] = []
        lines.append("Model: \(stats.model)")
        if let provider = stats.provider { lines.append("Provider: \(provider)") }
        lines.append("AI time: \(GenerationStats.formatDuration(stats.duration))")
        lines.append("TTFT: \(GenerationStats.formatDuration(stats.ttft))")
        lines.append("Throughput: \(String(format: "%.1f", stats.tps)) tok/s")
        if let promptTokens = stats.promptTokens { lines.append("Prompt tokens: \(GenerationStats.formatCount(promptTokens))") }
        lines.append("Response tokens: \(GenerationStats.formatCount(stats.responseTokens))")
        if let totalContextTokens = stats.totalContextTokens { lines.append("Total context: \(GenerationStats.formatCount(totalContextTokens))") }
        if let filesScanned = stats.filesScanned { lines.append("Files reviewed: \(GenerationStats.formatCount(filesScanned))") }
        if let size = stats.formattedTotalFileSize { lines.append("Data volume: \(size)") }
        if let scanDuration = stats.scanDuration { lines.append("Scan duration: \(GenerationStats.formatDuration(scanDuration))") }
        if let retryCount = stats.retryCount, retryCount > 0 { lines.append("Retries: \(retryCount)") }
        if stats.hasBillableCost { lines.append("Estimated cost: \(GenerationStats.formatCost(stats.computedCost))") }
        if stats.estimatedTimeSaved > 0 { lines.append("Estimated time saved: \(GenerationStats.formatDuration(stats.estimatedTimeSaved))") }
        return lines.joined(separator: "\n")
    }
    
    private func detailedStatsView(stats: GenerationStats) -> some View {
        LazyVGrid(columns: [
            GridItem(.flexible(minimum: 10, maximum: .infinity), spacing: 12),
            GridItem(.flexible(minimum: 10, maximum: .infinity), spacing: 12),
            GridItem(.flexible(minimum: 10, maximum: .infinity), spacing: 12),
            GridItem(.flexible(minimum: 10, maximum: .infinity), spacing: 12)
        ], spacing: 12) {
            NerdStatPillExpanded(
                icon: "clock.fill",
                color: .blue,
                title: "AI Time",
                value: GenerationStats.formatDuration(stats.duration),
                unit: nil
            )

            NerdStatPillExpanded(
                icon: "bolt.fill",
                color: .orange,
                title: "Throughput",
                value: String(format: "%.1f", stats.tps),
                unit: "tok/s"
            )
            
            NerdStatPillExpanded(
                icon: "timer",
                color: .green,
                title: "TTFT",
                value: GenerationStats.formatDuration(stats.ttft),
                unit: nil
            )

            if let promptTokens = stats.promptTokens {
                NerdStatPillExpanded(
                    icon: "text.alignleft",
                    color: .purple,
                    title: "Prompt",
                    value: GenerationStats.formatCount(promptTokens),
                    unit: "tok"
                )
            }

            NerdStatPillExpanded(
                icon: "text.bubble",
                color: .teal,
                title: "Response",
                value: GenerationStats.formatCount(stats.responseTokens),
                unit: "tok"
            )

            if let totalContextTokens = stats.totalContextTokens {
                NerdStatPillExpanded(
                    icon: "sum",
                    color: .mint,
                    title: "Context",
                    value: GenerationStats.formatCount(totalContextTokens),
                    unit: "tok"
                )
            }

            if let filesScanned = stats.filesScanned {
                NerdStatPillExpanded(
                    icon: "doc.text.magnifyingglass",
                    color: .indigo,
                    title: "Files Reviewed",
                    value: GenerationStats.formatCount(filesScanned),
                    unit: "files"
                )
            }

            if let totalFileSize = stats.formattedTotalFileSize {
                NerdStatPillExpanded(
                    icon: "internaldrive",
                    color: .cyan,
                    title: "Data Volume",
                    value: totalFileSize,
                    unit: nil
                )
            }

            if let scanDuration = stats.scanDuration {
                NerdStatPillExpanded(
                    icon: "stopwatch",
                    color: .cyan,
                    title: "Scan Duration",
                    value: GenerationStats.formatDuration(scanDuration),
                    unit: nil
                )
            }

            if stats.hasBillableCost {
                NerdStatPillExpanded(
                    icon: "dollarsign.circle",
                    color: .green,
                    title: "Estimated Cost",
                    value: GenerationStats.formatCost(stats.computedCost),
                    unit: nil
                )
            }

            if let duplicatesFound = stats.duplicatesFound, duplicatesFound > 0 {
                NerdStatPillExpanded(
                    icon: "doc.on.doc",
                    color: .red,
                    title: "Duplicates",
                    value: GenerationStats.formatCount(duplicatesFound),
                    unit: "files"
                )
            }

            if let retryCount = stats.retryCount, retryCount > 0 {
                NerdStatPillExpanded(
                    icon: "arrow.clockwise",
                    color: .orange,
                    title: "Retries",
                    value: GenerationStats.formatCount(retryCount),
                    unit: nil
                )
            }

            if stats.estimatedTimeSaved > 0 {
                NerdStatPillExpanded(
                    icon: "sparkles",
                    color: .yellow,
                    title: "Est. Time Saved",
                    value: GenerationStats.formatDuration(stats.estimatedTimeSaved),
                    unit: nil
                )
            }

            if let provider = stats.provider {
                NerdStatPillExpanded(
                    icon: "network",
                    color: .secondary,
                    title: "Provider",
                    value: provider,
                    unit: nil
                )
            }
            
            NerdStatPillExpanded(
                icon: "cpu",
                color: .primary,
                title: "Model",
                value: stats.model,
                unit: nil
            )
        }
    }
}

// MARK: - Previews

#Preview("Preview Stats - Collapsed") {
    PreviewStatsView(
        stats: GenerationStats(
            duration: 1.5,
            tps: 45.2,
            ttft: 0.3,
            totalTokens: 1250,
            model: "gpt-4o",
            filesScanned: 42,
            promptTokens: 850,
            provider: "OpenAI"
        ),
        showStatsForNerds: true,
        estimatedTimeRemaining: nil,
        currentFile: 0,
        totalFiles: 42,
        stage: "Analyzing"
    )
    .frame(width: 800)
}

#Preview("Preview Stats - Expanded") {
    PreviewStatsView(
        stats: GenerationStats(
            duration: 1.5,
            tps: 45.2,
            ttft: 0.3,
            totalTokens: 1250,
            model: "gpt-4o",
            filesScanned: 42,
            promptTokens: 850,
            provider: "OpenAI"
        ),
        showStatsForNerds: true,
        estimatedTimeRemaining: 120,  // 2 minutes
        currentFile: 20,
        totalFiles: 42,
        stage: "Moving files"
    )
    .frame(width: 800)
}

#Preview("Preview Stats - Hidden") {
    PreviewStatsView(
        stats: nil,
        showStatsForNerds: false,
        estimatedTimeRemaining: 45,
        currentFile: 10,
        totalFiles: 50,
        stage: "Organizing"
    )
    .frame(width: 800)
}
