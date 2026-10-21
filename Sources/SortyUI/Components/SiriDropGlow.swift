//
//  SiriDropGlow.swift
//  Sorty
//
//  Shared drop-zone modifier.
//

import SwiftUI

// MARK: - Drop Zone Modifier

/// A view modifier that wraps any view with drag-and-drop support.
struct SiriDropZoneModifier: ViewModifier {
    let acceptedTypes: [String]
    let isEnabled: Bool
    let onDrop: ([NSItemProvider]) -> Bool
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onDrop(of: acceptedTypes, isTargeted: $isTargeted) { providers in
                    onDrop(providers)
                }
        } else {
            content
        }
    }
}

extension View {
    /// Adds shared drop zone behavior.
    /// - Parameters:
    ///   - acceptedTypes: UTI type identifiers to accept.
    ///   - isEnabled: Whether drag/drop should be active.
    ///   - isTargeted: Binding that tracks whether a drag is hovering.
    ///   - onDrop: Closure called when items are dropped.
    package func siriDropZone(
        acceptedTypes: [String] = ["public.file-url"],
        isEnabled: Bool = true,
        isTargeted: Binding<Bool>,
        onDrop: @escaping ([NSItemProvider]) -> Bool
    ) -> some View {
        modifier(SiriDropZoneModifier(
            acceptedTypes: acceptedTypes,
            isEnabled: isEnabled,
            onDrop: onDrop,
            isTargeted: isTargeted
        ))
    }
}
