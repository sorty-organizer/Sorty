//
//  TrafficLightUpdateButton.swift
//  Sorty
//
//  Orange traffic-light style button in the title bar next to the traffic lights.
//  Release builds: appears only when a Sparkle update is available.
//  Debug builds: always visible as a "REBUILD" button that triggers `make now`.
//

import AppKit
import Combine
import SwiftUI

/// An orange traffic-light style control that appears in the title bar right
/// after the standard window buttons.
public struct TrafficLightUpdateButton: NSViewRepresentable {
    @SortyHotReload private var hotReload
    @ObservedObject var updateManager: SparkleUpdateManager

    public init(updateManager: SparkleUpdateManager) {
        self.updateManager = updateManager
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        DispatchQueue.main.async {
            guard let window = container.window else { return }
            context.coordinator.install(in: window, updateManager: updateManager)
        }
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        // makeNSView fires once before the container has a window; retry here
        // so a missed initial install still recovers once AppKit attaches it.
        if let window = nsView.window {
            context.coordinator.install(in: window, updateManager: updateManager)
        }
        context.coordinator.update(for: updateManager.updateState)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    // MARK: - Coordinator

    @MainActor
    public final class Coordinator: NSObject {
        private var buttonView: UpdateButtonNSView?
        private var accessoryController: NSTitlebarAccessoryViewController?
        private weak var installedWindow: NSWindow?

        func install(in window: NSWindow, updateManager: SparkleUpdateManager) {
            guard installedWindow !== window else { return }
            uninstall()
            installedWindow = window

            let button = UpdateButtonNSView(updateManager: updateManager)
            button.translatesAutoresizingMaskIntoConstraints = false

            let accessoryView = NSView()
            accessoryView.translatesAutoresizingMaskIntoConstraints = false
            accessoryView.addSubview(button)
            NSLayoutConstraint.activate([
                accessoryView.heightAnchor.constraint(equalToConstant: 28),
                button.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor, constant: 12),
                button.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
                button.centerYAnchor.constraint(equalTo: accessoryView.centerYAnchor),
            ])

            // A title-bar accessory participates in AppKit's layout. This keeps
            // the sidebar toggle to the right when the pill expands.
            let accessoryController = NSTitlebarAccessoryViewController()
            accessoryController.layoutAttribute = .left
            accessoryController.view = accessoryView
            window.addTitlebarAccessoryViewController(accessoryController)

            self.buttonView = button
            self.accessoryController = accessoryController
            update(for: updateManager.updateState)
        }

        func uninstall() {
            if let installedWindow,
               let accessoryController,
               let index = installedWindow.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessoryController }) {
                installedWindow.removeTitlebarAccessoryViewController(at: index)
            }
            buttonView = nil
            accessoryController = nil
            installedWindow = nil
        }

        func update(for state: SparkleUpdateManager.UpdateState) {
            guard let buttonView else { return }
            buttonView.update(for: state)
            #if DEBUG
            buttonView.isHidden = false
            #else
            switch state {
            case .available, .downloading, .readyToInstall, .installing:
                buttonView.isHidden = false
            default:
                buttonView.isHidden = true
            }
            #endif
        }
    }
}

// MARK: - AppKit Button View

final class UpdateButtonNSView: NSView {
    private weak var updateManager: SparkleUpdateManager?

    private let fillLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let arrowLayer = CAShapeLayer()
    private let spinnerLayer = CAShapeLayer()
    private let textLayer = CATextLayer()

    private let labelFont = NSFont.systemFont(ofSize: 8.4, weight: .bold)
    private let iconToTextSpacing: CGFloat = 5
    private let horizontalPadding: CGFloat = 7
    private let arrowOpticalOffsetY: CGFloat = -0.2
    private var widthConstraint: NSLayoutConstraint?
    private var isHovered = false
    private var isPressed = false
    private var isWindowFocused = false
    private var isBusy = false
    private var updateState: SparkleUpdateManager.UpdateState = .idle
    private var trackingArea: NSTrackingArea?
    private var windowFocusObservations: [NSObjectProtocol] = []
    private var stateCancellable: AnyCancellable?

    private let buttonDiameter: CGFloat = 14
    private let collapsedPillWidth: CGFloat = 14

    // Single update accent (orange family). All states are derived from this hue
    // so the inner glyph and the surrounding ring read as the same color, just at
    // different opacities/lightness.
    private static let updateAccent = NSColor(red: 0.92, green: 0.55, blue: 0.20, alpha: 1.0)

    private let normalFillColor = NSColor.clear
    private let hoverFillColor  = UpdateButtonNSView.updateAccent
    private let pressedFillColor = UpdateButtonNSView.updateAccent.blended(withFraction: 0.18, of: .black) ?? UpdateButtonNSView.updateAccent

    private let normalBorderColor = UpdateButtonNSView.updateAccent
    private let hoverBorderColor  = UpdateButtonNSView.updateAccent.blended(withFraction: 0.10, of: .black) ?? UpdateButtonNSView.updateAccent
    private let pressedBorderColor = UpdateButtonNSView.updateAccent.blended(withFraction: 0.25, of: .black) ?? UpdateButtonNSView.updateAccent

    private let normalArrowColor = UpdateButtonNSView.updateAccent
    private let hoverArrowColor = NSColor.white

    private let normalHighlightColor = NSColor.clear
    private let hoverHighlightColor  = NSColor(calibratedWhite: 1.0, alpha: 0.38)
    private let pressedHighlightColor = NSColor(calibratedWhite: 1.0, alpha: 0.18)

    #if DEBUG
    private let idleLabelText = "REBUILD"
    private let busyLabelText = "BUILDING"
    #else
    private let idleLabelText = "UPDATE"
    private let busyLabelText = "DOWNLOADING"
    #endif

    private var labelText: String {
        #if DEBUG
        isBusy ? busyLabelText : idleLabelText
        #else
        switch updateState {
        case .downloading(let progress):
            if let progress {
                return "\(Int((progress * 100).rounded()))%"
            }
            return busyLabelText
        case .readyToInstall:
            return "INSTALL"
        case .installing:
            return "INSTALLING"
        default:
            return idleLabelText
        }
        #endif
    }

    private var expandedPillWidth: CGFloat {
        let measuredTextWidth = (labelText as NSString).size(withAttributes: [.font: labelFont]).width
        let iconWidth: CGFloat = 7
        return ceil(horizontalPadding + iconWidth + iconToTextSpacing + measuredTextWidth + horizontalPadding)
    }

    init(updateManager: SparkleUpdateManager) {
        self.updateManager = updateManager
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setupLayers()
        setupStateObservation()

        let widthConstraint = widthAnchor.constraint(equalToConstant: collapsedPillWidth)
        self.widthConstraint = widthConstraint

        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: buttonDiameter),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        removeWindowFocusObservation()
    }

    // MARK: Setup

    private func setupLayers() {
        fillLayer.backgroundColor = normalFillColor.cgColor
        layer?.addSublayer(fillLayer)

        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        borderLayer.strokeColor = normalBorderColor.cgColor
        layer?.addSublayer(borderLayer)

        highlightLayer.fillColor = nil
        highlightLayer.lineWidth = 1
        highlightLayer.strokeColor = normalHighlightColor.cgColor
        layer?.addSublayer(highlightLayer)

        // Down-arrow icon
        let arrowPath = CGMutablePath()
        arrowPath.move(to: CGPoint(x: 0, y: 2.3))
        arrowPath.addLine(to: CGPoint(x: 0, y: -2.3))
        arrowPath.move(to: CGPoint(x: -1.9, y: -0.3))
        arrowPath.addLine(to: CGPoint(x: 0, y: -2.3))
        arrowPath.addLine(to: CGPoint(x: 1.9, y: -0.3))

        arrowLayer.path = arrowPath
        arrowLayer.strokeColor = normalArrowColor.cgColor
        arrowLayer.fillColor = nil
        arrowLayer.lineWidth = 1.5
        arrowLayer.lineCap = .round
        arrowLayer.lineJoin = .round
        layer?.addSublayer(arrowLayer)

        spinnerLayer.fillColor = nil
        spinnerLayer.lineWidth = 1.45
        spinnerLayer.lineCap = .round
        spinnerLayer.strokeColor = NSColor.white.cgColor
        spinnerLayer.isHidden = true
        layer?.addSublayer(spinnerLayer)

        // Label text — always visible
        textLayer.string = labelText
        textLayer.font = labelFont
        textLayer.fontSize = labelFont.pointSize
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.alignmentMode = .left
        textLayer.isWrapped = false
        textLayer.opacity = 1
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(textLayer)

        applyVisualState(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setAccessibilityIdentifier("trafficLight.updateButton")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibilityDescription()
        observeWindowFocusIfNeeded()
    }

    private func observeWindowFocusIfNeeded() {
        removeWindowFocusObservation()

        guard let window else {
            isWindowFocused = false
            applyVisualState(animated: false)
            return
        }

        let nc = NotificationCenter.default

        windowFocusObservations.append(
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.refreshWindowFocus(animated: true)
            }
        )

        windowFocusObservations.append(
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.refreshWindowFocus(animated: true)
            }
        )

        windowFocusObservations.append(
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refreshWindowFocus(animated: true)
            }
        )

        windowFocusObservations.append(
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refreshWindowFocus(animated: true)
            }
        )

        refreshWindowFocus(animated: false)
    }

    private func removeWindowFocusObservation() {
        for observation in windowFocusObservations {
            NotificationCenter.default.removeObserver(observation)
        }
        windowFocusObservations.removeAll()
    }

    private func refreshWindowFocus(animated: Bool) {
        let focused = (window?.isKeyWindow ?? false) && NSApp.isActive
        guard focused != isWindowFocused else { return }
        isWindowFocused = focused
        if !NSApp.isActive {
            isHovered = false
        }
        applyVisualState(animated: animated)
    }

    private func setupStateObservation() {
        #if DEBUG
        setBusyState(DevRebuilder.shared.isRebuilding, animated: false)
        stateCancellable = DevRebuilder.shared.$isRebuilding
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] rebuilding in
                self?.setBusyState(rebuilding, animated: true)
            }
        #else
        update(for: updateManager?.updateState ?? .idle)
        stateCancellable = updateManager?.$updateState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.update(for: state)
            }
        #endif
    }

    func update(for state: SparkleUpdateManager.UpdateState) {
        #if !DEBUG
        guard updateState != state else { return }
        updateState = state
        setBusyState(state.isBusyPhase, animated: true)
        textLayer.string = labelText
        toolTip = state.isBusyPhase ? "Downloading update…" : nil
        setExpanded(isBusy || isHovered, animated: true)
        updateAccessibilityDescription()
        needsLayout = true
        #endif
    }

    private func setBusyState(_ busy: Bool, animated: Bool) {
        guard isBusy != busy else { return }
        isBusy = busy

        textLayer.string = labelText
        if busy {
            startBusyAnimation()
            setExpanded(true, animated: animated)
        } else {
            stopBusyAnimation()
            setExpanded(isHovered, animated: animated)
        }

        applyVisualState(animated: animated)
        needsLayout = true
    }

    private func startBusyAnimation() {
        arrowLayer.isHidden = true
        spinnerLayer.isHidden = false

        if spinnerLayer.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = CGFloat.pi * 2
            spin.duration = 0.85
            spin.repeatCount = .infinity
            spin.timingFunction = CAMediaTimingFunction(name: .linear)
            spinnerLayer.add(spin, forKey: "spin")
        }

        if fillLayer.animation(forKey: "pulse") == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.87
            pulse.toValue = 1.0
            pulse.duration = 0.42
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fillLayer.add(pulse, forKey: "pulse")
        }
    }

    private func stopBusyAnimation() {
        fillLayer.removeAnimation(forKey: "pulse")
        spinnerLayer.removeAnimation(forKey: "spin")
        spinnerLayer.isHidden = true
        arrowLayer.isHidden = false
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        fillLayer.contentsScale = scale
        borderLayer.contentsScale = scale
        highlightLayer.contentsScale = scale
        arrowLayer.contentsScale = scale
        spinnerLayer.contentsScale = scale
        textLayer.contentsScale = scale

        fillLayer.frame = bounds
        fillLayer.cornerRadius = bounds.height / 2

        borderLayer.frame = bounds
        let borderRect = borderLayer.bounds.insetBy(dx: 0.5, dy: 0.5)
        borderLayer.path = CGPath(
            roundedRect: borderRect,
            cornerWidth: borderRect.height / 2,
            cornerHeight: borderRect.height / 2,
            transform: nil
        )

        highlightLayer.frame = bounds
        let highlightRect = highlightLayer.bounds.insetBy(dx: 1.25, dy: 1.25)
        highlightLayer.path = CGPath(
            roundedRect: highlightRect,
            cornerWidth: highlightRect.height / 2,
            cornerHeight: highlightRect.height / 2,
            transform: nil
        )

        let arrowBounds = arrowLayer.path?.boundingBoxOfPath ?? CGRect(x: 0, y: -2.3, width: 3.8, height: 4.6)
        let spinnerPath = CGMutablePath()
        spinnerPath.addArc(center: .zero, radius: 2.8, startAngle: 0.15, endAngle: .pi * 1.65, clockwise: false)
        spinnerLayer.path = spinnerPath
        let spinnerBounds = spinnerPath.boundingBox

        let iconWidth = ceil(max(arrowBounds.width + arrowLayer.lineWidth, spinnerBounds.width + spinnerLayer.lineWidth))
        let iconAreaWidth = min(buttonDiameter, bounds.width)
        let iconCenterX = pixelAligned(bounds.minX + iconAreaWidth / 2, scale: scale)
        let iconCenterY = pixelAligned(bounds.midY + arrowOpticalOffsetY, scale: scale)

        // Use a symmetric local bounds origin so `position` maps to path origin (0, 0).
        arrowLayer.bounds = CGRect(x: -0.5, y: -0.5, width: 1, height: 1)
        arrowLayer.position = CGPoint(x: iconCenterX, y: iconCenterY)
        spinnerLayer.bounds = CGRect(x: -0.5, y: -0.5, width: 1, height: 1)
        spinnerLayer.position = CGPoint(x: iconCenterX, y: iconCenterY)

        let measuredText = (labelText as NSString).size(withAttributes: [.font: labelFont])
        let textWidth = ceil(measuredText.width)
        let textHeight = ceil(labelFont.ascender - labelFont.descender)
        let textX = pixelAligned(iconCenterX + iconWidth / 2 + iconToTextSpacing, scale: scale)
        let textY = pixelAligned((bounds.height - textHeight) / 2, scale: scale)
        textLayer.frame = CGRect(x: textX, y: textY, width: textWidth, height: textHeight)

        CATransaction.commit()
    }

    private func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return round(value * scale) / scale
    }

    private func setExpanded(_ expanded: Bool, animated: Bool) {
        let targetWidth = expanded ? expandedPillWidth : collapsedPillWidth
        guard widthConstraint?.constant != targetWidth else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = expanded ? 0.25 : 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1.0, 0.32, 1.0) // ease-out curve
                widthConstraint?.animator().constant = targetWidth
                superview?.layoutSubtreeIfNeeded()
            }
        } else {
            widthConstraint?.constant = targetWidth
            superview?.layoutSubtreeIfNeeded()
        }

        needsLayout = true
    }

    private func applyVisualState(animated: Bool) {
        let fillColor: NSColor
        let borderColor: NSColor
        let highlightColor: NSColor
        let arrowColor: NSColor
        let spinnerColor: NSColor
        // Keep the expanded label readable while the title-bar focus state
        // transitions. The pill's orange fill can outlive that state briefly.
        let textColor = NSColor(calibratedWhite: 1.0, alpha: 1.0)

        if isBusy {
            fillColor = hoverFillColor
            borderColor = hoverBorderColor
            highlightColor = hoverHighlightColor
            arrowColor = hoverArrowColor
            spinnerColor = hoverArrowColor
        } else if isPressed {
            fillColor = pressedFillColor
            borderColor = pressedBorderColor
            highlightColor = pressedHighlightColor
            arrowColor = hoverArrowColor
            spinnerColor = hoverArrowColor
        } else if isHovered && NSApp.isActive {
            fillColor = hoverFillColor
            borderColor = hoverBorderColor
            highlightColor = hoverHighlightColor
            arrowColor = hoverArrowColor
            spinnerColor = hoverArrowColor
        } else if isWindowFocused {
            fillColor = hoverFillColor
            borderColor = hoverBorderColor
            highlightColor = normalHighlightColor
            arrowColor = hoverArrowColor
            spinnerColor = hoverArrowColor
        } else {
            fillColor = normalFillColor
            borderColor = normalBorderColor
            highlightColor = normalHighlightColor
            arrowColor = normalArrowColor
            spinnerColor = normalArrowColor
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.12 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        fillLayer.backgroundColor = fillColor.cgColor
        borderLayer.strokeColor = borderColor.cgColor
        highlightLayer.strokeColor = highlightColor.cgColor
        arrowLayer.strokeColor = arrowColor.cgColor
        spinnerLayer.strokeColor = spinnerColor.cgColor
        textLayer.foregroundColor = textColor.cgColor
        CATransaction.commit()
    }

    private func triggerPrimaryAction() {
        HapticFeedbackManager.shared.alignment()
        Task { @MainActor in
            #if DEBUG
            guard !isBusy else {
                HapticFeedbackManager.shared.selection()
                return
            }
            DevRebuilder.shared.rebuild()
            #else
            switch updateState {
            case .available:
                updateManager?.installAvailableUpdate()
            case .downloading, .readyToInstall, .installing:
                updateManager?.showUpdateInFocus()
            default:
                updateManager?.checkForUpdates()
            }
            #endif
        }
    }

    // MARK: Click Handling

    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        guard !isBusy else {
            HapticFeedbackManager.shared.selection()
            return
        }
        #endif

        isPressed = true
        applyVisualState(animated: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.isPressed = false
            self.applyVisualState(animated: true)
        }

        triggerPrimaryAction()
    }

    // MARK: Tracking & Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        setExpanded(true, animated: true)
        applyVisualState(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        if isPressed || isBusy { return }
        isHovered = false
        setExpanded(false, animated: true)
        applyVisualState(animated: true)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func accessibilityPerformPress() -> Bool {
        triggerPrimaryAction()
        return true
    }

    private func updateAccessibilityDescription() {
        #if DEBUG
        setAccessibilityLabel(isBusy ? "Sorty is rebuilding" : "Rebuild Sorty")
        #else
        switch updateState {
        case .available(let version, _):
            setAccessibilityLabel("Download Sorty \(version)")
        case .downloading(let progress):
            if let progress {
                let percent = Int((progress * 100).rounded())
                setAccessibilityLabel("Sorty update is downloading, \(percent) percent")
            } else {
                setAccessibilityLabel("Sorty update is downloading")
            }
        case .readyToInstall:
            setAccessibilityLabel("Sorty update is ready to install and relaunch")
        case .installing:
            setAccessibilityLabel("Sorty update is installing")
        default:
            setAccessibilityLabel("Update Sorty")
        }
        #endif
    }
}

// MARK: - View Extension

extension View {
    /// Adds an orange update button to the traffic light bar when an update is available.
    public func trafficLightUpdateButton(updateManager: SparkleUpdateManager) -> some View {
        background(
            TrafficLightUpdateButton(updateManager: updateManager)
                .frame(width: 0, height: 0)
        )
    }
}
