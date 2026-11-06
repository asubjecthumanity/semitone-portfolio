import SwiftUI

/// The finger's part in flipping the roll from one portrait layout to the
/// other. The two layouts are mirror images across the 45° diagonal through
/// the hinge, where the horizontal roll's play line meets the falling notes'
/// hit line: keyboard on the left edge with time running right, or keyboard
/// along the bottom with time running up. So the roll turns over that
/// diagonal like a card whose back is the falling notes, and the moment on
/// the line stays on the hinge throughout. (A plain quarter turn would land
/// the keyboard backwards, bass on the right.)
///
/// Progress is the finger's angle round the hinge: straight up (along the
/// horizontal roll's keyboard) is 0, straight right (along the falling notes'
/// keyboard) is 1, and the diagonal itself, where the card is edge-on, is
/// halfway.
nonisolated struct RollFlip: Equatable {
    /// The layout the drag started on.
    let from: RollLayout
    /// What the angle is measured round: the hinge, unless the touch starts
    /// so close to it (or past it) that the angle would leap or run
    /// backwards; then a point that far beyond the touch.
    let pivot: CGPoint
    /// The finger's angle round `pivot` in radians, unwrapped so it never
    /// jumps a whole turn: 0 straight up, π/2 straight right.
    private(set) var angle: Double

    /// How close a drag's pivot may be to where it starts. Nearer, a few
    /// points of finger would swing the card a long way.
    static let minimumRadius: CGFloat = 88

    init(from: RollLayout, hinge: CGPoint, touch: CGPoint) {
        self.from = from
        var pivot = hinge
        switch from {
        case .horizontal:
            // The keyboard runs up the left edge from the hinge; a touch low
            // on it measures round a point further down.
            pivot.y = max(hinge.y, touch.y + Self.minimumRadius)
        case .falling:
            // The keys run right from the hinge along the bottom; a touch on
            // the bass end measures round a point further left.
            pivot.x = min(hinge.x, touch.x - Self.minimumRadius)
        }
        self.pivot = pivot
        angle = Self.angle(of: touch, round: pivot)
    }

    /// 0 for the horizontal roll, 1 for the falling notes.
    static func progress(of layout: RollLayout) -> Double { layout == .falling ? 1 : 0 }

    /// Where the card is: 0 the horizontal roll, 1 the falling notes.
    var progress: Double { Self.progress(angle: angle) }

    static func progress(angle: Double) -> Double { min(max(angle / (.pi / 2), 0), 1) }

    /// The angle of `point` round `pivot`, 0 straight up, clockwise positive
    /// (screen coordinates: y runs down).
    static func angle(of point: CGPoint, round pivot: CGPoint) -> Double {
        atan2(Double(point.x - pivot.x), Double(pivot.y - point.y))
    }

    /// The angle of `point`, taken the short way round from the current angle.
    private func unwrappedAngle(of point: CGPoint) -> Double {
        let raw = Self.angle(of: point, round: pivot)
        return angle + (raw - angle).remainder(dividingBy: 2 * .pi)
    }

    mutating func move(to point: CGPoint) {
        angle = unwrappedAngle(of: point)
    }

    /// Where the card goes when the finger lets go, given where its motion
    /// would carry it (a drag's predicted end): past halfway it lands on the
    /// other layout, otherwise it falls back. A flick counts by where it
    /// would end, so a quick one lands from short of halfway, and one back
    /// the way it came falls back from past it.
    func settles(predictedEnd: CGPoint) -> RollLayout {
        Self.progress(angle: unwrappedAngle(of: predictedEnd)) >= 0.5 ? .falling : .horizontal
    }

    /// How far a drag from `from` has come, 0 to 1, for a card at `progress`.
    static func distance(from: RollLayout, at progress: Double) -> Double {
        abs(progress - Self.progress(of: from))
    }

    /// How a face of the card is turned and whether it's the side showing,
    /// for a card at `progress`: the horizontal roll turns from 0° to 180°
    /// about the hinge's diagonal, the falling notes from -180° (its back
    /// turned) to 0°. Each shows until the edge-on moment halfway.
    static func face(_ layout: RollLayout, at progress: Double) -> (degrees: Double, showing: Bool) {
        switch layout {
        case .horizontal: (progress * 180, progress < 0.5)
        case .falling: (progress * 180 - 180, progress >= 0.5)
        }
    }

    /// The hinge in a roll of `size`: on the horizontal roll's play line
    /// (`playLineX` from the left), at the height of the falling notes' hit
    /// line (their keys' height above the bottom).
    static func hinge(in size: CGSize, playLineX: CGFloat, fallingKeyboardHeight: CGFloat) -> CGPoint {
        CGPoint(x: playLineX, y: max(size.height - fallingKeyboardHeight, 0))
    }
}

extension RollLayout {
    /// The layout on screen: the chosen one while the phone is upright. An
    /// iPhone on its side always shows the falling notes, the 88 keys along
    /// the long edge (`isPhoneLandscape`: compact height, which an iPad never
    /// is full screen, so an iPad keeps its chosen layout either way).
    static func shown(chosen: RollLayout, isPhoneLandscape: Bool) -> RollLayout {
        isPhoneLandscape ? .falling : chosen
    }

    /// The VoiceOver action that switches away from this layout.
    var switchActionName: String {
        switch self {
        case .horizontal: "Switch to falling notes"
        case .falling: "Switch to horizontal roll"
        }
    }

    var other: RollLayout { self == .horizontal ? .falling : .horizontal }
}

/// The transcription screen's roll: the horizontal roll or the falling
/// notes, whichever is chosen for the phone upright (`RollLayout.storageKey`,
/// also set by the Roll style cards in a Tone's Settings), and always the falling notes
/// on an iPhone on its side.
///
/// Upright, the keyboard can be pulled round the corner to switch: hold it a
/// quarter of a second (it lifts, with a light tick and a hint), then pull it
/// round the bottom-left corner, or, from the falling notes, up round the
/// corner to the left edge. While the card turns, the hint says what letting
/// go will do. The hold comes first so the left-edge Back swipe, which starts
/// on the keyboard, still goes back. VoiceOver has an action on the roll for
/// the same switch. With Reduce Motion the card doesn't turn: the hint shows
/// how far the drag has come, and letting go crossfades.
///
/// Turning the phone crossfades: the turn swaps the keyboard's ends (turned
/// a quarter left, the bass would lie at the right), so there is no
/// continuous move between the two. The moment on the line, and playback,
/// carry on through either change.
struct RollStage: View {
    @ObservedObject var viewModel: TranscriberViewModel
    @AppStorage(RollLayout.storageKey) private var rollLayoutRaw = RollLayout.horizontal.rawValue
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A switch under way, from the lift (or a VoiceOver action) until the
    /// card lands.
    @State private var flip: Flip?
    @State private var size: CGSize = .zero
    @State private var lifts = 0
    @State private var halfwayCrossings = 0
    @State private var landings = 0

    struct Flip: Equatable {
        let from: RollLayout
        /// Where the faces are: 0 the horizontal roll, 1 the falling notes.
        var shown: Double
        /// The finger's drag, until it lets go.
        var drag: RollFlip?
        /// How far the finger has pulled, 0 to 1 from `from` (the faces
        /// follow it unless Reduce Motion is on).
        var pulled: Double = 0
        /// Where the drag started, for the hint.
        var touch: CGPoint?
        /// Let go: the card is on its way to `to`.
        var to: RollLayout?
        var announce = false
    }

    private static let space = "roll-stage"
    /// How far ahead of the finger a let-go looks, in seconds of its speed.
    private static let throwTime: CGFloat = 0.15
    /// The phone turning swaps the layouts with a crossfade. The animation
    /// rides on the transition alone: the rest of the turn's changes (the
    /// roll's size, its scroll position) must not be animated along with it.
    private static let turnCrossfade = AnyTransition.opacity.animation(.easeInOut(duration: 0.3))

    private var chosen: RollLayout { RollLayout(rawValue: rollLayoutRaw) ?? .horizontal }
    private var isPhoneLandscape: Bool { verticalSizeClass == .compact }
    private var layout: RollLayout { RollLayout.shown(chosen: chosen, isPhoneLandscape: isPhoneLandscape) }
    /// The upright layouts can be switched; on its side it's always the falling notes.
    private var canSwitch: Bool { !isPhoneLandscape }

    private var fallingPxPerSecond: CGFloat {
        isPhoneLandscape ? FallingGeometry.landscapePxPerSecond : FallingGeometry.pxPerSecond
    }
    private var fallingKeyboardHeight: CGFloat {
        isPhoneLandscape ? FallingGeometry.landscapeKeyboardHeight : FallingGeometry.keyboardHeight
    }

    private var hinge: CGPoint {
        RollFlip.hinge(in: size, playLineX: PianoRollView.keyboardWidth + RollGeometry().playLineInset,
                       fallingKeyboardHeight: fallingKeyboardHeight)
    }

    private var hingeAnchor: UnitPoint {
        guard size.width > 0, size.height > 0 else { return .bottomLeading }
        return UnitPoint(x: hinge.x / size.width, y: hinge.y / size.height)
    }

    /// Where the faces are when nothing is flipping.
    private var shown: Double { flip?.shown ?? RollFlip.progress(of: layout) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if flip != nil {
                backdrop
            }
            if flip != nil || layout == .horizontal {
                horizontal
                    // Opaque, so the card doesn't show the backdrop through its
                    // white rows as it turns. The roll runs on under the home
                    // indicator, and so does this.
                    .background { RollTheme.surface.ignoresSafeArea(.container, edges: .bottom) }
                    .overlay(alignment: .topLeading) { liftShadow(.horizontal) }
                    .modifier(FlipFace(layout: .horizontal, shown: shown, anchor: hingeAnchor, turns: !reduceMotion))
                    .allowsHitTesting(flip == nil)
                    .environment(\.rollSwitchAction, switchAction(from: .horizontal))
                    .transition(Self.turnCrossfade)
            }
            if flip != nil || layout == .falling {
                falling
                    .background(RollTheme.surface)
                    .overlay(alignment: .topLeading) { liftShadow(.falling) }
                    .modifier(FlipFace(layout: .falling, shown: shown, anchor: hingeAnchor, turns: !reduceMotion))
                    .allowsHitTesting(flip == nil)
                    .environment(\.rollSwitchAction, switchAction(from: .falling))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("falling-notes-view")
                    .transition(Self.turnCrossfade)
            }
            if canSwitch, viewModel.hasContent {
                grip
            }
            if let flip, flip.to == nil {
                hint(flip)
            }
        }
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        // The turning card stays below the parts bar; it may run on into the
        // bottom edge, where the roll itself runs under the home indicator.
        .clipShape(BelowTopEdge())
        .onChange(of: isPhoneLandscape) { _, landscape in turned(landscape: landscape) }
        #if DEBUG
        .onAppear {
            if RegressionUIFixture.selected != nil, let progress = RegressionUIFixture.flipProgress, canSwitch {
                flip = Flip(from: .horizontal, shown: progress, pulled: progress)
            }
        }
        #endif
        .sensoryFeedback(.impact(weight: .light), trigger: lifts)
        .sensoryFeedback(.selection, trigger: halfwayCrossings)
        .sensoryFeedback(.impact(weight: .medium), trigger: landings)
    }

    // MARK: Faces

    private var horizontal: some View {
        PianoRollView(
            notes: viewModel.visibleNotes,
            chords: viewModel.chordSegments,
            duration: viewModel.duration,
            isLive: viewModel.isRecording,
            clock: viewModel.isPlaying ? viewModel.clock : nil,
            beatTimes: viewModel.showBeatGrid ? viewModel.beatGrid.beats : [],
            downbeatTimes: viewModel.showBeatGrid ? viewModel.beatGrid.downbeats : [],
            onCue: { viewModel.cue(at: $0, settled: $1) },
            onHold: { viewModel.holdPlayback() },
            onResume: { viewModel.resumePlayback(from: $0) },
            // The cue only places a stopped roll; playing, it follows the
            // clock. Not reading the playhead then keeps its few publishes a
            // second from re-rendering the stage and the roll.
            cue: viewModel.isPlaying ? 0 : viewModel.playhead,
            cueChosen: viewModel.cueChosen,
            onChooseCue: { viewModel.userChoseCue() }
        )
    }

    private var falling: some View {
        FallingNotesView(
            notes: viewModel.visibleNotes,
            chords: viewModel.chordSegments,
            time: viewModel.isRecording ? viewModel.duration : viewModel.playhead,
            duration: viewModel.duration,
            isLive: viewModel.isRecording,
            clock: viewModel.isPlaying ? viewModel.clock : nil,
            beatTimes: viewModel.showBeatGrid ? viewModel.beatGrid.beats : [],
            downbeatTimes: viewModel.showBeatGrid ? viewModel.beatGrid.downbeats : [],
            // Only a scrub while stopped cues: the user picking where play
            // starts, which the horizontal roll shows when it comes back.
            onCue: { viewModel.cue(at: $0, settled: $1); viewModel.userChoseCue() },
            onHold: { viewModel.holdPlayback() },
            onResume: { viewModel.resumePlayback(from: $0) },
            onSeek: { viewModel.seek(to: $0) },
            pxPerSecond: fallingPxPerSecond,
            keyboardHeight: fallingKeyboardHeight
        )
    }

    /// Behind the card while it turns, Home's ground with dashed navy
    /// outlines (at 30%) where the two keyboards lie, so the corner it goes
    /// round reads.
    private var backdrop: some View {
        RollTheme.ground
            .overlay(alignment: .topLeading) {
                let dash = StrokeStyle(lineWidth: 1, dash: [4, 4])
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(RollTheme.navy.opacity(0.3), style: dash)
                        .frame(width: PianoRollView.keyboardWidth - 8, height: max(size.height - PianoRollView.headerHeight - 8, 0))
                        .offset(x: 4, y: PianoRollView.headerHeight + 4)
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(RollTheme.navy.opacity(0.3), style: dash)
                        .frame(width: max(size.width - 8, 0), height: max(fallingKeyboardHeight - 8, 0))
                        .offset(x: 4, y: size.height - fallingKeyboardHeight + 4)
                }
            }
            .accessibilityHidden(true)
    }

    /// The held keyboard lifts off the roll: a soft shadow along its inner
    /// edge, which turns with the card.
    @ViewBuilder
    private func liftShadow(_ face: RollLayout) -> some View {
        if let flip, flip.from == face {
            let shade = LinearGradient(colors: [.black.opacity(0.22), .clear],
                                       startPoint: face == .horizontal ? .leading : .bottom,
                                       endPoint: face == .horizontal ? .trailing : .top)
            Group {
                if face == .horizontal {
                    shade.frame(width: 12, height: max(size.height - PianoRollView.headerHeight, 0))
                        .offset(x: PianoRollView.keyboardWidth, y: PianoRollView.headerHeight)
                } else {
                    shade.frame(width: size.width, height: 12)
                        .offset(y: size.height - fallingKeyboardHeight - 12)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }

    // MARK: Gesture

    /// Where the keyboard can be held: the horizontal roll's keys down the
    /// left edge, or the falling notes' keys along the bottom. It fills
    /// whatever room the stage is given rather than taking the stage's
    /// measured `size`: sized from that, it held the stage open at its last
    /// size, so the stage measured the same again and never shrank. Turned
    /// upright again with the falling notes chosen, the stage kept its width
    /// on its side, the keys magnified and the parts run off the left edge.
    @ViewBuilder
    private var grip: some View {
        let from = flip?.from ?? layout
        Color.clear
            .contentShape(Rectangle())
            .frame(width: from == .horizontal ? PianoRollView.keyboardWidth : nil,
                   height: from == .horizontal ? nil : fallingKeyboardHeight)
            .gesture(KeyboardGrip(
                space: .named(Self.space),
                onLift: { lift(from: from, at: $0) },
                onMove: { pull(to: $0) },
                onEnd: { letGo(at: $0, velocity: $1) },
                onCancel: { cancelHold() }
            ))
            .padding(.top, from == .horizontal ? PianoRollView.headerHeight : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: from == .horizontal ? .leading : .bottom)
            .accessibilityHidden(true)
    }

    /// Held long enough: the keyboard lifts and the hint shows the way.
    private func lift(from start: RollLayout, at touch: CGPoint) {
        guard flip == nil, canSwitch else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            flip = Flip(from: start, shown: RollFlip.progress(of: start),
                        drag: RollFlip(from: start, hinge: hinge, touch: touch), touch: touch)
        }
        lifts += 1
    }

    private func pull(to location: CGPoint) {
        guard var f = flip, f.to == nil, f.drag != nil else { return }
        f.drag?.move(to: location)
        let progress = f.drag?.progress ?? f.shown
        let pulled = RollFlip.distance(from: f.from, at: progress)
        if (pulled >= 0.5) != (f.pulled >= 0.5) { halfwayCrossings += 1 }
        f.pulled = pulled
        if !reduceMotion { f.shown = progress }
        flip = f
    }

    /// Let go: where the finger was heading decides, so a flick counts by
    /// where it would have carried the card (a short throw's worth, as a
    /// drag gesture predicts its end).
    private func letGo(at location: CGPoint, velocity: CGVector) {
        guard let f = flip, f.to == nil else { return }
        pull(to: location)
        let predicted = CGPoint(x: location.x + velocity.dx * Self.throwTime, y: location.y + velocity.dy * Self.throwTime)
        let target = flip?.drag?.settles(predictedEnd: predicted) ?? f.from
        land(target, from: f.from)
    }

    /// The system took the touch (a call, the app leaving the screen): fall back.
    private func cancelHold() {
        guard let f = flip, f.to == nil else { return }
        land(f.from, from: f.from)
    }

    /// Turns the card the rest of the way onto `target` (back onto `from`
    /// if it falls back), then keeps only that face.
    private func land(_ target: RollLayout, from: RollLayout, announce: Bool = false) {
        if flip == nil { flip = Flip(from: from, shown: RollFlip.progress(of: from)) }
        flip?.drag = nil
        flip?.to = target
        flip?.announce = announce
        let animation: Animation = reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.45, bounce: 0.1)
        withAnimation(animation) {
            flip?.shown = RollFlip.progress(of: target)
        } completion: {
            landed(on: target)
        }
    }

    private func landed(on target: RollLayout) {
        guard let f = flip, f.to == target else { return }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) {
            if target != f.from, canSwitch { rollLayoutRaw = target.rawValue }
            flip = nil
        }
        guard target != f.from else { return }
        landings += 1
        if f.announce { AccessibilityNotification.Announcement(target.label).post() }
    }

    /// VoiceOver's way to the other layout: the same turn, without the drag.
    /// Only on the face showing, and not on its side.
    private func switchAction(from face: RollLayout) -> RollSwitchAction? {
        guard canSwitch, flip == nil, layout == face else { return nil }
        return RollSwitchAction(name: face.switchActionName) {
            guard flip == nil else { return }
            land(face.other, from: face, announce: true)
        }
    }

    /// The phone turned: a turn mid-flip drops the flip, and VoiceOver hears
    /// which layout is now on screen when it changed.
    private func turned(landscape: Bool) {
        if flip != nil {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { flip = nil }
        }
        if chosen != .falling {
            AccessibilityNotification.Announcement(layout.label).post()
        }
    }

    // MARK: Hint

    /// How far a pull has to come before the hint says what letting go does.
    static let hintTurnsAt = 0.08

    /// The hint by the lifted keyboard, in glass over the card, as R01's
    /// frames have it: "Pull round to the bottom" on the lift, then, once
    /// the card starts to turn, what letting go will do ("Let go: stays
    /// horizontal" short of halfway, "Let go: falling notes" past it), since
    /// the halfway tick is the only other cue and not every phone plays it.
    /// With Reduce Motion (no turn) a ring in it fills as the drag comes round.
    static func hintText(from: RollLayout, pulled: Double) -> String {
        let toFalling = from == .horizontal
        guard pulled >= hintTurnsAt else { return toFalling ? "Pull round to the bottom" : "Pull round to the left" }
        if pulled >= 0.5 { return toFalling ? "Let go: falling notes" : "Let go: horizontal roll" }
        return toFalling ? "Let go: stays horizontal" : "Let go: stays falling notes"
    }

    private func hint(_ flip: Flip) -> some View {
        let toFalling = flip.from == .horizontal
        let lifted = flip.pulled < Self.hintTurnsAt
        let label = HStack(spacing: 7) {
            if reduceMotion {
                ZStack {
                    Circle().stroke(HomeTheme.navy(0.2), lineWidth: 2.5)
                    Circle().trim(from: 0, to: flip.pulled)
                        .stroke(HomeTheme.navy, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
            } else if lifted {
                Image(systemName: toFalling ? "arrow.turn.right.down" : "arrow.turn.left.up")
                    .fontWeight(.semibold)
            }
            Text(Self.hintText(from: flip.from, pulled: flip.pulled))
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .foregroundStyle(HomeTheme.controlInk)
        .padding(.leading, 11)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 36)
        // A pill on one line; at the largest text sizes it wraps rather than
        // run off the screen. Pinned light, like Home's controls.
        .glassEffect(.regular.tint(HomeTheme.controlTint), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: Self.hintText(from: flip.from, pulled: flip.pulled))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)

        return Group {
            if toFalling {
                // Beside the keyboard, above the finger so the thumb doesn't hide it.
                let y = min(max((flip.touch?.y ?? size.height * 0.45) - 110, PianoRollView.headerHeight + 8),
                            max(size.height - fallingKeyboardHeight - 60, PianoRollView.headerHeight + 8))
                label
                    .padding(.leading, PianoRollView.keyboardWidth + 12)
                    .padding(.trailing, 12)
                    .padding(.top, y)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                label
                    .padding(.horizontal, 12)
                    .padding(.bottom, fallingKeyboardHeight + 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

/// One face of the card: turned about the hinge's diagonal (the axis runs up
/// and to the right through it), and shown only while it's the side facing
/// out. Animatable, so a landing turn decides which side shows frame by
/// frame rather than fading one face out across the whole turn. Without the
/// turn (Reduce Motion) the faces crossfade instead.
private struct FlipFace: ViewModifier, Animatable {
    let layout: RollLayout
    var shown: Double
    let anchor: UnitPoint
    let turns: Bool

    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    func body(content: Content) -> some View {
        let face = RollFlip.face(layout, at: shown)
        content
            .rotation3DEffect(.degrees(turns ? face.degrees : 0), axis: (x: 1, y: -1, z: 0),
                              anchor: anchor, perspective: 0.5)
            .opacity(turns ? (face.showing ? 1 : 0) : (layout == .falling ? shown : 1 - shown))
    }
}

/// Clips at the top edge only: the turning card stays out of the parts bar
/// and toolbar above, while the roll still runs on under the home indicator.
private struct BelowTopEdge: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - 2000, y: rect.minY, width: rect.width + 4000, height: rect.height + 2000))
    }
}

/// The keyboard's grip: a UIKit long press. A SwiftUI gesture there (even a
/// long press first, even simultaneous) kept the system's Back swipe, which
/// starts on the keyboard, from going back; a UIKit recognizer takes part in
/// UIKit's own rules instead: whichever recognizes first wins. A quick swipe
/// is the Back swipe's before the press has been held long enough, and a held
/// press is ours, so a pull after it never goes back. It's a recognizer on a
/// SwiftUI view rather than a UIKit view of its own: with a view there, the
/// layout of the phone turning never finished.
private struct KeyboardGrip: UIGestureRecognizerRepresentable {
    /// Where the locations below are measured: the roll's own space.
    let space: NamedCoordinateSpace
    let onLift: (CGPoint) -> Void
    let onMove: (CGPoint) -> Void
    let onEnd: (_ location: CGPoint, _ velocity: CGVector) -> Void
    let onCancel: () -> Void

    final class Coordinator {
        /// The last tenth of a second of the finger, for its speed at let-go.
        var samples: [(time: CFTimeInterval, location: CGPoint)] = []

        func add(_ location: CGPoint, at time: CFTimeInterval) {
            samples.append((time, location))
            samples.removeAll { time - $0.time > 0.1 }
        }

        /// Points per second over the last samples (none: standing still).
        var velocity: CGVector {
            guard let first = samples.first, let last = samples.last, last.time - first.time > 0.01 else { return .zero }
            let dt = CGFloat(last.time - first.time)
            return CGVector(dx: (last.location.x - first.location.x) / dt, dy: (last.location.y - first.location.y) / dt)
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0.25
        // A finger that moves further first is swiping, not holding.
        press.allowableMovement = 10
        return press
    }

    func handleUIGestureRecognizerAction(_ press: UILongPressGestureRecognizer, context: Context) {
        let location = context.converter.location(in: space)
        let now = CACurrentMediaTime()
        switch press.state {
        case .began:
            context.coordinator.samples = [(now, location)]
            onLift(location)
        case .changed:
            context.coordinator.add(location, at: now)
            onMove(location)
        case .ended:
            context.coordinator.add(location, at: now)
            onEnd(location, context.coordinator.velocity)
        case .cancelled, .failed:
            onCancel()
        default:
            break
        }
    }
}
