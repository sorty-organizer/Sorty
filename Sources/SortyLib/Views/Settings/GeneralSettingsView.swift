//
//  GeneralSettingsView.swift
//  Sorty
//
//  App-wide startup, Dock, and menu bar behavior
//

import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @SortyHotReload private var hotReload
    @EnvironmentObject var loginItemManager: LoginItemManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hideDockIcon") private var hideDockIcon = false
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage(MenuBarIconPreferences.preferenceKey, store: MenuBarIconPreferences.defaults)
    private var usesAppleNativeIconStyle = false

    /// Reflects the real SMAppService registration (not just the stored
    /// preference) and routes toggles back through the manager.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginItemManager.isLaunchAtLoginEnabled },
            set: { newValue in
                loginItemManager.setLaunchAtLogin(newValue)
                AnalyticsManager.shared.captureSettingChanged(
                    "Launch at Login",
                    isEnabled: newValue,
                    section: "general"
                )
            }
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Startup", icon: "power", color: .green) {
                VStack(spacing: 12) {
                    SettingsToggle(
                        isOn: launchAtLoginBinding,
                        title: "Launch at Login",
                        description: "Automatically start Sorty when you log in to macOS",
                        focusTarget: .generalLaunchAtLogin
                    )

                    Divider()

                    SettingsToggle(
                        isOn: $hideDockIcon,
                        title: "Hide Dock Icon",
                        description: "Run as a menu bar app without showing in the Dock",
                        focusTarget: .generalHideDockIcon
                    )
                    .onChange(of: hideDockIcon) { _, newValue in
                        // The main-window onChange is window-scoped; apply the
                        // policy here so the toggle works with zero windows.
                        NSApp.setActivationPolicy(newValue ? .accessory : .regular)
                        AnalyticsManager.shared.captureSettingChanged(
                            "Hide Dock Icon",
                            isEnabled: newValue,
                            section: "general"
                        )
                    }
                }
            }

            SettingsCard(title: "Menu Bar", icon: "menubar.rectangle", color: .blue) {
                VStack(spacing: 12) {
                    SettingsToggle(
                        isOn: $showMenuBarExtra,
                        title: "Show Menu Bar Icon",
                        description: "Display Sorty icon in the menu bar for quick access",
                        focusTarget: .generalMenuBar
                    )

                    if showMenuBarExtra {
                        SettingsSubsettingRow(
                            title: "Icon Style",
                            description: "Use Sorty's colorful style or a white style with native Finder symbols."
                        ) {
                            MenuBarIconStyleControl(selection: $usesAppleNativeIconStyle)
                                .frame(width: 250)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .animation(
                    reduceMotion
                        ? .easeInOut(duration: 0.14)
                        : .spring(response: 0.34, dampingFraction: 0.78),
                    value: showMenuBarExtra
                )
            }
            .settingsFocusable(.generalMenuBarIconStyle)
        }
        .onChange(of: usesAppleNativeIconStyle) { _, newValue in
            MenuBarIconPreferences.notifyFinderStyleChanged(usesAppleNativeStyle: newValue)
            HapticFeedbackManager.shared.selection()
            AnalyticsManager.shared.captureSettingChanged(
                "Menu Bar Icon Style",
                isEnabled: newValue,
                section: "general"
            )
            Task {
                await ExtensionCommunication.refreshInstalledQuickActionIconsAsync()
            }
        }
    }
}

/// Uses the native capsule selector treatment shared with the History filters.
private struct MenuBarIconStyleControl: NSViewRepresentable {
    @Binding var selection: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: ["Sorty", "Apple Native"],
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.font = .systemFont(ofSize: 11, weight: .medium)
        control.setAccessibilityLabel("Menu Bar Icon Style")
        control.setAccessibilityIdentifier("MenuBarIconStylePicker")
        if #available(macOS 26.0, *) {
            control.controlSize = .extraLarge
            control.borderShape = .capsule
        } else {
            control.controlSize = .large
        }
        // Adopt the public tabs role when the project moves to the macOS 27 SDK.
        if control.responds(to: NSSelectorFromString("setRole:")) {
            control.setValue(1, forKey: "role")
        }
        control.segmentDistribution = .fillEqually
        for segment in 0..<2 {
            let source = SortyResources.image(
                named: MenuBarActivity.idle.iconResourceName(usesAppleNativeStyle: segment == 1),
                withExtension: "png"
            )
            if let source {
                // Draw the full-resolution artwork at the destination's backing scale.
                let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                    NSGraphicsContext.current?.imageInterpolation = .high
                    source.draw(
                        in: rect,
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1
                    )
                    return true
                }
                image.isTemplate = false
                control.setImage(image, forSegment: segment)
                control.setImageScaling(.scaleProportionallyDown, forSegment: segment)
            }
        }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = selection ? 1 : 0
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Bool>

        init(selection: Binding<Bool>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard sender.selectedSegment == 0 || sender.selectedSegment == 1 else { return }
            let newSelection = sender.selectedSegment == 1
            guard selection.wrappedValue != newSelection else { return }
            selection.wrappedValue = newSelection
            HapticFeedbackManager.shared.selection()
        }
    }
}

#if DEBUG
#Preview {
    GeneralSettingsView()
        .environmentObject(LoginItemManager.shared)
        .frame(width: 500, height: 400)
        .padding(24)
}
#endif
