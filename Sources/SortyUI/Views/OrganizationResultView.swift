//
//  OrganizationResultView.swift
//  Sorty
//
//  Display for organization results and stats
//

import AppKit
import SwiftUI

package struct OrganizationResultView: View {
    @SortyHotReload private var hotReload
    let stats: GenerationStats
    var duplicatesFound: Int = 0

    package init(stats: GenerationStats, duplicatesFound: Int = 0) {
        self.stats = stats
        self.duplicatesFound = duplicatesFound
    }
    
    package var body: some View {
        VStack(spacing: 0) {
            GenerationStatsView(stats: stats, duplicatesFound: duplicatesFound)
        }
        .padding()
    }
}

struct GenerationStatsView: View {
    @SortyHotReload private var hotReload
    let stats: GenerationStats
    var duplicatesFound: Int = 0
    @State private var isExpanded = false
    
    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 10, maximum: .infinity), spacing: 16),
            GridItem(.flexible(minimum: 10, maximum: .infinity), spacing: 16),
            GridItem(.flexible(minimum: 10, maximum: .infinity), spacing: 16)
        ]
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                HapticFeedbackManager.shared.light()
                withAnimation(.sortySnappy) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SortyDesignSystem.Colors.resolvedAccent)
                    
                    Text("Stats for Nerds")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    Text(stats.compactModelName)
                        .sortyBadge(tint: SortyDesignSystem.Colors.resolvedAccent)
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .symbolReplaceTransition(animationValue: isExpanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .onHover { hovering in
                if hovering {
                    HapticFeedbackManager.shared.selection()
                }
            }
            .accessibilityLabel(
                Text(
                    isExpanded
                        ? "Stats for nerds. Collapse for details"
                        : "Stats for nerds. Expand for details"
                )
            )

            if isExpanded {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    NerdStatPillExpanded(
                        icon: "clock.fill",
                        color: SortyDesignSystem.Colors.info,
                        title: "AI Time",
                        value: GenerationStats.formatDuration(stats.duration),
                        unit: nil
                    )

                    NerdStatPillExpanded(
                        icon: "bolt.fill",
                        color: SortyDesignSystem.Colors.resolvedAccent,
                        title: "Throughput",
                        value: String(format: "%.1f", stats.tps),
                        unit: "t/s"
                    )
                    
                    NerdStatPillExpanded(
                        icon: "timer",
                        color: SortyDesignSystem.Colors.info,
                        title: "TTFT",
                        value: GenerationStats.formatDuration(stats.ttft),
                        unit: nil
                    )

                    NerdStatPillExpanded(
                        icon: "text.bubble",
                        color: SortyDesignSystem.Colors.resolvedAccent,
                        title: "Response",
                        value: GenerationStats.formatCount(stats.responseTokens),
                        unit: "tok"
                    )
                    
                    if let promptTokens = stats.promptTokens {
                        NerdStatPillExpanded(
                            icon: "text.alignleft",
                            color: SortyDesignSystem.Colors.resolvedAccent,
                            title: "Prompt",
                            value: GenerationStats.formatCount(promptTokens),
                            unit: "tok"
                        )
                    }

                    if let totalContextTokens = stats.totalContextTokens {
                        NerdStatPillExpanded(
                            icon: "sum",
                            color: SortyDesignSystem.Colors.resolvedAccent,
                            title: "Context",
                            value: GenerationStats.formatCount(totalContextTokens),
                            unit: "tok"
                        )
                    }
                    
                    if let scanned = stats.filesScanned {
                        NerdStatPillExpanded(
                            icon: "doc.text.magnifyingglass",
                            color: SortyDesignSystem.Colors.resolvedAccent,
                            title: "Files Reviewed",
                            value: GenerationStats.formatCount(scanned),
                            unit: "files"
                        )
                    }
                    
                    if let size = stats.formattedTotalFileSize {
                        NerdStatPillExpanded(
                            icon: "internaldrive",
                            color: .gray,
                            title: "Data Volume",
                            value: size,
                            unit: nil
                        )
                    }

                    if let scanDuration = stats.scanDuration {
                        NerdStatPillExpanded(
                            icon: "stopwatch",
                            color: SortyDesignSystem.Colors.info,
                            title: "Scan Time",
                            value: GenerationStats.formatDuration(scanDuration),
                            unit: nil
                        )
                    }

                    if stats.hasBillableCost {
                        NerdStatPillExpanded(
                            icon: "dollarsign.circle.fill",
                            color: SortyDesignSystem.Colors.success,
                            title: "Estimated Cost",
                            value: GenerationStats.formatCost(stats.computedCost),
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
                    
                    let dups = duplicatesFound > 0 ? duplicatesFound : (stats.duplicatesFound ?? 0)
                    if dups > 0 {
                        NerdStatPillExpanded(
                            icon: "square.on.square",
                            color: SortyDesignSystem.Colors.warning,
                            title: "Duplicates",
                            value: GenerationStats.formatCount(dups),
                            unit: "files"
                        )
                    }
                }
            }
        }
        .sortyCard()
        .accessibilityElement(children: .contain)
    }
}

public struct NerdStatPill: View {
    @SortyHotReload private var hotReload
    public let title: String?
    public let icon: String
    public let value: String
    public let unit: String?
    public let color: Color
    
    public init(title: String? = nil, icon: String, value: String, unit: String?, color: Color) {
        self.title = title
        self.icon = icon
        self.value = value
        self.unit = unit
        self.color = color
    }
    
    private var copyText: String {
        let displayValue = [value, unit].compactMap { $0 }.joined(separator: " ")
        guard let title else { return displayValue }
        return "\(title): \(displayValue)"
    }

    public var body: some View {
        Button(action: copyToPasteboard) {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
            
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .numericTextTransition(animationValue: value)
            
            if let unit = unit {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .sortyBadge(tint: color)
        }
        .buttonStyle(.plain)
        .help("Copy \(copyText)")
        .accessibilityLabel("Copy \(copyText)")
        .accessibilityHint("Copies this statistic to the clipboard")
    }

    private func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        HapticFeedbackManager.shared.success()
    }
}

public struct NerdStatPillExpanded: View {
    @SortyHotReload private var hotReload
    public let icon: String
    public let color: Color
    public let title: String
    public let value: String
    public let unit: String?
    
    public init(icon: String, color: Color, title: String, value: String, unit: String?) {
        self.icon = icon
        self.color = color
        self.title = title
        self.value = value
        self.unit = unit
    }

    private var copyText: String {
        let displayValue = [value, unit].compactMap { $0 }.joined(separator: " ")
        return "\(title): \(displayValue)"
    }
    
    public var body: some View {
        Button(action: copyToPasteboard) {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 24, height: 24)
                
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
            }
            
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .numericTextTransition(animationValue: value)
                    
                    if let unit = unit {
                        Text(unit)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                
                Text(LocalizedStringKey(title))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .sortyInsetSurface(cornerRadius: SortyDesignSystem.Radius.lg)
        }
        .buttonStyle(.plain)
        .help("Copy \(copyText)")
        .accessibilityLabel("Copy \(copyText)")
        .accessibilityHint("Copies this statistic to the clipboard")
    }

    private func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        HapticFeedbackManager.shared.success()
    }
}

package struct NerdStatCard: View {
    @SortyHotReload private var hotReload
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    let unit: String?
    let description: String

    package init(
        icon: String,
        iconColor: Color,
        title: String,
        value: String,
        unit: String?,
        description: String
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.value = value
        self.unit = unit
        self.description = description
    }
    
    package var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                
                Text(LocalizedStringKey(title))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .numericTextTransition(animationValue: value)
                    
                    if let unit = unit {
                        Text(unit)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                
                Text(LocalizedStringKey(description))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 112 - 24, alignment: .topLeading)
        .sortyCard(padding: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value) \(unit ?? "")")
    }
}
