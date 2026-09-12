//
//  CometLoader.swift
//  Sorty
//
//  A reusable comet-trail loading indicator.
//

import SwiftUI

struct CometLoader<S: Shape>: View {
    @SortyHotReload private var hotReload
    var shape: S
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2
    var color: Color = SortyDesignSystem.Colors.resolvedAccent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isWindowVisible = true
    @State private var pausedAt: Date?
    @State private var hiddenDuration: TimeInterval = 0

    init(
        shape: S,
        size: CGFloat = 18,
        lineWidth: CGFloat = 2,
        color: Color = SortyDesignSystem.Colors.resolvedAccent
    ) {
        self.shape = shape
        self.size = size
        self.lineWidth = lineWidth
        self.color = color
    }

    var body: some View {
        SwiftUI.TimelineView(.animation(paused: reduceMotion || !isWindowVisible)) { timeline in
            Canvas { context, canvasSize in
                let rect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: lineWidth, dy: lineWidth)
                let path = shape.path(in: rect)

                context.stroke(
                    path,
                    with: .color(color.opacity(0.16)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )

                let time = (pausedAt ?? timeline.date).timeIntervalSinceReferenceDate - hiddenDuration
                let phase = reduceMotion ? 0.18 : time.truncatingRemainder(dividingBy: 1.2) / 1.2
                let head = CGFloat(phase)
                let tail = max(0, head - 0.28)
                let cometPath = path.trimmedPath(from: tail, to: head)

                context.stroke(
                    cometPath,
                    with: .linearGradient(
                        Gradient(colors: [
                            color.opacity(0.05),
                            color.opacity(0.55),
                            color
                        ]),
                        startPoint: CGPoint(x: rect.minX, y: rect.midY),
                        endPoint: CGPoint(x: rect.maxX, y: rect.midY)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .frame(width: size, height: size)
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .onChange(of: isWindowVisible) { _, visible in
            // Keep the comet in phase across occlusion. Losing keyboard focus
            // alone must not pause a window that remains visible.
            if visible {
                if let pausedAt {
                    hiddenDuration += Date().timeIntervalSince(pausedAt)
                    self.pausedAt = nil
                }
            } else if pausedAt == nil {
                pausedAt = Date()
            }
        }
        .accessibilityHidden(true)
    }
}

extension CometLoader where S == Circle {
    init(size: CGFloat = 18, lineWidth: CGFloat = 2, color: Color = SortyDesignSystem.Colors.resolvedAccent) {
        self.init(shape: Circle(), size: size, lineWidth: lineWidth, color: color)
    }
}
