import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI

/// Uses intrinsic layout for short lists and a bounded viewport for overflow.
struct SkillImportChecklist<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var hasMoreBelow = false

    var body: some View {
        ViewThatFits(in: .vertical) {
            content()
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                ScrollView {
                    content()
                }
                .scrollIndicators(.visible)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.containerSize.height > 0
                        && geometry.contentSize.height + geometry.contentInsets.bottom
                            > geometry.contentOffset.y + geometry.containerSize.height + 1
                } action: { _, hasMore in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        hasMoreBelow = hasMore
                    }
                }
                // Keep the viewport height stable as the hint appears and disappears.
                Label("Scroll for more", systemImage: "chevron.down")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .opacity(hasMoreBelow ? 1 : 0)
                    .accessibilityHidden(!hasMoreBelow)
                    .accessibilityIdentifier("skill-import.scroll-hint")
            }
        }
    }
}

struct SkillIntroductionReveal: ViewModifier {
    let isVisible: Bool
    let reduceMotion: Bool
    let duration: Double

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: duration), value: isVisible)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

/// Retains the app image while the compositor animates its Gaussian blur.
/// The surrounding SwiftUI view still owns the original slide and fade.
struct SkillIntroductionAppIcon: NSViewRepresentable {
    let isBlurred: Bool
    let animatesBlur: Bool

    func makeNSView(context: Context) -> SkillIntroductionAppIconView {
        SkillIntroductionAppIconView()
    }

    func updateNSView(_ nsView: SkillIntroductionAppIconView, context: Context) {
        nsView.update(isBlurred: isBlurred, animated: animatesBlur)
    }
}

@MainActor
final class SkillIntroductionAppIconView: NSView {
    private let imageLayer = CALayer()
    private let blurContainer = CALayer()
    private let blurFilter = CIFilter.gaussianBlur()
    private var lastIsBlurred: Bool?
    private var lastAnimatesBlur: Bool?
    private var lastLayoutBounds: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
        blurFilter.name = "skillIntroductionBlur"
        blurFilter.radius = 0
        blurContainer.filters = [blurFilter]
        imageLayer.contentsGravity = .resizeAspect
        var proposedRect = CGRect(x: 0, y: 0, width: 160, height: 160)
        imageLayer.contents = NSApp.applicationIconImage.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        )
        blurContainer.addSublayer(imageLayer)
        layer?.addSublayer(blurContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard lastLayoutBounds != bounds else { return }
        lastLayoutBounds = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Three Gaussian radii retain the same soft edge outside the icon.
        let outset: CGFloat = 12
        blurContainer.frame = bounds.insetBy(dx: -outset, dy: -outset)
        imageLayer.frame = CGRect(origin: CGPoint(x: outset, y: outset), size: bounds.size)
        CATransaction.commit()
    }

    func update(isBlurred: Bool, animated: Bool) {
        guard lastIsBlurred != isBlurred || lastAnimatesBlur != animated else { return }
        let hadPreviousState = lastIsBlurred != nil
        lastIsBlurred = isBlurred
        lastAnimatesBlur = animated
        let radius: Float = isBlurred ? 4 : 0
        let keyPath = "filters.skillIntroductionBlur.inputRadius"
        let currentRadius = blurContainer.presentation()?.value(forKeyPath: keyPath)
            ?? blurContainer.value(forKeyPath: keyPath)
        blurContainer.removeAnimation(forKey: "skillIntroductionBlur")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // CALayer copies its filters; persist the endpoint on the layer's copy.
        blurContainer.setValue(radius, forKeyPath: keyPath)
        CATransaction.commit()
        if animated && hadPreviousState {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = currentRadius
            animation.toValue = radius
            animation.duration = 0.45
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            blurContainer.add(animation, forKey: "skillIntroductionBlur")
        }
    }
}
