//
//  OrganizingFlightStageView.swift
//  Sorty
//
//  Files flying into folders animation. This view is purely presentational:
//  it never gates the AI response, preview creation, or transition to ready.
//
//  Note: there is no public API to reuse Finder's exact drop-into-folder
//  animation in an arbitrary view. The legacy `kOpenFolderIcon` resource
//  only ships at 32x32 and looks pixelated at our sizes, so we render the
//  real high-resolution folder icon and use the same kind of subtle scale
//  bump + halo that Finder itself shows on a successful drop.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OrganizingFlightStageView: View {
    @SortyHotReload private var hotReload
    let suggestions: [FolderSuggestion]
    var prioritizesFilenames = false

    var stageWidth: CGFloat = 430
    var stageHeight: CGFloat = 170
    var maxBuckets: Int = 5

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var flightProgress: CGFloat = 0
    @State private var flightDestination: CGSize = .zero
    @State private var tuckOffset: CGSize = .zero
    @State private var cardRotation: Double = 0
    @State private var cardLift: CGFloat = 0
    @State private var cardScale: CGFloat = 0.85
    @State private var cardOpacity: Double = 0
    @State private var bumpedFolderName: String?
    @State private var haloFolderName: String?
    @State private var flightTargetFolderName: String?
    @State private var bumpTrigger: Int = 0
    @State private var currentFileIcon: NSImage = AnalysisIconProvider.icon(for: .data)
    @State private var currentFileName = ""
    @State private var currentRenamedFileName: String?
    @State private var renameStrikeProgress: CGFloat = 0
    @State private var renameProgress: CGFloat = 0
    @State private var currentCardWidth: CGFloat = 188
    @State private var displayedSuggestions: [FolderSuggestion] = []
    @State private var flightTask: Task<Void, Never>?
    @State private var shownFlightFileIDs: Set<UUID> = []
    @State private var flightQueue: [FlightCandidate] = []
    @State private var nextFlightIndex = 0
    /// Throttles mid-flight retargets during streaming bursts: the row reflow
    /// already animates, so re-aiming faster than 10Hz only repaints.
    @State private var lastRetargetAt = Date.distantPast

    private let cardSize = CGSize(width: 24, height: 24)
    private let bucketSize = CGSize(width: 56, height: 56)

    private var visibleSuggestions: [FolderSuggestion] {
        let source = displayedSuggestions.isEmpty ? suggestions : displayedSuggestions
        return Array(source.prefix(maxBuckets))
    }

    private var bucketCount: Int { visibleSuggestions.count }

    var body: some View {
        Group {
            if visibleSuggestions.isEmpty {
                EmptyView()
            } else {
                ZStack {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        HStack(spacing: 0) {
                            // Identity by stable suggestion id, never the
                            // streaming folder name: names update mid-stream,
                            // and name identity would recreate buckets (and
                            // their animations) on every rename.
                            ForEach(Array(visibleSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                                destinationView(suggestion: suggestion, index: index)
                                    .frame(maxWidth: .infinity)
                                    // Opacity/scale only: blur in transitions
                                    // forces a fullscreen blur pass per bucket.
                                    .transition(.asymmetric(
                                        insertion: .modifier(
                                            active: FolderRevealModifier(opacity: 0, scale: 0.4, yOffset: 14),
                                            identity: FolderRevealModifier()
                                        ),
                                        removal: .modifier(
                                            active: FolderRevealModifier(opacity: 0, scale: 0.85, yOffset: 0),
                                            identity: FolderRevealModifier()
                                        )
                                    ))
                            }
                        }
                        .padding(.bottom, 6)
                        .animation(
                            systemReduceMotion
                                ? .easeInOut(duration: 0.18)
                                : .spring(response: 0.42, dampingFraction: 0.72),
                            value: visibleSuggestions.map(\.id)
                        )
                    }

                    fileCard
                        .modifier(FolderDropFlightEffect(
                            progress: flightProgress,
                            destination: flightDestination
                        ))
                        .offset(tuckOffset)
                        .rotationEffect(.degrees(cardRotation))
                        .scaleEffect(cardScale)
                        .opacity(cardOpacity)
                        .shadow(
                            color: Color.black.opacity(0.10 * Double(cardLift)),
                            radius: 8 * cardLift,
                            x: 0,
                            y: 5 * cardLift
                        )
                        .allowsHitTesting(false)
                }
                .frame(width: stageWidth, height: stageHeight)
                .accessibilityHidden(true)
                .onAppear {
                    mergeDisplayedSuggestions(animated: false)
                    startCycleIfNeeded()
                }
                .onDisappear { stopCycle() }
                .onChange(of: suggestions) { _, _ in
                    mergeDisplayedSuggestions(animated: true)
                }
                .onChange(of: visibleSuggestions.map(\.id)) { _, _ in
                    retargetInFlightCard()
                }
            }
        }
    }

    // MARK: - Subviews

    private var fileCard: some View {
        HStack(spacing: 9) {
            Image(nsImage: currentFileIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: cardSize.width, height: cardSize.height)

            if !currentFileName.isEmpty {
                fileNameLabel
            }

            if !prioritizesFilenames {
                Image(systemName: "arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: currentCardWidth, height: 42)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }

    private var fileNameLabel: some View {
        Group {
            if prioritizesFilenames, let currentRenamedFileName {
                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Text(currentFileName)
                            .foregroundStyle(Color.primary.opacity(0.72))
                            .opacity(1 - Double(renameStrikeProgress))
                            .numericTextTransition(
                                animationValue: currentFileName,
                                animation: .easeInOut(duration: 0.28)
                            )

                        Text(currentFileName)
                            .foregroundStyle(Color.red.opacity(0.82))
                            .opacity(Double(renameStrikeProgress))
                            .numericTextTransition(
                                animationValue: currentFileName,
                                animation: .easeInOut(duration: 0.28)
                            )
                            .overlay {
                                Rectangle()
                                    .fill(Color.red.opacity(0.78))
                                    .frame(height: 1.5)
                                    .scaleEffect(x: renameStrikeProgress, anchor: .leading)
                            }
                    }
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(1 - Double(renameProgress))

                    Text(currentRenamedFileName)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .numericTextTransition(
                            animationValue: currentRenamedFileName,
                            animation: .easeInOut(duration: 0.28)
                        )
                        .opacity(Double(renameProgress))
                }
            } else {
                Text(currentFileName)
                    .foregroundStyle(.primary.opacity(0.72))
                    .numericTextTransition(
                        animationValue: currentFileName,
                        animation: .easeInOut(duration: 0.28)
                    )
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(
            maxWidth: currentCardWidth - cardSize.width - 33 - (prioritizesFilenames ? 0 : 23),
            alignment: .leading
        )
        .accessibilityHidden(true)
    }

    private func measuredWidth(of name: String) -> CGFloat {
        let font = NSFont.systemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .semibold
        )
        return ceil((name as NSString).size(withAttributes: [.font: font]).width)
    }

    @ViewBuilder
    private func destinationView(suggestion: FolderSuggestion, index: Int) -> some View {
        let isBumped = bumpedFolderName == suggestion.folderName
        let showHalo = haloFolderName == suggestion.folderName
        // Name streamed in but no file assignments yet: the model is still
        // generating this folder, so render it dimmed until files arrive.
        let isPending = suggestion.files.isEmpty && suggestion.subfolders.isEmpty

        VStack(spacing: 4) {
            ZStack {
                if showHalo {
                    Circle()
                        .fill(Color.accentColor.opacity(0.22))
                        .frame(width: bucketSize.width + 18, height: bucketSize.width + 18)
                        .blur(radius: 10)
                        .transition(.opacity)
                }

                AppKitImageView(image: FolderDropBucket.folderIcon, size: bucketSize)
                    .frame(width: bucketSize.width, height: bucketSize.height)
                    .scaleEffect(isBumped ? 1.07 : (isPending ? 0.94 : 1.0))
                    .shadow(color: Color.black.opacity(isBumped ? 0.18 : 0.10),
                            radius: isBumped ? 8 : 4, x: 0, y: 3)
            }
            .frame(width: bucketSize.width + 18, height: bucketSize.height + 6)
            .animation(.spring(response: 0.32, dampingFraction: 0.55), value: bumpTrigger)
            .animation(.easeOut(duration: 0.25), value: showHalo)

            GeneratingFolderNameLabel(
                name: suggestion.folderName,
                maxWidth: folderLabelMaxWidth
            )
        }
        .opacity(isPending ? 0.55 : 1)
        .animation(.easeOut(duration: 0.3), value: isPending)
    }

    /// Full column width for the folder label instead of the icon width, so
    /// longer folder names aren't needlessly middle-truncated.
    private var folderLabelMaxWidth: CGFloat {
        max(bucketSize.width + 24, stageWidth / CGFloat(max(1, bucketCount)) - 10)
    }

    // MARK: - Geometry

    private func centerOffset(for index: Int) -> CGFloat {
        guard bucketCount > 0 else { return 0 }
        let step = stageWidth / CGFloat(bucketCount)
        let pos = step * (CGFloat(index) + 0.5)
        return pos - stageWidth / 2
    }

    private func folderTopOffset() -> CGFloat {
        // Folders sit pinned to the bottom of the stage; this gives the
        // approximate Y position of the folder's center for the file to
        // land into.
        let folderCenterY = stageHeight / 2 - bucketSize.height / 2 - 15
        return folderCenterY
    }

    // MARK: - Animation cycle

    private func startCycleIfNeeded() {
        guard flightTask == nil, !systemReduceMotion, bucketCount > 0 else { return }

        flightTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let flight = nextFlight() else {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    continue
                }
                let pace = flightPace()
                currentFileIcon = iconForPath(flight.file.path)
                currentFileName = flight.file.displayName
                currentRenamedFileName = flight.renameMapping?.suggestedName
                currentCardWidth = cardWidth(
                    originalName: flight.file.displayName,
                    suggestedName: flight.renameMapping?.suggestedName
                )
                renameStrikeProgress = 0
                renameProgress = 0
                await runFlight(toFolderNamed: flight.folderName, pace: pace)
                await sleepScaled(90_000_000, pace)
            }
        }
    }

    /// How fast the current flight should run. 1.0 is the relaxed pace; the
    /// more unshown files are queued behind the stream, the faster flights run
    /// so the animation keeps up with reality instead of replaying history the
    /// stream has long moved past.
    private func flightPace() -> Double {
        let backlog = pendingFlightCount()
        guard backlog > 1 else { return 1.0 }
        // Floor at 0.45 so fast runs stay watchable instead of strobing.
        return max(0.45, 1.0 - 0.08 * Double(backlog - 1))
    }

    /// At high speed a haptic per landing becomes a continuous buzz, so only
    /// tick at relaxed paces.
    private func landingHapticIfCalm(_ pace: Double) {
        guard pace >= 0.6 else { return }
        HapticFeedbackManager.shared.selection()
    }

    private func pendingFlightCount() -> Int {
        max(0, flightQueue.count - nextFlightIndex)
    }

    private func sleepScaled(_ nanoseconds: UInt64, _ pace: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(Double(nanoseconds) * pace))
    }

    private func stopCycle() {
        flightTask?.cancel()
        flightTask = nil
        cardOpacity = 0
        flightProgress = 0
        flightDestination = .zero
        tuckOffset = .zero
        cardRotation = 0
        cardLift = 0
        bumpedFolderName = nil
        haloFolderName = nil
        flightTargetFolderName = nil
        renameStrikeProgress = 0
        renameProgress = 0
    }

    /// Keeps the in-flight card aimed at its folder when the row reflows
    /// (a new folder inserting shifts every bucket left). The destination is
    /// animatable, so the card curves toward the folder's new position with
    /// the same spring the row uses instead of landing where the folder was.
    private func retargetInFlightCard() {
        guard let target = flightTargetFolderName, cardOpacity > 0 else { return }
        // Throttle: streaming name updates arrive in bursts, and the launch
        // position is recomputed before the carry phase anyway.
        guard Date().timeIntervalSince(lastRetargetAt) >= 0.1 else { return }
        lastRetargetAt = Date()
        guard let index = visibleSuggestions.firstIndex(where: { $0.folderName == target }) else {
            // The target folder was evicted mid-flight: fade the card out
            // rather than dropping the file into a stranger's folder.
            withAnimation(.easeOut(duration: 0.18)) { cardOpacity = 0 }
            return
        }
        let destX = centerOffset(for: index)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
            flightDestination.width = destX
        }
    }

    private func runFlight(toFolderNamed folderName: String, pace: Double = 1.0) async {
        guard let startIndex = visibleSuggestions.firstIndex(where: { $0.folderName == folderName })
        else { return }
        let destX = centerOffset(for: startIndex)
        let landingY = folderTopOffset() - 8
        let direction = max(-1, min(1, destX / max(1, stageWidth / 2)))
        flightTargetFolderName = folderName

        // Phase 1: lift the file like a drag has just begun.
        flightProgress = 0
        flightDestination = .zero
        tuckOffset = .zero
        cardRotation = 0
        cardLift = 0
        cardScale = 0.97
        cardOpacity = 0
        haloFolderName = nil

        withAnimation(.spring(response: 0.24 * pace, dampingFraction: 0.72)) {
            cardOpacity = 1
            cardScale = 1.075
            cardLift = 1.35
            cardRotation = Double(direction) * -3.2
        }
        await sleepScaled(170_000_000, pace)
        if Task.isCancelled { return }

        // Phase 2: carry the lifted file toward its folder along a visible arc.

        if currentRenamedFileName != nil {
            withAnimation(.easeInOut(duration: 0.14 * pace)) {
                renameStrikeProgress = 1
            }
            await sleepScaled(100_000_000, pace)
            if Task.isCancelled { return }

            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.24 * pace)) {
                renameProgress = 1
            }
            landingHapticIfCalm(pace)
            await sleepScaled(130_000_000, pace)
            if Task.isCancelled { return }
        }

        await sleepScaled(30_000_000, pace)
        if Task.isCancelled { return }

        // Show the receive halo just before the file lands.
        withAnimation(.easeIn(duration: 0.28 * pace).delay(0.14 * pace)) {
            haloFolderName = folderName
        }

        // Recompute the target position: folders may have shifted while the
        // card was lifting or the rename played.
        let launchIndex = visibleSuggestions.firstIndex(where: { $0.folderName == folderName }) ?? startIndex
        flightDestination = CGSize(width: centerOffset(for: launchIndex), height: landingY)
        withAnimation(.timingCurve(0.22, 0.72, 0.20, 1.0, duration: 0.58 * pace)) {
            flightProgress = 1
            cardScale = 1
            cardRotation = Double(direction) * 4.8
        }
        await sleepScaled(540_000_000, pace)
        if Task.isCancelled { return }

        // Phase 3: the file tucks into the folder, the folder bumps.
        withAnimation(.spring(response: 0.24 * pace, dampingFraction: 0.78)) {
            tuckOffset = CGSize(width: 0, height: 20)
            cardScale = 0.28
            cardOpacity = 0
            cardRotation = 0
            cardLift = 0
        }
        bumpedFolderName = folderName
        bumpTrigger &+= 1
        landingHapticIfCalm(pace)

        await sleepScaled(180_000_000, pace)
        if Task.isCancelled { return }
        withAnimation(.easeOut(duration: 0.22 * pace)) {
            haloFolderName = nil
        }
        bumpedFolderName = nil
        flightTargetFolderName = nil
    }

    // MARK: - Suggestions and file selection

    private func mergeDisplayedSuggestions(animated: Bool = true) {
        let incoming = Array(suggestions.prefix(maxBuckets))
        guard !incoming.isEmpty else {
            // The stream was cleared (new run or next request batch): start the
            // next session fresh instead of keeping stale folders and blocking
            // the new plan's files from flying.
            if !displayedSuggestions.isEmpty {
                displayedSuggestions = []
                shownFlightFileIDs = []
                flightQueue = []
                nextFlightIndex = 0
            }
            return
        }

        // Mirror the parser's rolling window: update retained folders, evict
        // ones that fell out of the window, and append newcomers. Without
        // eviction the stage freezes once `maxBuckets` folders have appeared.
        let incomingNames = Set(incoming.map(\.folderName))
        var merged = displayedSuggestions.filter { incomingNames.contains($0.folderName) }
        var didInsert = false
        for suggestion in incoming {
            if let index = merged.firstIndex(where: { $0.folderName == suggestion.folderName }) {
                merged[index] = suggestion
            } else if merged.count < maxBuckets {
                merged.append(suggestion)
                didInsert = true
            }
        }

        guard merged != displayedSuggestions else { return }

        if animated && didInsert && !systemReduceMotion {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                displayedSuggestions = merged
            }
            HapticFeedbackManager.shared.light()
        } else {
            displayedSuggestions = merged
        }

        rebuildFlightQueue(from: merged)
        startCycleIfNeeded()
    }

    private struct FlightCandidate {
        let folderName: String
        let file: FileItem
        let renameMapping: FileRenameMapping?
    }

    private func nextFlight() -> FlightCandidate? {
        guard nextFlightIndex < flightQueue.count else { return nil }
        let candidate = flightQueue[nextFlightIndex]
        nextFlightIndex += 1
        shownFlightFileIDs.insert(candidate.file.id)
        return candidate
    }

    private func rebuildFlightQueue(from suggestions: [FolderSuggestion]) {
        var renameIndex: [UUID: FileRenameMapping] = [:]
        for suggestion in suggestions {
            indexRenames(in: suggestion, into: &renameIndex)
        }

        var queue: [FlightCandidate] = []
        for suggestion in suggestions.prefix(maxBuckets) {
            appendFlightCandidates(
                in: suggestion,
                destinationFolderName: suggestion.folderName,
                renameIndex: renameIndex,
                to: &queue
            )
        }
        flightQueue = queue.filter { !shownFlightFileIDs.contains($0.file.id) }
        nextFlightIndex = 0
    }

    private func indexRenames(
        in suggestion: FolderSuggestion,
        into index: inout [UUID: FileRenameMapping]
    ) {
        for mapping in suggestion.fileRenameMappings where mapping.hasRename {
            index[mapping.originalFile.id] = mapping
        }
        for subfolder in suggestion.subfolders {
            indexRenames(in: subfolder, into: &index)
        }
    }

    private func appendFlightCandidates(
        in suggestion: FolderSuggestion,
        destinationFolderName: String,
        renameIndex: [UUID: FileRenameMapping],
        to queue: inout [FlightCandidate]
    ) {
        for file in suggestion.files {
            queue.append(FlightCandidate(
                folderName: destinationFolderName,
                file: file,
                renameMapping: renameIndex[file.id]
            ))
        }
        for subfolder in suggestion.subfolders {
            appendFlightCandidates(
                in: subfolder,
                destinationFolderName: destinationFolderName,
                renameIndex: renameIndex,
                to: &queue
            )
        }
    }

    private func iconForPath(_ path: String) -> NSImage {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        if !ext.isEmpty {
            return AnalysisIconProvider.icon(forFileExtension: ext)
        }
        return AnalysisIconProvider.icon(for: .data)
    }

    private func cardWidth(originalName: String, suggestedName: String?) -> CGFloat {
        // Size the card to the actual name in both modes; a fixed width cut
        // off ordinary filenames. The non-rename card also shows the
        // arrow.down.right glyph, so reserve room for it.
        let longestName = [originalName, suggestedName ?? ""]
            .max(by: { measuredWidth(of: $0) < measuredWidth(of: $1) }) ?? originalName
        let arrowAllowance: CGFloat = prioritizesFilenames ? 0 : 23
        return min(320, max(116, measuredWidth(of: longestName) + cardSize.width + 33 + arrowAllowance))
    }
}

private struct GeneratingFolderNameLabel: View {
    @SortyHotReload private var hotReload
    let name: String
    let maxWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false

    var body: some View {
        // Wrap to a second line before truncating: full folder names beat
        // tidy ellipses. The fixed two-line height keeps the row from
        // jumping as names stream in.
        Text(name)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .truncationMode(.middle)
            .numericTextTransition(
                animationValue: name,
                animation: .easeInOut(duration: 0.28)
            )
            .frame(maxWidth: maxWidth)
            .frame(height: 28, alignment: .top)
            .opacity(isRevealed ? 1 : 0.35)
            .scaleEffect(isRevealed ? 1 : 0.94)
            .onAppear {
                guard !reduceMotion else {
                    isRevealed = true
                    return
                }
                withAnimation(.spring(response: 0.48, dampingFraction: 0.84).delay(0.12)) {
                    isRevealed = true
                }
            }
            .onChange(of: name) { _, _ in
                revealUpdatedName()
            }
    }

    private func revealUpdatedName() {
        guard !reduceMotion else {
            isRevealed = true
            return
        }

        isRevealed = false
        withAnimation(.spring(response: 0.48, dampingFraction: 0.84).delay(0.08)) {
            isRevealed = true
        }
    }
}

/// Appear/disappear for folder buckets: new folders spring up instead of
/// only scaling in. Opacity/scale/offset only — no blur passes.
private struct FolderRevealModifier: ViewModifier {
    var opacity: Double = 1
    var scale: CGFloat = 1
    var yOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(scale, anchor: .bottom)
            .offset(y: yOffset)
    }
}

private struct FolderDropFlightEffect: GeometryEffect {
    var progress: CGFloat
    var destination: CGSize

    /// Progress and destination are both animatable so a mid-flight retarget
    /// (folders reflowing under the card) glides instead of jumping.
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(progress, AnimatablePair(destination.width, destination.height)) }
        set {
            progress = newValue.first
            destination = CGSize(width: newValue.second.first, height: newValue.second.second)
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = max(0, min(1, progress))
        let inverse = 1 - t
        let horizontalProgress = t * t * (3 - 2 * t)
        let arcHeight = min(54, max(34, abs(destination.width) * 0.18))
        let x = destination.width * horizontalProgress
        let y = (2 * inverse * t * -arcHeight) + (t * t * destination.height)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: y))
    }
}

private enum FolderDropBucket {
    static let folderIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: 128, height: 128)
        return icon
    }()
}

#Preview {
    OrganizingFlightStageView(
        suggestions: [
            FolderSuggestion(folderName: "Screenshots"),
            FolderSuggestion(folderName: "Invoices"),
            FolderSuggestion(folderName: "Projects"),
            FolderSuggestion(folderName: "Music")
        ]
    )
    .padding()
    .frame(width: 500, height: 320)
}
