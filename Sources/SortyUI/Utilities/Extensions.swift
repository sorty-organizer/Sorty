//
//  Extensions.swift
//  Sorty
//
//  Utility extensions
//

import Foundation
import SwiftUI

private struct MinimumHitTargetModifier: ViewModifier {
    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(minWidth: size, minHeight: size)
            .contentShape(Rectangle())
    }
}

private struct NumericTextTransitionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let animationValue: Value
    let animation: Animation

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .transaction(value: animationValue) { transaction in
                transaction.disablesAnimations = false
                transaction.animation = reduceMotion
                    ? .sortyQuick
                    : animation
            }
    }
}

private struct SymbolReplaceTransitionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let animationValue: Value
    let animation: Animation

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            .transaction(value: animationValue) { transaction in
                transaction.disablesAnimations = false
                transaction.animation = reduceMotion
                    ? .sortyQuick
                    : animation
            }
    }
}

extension KeyEquivalent {
    package static let cancelAction = KeyEquivalent("\u{1b}") // Escape
    package static let defaultAction = KeyEquivalent("\r") // Return
}

extension View {
    package func minimumHitTarget(_ size: CGFloat = 40) -> some View {
        modifier(MinimumHitTargetModifier(size: size))
    }

    package func numericTextTransition<Value: Equatable>(
        animationValue: Value,
        animation: Animation = .sortySnappy
    ) -> some View {
        modifier(
            NumericTextTransitionModifier(
                animationValue: animationValue,
                animation: animation
            )
        )
    }

    package func symbolReplaceTransition<Value: Equatable>(
        animationValue: Value,
        animation: Animation = .sortySnappy
    ) -> some View {
        modifier(
            SymbolReplaceTransitionModifier(
                animationValue: animationValue,
                animation: animation
            )
        )
    }
}
