import Foundation
import AppKit
import SwiftUI

/// Matches the native capsule selector used by History filters.
struct ProviderAuthenticationControl: NSViewRepresentable {
    let methods: [ProviderAuthMethod]
    @Binding var selection: ProviderAuthMethod

    func makeCoordinator() -> Coordinator {
        Coordinator(methods: methods, selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: methods.map(\.displayName),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.font = .systemFont(ofSize: 11, weight: .medium)
        control.setAccessibilityLabel("Authentication")
        control.setAccessibilityIdentifier("ProviderAuthenticationPicker")
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
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.methods = methods
        context.coordinator.selection = $selection
        control.segmentCount = methods.count
        for (index, method) in methods.enumerated() {
            control.setLabel(method.displayName, forSegment: index)
        }
        control.selectedSegment = methods.firstIndex(of: selection) ?? -1
    }

    @MainActor
    final class Coordinator: NSObject {
        var methods: [ProviderAuthMethod]
        var selection: Binding<ProviderAuthMethod>

        init(methods: [ProviderAuthMethod], selection: Binding<ProviderAuthMethod>) {
            self.methods = methods
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard methods.indices.contains(sender.selectedSegment) else { return }
            let method = methods[sender.selectedSegment]
            guard selection.wrappedValue != method else { return }
            selection.wrappedValue = method
            HapticFeedbackManager.shared.selection()
        }
    }
}
