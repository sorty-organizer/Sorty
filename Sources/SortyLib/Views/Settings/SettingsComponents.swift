//
//  SettingsComponents.swift
//  Sorty
//
//  Shared settings UI components
//

import SwiftUI

private struct SettingsFocusTargetKey: EnvironmentKey {
    static let defaultValue: SettingsFocusTarget? = nil
}

private struct SettingsFocusDismissActionKey: EnvironmentKey {
    static let defaultValue: @MainActor (SettingsFocusTarget) -> Void = { _ in }
}

extension EnvironmentValues {
    var settingsFocusTarget: SettingsFocusTarget? {
        get { self[SettingsFocusTargetKey.self] }
        set { self[SettingsFocusTargetKey.self] = newValue }
    }

    var settingsFocusDismissAction: @MainActor (SettingsFocusTarget) -> Void {
        get { self[SettingsFocusDismissActionKey.self] }
        set { self[SettingsFocusDismissActionKey.self] = newValue }
    }
}

private struct SettingsFocusableModifier<FocusShape: InsettableShape>: ViewModifier {
    @Environment(\.settingsFocusDismissAction) private var dismissFocus
    @Environment(\.settingsFocusTarget) private var focusTarget

    let target: SettingsFocusTarget
    let shape: FocusShape
    let horizontalRingPadding: CGFloat
    let verticalRingPadding: CGFloat

    private var isFocused: Bool {
        focusTarget == target
    }

    func body(content: Content) -> some View {
        content
            .id(target.rawValue)
            .sortyFocusHighlight(
                isActive: isFocused,
                shape: shape,
                horizontalRingPadding: horizontalRingPadding,
                verticalRingPadding: verticalRingPadding
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard isFocused else { return }
                    dismissFocus(target)
                }
            )
    }

}

private struct SortyFocusHighlightModifier<FocusShape: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    let isActive: Bool
    let shape: FocusShape
    let horizontalRingPadding: CGFloat
    let verticalRingPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                // Inactive targets must not build transparent stroked and blurred
                // layers. Settings pages can contain dozens of these highlights.
                if isActive {
                    ZStack {
                        shape
                            .strokeBorder(
                                Color.accentColor.opacity(isBreathing ? 0.95 : 0.72),
                                lineWidth: 2
                            )

                        shape
                            .strokeBorder(
                                Color.accentColor.opacity(isBreathing ? 0.42 : 0.16),
                                lineWidth: 3
                            )
                            .scaleEffect(!reduceMotion && isBreathing ? 1.012 : 1)
                            .blur(radius: reduceMotion ? 0 : (isBreathing ? 4 : 2))
                    }
                    .padding(.horizontal, -horizontalRingPadding)
                    .padding(.vertical, -verticalRingPadding)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
            }
            .shadow(
                color: isActive && !reduceMotion
                    ? Color.accentColor.opacity(isBreathing ? 0.38 : 0.16)
                    : .clear,
                radius: reduceMotion ? 0 : (isBreathing ? 14 : 7)
            )
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isActive)
            .onAppear { updateBreathingAnimation(isActive) }
            .onChange(of: isActive) { _, newValue in
                updateBreathingAnimation(newValue)
            }
            .onChange(of: reduceMotion) { _, _ in
                updateBreathingAnimation(isActive)
            }
    }

    private func updateBreathingAnimation(_ shouldBreathe: Bool) {
        guard shouldBreathe, !reduceMotion else {
            isBreathing = false
            return
        }

        isBreathing = false
        // A few pulses draw attention without keeping SwiftUI's animation
        // timeline active for the full lifetime of the focus highlight.
        withAnimation(.easeInOut(duration: 0.7).repeatCount(3, autoreverses: true)) {
            isBreathing = true
        }
    }
}

struct SidebarButton: View {
    @SortyHotReload private var hotReload
    let title: String
    let icon: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? color : .secondary)
                    .frame(width: 20)
                
                Text(LocalizedStringKey(title))
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? color.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct SettingsCard<Content: View>: View {
    @SortyHotReload private var hotReload
    let title: String
    let icon: String
    let color: Color
    let count: Int?
    let isExpanded: Binding<Bool>?
    let headerAccessory: AnyView?
    @ViewBuilder let content: Content

    init(
        title: String,
        icon: String,
        color: Color,
        count: Int? = nil,
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.color = color
        self.count = count
        self.isExpanded = isExpanded
        self.headerAccessory = nil
        self.content = content()
    }

    init<HeaderAccessory: View>(
        title: String,
        icon: String,
        color: Color,
        count: Int? = nil,
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder headerAccessory: () -> HeaderAccessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.color = color
        self.count = count
        self.isExpanded = isExpanded
        self.headerAccessory = AnyView(headerAccessory())
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded == nil ? 12 : 0) {
            if let isExpanded {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.wrappedValue.toggle()
                    }
                    HapticFeedbackManager.shared.tap()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(color)
                            .frame(width: 16)

                        Text(LocalizedStringKey(title))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        headerAccessory
                        countBadge
                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .rotationEffect(
                                .degrees(isExpanded.wrappedValue ? 90 : 0)
                            )
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    Text(
                        isExpanded.wrappedValue
                            ? "\(title). Collapse section"
                            : "\(title). Expand section"
                    )
                )
                .help(isExpanded.wrappedValue ? "Collapse \(title)" : "Expand \(title)")
            } else {
                header()
            }

            if isExpanded?.wrappedValue != false {
                if isExpanded != nil {
                    Divider()
                        .padding(.horizontal, 16)
                }

                content
                    .padding(isExpanded == nil ? 0 : 16)
            }
        }
        .padding(isExpanded == nil ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The card is a container. Its controls provide their own interaction
        // feedback, so the glass itself does not need continuous pointer state.
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
    }

    private func header() -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(LocalizedStringKey(title))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            headerAccessory
            countBadge
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var countBadge: some View {
        if let count, count > 0 {
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .numericTextTransition(animationValue: count)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
    }
}

struct StepCard<Content: View>: View {
    @SortyHotReload private var hotReload
    let number: Int
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.medium))
                content
            }
        }
    }
}

struct SettingsTextField: View {
    @SortyHotReload private var hotReload
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title))
                .font(.subheadline)
            TextField(LocalizedStringKey(placeholder), text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct SettingsSecureField: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    @Binding var text: String
    var isOptional: Bool = false
    
    @State private var isShowingText = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(LocalizedStringKey(title))
                    .font(.subheadline)
                if isOptional {
                    Text("Optional")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if FeatureFlags.privacyModeEnabled {
                    Button {
                        withAnimation(visibilityAnimation) {
                            isShowingText.toggle()
                        }
                        HapticFeedbackManager.shared.tap()
                    } label: {
                        Image(systemName: isShowingText ? "eye.slash" : "eye")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .symbolReplaceTransition(animationValue: isShowingText)
                    }
                    .buttonStyle(.plain)
                    .help(visibilityButtonLabel)
                    .accessibilityLabel(visibilityButtonLabel)
                }
            }
            
            ZStack {
                if isShowingText && FeatureFlags.privacyModeEnabled {
                    TextField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .transition(.opacity)
                } else {
                    SecureField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .transition(.opacity)
                }
            }
        }
    }

    private var visibilityAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.14)
            : .spring(response: 0.34, dampingFraction: 0.78)
    }

    private var visibilityButtonLabel: String {
        isShowingText ? "Hide \(title)" : "Show \(title)"
    }
}

struct SettingsToggle: View {
    @SortyHotReload private var hotReload
    @Binding var isOn: Bool
    let title: String
    var description: String? = nil
    var previewAction: (() -> Void)? = nil
    var previewIcon: String = "speaker.wave.2.fill"
    var focusTarget: SettingsFocusTarget? = nil
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                if let description = description {
                    Text(LocalizedStringKey(description))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }
            }
            
            Spacer()
            
            if let previewAction {
                Button {
                    AnalyticsManager.shared.captureFeature(
                        feature: "settings",
                        subfeature: "preview",
                        action: "preview_clicked",
                        outcome: "started",
                        properties: ["control": title]
                    )
                    previewAction()
                } label: {
                    Image(systemName: previewIcon)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .accessibilityIdentifier("preview\(title.replacingOccurrences(of: " ", with: ""))Button")
                .accessibilityLabel("Preview \(title)")
            }
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 4)
        .settingsFocusableSetting(focusTarget)
        .onChange(of: isOn) { _, newValue in
            HapticFeedbackManager.shared.selection()
            AnalyticsManager.shared.captureSettingChanged(
                title,
                isEnabled: newValue
            )
        }
    }
}

extension View {
    func sortyFocusHighlight<FocusShape: InsettableShape>(
        isActive: Bool,
        shape: FocusShape,
        horizontalRingPadding: CGFloat = 0,
        verticalRingPadding: CGFloat = 0
    ) -> some View {
        modifier(
            SortyFocusHighlightModifier(
                isActive: isActive,
                shape: shape,
                horizontalRingPadding: horizontalRingPadding,
                verticalRingPadding: verticalRingPadding
            )
        )
    }

    @ViewBuilder
    func applyIdentifier(_ id: String?) -> some View {
        if let id = id {
            self.accessibilityIdentifier(id)
        } else {
            self
        }
    }

    func settingsFocusTarget(_ target: SettingsFocusTarget?) -> some View {
        environment(\.settingsFocusTarget, target)
    }

    func settingsFocusDismissAction(
        _ action: @escaping @MainActor (SettingsFocusTarget) -> Void
    ) -> some View {
        environment(\.settingsFocusDismissAction, action)
    }

    func settingsFocusable(_ target: SettingsFocusTarget) -> some View {
        settingsFocusable(
            target,
            shape: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    func settingsFocusable<FocusShape: InsettableShape>(
        _ target: SettingsFocusTarget,
        shape: FocusShape,
        horizontalRingPadding: CGFloat = 0,
        verticalRingPadding: CGFloat = 0
    ) -> some View {
        modifier(
            SettingsFocusableModifier(
                target: target,
                shape: shape,
                horizontalRingPadding: horizontalRingPadding,
                verticalRingPadding: verticalRingPadding
            )
        )
    }

    @ViewBuilder
    func settingsFocusable(_ target: SettingsFocusTarget?) -> some View {
        if let target {
            settingsFocusable(target)
        } else {
            self
        }
    }

    func settingsFocusableSetting(_ target: SettingsFocusTarget) -> some View {
        settingsFocusable(
            target,
            shape: RoundedRectangle(cornerRadius: 10, style: .continuous),
            horizontalRingPadding: 8,
            verticalRingPadding: 6
        )
    }

    @ViewBuilder
    func settingsFocusableSetting(_ target: SettingsFocusTarget?) -> some View {
        if let target {
            settingsFocusableSetting(target)
        } else {
            self
        }
    }
}
