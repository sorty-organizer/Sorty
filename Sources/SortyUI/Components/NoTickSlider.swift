//
//  NoTickSlider.swift
//  Sorty
//
//  Slider wrapper that suppresses the macOS native tick mark dots.
//

import SwiftUI

package struct NoTickSlider: View {
    @SortyHotReload private var hotReload
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?

    package init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil) {
        self._value = value
        self.range = range
        self.step = step
    }

    package var body: some View {
        Slider(value: steppedValue, in: range)
        .labelsHidden()
    }

    private var steppedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                value = snappedValue(for: newValue)
            }
        )
    }

    private func snappedValue(for newValue: Double) -> Double {
        guard let step, step > 0 else {
            return newValue
        }

        let snapped = (newValue / step).rounded() * step
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}
