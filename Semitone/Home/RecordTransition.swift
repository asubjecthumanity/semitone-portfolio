import SwiftUI

/// The record transition, from Home's record button to the roll: what is in
/// the air and where it is going. One lives in `RootView`, in the
/// environment, so the record button can say where it is and that it was
/// tapped, the roll's keyboard where it is and that it is being flown to,
/// and `RecordFlightOverlay`, over the whole navigation stack, can fly the
/// piano between them across the push.
///
/// At the tap Home dissolves into a veil of its grey (which the
/// transcription screen shares) round a copy of the red record disc, and
/// the piano sets off out of the disc. A moment later, Home hidden, the
/// transcription screen is pushed under the veil, and the veil clears to
/// the roll as the piano flies on into its keyboard.
///
/// Building that screen stalls the main thread (about a third of a second
/// in the simulator's debug build), which holds up anything SwiftUI
/// animates. So the piano and the disc are flown by Core Animation
/// (`RecordFlightCanvas`), which the render server plays on through the
/// stall: the piano spirals and turns over the veil all the while. The
/// veil, which must stay whole until the roll is there to clear to, keeps
/// its own clock, stepped by the overlay's frames (`RecordFlightClock`).
///
/// The flight is only ever visual. The take starts recording at the tap, as
/// it always has, and nothing waits for the piano to land. Every way a
/// flight can end (landing, being let go early, being cancelled, the safety
/// timeout) shows the keyboard again.
@Observable
final class RecordTransition {
    struct Flight: Equatable {
        let id: Int
        /// `.fly` or `.crossfade`.
        let kind: RecordTakeOff
        /// Which keyboard it flies to: the one the roll will show.
        let layout: RollLayout
        var path: RecordFlight
        /// How far down the 88 keys the horizontal roll's keyboard is
        /// scrolled, so the piano shows the keys the keyboard will.
        var scrollY: CGFloat
        /// The keyboard has said where it is: `path` lands on it rather
        /// than on a guess, and the landing can be a plain swap.
        var landsOnKeyboard: Bool
        /// The transcription screen is under the veil, so the veil can clear.
        var launched = false
        /// The piano has flown its course and lies on the keyboard's frame;
        /// it lands (swaps with the keyboard) once the veil is clear too.
        var flown = false
        /// Let go before landing (the phone turned, the keyboard went, the
        /// take couldn't start): the piano and the veil fade where they are
        /// and the keyboard fades in.
        var released = false
    }

    /// How the last flight ended. Only the simulator's UI tests read it
    /// (in DEBUG, through the overlay's state element), to tell a piano
    /// that landed on the keyboard, swapping with it unseen, from one that
    /// was let go short of it and faded: both end with the keyboard shown.
    enum Outcome: Equatable, CustomStringConvertible {
        case landed(RollLayout)
        case crossfaded
        case released
        case cancelled
        case timedOut

        var description: String {
            switch self {
            case .landed(let layout): "landed on \(layout.rawValue)"
            case .crossfaded: "crossfaded"
            case .released: "released"
            case .cancelled: "cancelled"
            case .timedOut: "timed out"
            }
        }
    }

    private(set) var flight: Flight?

    /// Home's record button has started a take that is still starting (the
    /// microphone being asked for, the model loading). The transcription
    /// screen shows the roll for it from the tap, empty, rather than its
    /// empty state, because the piano lands on the roll's keyboard, which
    /// has to be there. Only for this take: one started from the empty
    /// state's own Start Listening button keeps the empty state until it is
    /// recording, as it always has, so a refused microphone never flips it
    /// to a blank roll and back under the alert, taking VoiceOver's focus
    /// off the button it was on.
    private(set) var startedTakeFromHome = false

    /// Set as a flight ends, with it: not observed on its own.
    @ObservationIgnored private(set) var lastOutcome: Outcome?

    /// The roll's keyboard is kept out of sight while the piano flies to it,
    /// so there is only ever one keyboard on screen.
    var hidesKeyboard: Bool {
        guard let flight else { return false }
        return flight.kind == .fly && !flight.released
    }

    // Where things are, in the window's (global) coordinates. Not observed:
    // only a flight reads them, and the keyboard reports often.
    @ObservationIgnored private(set) var recordButton: CGRect?
    @ObservationIgnored private(set) var window: CGRect = .zero
    @ObservationIgnored var safeArea = EdgeInsets()
    @ObservationIgnored private var keyboards: [RollLayout: CGRect] = [:]
    @ObservationIgnored private var keyboardScroll: [RollLayout: CGFloat] = [:]
    /// The record button was just tapped to start a take: only for the
    /// rest of that tap's handling.
    @ObservationIgnored private var recordTapped = false
    @ObservationIgnored private var flights = 0
    /// The flight's time, stepped by the overlay's frames; and which flight
    /// has been asked to land already.
    @ObservationIgnored private var clock = RecordFlightClock()
    @ObservationIgnored private var landing: Int?
    /// The push, waiting for the veil to cover Home (`whenVeiled`).
    @ObservationIgnored private var pushUnderVeil: (() -> Void)?

    /// The longest the flight waits under the veil for the push (which
    /// going back or the app leaving the screen may have overtaken): then
    /// it sets off anyway.
    static let launchTimeout: Double = 0.6

    // MARK: Home's side

    /// The record button, as it lays out.
    func recordButtonMoved(to frame: CGRect) {
        recordButton = frame
    }

    /// The record button was tapped while idle. Home handles the tap at
    /// once, starting the take and asking for the transcription screen,
    /// which is when `takeOff` asks; anything later (another screen's
    /// push) was not this tap's.
    func armRecordTap() {
        recordTapped = true
        Task { @MainActor [weak self] in self?.recordTapped = false }
    }

    /// Home asks for the transcription screen. A take the record button has
    /// just started flies (or, with Reduce Motion, crossfades); anything
    /// else is pushed as it always was. The caller pushes the screen after
    /// `RecordTakeOff.veilRise` for the first two, and says so
    /// (`screenPushed`).
    func takeOff(startedTake: Bool, layout: RollLayout, isPhoneLandscape: Bool, reduceMotion: Bool) -> RecordTakeOff {
        let tapped = recordTapped
        recordTapped = false
        let button = recordButton.flatMap { window.intersects($0) ? $0 : nil }
        let decision = RecordTakeOff.decide(recordTapped: tapped, startedTake: startedTake, inFlight: flight != nil,
                                            reduceMotion: reduceMotion, knowsRecordButton: button != nil)
        guard decision == .fly || decision == .crossfade else { return decision }
        startedTakeFromHome = true
        flights += 1
        let id = flights
        let known = keyboards[layout]
        let destination = known
            ?? RecordFlight.fallbackKeyboard(layout, in: window, safeArea: safeArea, isPhoneLandscape: isPhoneLandscape)
        let start = button ?? CGRect(x: window.midX, y: window.maxY, width: 0, height: 0)
        clock = RecordFlightClock()
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) {
            flight = Flight(id: id, kind: decision, layout: layout,
                            path: RecordFlight(start: CGPoint(x: start.midX, y: start.midY),
                                               startSide: min(start.width, start.height) * RecordButton.discRatio,
                                               destination: destination, bounds: window),
                            scrollY: keyboardScroll[layout] ?? 0, landsOnKeyboard: known != nil)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds((RecordTakeOff.veilRise + Self.launchTimeout) * Self.timeScale))
            self?.launch(id)
            // Whatever happens to the overlay's frames (the app leaving the
            // screen mid-flight), the keyboard comes back.
            try? await Task.sleep(for: .seconds((decision.duration + 1) * Self.timeScale))
            self?.finish(id, .timedOut)
        }
        return decision
    }

    /// Runs `push` just after the frame that first shows the veil whole,
    /// Home out of sight under it: the transcription screen goes under the
    /// veil then, and not by the wall clock. Pushing stalls the main thread,
    /// and the veil is drawn by the main thread; pushed a set time after
    /// the tap, a slow first frame or two could leave the veil part-risen
    /// for the length of the stall, Home showing through it, the piano
    /// flying over Home. `push` is the caller's own, so it can also make
    /// sure the push comes some other way (a timeout) if the veil never
    /// gets there.
    func whenVeiled(_ push: @escaping () -> Void) {
        pushUnderVeil = push
    }

    /// The transcription screen has just been pushed under the veil, which
    /// can clear once it is drawn. The push's stall comes next, before the
    /// screen is drawn; the veil's clock pauses for it.
    func screenPushed() {
        guard let flight else { return }
        launch(flight.id)
    }

    /// The transcription screen is under the veil: the veil clears to the
    /// roll from here.
    func launch(_ id: Int) {
        guard let current = flight, current.id == id, !current.launched, !current.released else { return }
        flight?.launched = true
    }

    /// Where the veil is (seconds of the transition's timing) for the frame
    /// drawn at `date`: the overlay asks once a frame. It waits at the end
    /// of the veil's rise until the screen is pushed, and stands still once
    /// the flight is let go (the veil fades where it is). A flight lands
    /// once the piano has flown its course and the veil has cleared; a
    /// crossfade once the veil has cleared.
    func time(at date: Date) -> Double {
        guard let current = flight else { return 0 }
        let limit = current.released ? clock.time
            : current.launched ? current.kind.duration : RecordTakeOff.veilRise
        let t = clock.tick(at: date.timeIntervalSinceReferenceDate, limit: limit, scale: Self.timeScale)
        if !current.launched, t >= RecordTakeOff.veilRise, let push = pushUnderVeil {
            // After this frame, which shows the veil whole, is committed.
            pushUnderVeil = nil
            DispatchQueue.main.async(execute: push)
        }
        let done = current.kind == .fly ? current.flown && t >= RecordTakeOff.veilCleared
            : t >= current.kind.duration
        if current.launched, !current.released, done, landing != current.id {
            // Not while the overlay is being drawn: just after this frame.
            landing = current.id
            let id = current.id
            DispatchQueue.main.async { [weak self] in self?.land(id) }
        }
        return t
    }

    /// The piano has flown its course (Core Animation says so): it lies on
    /// the keyboard's frame, and waits there for the veil to clear.
    func flown(_ id: Int) {
        guard let current = flight, current.id == id, !current.flown else { return }
        flight?.flown = true
    }

    /// The flight has run its course. On the keyboard, the piano is the
    /// keyboard's own drawing at its own size and place, so the two swap in
    /// one frame, with nothing animated. Short of it (the keyboard never
    /// said where it is), the piano fades out as the keyboard fades in.
    private func land(_ id: Int) {
        guard let current = flight, current.id == id, !current.released else { return }
        switch current.kind {
        case .fly where current.landsOnKeyboard: finish(id, .landed(current.layout))
        case .fly: release(id)
        default: finish(id, .crossfaded)
        }
    }

    /// Fades the piano and the veil out where they are and the keyboard in.
    private func release(_ id: Int) {
        guard let current = flight, current.id == id, !current.released else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            flight?.released = true
        } completion: { [weak self] in
            self?.finish(id, .released)
        }
    }

    /// Ends flight `id` at once, the keyboard shown.
    private func finish(_ id: Int, _ outcome: Outcome) {
        guard flight?.id == id else { return }
        lastOutcome = outcome
        // The push, if it is still waiting, comes by the caller's timeout.
        pushUnderVeil = nil
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { flight = nil }
    }

    /// The take is done starting, recording or not: the transcription
    /// screen goes back to showing the roll only for a take that has
    /// content or is recording.
    func takeDoneStarting() {
        if startedTakeFromHome { startedTakeFromHome = false }
    }

    /// Back on Home, or the app gone to the background: whatever is in the
    /// air goes at once.
    func cancel() {
        takeDoneStarting()
        guard let flight else { return }
        finish(flight.id, .cancelled)
    }

    /// The scene's phase changed. Only the background cancels a flight. An
    /// inactive app is still on screen and still drawing: the microphone's
    /// permission prompt makes it inactive straight after the first take's
    /// tap, as do Control Centre and Notification Centre pulled down over
    /// it. Cancelling then cut the first take's transition short to a grey
    /// flash and a hard push. A flight the app stops drawing for still ends
    /// by the safety timeout, and one whose take can't start by
    /// `takeFailed`, so the keyboard always comes back.
    func sceneChanged(to phase: ScenePhase) {
        if phase == .background { cancel() }
    }

    /// The take the record button started couldn't start after all (the
    /// microphone refused, or the recorder failed). There is no take to show
    /// and, on a fresh launch, no roll or keyboard for the piano to land on,
    /// only the empty state and its alert, so whatever is in the air is let
    /// go at once rather than flown to the empty state's corner: the piano
    /// and the veil fade where they are, whether or not it has set off.
    func takeFailed() {
        guard let flight else { return }
        release(flight.id)
    }

    /// The window, as the overlay over it lays out. Turned mid-flight (the
    /// width changes; the height also changes for a moment as the pushed
    /// screen sets its safe area), the record button and the keyboard are
    /// no longer where the path runs, so the piano is let go rather than
    /// flown somewhere wrong.
    func windowChanged(to frame: CGRect) {
        let old = window
        window = frame
        if let flight, old.width > 0, abs(old.width - frame.width) > 0.5 {
            release(flight.id)
        }
    }

    // MARK: The roll's side

    /// A keyboard laid out on the roll. The flight aims at it from then on
    /// (until then it aims at where the keyboard should be, which is where
    /// it turns out to be, so nothing moves). Frames off the window are a
    /// layout passing through, not the keyboard's place.
    func keyboardLaidOut(_ layout: RollLayout, frame: CGRect) {
        guard frame.width > 0, frame.height > 0, window.insetBy(dx: -1, dy: -1).contains(frame) else { return }
        keyboards[layout] = frame
        guard let current = flight, current.kind == .fly, !current.released, current.layout == layout else { return }
        if current.path.destination != frame { flight?.path.destination = frame }
        if !current.landsOnKeyboard { flight?.landsOnKeyboard = true }
    }

    /// The horizontal roll's keyboard scrolled through the 88 keys.
    func keyboardScrolled(_ layout: RollLayout, to y: CGFloat) {
        keyboardScroll[layout] = y
        if let current = flight, current.layout == layout, current.scrollY != y { flight?.scrollY = y }
    }

    /// A keyboard left the screen. One being flown to (the take couldn't
    /// start, so the roll gave way to its empty state) lets the piano go.
    func keyboardGone(_ layout: RollLayout) {
        keyboards[layout] = nil
        keyboardScroll[layout] = nil
        if let current = flight, current.layout == layout, current.landsOnKeyboard {
            release(current.id)
        }
    }

    // MARK: Simulator aids

    /// Real time per second of the transition's own timing: 1, except in
    /// DEBUG under -semitone-record-transition-slow <factor>, for UI tests
    /// that must act mid-flight (XCUITest waits for each tap to settle).
    static var timeScale: Double {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-semitone-record-transition-slow"),
           arguments.indices.contains(index + 1), let factor = Double(arguments[index + 1]), factor >= 1 {
            return factor
        }
        #endif
        return 1
    }

    #if DEBUG
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    /// -semitone-record-transition-demo: Home's record button plays the
    /// transition and shows an empty take as if it were being recorded,
    /// without the microphone (the simulator can't reliably record).
    static let isDemo = arguments.contains("-semitone-record-transition-demo") || autoTaps

    /// -semitone-record-transition-autotap: the demo, with the record tap
    /// made 1.5 s after launch, for screen recordings of the transition.
    static let autoTaps = arguments.contains("-semitone-record-transition-autotap")

    /// -semitone-reduce-motion: the transition as Reduce Motion has it (a
    /// UI test can't turn the setting on).
    static let forcesReduceMotion = arguments.contains("-semitone-reduce-motion")

    /// -semitone-record-transition-deny: the demo's record tap fails as a
    /// real one does with the microphone refused, for the transition's
    /// failure path (the simulator never asks for the microphone).
    static let deniesMicrophone = arguments.contains("-semitone-record-transition-deny")

    /// The overlay's state element's value, for UI tests: "idle" (with how
    /// the last flight ended, if there was one) or "flying" (with its kind,
    /// and whether the keyboard is out of sight for it).
    var debugState: String {
        guard let flight else {
            return lastOutcome.map { "idle, \($0)" } ?? "idle"
        }
        let kind = flight.kind == .fly ? "fly" : "crossfade"
        return "flying (\(kind))" + (hidesKeyboard ? ", keyboard hidden" : "")
    }
    #endif
}

extension RecordFlight {
    /// Where a keyboard will be before it has said so (the roll lays out a
    /// frame after the push): the horizontal roll's down the left edge from
    /// below the navigation bar and the roll's header to the bottom of the
    /// screen; the falling notes' along the bottom above the home indicator.
    static func fallbackKeyboard(_ layout: RollLayout, in window: CGRect, safeArea: EdgeInsets,
                                 isPhoneLandscape: Bool) -> CGRect {
        switch layout {
        case .horizontal:
            let top = window.minY + safeArea.top + navigationBarHeight + PianoRollView.headerHeight
            return CGRect(x: window.minX + safeArea.leading, y: top,
                          width: PianoRollView.keyboardWidth, height: max(window.maxY - top, 1))
        case .falling:
            let height = isPhoneLandscape ? FallingGeometry.landscapeKeyboardHeight : FallingGeometry.keyboardHeight
            return CGRect(x: window.minX + safeArea.leading, y: window.maxY - safeArea.bottom - height,
                          width: max(window.width - safeArea.leading - safeArea.trailing, 1), height: height)
        }
    }

    /// The inline navigation bar over the transcription screen (iOS 26's,
    /// with its glass controls).
    static let navigationBarHeight: CGFloat = 54
}

// MARK: - The overlay

/// Over the whole navigation stack: the veil and the flying piano. It never
/// takes a touch (the take can be stopped, or the screen left, mid-flight)
/// and VoiceOver never meets it: its focus goes to the transcription
/// screen as it always did.
struct RecordFlightOverlay: View {
    let transition: RecordTransition

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let flight = transition.flight {
                // The veil, every frame while anything is in the air, and
                // only then.
                TimelineView(.animation) { context in
                    let t = transition.time(at: context.date)
                    HomeTheme.ground
                        .opacity(flight.released ? 0 : flight.kind.veil(at: t))
                }
                .id(flight.id)
                if flight.kind == .fly {
                    // Over the veil: the disc and the piano, flown by Core
                    // Animation, posed only when the flight changes.
                    RecordFlightPianoLayer(flight: flight, origin: transition.window.origin) { id in
                        transition.flown(id)
                    }
                    .id(flight.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { transition.windowChanged(to: $0) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if RecordTransition.isDemo {
                // For UI tests: whether anything is still in the air, and
                // whether the keyboard is out of sight for it.
                Text("Record transition")
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("record-transition-state")
                    .accessibilityValue(transition.debugState)
            }
        }
        #endif
    }
}

// MARK: - The keyboard's side

extension View {
    /// The roll's keyboard (`layout`'s): says where it is, and how far its
    /// keys are scrolled, for the record transition to fly to, and keeps
    /// out of sight while the piano is on its way.
    func recordTransitionKeyboard(_ layout: RollLayout, scrollY: CGFloat = 0) -> some View {
        modifier(RecordTransitionKeyboard(layout: layout, scrollY: scrollY))
    }
}

private struct RecordTransitionKeyboard: ViewModifier {
    let layout: RollLayout
    let scrollY: CGFloat
    @Environment(RecordTransition.self) private var transition: RecordTransition?

    func body(content: Content) -> some View {
        let hidden = transition?.hidesKeyboard ?? false
        content
            // Out of sight only: VoiceOver's keyboard element stays, so its
            // focus lands on the transcription screen as it always has.
            .opacity(hidden ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                transition?.keyboardLaidOut(layout, frame: frame)
            }
            .onChange(of: scrollY, initial: true) { transition?.keyboardScrolled(layout, to: scrollY) }
            .onDisappear { transition?.keyboardGone(layout) }
            #if DEBUG
            .overlay {
                if RecordTransition.isDemo {
                    // For UI tests: whether the keyboard is drawn or out of
                    // sight. Its own element stays either way (see above),
                    // so it can't tell them; this one, outside the opacity,
                    // reports the very flag that sets it.
                    Text("Keyboard")
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("record-transition-keyboard-\(layout.rawValue)")
                        .accessibilityValue(hidden ? "hidden" : "shown")
                }
            }
            #endif
    }
}
