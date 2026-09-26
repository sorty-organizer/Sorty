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
                    ? .easeOut(duration: 0.12)
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
                    ? .easeOut(duration: 0.12)
                    : animation
            }
    }
}

extension KeyEquivalent {
    static let cancelAction = KeyEquivalent("\u{1b}") // Escape
    static let defaultAction = KeyEquivalent("\r") // Return
}

extension View {
    func minimumHitTarget(_ size: CGFloat = 40) -> some View {
        modifier(MinimumHitTargetModifier(size: size))
    }

    func numericTextTransition<Value: Equatable>(
        animationValue: Value,
        animation: Animation = .spring(response: 0.28, dampingFraction: 0.78)
    ) -> some View {
        modifier(
            NumericTextTransitionModifier(
                animationValue: animationValue,
                animation: animation
            )
        )
    }

    func symbolReplaceTransition<Value: Equatable>(
        animationValue: Value,
        animation: Animation = .spring(response: 0.28, dampingFraction: 0.78)
    ) -> some View {
        modifier(
            SymbolReplaceTransitionModifier(
                animationValue: animationValue,
                animation: animation
            )
        )
    }
}
