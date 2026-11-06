import SwiftUI
import UIKit

/// Sizes and the time and pitch mapping of the horizontal roll.
nonisolated struct RollGeometry: Equatable {
    var pxPerSecond: CGFloat = 110
    /// One row per semitone. 15 pt (it was 14) with 56 pt keys: a little
    /// bigger all round, while a Song take's usual range (about three octaves)
    /// still fits on an iPhone during playback.
    var rowHeight: CGFloat = 15
    var minPitch = 21   // A0
    var maxPitch = 108  // C8
    /// The play line, this far right of the keyboard: none (it was 8 pt), so
    /// the notes run straight into the keys and a key lights as its note's
    /// start reaches it. Playback starts here, the play marker stays here
    /// while playing, and snapped beat lines park here.
    var playLineInset: CGFloat = 0

    /// The play marker: 3 pt of the brand navy at 70 % (#576275, 6.2:1 on
    /// white; darker than the bar lines, at 55 %), so the notes show through
    /// it, its left edge on the play line, against the keys.
    static let markerWidth: CGFloat = 3
    static let markerOpacity = 0.7

    var rowCount: Int { maxPitch - minPitch + 1 }
    var rollHeight: CGFloat { CGFloat(rowCount) * rowHeight }
    /// Key and note names grow with the rows (8 pt at 14 pt rows).
    var labelSize: CGFloat { rowHeight * 8 / 14 }

    /// Row top within the roll.
    func yFor(pitch: Int) -> CGFloat { CGFloat(maxPitch - pitch) * rowHeight }

    /// Scroll offset that parks time `t` on the play line.
    func offsetX(forTime t: Double) -> CGFloat { CGFloat(t) * pxPerSecond - playLineInset }

    /// The time on the play line at scroll offset `x`.
    func time(atOffsetX x: CGFloat) -> Double { Double((x + playLineInset) / pxPerSecond) }

    func contains(_ pitch: Int) -> Bool { pitch >= minPitch && pitch <= maxPitch }

    static let blackKeys: Set<Int> = [1, 3, 6, 8, 10]
    static func isBlack(_ pitch: Int) -> Bool { blackKeys.contains(pitch % 12) }

    /// Note names are drawn on bars wider than this, centred this far in.
    static let labelMinWidth: CGFloat = 26
    static let labelCenterInset: CGFloat = 13

    /// The vertical offset that brings `pitches` (the notes about to play)
    /// comfortably on screen from `y`, or nil when they already are. Moves
    /// leave some headroom so the roll doesn't creep a row at a time. A range
    /// that fits only without its margins is centred; one taller than the
    /// screen centres where most of its notes are.
    static func registerTarget(pitches: [Int], from y: CGFloat, viewportHeight height: CGFloat,
                               maxScrollY: CGFloat, geometry g: RollGeometry) -> CGFloat? {
        guard let lo = pitches.min(), let hi = pitches.max(), height > 0 else { return nil }
        let margin = g.rowHeight
        let headroom = 3 * g.rowHeight
        let top = g.yFor(pitch: hi), bottom = g.yFor(pitch: lo) + g.rowHeight
        let span = bottom - top
        var target: CGFloat
        if span <= height - 2 * margin {
            if top >= y + margin, bottom <= y + height - margin { return nil }
            if top < y + margin {
                // Move up, with headroom above, but never lose the lowest note.
                target = max(top - margin - headroom, bottom + margin - height)
            } else {
                target = min(bottom + margin + headroom - height, top - margin)
            }
        } else if span <= height {
            if top >= y, bottom <= y + height { return nil }
            target = (top + bottom) / 2 - height / 2
        } else {
            let sorted = pitches.sorted()
            target = g.yFor(pitch: sorted[sorted.count / 2]) + g.rowHeight / 2 - height / 2
        }
        let clamped = min(max(target, 0), maxScrollY)
        return abs(clamped - y) < 0.5 ? nil : clamped
    }
}

struct PianoRollView: View {
    let notes: [NoteEvent]
    let chords: [ChordSegment]
    let duration: Double
    let isLive: Bool
    /// The playback clock while playing, nil when stopped. The roll reads it
    /// once per display frame; nothing about playback re-renders this view.
    var clock: PlaybackClock? = nil
    /// Beat grid overlay (optional).
    var beatTimes: [Double] = []
    var downbeatTimes: [Double] = []
    /// Called with the time at the play line as the user scrolls while stopped,
    /// so playback starts wherever the roll was dragged to. `settled` is true
    /// once the roll comes to rest.
    var onCue: ((_ time: Double, _ settled: Bool) -> Void)? = nil
    /// A drag through time began during playback: hold the sound, as the
    /// falling notes do, so the drag scrubs.
    var onHold: (() -> Void)? = nil
    /// The held drag came to rest: play on from the play line (or, if
    /// playback was stopped meanwhile, cue there).
    var onResume: ((_ time: Double) -> Void)? = nil
    /// The moment to put on the play line when the roll appears while
    /// stopped: the cue, which the falling notes showed on their hit line
    /// before the roll flipped back or the phone turned upright.
    var cue: Double = 0
    /// Whether the user has picked where play starts while stopped
    /// (`TranscriberViewModel.cueChosen`): the marker then shows it against
    /// the keys. Otherwise it waits behind them, so the notes on the play
    /// line meet the keys.
    var cueChosen = false
    /// The user dragged the roll through time while stopped: they have
    /// picked where play starts.
    var onChooseCue: (() -> Void)? = nil

    private let geometry = RollGeometry()
    /// Pinned keyboard on the left and chord / bar header on top.
    static let keyboardWidth: CGFloat = 56
    static let headerHeight: CGFloat = 34

    @State private var scrollPosition = ScrollPosition()
    /// Size of the scrolling area (right of the keyboard, below the header,
    /// inside the safe area).
    @State private var viewport: CGSize = .zero
    @State private var live = RollLive()
    @State private var follower = RollFollower()
    @State private var index = NoteTimeIndex([])
    /// From touch-down until the roll comes to rest: whether the user started
    /// scrolling while stopped (not playing or recording).
    @State private var scrollStartedStopped: Bool?
    /// Where the roll was when a drag began during playback, to tell a drag
    /// through time (which holds the sound) from one only up or down.
    @State private var playingDragStartX: CGFloat?
    /// Where the roll was when a drag began while stopped, until the finger
    /// has moved it through time (the user picking where play starts; a drag
    /// only up or down picks nothing) or lifts.
    @State private var cueDragStartX: CGFloat?
    /// A drag through time is holding playback, until the roll comes to rest.
    @State private var scrubHeld = false
    /// The live follower's own idea of the current vertical offset.
    @State private var followY: CGFloat?
    /// Until the roll has first been put on its moment: the cue when stopped,
    /// the clock when it appears mid-play.
    @State private var placed = false

    private var isPlaying: Bool { clock != nil }

    var body: some View {
        // Header above and keyboard beside the scroll view (not floating over
        // it), so the scroll view never runs under the navigation bar and
        // picks up hidden content insets that would misalign the keyboard.
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(RollTheme.surface)
                    .frame(width: Self.keyboardWidth)
                    .overlay(alignment: .bottom) { Rectangle().fill(RollTheme.hairline).frame(height: 0.5) }
                RollHeader(live: live, chords: chords, downbeatTimes: downbeatTimes, geometry: geometry)
            }
            .frame(height: Self.headerHeight)

            HStack(spacing: 0) {
                // Down to the bottom edge, like the scroll view beside it,
                // which runs under the home indicator.
                RollKeyboard(live: live, index: index, isLive: isLive, duration: duration, geometry: geometry)
                    .frame(width: Self.keyboardWidth)
                    .ignoresSafeArea(.container, edges: .bottom)
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        RollContent(notes: notes, chords: chords, beatTimes: beatTimes, downbeatTimes: downbeatTimes,
                                    width: rollWidth, liveEdge: isLive ? duration : nil, geometry: geometry)
                            .equatable()
                            .rollSwitchAction()
                            .overlay(alignment: .topLeading) {
                                PinnedNoteNames(live: live, index: index, beatTimes: beatTimes,
                                                downbeatTimes: downbeatTimes, chords: chords, geometry: geometry)
                            }
                            .overlay(alignment: .topLeading) {
                                PlayheadLine(live: live, geometry: geometry)
                            }
                            #if DEBUG
                            .overlay(alignment: .topLeading) {
                                if RegressionUIFixture.selected != nil {
                                    PlayLineProbe(live: live, geometry: geometry)
                                }
                            }
                            #endif
                            .background(DirectionalScrollLock())
                            .background(ScrollViewFinder { scrollView in
                                follower.scrollView = scrollView
                                placeOnAppear()
                            })
                    }
                    .accessibilityIdentifier("piano-roll-scroll")
                    .overlay(alignment: .leading) {
                        // Where play will start, while stopped: out against
                        // the keys once the user has picked a spot.
                        if !isLive, !isPlaying, !notes.isEmpty {
                            CueMarker(out: cueChosen)
                                .padding(.leading, geometry.playLineInset)
                                // Down to the bottom edge, as the keys and the notes run.
                                .ignoresSafeArea(.container, edges: .bottom)
                        }
                    }
                    // For the user's own flicks only: the playback follow sets
                    // the offset directly and never passes through it.
                    .scrollTargetBehavior(BeatSnapBehavior(
                        beatOffsets: beatTimes.map(geometry.offsetX(forTime:)),
                        measureOffsets: downbeatTimes.map(geometry.offsetX(forTime:))
                    ))
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: CGPoint.self) { geometry in
                        CGPoint(x: geometry.contentOffset.x + geometry.contentInsets.leading,
                                y: geometry.contentOffset.y + geometry.contentInsets.top)
                    } action: { _, offset in
                        if live.scroll != offset { live.scroll = offset }
                        if scrubHeld {
                            // The play marker and lit keys show what's on the play line.
                            if live.time != cueTime { live.time = cueTime }
                        } else if let startX = playingDragStartX, isPlaying,
                                  abs(offset.x - startX) > Self.scrubSlop {
                            holdForScrub()
                        }
                        if let startX = cueDragStartX, !isPlaying, abs(offset.x - startX) > Self.scrubSlop {
                            cueDragStartX = nil
                            onChooseCue?()
                        }
                        // Keep the start spot current as the roll moves, so play
                        // pressed while a flick is still gliding starts where it shows.
                        if scrollStartedStopped != nil, !isLive, !isPlaying { onCue?(cueTime, false) }
                    }
                    .onScrollPhaseChange { _, newPhase in
                        if newPhase == .interacting {
                            follower.holdUntil = .infinity
                            followY = nil
                            scrollStartedStopped = !isLive && !isPlaying
                            playingDragStartX = isPlaying && !isLive ? live.scroll.x : nil
                            cueDragStartX = !isLive && !isPlaying && !cueChosen ? live.scroll.x : nil
                        } else {
                            // Only the finger picks a spot: once it lifts, a glide
                            // or the beat snap (which can move the roll onto a beat
                            // after a drag only up or down) picks nothing.
                            cueDragStartX = nil
                        }
                        if newPhase == .idle, scrollStartedStopped != nil {
                            scrollStartedStopped = nil
                            playingDragStartX = nil
                            if scrubHeld { resumeAfterScrub() }
                            // During playback (play pressed before the roll came to
                            // rest, a scrub playing on, or a drag only up or down):
                            // follow at once. Stopped or recording, give the user a
                            // moment before the follow takes the roll back.
                            follower.holdUntil = isPlaying ? 0 : CACurrentMediaTime() + 2.5
                            if !isLive, !isPlaying { onCue?(cueTime, true) }
                        }
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.width } action: { _, _ in
                        placeOnAppear()
                    }
                    .onAppear { viewport = geo.size }
                    .onChange(of: geo.size) { viewport = geo.size }
                }
            }
        }
        .onChange(of: followConfig, initial: true) {
            follower.config = followConfig
            placeOnAppear()
        }
        .onChange(of: viewport) { old, _ in
            follower.config = followConfig
            if old != .zero { resized() }
        }
        .onChange(of: duration) { if isLive { followLive(now: duration) } }
        .onChange(of: cue) { _, t in cueMoved(to: t) }
        .onChange(of: isPlaying) { _, playing in
            if playing, let clock, !isLive {
                // Pressing play means the user has picked the spot: follow at once.
                follower.start(clock: clock, live: live)
            } else if !playing {
                // Stopped (a new take stops playback too): the live follow takes over.
                follower.stop()
                if !isLive { playbackStopped() }
            }
        }
        .onChange(of: notes, initial: true) { _, _ in
            index = NoteTimeIndex(notes)
            // Not before the roll is first placed: its scroll position isn't
            // its own yet, and an animated reveal from there would carry it
            // off the cue (placing it brings the notes into view anyway).
            if isLive { followLive(now: duration) } else if !isPlaying, placed { revealNotesOnScreen() }
        }
        .onDisappear {
            follower.stop()
            // Gone mid-scrub (the phone turned on its side): don't leave playback held.
            if scrubHeld { resumeAfterScrub() }
        }
    }

    /// How far sideways a drag during playback moves the roll before it
    /// counts as a drag through time. The scroll view locks a drag to one
    /// direction, so one up or down doesn't move it sideways at all.
    private static let scrubSlop: CGFloat = 4

    /// A drag during playback has moved the roll through time: hold the
    /// sound and let the drag scrub, as on the falling notes. (One rule for
    /// both layouts: before, the horizontal roll played on under the drag
    /// and glided back 2.5 s after it.)
    private func holdForScrub() {
        scrubHeld = true
        follower.scrubbing = true
        onHold?()
        if live.time != cueTime { live.time = cueTime }
    }

    /// The held drag came to rest: play on from the play line.
    private func resumeAfterScrub() {
        scrubHeld = false
        follower.scrubbing = false
        // Stopped meanwhile: the drag kept the playing marker and the lit
        // keys on the play line; nothing else takes them away now.
        if !isPlaying { live.time = nil }
        onResume?(cueTime)
    }

    private var followConfig: RollFollower.Config {
        RollFollower.Config(geometry: geometry, index: index, maxScrollX: maxScrollX, maxScrollY: maxScrollY,
                            viewportHeight: viewport.height)
    }

    /// While recording the live edge stays near the right side. Otherwise a
    /// screen of room follows the last note, so any moment, the end included,
    /// can be dragged to the play line.
    private var rollWidth: CGFloat {
        max(CGFloat(duration) * geometry.pxPerSecond + (isLive ? 40 : max(viewport.width, 40)), 300)
    }

    /// Time under the play line (0 when scrolled all the way left, or within
    /// half a point of it).
    private var cueTime: Double {
        guard live.scroll.x > 0.5 else { return 0 }
        return min(max(geometry.time(atOffsetX: live.scroll.x), 0), duration)
    }

    private var maxScrollX: CGFloat { max(0, rollWidth - viewport.width) }
    private var maxScrollY: CGFloat { max(0, geometry.rollHeight - viewport.height) }

    /// The roll appeared (a take opened, the falling notes flipped back, the
    /// phone turned upright): once its scroll view is laid out, put the cue
    /// on the play line with the notes around it in view, or pick playback
    /// up where it is. Not while recording: the live follow has the roll.
    private func placeOnAppear() {
        guard !placed else { return }
        if isLive {
            placed = true
            return
        }
        guard let scrollView = follower.scrollView, viewport.width > 0, viewport.height > 0,
              follower.config.viewportHeight == viewport.height,
              scrollView.contentSize.width >= rollWidth - 1 else { return }
        placed = true
        if let clock {
            follower.start(clock: clock, live: live, jump: true)
        } else {
            follower.show(cue, live: live)
        }
    }

    /// The roll changed size once on screen (it appeared mid-turn, or the
    /// text size changed): keep the moment on the play line, with the notes
    /// around it brought into view for the new height.
    private func resized() {
        guard placed, !isLive, !isPlaying, scrollStartedStopped == nil, !follower.isHolding else { return }
        follower.show(cueTime, live: live)
    }

    /// The cue moved from outside while stopped (a take opened, a fixture's
    /// start): show it, unless the roll put it there itself or the user has
    /// the roll in hand.
    private func cueMoved(to t: Double) {
        guard placed, !isLive, !isPlaying, scrollStartedStopped == nil, !follower.isHolding,
              abs(t - cueTime) > 0.02 else { return }
        follower.show(t, live: live)
    }

    /// Playback stopped: the follow left the stop time on the play line,
    /// where play resumes. If the user had scrolled away, play resumes from
    /// what's on screen instead.
    private func playbackStopped() {
        if follower.isHolding {
            onCue?(cueTime, true)
        } else {
            follower.park()
        }
    }

    private func followLive(now: Double) {
        guard !follower.isHolding else { return }
        let current = followY ?? live.scroll.y
        let pitches = index.notes(overlapping: max(0, now - 3)...now).map(\.pitch).filter(geometry.contains)
        let target = RollGeometry.registerTarget(pitches: pitches, from: current, viewportHeight: viewport.height,
                                                 maxScrollY: maxScrollY, geometry: geometry) ?? current
        followY = target
        // Live updates arrive a few times a second, so animate each one fully.
        withAnimation(.easeInOut(duration: target == current ? 0.1 : 0.45)) {
            scrollPosition.scrollTo(point: CGPoint(x: maxScrollX, y: target))
        }
    }

    /// A finished take appeared (or was replaced): if none of the notes in
    /// view are visible vertically, bring them into view once.
    private func revealNotesOnScreen() {
        guard !follower.isHolding, viewport.height > 0 else { return }
        let t0 = Double(max(0, live.scroll.x) / geometry.pxPerSecond)
        let t1 = t0 + Double(viewport.width / geometry.pxPerSecond)
        let pitches = index.notes(overlapping: t0...t1).map(\.pitch).filter(geometry.contains)
        guard let target = RollGeometry.registerTarget(pitches: pitches, from: live.scroll.y,
                                                       viewportHeight: viewport.height, maxScrollY: maxScrollY,
                                                       geometry: geometry) else { return }
        followY = target
        withAnimation(.easeInOut(duration: 0.45)) {
            scrollPosition.scrollTo(point: CGPoint(x: live.scroll.x, y: target))
        }
    }
}

// MARK: - Playback follow

/// Moves the roll once per display frame while playing. The offset is set
/// directly on the scroll view, from the playback time at the moment the
/// frame reaches the screen: no animation (overlapping 120 ms glides are what
/// made the old follow uneven) and no scroll target behaviour (the beat snap
/// parked the old follow on beat lines, then it leapt). Stands down while the
/// user holds or flings the roll; once it comes to rest, glides back onto the
/// play line (a drag through time has held playback meanwhile, and it plays
/// on from there, so there is nothing to glide).
@MainActor
final class RollFollower {
    nonisolated struct Config: Equatable {
        var geometry = RollGeometry()
        var index = NoteTimeIndex([])
        var maxScrollX: CGFloat = 0
        var maxScrollY: CGFloat = 0
        var viewportHeight: CGFloat = 0

        static func == (a: Config, b: Config) -> Bool {
            a.geometry == b.geometry && a.index.notes == b.index.notes && a.maxScrollX == b.maxScrollX
                && a.maxScrollY == b.maxScrollY && a.viewportHeight == b.viewportHeight
        }

        func goalX(at t: Double) -> CGFloat {
            min(max(geometry.offsetX(forTime: t), 0), maxScrollX)
        }

        /// What's on screen during playback: the notes sounding on the play
        /// line, at the keys, to three seconds ahead. (Nothing behind the
        /// line shows since it moved against the keys.)
        func registerTarget(at t: Double, from y: CGFloat) -> CGFloat? {
            let pitches = index.notes(overlapping: t...(t + 3.0)).map(\.pitch).filter(geometry.contains)
            return RollGeometry.registerTarget(pitches: pitches, from: y, viewportHeight: viewportHeight,
                                               maxScrollY: maxScrollY, geometry: geometry)
        }
    }

    /// How long the glide back onto the play line takes after the user lets go.
    static let glideBack: CFTimeInterval = 0.35
    /// Time constant of the register (vertical) moves: settles in about 0.7 s.
    static let registerTau: CFTimeInterval = 0.22

    weak var scrollView: UIScrollView?
    var config = Config()
    /// A drag through time holds playback: the roll and the play marker
    /// follow the finger, not the (stopped) clock.
    var scrubbing = false
    /// Host time until which the follow stands down (the user scrolled).
    var holdUntil: CFTimeInterval = 0
    var isHolding: Bool { CACurrentMediaTime() < holdUntil }

    private let ticker = FrameTicker()
    private weak var clock: PlaybackClock?
    private weak var live: RollLive?
    private var lastShownAt: CFTimeInterval = 0
    private var glide: (from: CGFloat, start: CFTimeInterval)?
    private var registerGoal: CGFloat?
    private var followY: CGFloat?
    /// Set when following (re)starts: decide once how to get onto the play line.
    private var resuming = true
    /// Playback starts a hair before the cue: hold until the play line catches up.
    private var holdingAhead = false
    /// The roll appeared mid-play: the first frame puts it on the play line
    /// and the notes in view at once, rather than gliding there from 0:00.
    private var jumping = false

    /// `jump`: the roll has only just appeared, so there is nothing on
    /// screen to glide from.
    func start(clock: PlaybackClock, live: RollLive, jump: Bool = false) {
        self.clock = clock
        self.live = live
        holdUntil = 0
        glide = nil
        registerGoal = nil
        followY = nil
        resuming = !jump
        jumping = jump
        holdingAhead = false
        lastShownAt = 0
        // Play pressed while a flick still glides: playback starts where the
        // roll showed, so stop it there.
        if let scrollView, scrollView.isDecelerating, !scrollView.isTracking {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        ticker.onFrame = { [weak self] shownAt, frameDuration in self?.frame(shownAt: shownAt, frameDuration: frameDuration) }
        ticker.start()
    }

    func stop() {
        ticker.stop()
        live?.time = nil
    }

    /// Puts `t` on the play line at once, with the notes around it in view:
    /// no animation, and not through the beat snap, which could move the cue.
    func show(_ t: Double, live: RollLive) {
        guard let scrollView else { return }
        let inset = scrollView.adjustedContentInset
        let currentY = scrollView.contentOffset.y + inset.top
        let target = CGPoint(x: config.goalX(at: t), y: config.registerTarget(at: t, from: currentY) ?? currentY)
        scrollView.contentOffset = CGPoint(x: target.x - inset.left, y: target.y - inset.top)
        if live.scroll != target { live.scroll = target }
    }

    /// After a stop, puts the stop time exactly on the play line (the follow
    /// left it within a frame of it).
    func park() {
        guard let clock, let scrollView else { return }
        let inset = scrollView.adjustedContentInset
        let x = config.goalX(at: clock.time(at: CACurrentMediaTime()))
        let target = CGPoint(x: x - inset.left, y: scrollView.contentOffset.y)
        scrollView.setContentOffset(target, animated: abs(target.x - scrollView.contentOffset.x) > 2)
    }

    private func frame(shownAt: CFTimeInterval, frameDuration: CFTimeInterval) {
        guard let clock, let live else { return }
        if scrubbing {
            lastShownAt = 0
            glide = nil
            followY = nil
            registerGoal = nil
            resuming = true
            holdingAhead = false
            return
        }
        let t = clock.time(at: shownAt)
        let dt = lastShownAt == 0 ? frameDuration : shownAt - lastShownAt
        lastShownAt = shownAt
        guard let sv = scrollView else {
            if live.time != t { live.time = t }
            return
        }

        let inset = sv.adjustedContentInset
        let current = CGPoint(x: sv.contentOffset.x + inset.left, y: sv.contentOffset.y + inset.top)
        if sv.isUserMoving || CACurrentMediaTime() < holdUntil {
            if live.time != t { live.time = t }
            glide = nil
            followY = nil
            registerGoal = nil
            resuming = true
            holdingAhead = false
            return
        }
        let goalX = config.goalX(at: t)
        var x = goalX
        if jumping {
            jumping = false
            followY = config.registerTarget(at: t, from: current.y) ?? current.y
        }
        if resuming {
            resuming = false
            if abs(goalX - current.x) > 0.5 {
                // Playback starts a hair before the cue: hold rather than nudge back.
                if current.x > goalX, current.x - goalX < 12 {
                    holdingAhead = true
                } else {
                    glide = (current.x, shownAt)
                }
            }
        }
        if holdingAhead {
            if goalX >= current.x { holdingAhead = false } else { x = current.x }
        }
        // The play marker and the lit keys hold with the roll: they show
        // the moment on the play line, not the sequencer's early start
        // 60 ms before it (as the falling notes do).
        let shown = holdingAhead ? max(t, config.geometry.time(atOffsetX: x)) : t
        if live.time != shown { live.time = shown }
        if let g = glide {
            let length = UIAccessibility.isReduceMotionEnabled ? 0 : Self.glideBack
            let p = length > 0 ? min(max((shownAt - g.start) / length, 0), 1) : 1
            x = g.from + (goalX - g.from) * CGFloat(Self.smoothstep(p))
            if p >= 1 { glide = nil }
        }
        let y = registerY(t: t, dt: dt, currentY: current.y)
        let offset = CGPoint(x: x, y: y)
        sv.contentOffset = CGPoint(x: x - inset.left, y: y - inset.top)
        // The header and keyboard draw from this in the same frame.
        if live.scroll != offset { live.scroll = offset }
    }

    nonisolated static func smoothstep(_ p: Double) -> Double { p * p * (3 - 2 * p) }

    /// Per-frame vertical position: holds still until the notes about to
    /// play would leave the screen, then eases (not jumps) to a position that
    /// shows them with some headroom.
    private func registerY(t: Double, dt: CFTimeInterval, currentY: CGFloat) -> CGFloat {
        let current = followY ?? currentY
        if registerGoal == nil, let needed = config.registerTarget(at: t, from: current) {
            registerGoal = needed
        }
        guard let goal = registerGoal else {
            followY = current
            return current
        }
        // Time-based exponential approach, the same at any frame rate.
        let blend = CGFloat(1 - exp(-min(max(dt, 0), 0.1) / Self.registerTau))
        let next = abs(goal - current) < 0.5 ? goal : current + (goal - current) * blend
        if next == goal { registerGoal = nil }
        followY = next
        return next
    }
}

// MARK: - Per-frame pieces

/// The play marker during playback, in the roll's content so it moves
/// exactly with the notes: its left edge on the playing moment, which the
/// follow keeps on the play line, against the keys. When playback stops it
/// tucks back behind the keys (it slides left out of the roll as it fades;
/// with Reduce Motion it only fades).
private struct PlayheadLine: View {
    let live: RollLive
    let geometry: RollGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let time = live.time
        ZStack(alignment: .topLeading) {
            if let t = time {
                Rectangle()
                    .fill(RollTheme.navy.opacity(RollGeometry.markerOpacity))
                    .frame(width: RollGeometry.markerWidth, height: geometry.rollHeight)
                    .offset(x: CGFloat(t) * geometry.pxPerSecond)
                    .transition(.asymmetric(insertion: .identity, removal: reduceMotion ? Self.fade : Self.tuck))
                    .allowsHitTesting(false)
                    #if DEBUG
                    // UI tests check it stays on the play line while the roll follows.
                    .accessibilityElement()
                    .accessibilityLabel("Playhead")
                    .accessibilityIdentifier("roll-playhead")
                    .accessibilityHidden(RegressionUIFixture.selected == nil)
                    #else
                    .accessibilityHidden(true)
                    #endif
            }
        }
        // Only the stop animates: the moment moving on every frame doesn't.
        .animation(.easeOut(duration: CueMarker.tuckDuration), value: time == nil)
    }

    private static let tuck = AnyTransition.opacity.combined(with: .offset(x: -RollGeometry.markerWidth))
    private static let fade = AnyTransition.opacity
}

/// The play marker while stopped, over the roll at the play line. Once the
/// user has picked where play starts (`out`) it shows it, against the keys;
/// otherwise it waits behind them, so the notes on the play line meet the
/// keys. It comes out from under the keys as it fades in (with Reduce Motion
/// it only fades).
private struct CueMarker: View {
    let out: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long the marker takes to come out from behind the keys, or to
    /// tuck back behind them.
    static let tuckDuration = 0.2

    var body: some View {
        Rectangle()
            .fill(RollTheme.navy.opacity(RollGeometry.markerOpacity))
            .offset(x: out || reduceMotion ? 0 : -RollGeometry.markerWidth)
            .opacity(out ? 1 : 0)
            // Clipped at the keyboard's edge, so the part not yet out is under the keys.
            .frame(width: RollGeometry.markerWidth, alignment: .leading)
            .clipped()
            .animation(.easeOut(duration: Self.tuckDuration), value: out)
            .allowsHitTesting(false)
            #if DEBUG
            // UI tests check when it comes out and when it stays tucked away.
            .accessibilityElement()
            .accessibilityLabel("Play marker")
            .accessibilityValue(out ? "Out" : "Behind the keys")
            .accessibilityIdentifier("roll-cue-marker")
            .accessibilityHidden(RegressionUIFixture.selected == nil)
            #else
            .accessibilityHidden(true)
            #endif
    }
}

#if DEBUG
/// The time on the play line, for UI tests (fixtures only): the roll's notes
/// are drawn, and a lazy stack's frame covers only the tiles it has built.
private struct PlayLineProbe: View {
    let live: RollLive
    let geometry: RollGeometry

    var body: some View {
        // Not during playback: a value changing every frame keeps UI tests
        // waiting for the app to settle (they read the play marker then).
        if live.time == nil {
            probe
        }
    }

    private var probe: some View {
        let x = max(live.scroll.x, 0)
        return Color.clear
            .frame(width: 1, height: 1)
            .offset(x: x, y: max(live.scroll.y, 0))
            .accessibilityElement()
            .accessibilityLabel("Play line")
            .accessibilityValue(Text(verbatim: String(format: "%.3f", geometry.time(atOffsetX: x))))
            .accessibilityIdentifier("roll-play-line")
            .allowsHitTesting(false)
    }
}
#endif

/// Chord names and bar numbers, pinned above the roll. They are drawn once,
/// in tiles that only move with the roll (redrawing them every frame was the
/// biggest per-frame cost left); only the name kept at the left edge is drawn
/// per frame.
private struct RollHeader: View {
    let live: RollLive
    let chords: [ChordSegment]
    let downbeatTimes: [Double]
    let geometry: RollGeometry
    @State private var labels = ChordLabels(chords: [], pxPerSecond: 110)
    @State private var width: CGFloat = 0

    var body: some View {
        let scrollX = live.scroll.x
        let first = max(0, Int((scrollX / HeaderTile.width).rounded(.down)))
        let last = max(first, Int(((scrollX + width) / HeaderTile.width).rounded(.down)))
        // The tiles live in an overlay, so their size never moves the layout.
        RollTheme.surface
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(first...last, id: \.self) { index in
                        HeaderTile(index: index, labels: labels, downbeatTimes: downbeatTimes, pxPerSecond: geometry.pxPerSecond)
                            .equatable()
                            .frame(width: HeaderTile.width)
                            .offset(x: CGFloat(index) * HeaderTile.width - scrollX)
                    }
                    StickyChordName(labels: labels, scrollX: scrollX)
                }
            }
            .clipped()
            .overlay(alignment: .bottom) { Rectangle().fill(RollTheme.hairline).frame(height: 0.5) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: chords, initial: true) {
            labels = ChordLabels(chords: chords, pxPerSecond: geometry.pxPerSecond)
        }
        .allowsHitTesting(false)
    }
}

/// Where the header writes each chord's name. Laid out right to left so each
/// name only has to clear the one drawn after it; names too crowded to fit
/// are skipped.
nonisolated struct ChordLabels: Equatable {
    struct Label: Equatable {
        let text: String
        /// The chord's start, in roll points.
        let start: CGFloat
        let width: CGFloat
        /// Drawn at `start + 4` when not pinned at the left edge.
        let shown: Bool
    }
    let labels: [Label]

    static let font = UIFont.systemFont(ofSize: 13, weight: .heavy)

    init(chords: [ChordSegment], pxPerSecond: CGFloat) {
        let sorted = chords.sorted { $0.startTime < $1.startTime }
        var labels: [Label] = []
        var nextX = CGFloat.greatestFiniteMagnitude
        for chord in sorted.reversed() {
            let start = CGFloat(chord.startTime) * pxPerSecond
            let width = ceil((chord.label as NSString).size(withAttributes: [.font: Self.font]).width)
            let shown = start + 4 + width + 6 <= nextX
            if shown { nextX = start + 4 }
            labels.append(Label(text: chord.label, start: start, width: width, shown: shown))
        }
        self.labels = labels.reversed()
    }

    /// The chord in effect at the left edge (`scrollX`) once its start has
    /// scrolled off, and where its name goes: at the edge until the next
    /// shown name pushes it off.
    func pinned(at scrollX: CGFloat) -> (label: Label, x: CGFloat)? {
        guard let i = labels.lastIndex(where: { $0.start < scrollX }) else { return nil }
        let label = labels[i]
        let next = labels[(i + 1)...].first { $0.shown }.map { $0.start + 4 - scrollX } ?? .greatestFiniteMagnitude
        return (label, min(4, next - label.width - 6))
    }
}

/// 512 pt of the header, drawn once.
private struct HeaderTile: View, Equatable {
    let index: Int
    let labels: ChordLabels
    let downbeatTimes: [Double]
    let pxPerSecond: CGFloat

    static let width: CGFloat = 512

    var body: some View {
        let x0 = CGFloat(index) * Self.width
        Canvas { context, size in
            context.translateBy(x: -x0, y: 0)
            // Bar ticks (as the bar lines below them) and numbers (navy)
            // along the bottom of the header.
            for (bar, t) in downbeatTimes.enumerated() {
                let x = CGFloat(t) * pxPerSecond
                guard x > x0 - 30, x < x0 + Self.width + 2 else { continue }
                context.stroke(
                    Path { $0.move(to: CGPoint(x: x, y: size.height - 9)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                    with: .style(RollTheme.barLine), lineWidth: 1.2
                )
                context.draw(
                    Text("\(bar + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(RollInk.chord),
                    at: CGPoint(x: x + 3, y: size.height - 5), anchor: .leading
                )
            }
            for label in labels.labels where label.shown
                && label.start + 4 < x0 + Self.width && label.start + 4 + label.width > x0 {
                context.draw(ChordLabels.text(label.text), at: CGPoint(x: label.start + 4, y: 11), anchor: .leading)
            }
        }
    }
}

extension ChordLabels {
    /// A chord name as the header draws it (the rolls' navy, 16.6:1).
    static func text(_ name: String) -> Text {
        Text(name).font(.system(size: 13, weight: .heavy)).foregroundStyle(RollInk.chord)
    }
}

/// The chord in effect at the left edge stays readable there until the next
/// chord's name pushes it off. Drawn every frame, over the tile's copy of the
/// name scrolling away under it.
private struct StickyChordName: View {
    let labels: ChordLabels
    let scrollX: CGFloat

    var body: some View {
        if let pinned = labels.pinned(at: scrollX), pinned.x + pinned.label.width > 0 {
            let label = pinned.label
            Canvas { context, size in
                if label.shown {
                    // Hide the tile's copy scrolling off the edge.
                    let end = label.start + 4 + label.width + 1 - scrollX
                    if end > 0 {
                        context.fill(Path(CGRect(x: 0, y: 0, width: end, height: 22)), with: .color(RollTheme.surface))
                    }
                }
                context.draw(ChordLabels.text(label.text), at: CGPoint(x: pinned.x, y: 11), anchor: .leading)
            }
            .frame(width: 160, height: 24)
        }
    }
}

/// The keyboard pinned at the left, lit by what's sounding under the play
/// line. The keys are drawn once and moved with the roll; only the lit keys
/// are drawn per frame.
private struct RollKeyboard: View {
    let live: RollLive
    let index: NoteTimeIndex
    let isLive: Bool
    let duration: Double
    let geometry: RollGeometry
    @State private var height: CGFloat = 0

    var body: some View {
        let scrollY = live.scroll.y
        let g = geometry
        // The 88 keys live in an overlay, so their height never moves the layout.
        Color.white
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    KeyboardColumn(geometry: g)
                        .equatable()
                        .frame(height: g.rollHeight)
                        .offset(y: -scrollY)
                    LitKeys(live: live, index: index, isLive: isLive, duration: duration, geometry: g)
                }
            }
            .clipped()
            .overlay(alignment: .trailing) { Rectangle().fill(RollTheme.hairline).frame(width: 0.5) }
            .accessibilityHidden(true)
            // VoiceOver's element is a plain one the keyboard's size: a clip
            // doesn't trim accessibility frames, and the keys run far past it.
            .overlay { keyboardElement(scrollY: scrollY) }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .allowsHitTesting(false)
            // The record transition's piano lands here, drawn as `RollKeyboardFace`.
            .recordTransitionKeyboard(.horizontal, scrollY: scrollY)
    }

    private func keyboardElement(scrollY: CGFloat) -> some View {
        let g = geometry
        return Rectangle()
            .fill(Color.clear)
            .contentShape(.accessibility, Rectangle())
            .accessibilityElement()
            .accessibilityLabel("Piano keyboard")
            .accessibilityIdentifier("piano-keyboard")
            .rollSwitchAction()
            #if DEBUG
            .accessibilityChildren {
                if RegressionUIFixture.selected != nil {
                    ZStack(alignment: .topLeading) {
                        ForEach(g.minPitch...g.maxPitch, id: \.self) { pitch in
                            let y = g.yFor(pitch: pitch) - scrollY
                            if y + g.rowHeight > 0, y < height {
                                Rectangle()
                                    .frame(width: PianoRollView.keyboardWidth, height: g.rowHeight)
                                    .contentShape(.accessibility, Rectangle())
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("\(NoteEvent.name(for: pitch)), MIDI \(pitch)")
                                    .accessibilityIdentifier("piano-key-\(pitch)")
                                    .position(x: PianoRollView.keyboardWidth / 2, y: y + g.rowHeight / 2)
                            }
                        }
                    }
                    .frame(width: PianoRollView.keyboardWidth, height: height, alignment: .topLeading)
                }
            }
            #endif
    }
}

/// The keyboard as `RollKeyboard` shows it with no key lit, scrolled
/// `scrollY` down the 88 keys: the record transition's flying piano, which
/// lands on the keyboard and has to be indistinguishable from it there.
struct RollKeyboardFace: View {
    let scrollY: CGFloat

    var body: some View {
        let g = RollGeometry()
        Color.white
            .overlay(alignment: .topLeading) {
                KeyboardColumn(geometry: g)
                    .equatable()
                    .frame(height: g.rollHeight)
                    .offset(y: -scrollY)
            }
            .clipped()
            .overlay(alignment: .trailing) { Rectangle().fill(RollTheme.hairline).frame(width: 0.5) }
    }
}

/// All 88 keys, unlit, drawn once.
private struct KeyboardColumn: View, Equatable {
    let geometry: RollGeometry

    var body: some View {
        let g = geometry
        Canvas { context, size in
            for pitch in g.minPitch...g.maxPitch {
                RollKeyboard.drawKey(pitch, y: g.yFor(pitch: pitch), width: size.width, lit: nil, geometry: g, in: context)
            }
        }
    }
}

/// The keys sounding now, drawn over the unlit keyboard every frame.
private struct LitKeys: View {
    let live: RollLive
    let index: NoteTimeIndex
    let isLive: Bool
    let duration: Double
    let geometry: RollGeometry

    /// How brightly each sounding key is lit: 1 as its note starts, fading
    /// linearly to 0 as the note runs out under the playhead. While recording,
    /// notes still sounding at the live edge have no end yet, so they stay at 1.
    private func keyLevels(at time: Double?) -> KeyLights {
        var levels = KeyLights()
        if let t = time {
            index.forEach(overlapping: t...t) { note in
                guard note.startTime <= t, note.endTime > t else { return }
                levels.light(note, level: min((note.endTime - t) / max(note.endTime - note.startTime, 1e-6), 1))
            }
        } else if isLive {
            index.forEach(overlapping: (duration - 0.05)...duration) { note in
                guard note.startTime <= duration, note.endTime >= duration - 0.05 else { return }
                levels.light(note, level: 1)
            }
        }
        return levels
    }

    var body: some View {
        let scrollY = live.scroll.y
        let levels = keyLevels(at: live.time)
        let g = geometry
        if levels.pitches.contains(where: { $0 >= g.minPitch && $0 <= g.maxPitch }) {
            Canvas { context, size in
                let palette = PartPalette(context.environment)
                for pitch in levels.pitches where pitch >= g.minPitch && pitch <= g.maxPitch {
                    let y = g.yFor(pitch: pitch) - scrollY
                    guard y > -g.rowHeight, y < size.height, let lit = levels[pitch], lit.level > 0 else { continue }
                    let color = palette.fill(lit.voice)
                    RollKeyboard.drawKey(pitch, y: y, width: size.width, lit: (lit.level, color, palette.rgb(color)),
                                         geometry: g, in: context)
                }
            }
        }
    }
}

extension RollKeyboard {
    /// One key of the pinned keyboard, unlit or lit in a part's colour:
    /// white keys and navy black keys (`RollTheme`). A lit key is drawn
    /// whole (white or black first), covering the unlit key and its name
    /// under it.
    static func drawKey(_ pitch: Int, y: CGFloat, width w: CGFloat, lit: (level: Double, color: Color, rgb: RollInk.RGB)?,
                        geometry g: RollGeometry, in context: GraphicsContext) {
        let rowHeight = g.rowHeight
        let level = lit?.level ?? 0
        if RollGeometry.isBlack(pitch) {
            let key = Path(roundedRect: CGRect(x: 0, y: y + 1, width: w * 0.6, height: rowHeight - 2), cornerRadius: 2)
            context.fill(key, with: .color(RollTheme.blackKey))
            if let lit { context.fill(key, with: .color(lit.color.opacity(level))) }
            return
        }
        if let lit {
            let row = Path(CGRect(x: 0, y: y, width: w, height: rowHeight))
            context.fill(row, with: .color(RollTheme.whiteKey))
            context.fill(row, with: .color(lit.color.opacity(level)))
        }
        // Seams between neighbouring white keys (B|C and E|F).
        if pitch % 12 == 0 || pitch % 12 == 5 {
            context.stroke(
                Path { $0.move(to: CGPoint(x: 0, y: y + rowHeight)); $0.addLine(to: CGPoint(x: w, y: y + rowHeight)) },
                with: .style(RollTheme.keySeam), lineWidth: 0.5
            )
        }
        if pitch % 12 == 0 {
            // Grey on the white key, or black or white once it's lit enough
            // that grey would no longer read.
            let key = lit.map { RollInk.RGB.white.under($0.rgb, opacity: $0.level) } ?? .white
            let ink = RollInk.text(on: key, preferred: RollInk.keyLabel)
            context.draw(
                Text("C\(pitch / 12 - 1)").font(.system(size: g.labelSize, weight: .semibold)).foregroundStyle(ink.color),
                at: CGPoint(x: w - 3, y: y + rowHeight / 2), anchor: .trailing
            )
        }
    }
}

// MARK: - The roll, drawn once in tiles

/// How a note bar and its name are drawn, shared by the tiles and the pinned
/// names so a pinned name's patch matches the bar under it exactly.
private struct BarStyle {
    let geometry: RollGeometry
    let rowBackground: RollInk.RGB
    let shadedRow: RollInk.RGB
    let palette: PartPalette
    let contrast: ColorSchemeContrast

    init(_ context: GraphicsContext, geometry: RollGeometry) {
        self.geometry = geometry
        palette = PartPalette(context.environment)
        contrast = context.environment.colorSchemeContrast
        rowBackground = .white
        shadedRow = RollTheme.shadedRowRGB
    }

    func rect(_ note: NoteEvent) -> CGRect {
        let g = geometry
        let x = CGFloat(note.startTime) * g.pxPerSecond
        let width = max(CGFloat(note.endTime - note.startTime) * g.pxPerSecond, 3)
        return CGRect(x: x, y: g.yFor(pitch: note.pitch) + 1.5, width: width, height: g.rowHeight - 3)
    }

    static func opacity(_ note: NoteEvent) -> Double { 0.35 + 0.6 * note.amplitude }

    /// The part's light fill at the note's loudness (with Increase Contrast
    /// its deeper one, `Voice.fill(for:)`), with its deeper outline
    /// (`Voice.outline`, 3:1 or better on the rows) so a quiet note still
    /// has a clear edge.
    func drawBar(_ note: NoteEvent, in context: GraphicsContext) {
        let path = Path(roundedRect: rect(note), cornerRadius: 3)
        context.fill(path, with: .color(note.voice.fill(for: contrast).opacity(Self.opacity(note))))
        context.stroke(path, with: .color(note.voice.outline), lineWidth: Self.outlineWidth)
    }

    static let outlineWidth: CGFloat = 0.75

    /// The note's name in navy where it reads at 4.5:1 or better on the bar
    /// as drawn over its row, otherwise black or white, whichever reads
    /// better. On the calm fills that's navy on every part but the plum
    /// bass at any loudness; the bass's names are navy up to about 0.65-0.7
    /// loudness (the shaded rows, the white), black from there, and white
    /// from about 0.85-0.9 (each 4.5:1 or better). With Increase Contrast's
    /// deeper fills, navy holds on the melody and countermelody; the
    /// chords' loudest (from about 0.8) take black, and the bass's names
    /// turn black from about 0.45 and white from about 0.6.
    func name(_ note: NoteEvent, in context: GraphicsContext) -> GraphicsContext.ResolvedText {
        let row = RollGeometry.isBlack(note.pitch) ? shadedRow : rowBackground
        let fill = row.under(palette.rgb(note.voice), opacity: Self.opacity(note))
        return context.resolve(Text(note.noteName).font(.system(size: geometry.labelSize, weight: .bold))
            .foregroundStyle(RollInk.text(on: fill, preferred: RollInk.navyRGB).color))
    }
}

/// Everything that doesn't move with playback, in fixed-width tiles that a
/// lazy stack only builds near the screen. Equatable, so per-frame updates
/// elsewhere never redraw it (the old single Canvas redrew the whole take
/// every tick: 22 ms at 2,800 notes).
private struct RollContent: View, Equatable {
    let notes: [NoteEvent]
    let chords: [ChordSegment]
    let beatTimes: [Double]
    let downbeatTimes: [Double]
    let width: CGFloat
    let liveEdge: Double?
    let geometry: RollGeometry

    static let tileWidth: CGFloat = 512

    var body: some View {
        let count = max(1, Int((width / Self.tileWidth).rounded(.up)))
        LazyHStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let x0 = CGFloat(index) * Self.tileWidth
                let w = min(Self.tileWidth, width - x0)
                RollTile(content: self, x0: x0, width: w)
                    .frame(width: w, height: geometry.rollHeight)
            }
        }
        .frame(width: width, height: geometry.rollHeight, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel("Piano roll notes")
    }
}

private struct RollTile: View {
    let content: RollContent
    let x0: CGFloat
    let width: CGFloat

    var body: some View {
        let c = content
        let g = c.geometry
        let pps = g.pxPerSecond
        let t0 = Double(x0 / pps), t1 = Double((x0 + width) / pps)
        Canvas { context, _ in
            context.translateBy(x: -x0, y: 0)
            let rollHeight = g.rollHeight
            // Row shading and octave lines.
            for pitch in g.minPitch...g.maxPitch {
                let y = g.yFor(pitch: pitch)
                if RollGeometry.isBlack(pitch) {
                    context.fill(Path(CGRect(x: x0, y: y, width: width, height: g.rowHeight)),
                                 with: .color(RollTheme.shadedRow))
                }
                if pitch % 12 == 0 {
                    context.stroke(
                        Path { $0.move(to: CGPoint(x: x0, y: y + g.rowHeight)); $0.addLine(to: CGPoint(x: x0 + width, y: y + g.rowHeight)) },
                        with: .style(RollTheme.octaveLine), lineWidth: 1
                    )
                }
            }
            RollTile.drawGrid(in: context, beatTimes: c.beatTimes, downbeatTimes: c.downbeatTimes,
                              range: t0...t1, height: rollHeight, pxPerSecond: pps)
            // Notes: the chords part first, so the lines are drawn over it
            // (`Voice.drawnBeneath`). A note starting just left of the tile
            // still has its name drawn here (the name spills past its start).
            let style = BarStyle(context, geometry: g)
            for beneath in [true, false] {
                for note in c.notes where note.voice.drawnBeneath == beneath && g.contains(note.pitch)
                    && note.startTime <= t1 && note.endTime >= t0 - 0.3 {
                    style.drawBar(note, in: context)
                    let rect = style.rect(note)
                    if rect.width > RollGeometry.labelMinWidth {
                        context.draw(style.name(note, in: context),
                                     at: CGPoint(x: rect.minX + RollGeometry.labelCenterInset, y: rect.midY))
                    }
                }
            }
            RollTile.drawChordLines(in: context, chords: c.chords, range: t0...t1, height: rollHeight, pxPerSecond: pps)
            // Live edge while recording.
            if let edge = c.liveEdge {
                let x = CGFloat(edge) * pps
                context.stroke(
                    Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: rollHeight)) },
                    with: .color(RollTheme.liveEdge), lineWidth: 1.5
                )
            }
        }
    }

    /// The beat grid (measure lines darkest, beat lines a step lighter, both
    /// in navy, `RollTheme`), or without one a plain one-second grid for
    /// orientation.
    static func drawGrid(in context: GraphicsContext, beatTimes: [Double], downbeatTimes: [Double],
                         range: ClosedRange<Double>, height: CGFloat, pxPerSecond pps: CGFloat) {
        if beatTimes.isEmpty {
            var second = Int(range.lowerBound.rounded(.down))
            while Double(second) <= range.upperBound {
                let x = CGFloat(second) * pps
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: height)) },
                               with: .style(RollTheme.secondLine), lineWidth: 0.5)
                second += 1
            }
            return
        }
        let downbeatSet = Set(downbeatTimes.map { round($0 * 1000) })
        for t in beatTimes where t >= range.lowerBound - 0.05 && t <= range.upperBound + 0.05 {
            let x = CGFloat(t) * pps
            let isDownbeat = downbeatSet.contains(round(t * 1000))
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: height)) },
                           with: .style(isDownbeat ? RollTheme.barLine : RollTheme.beatLine),
                           lineWidth: isDownbeat ? 1.2 : 0.6)
        }
    }

    /// Chord changes (their names live in the pinned header).
    static func drawChordLines(in context: GraphicsContext, chords: [ChordSegment], range: ClosedRange<Double>,
                               height: CGFloat, pxPerSecond pps: CGFloat) {
        for chord in chords where chord.startTime >= range.lowerBound - 0.05 && chord.startTime <= range.upperBound + 0.05 {
            let x = CGFloat(chord.startTime) * pps
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: height)) },
                           with: .style(RollTheme.chordLine), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}

/// Keeps a note's name readable once its start has scrolled off the roll's
/// left edge: the name sticks just right of the play marker, where nothing
/// crosses it, while the bar runs on, so no fragment of the scrolled-off name
/// peeks out. It takes over from the bar's own name as that slides past the
/// spot (so it never jumps), covers that name with a patch of the bar as the
/// tile drew it (row, grid, bar, chord line), and draws the name over it.
private struct PinnedNoteNames: View {
    let live: RollLive
    let index: NoteTimeIndex
    let beatTimes: [Double]
    let downbeatTimes: [Double]
    let chords: [ChordSegment]
    let geometry: RollGeometry

    /// Wide enough for the patch and a pinned name.
    private static let width: CGFloat = 64

    var body: some View {
        let left = max(live.scroll.x, 0)
        let g = geometry
        // A pinned name's leading edge, from the roll's left edge: 3 pt clear of the marker.
        let stuck = g.playLineInset + RollGeometry.markerWidth + 3
        let edge = Double(left / g.pxPerSecond)
        // Names reach no further right than this before they stick.
        let reach = Double((stuck + 12 - RollGeometry.labelCenterInset) / g.pxPerSecond)
        let crossing = index.notes(overlapping: edge...(edge + reach)).filter { note in
            g.contains(note.pitch) && note.startTime < edge + reach
                && CGFloat(note.endTime - note.startTime) * g.pxPerSecond > RollGeometry.labelMinWidth
        }
        if !crossing.isEmpty {
            Canvas { context, size in
                context.translateBy(x: -left, y: 0)
                let style = BarStyle(context, geometry: g)
                // Chords first, as the tiles draw them.
                for note in crossing.sorted(by: { $0.voice.drawnBeneath && !$1.voice.drawnBeneath }) {
                    let rect = style.rect(note)
                    let name = style.name(note, in: context)
                    let nameWidth = name.measure(in: CGSize(width: 100, height: 40)).width
                    let natural = rect.minX + RollGeometry.labelCenterInset - nameWidth / 2
                    guard natural < left + stuck else { continue }   // its own name still shows
                    // The bar's own name ends here; a point spare for a frame's lag.
                    let fragmentEnd = natural + nameWidth + 1.5
                    if fragmentEnd > left {
                        // Only over the bar itself, so no neighbouring note is covered.
                        let x0 = max(left, rect.minX - 0.5), x1 = min(fragmentEnd, rect.maxX + 1)
                        let patch = CGRect(x: x0, y: rect.minY - 0.5, width: max(x1 - x0, 0), height: rect.height + 1)
                        context.drawLayer { layer in
                            layer.clip(to: Path(patch))
                            let row = CGRect(x: patch.minX, y: g.yFor(pitch: note.pitch), width: patch.width, height: g.rowHeight)
                            layer.fill(Path(row), with: .color(RollGeometry.isBlack(note.pitch) ? RollTheme.shadedRow : RollTheme.surface))
                            let range = Double(patch.minX / g.pxPerSecond)...Double(patch.maxX / g.pxPerSecond)
                            RollTile.drawGrid(in: layer, beatTimes: beatTimes, downbeatTimes: downbeatTimes,
                                              range: range, height: g.rollHeight, pxPerSecond: g.pxPerSecond)
                            style.drawBar(note, in: layer)
                            RollTile.drawChordLines(in: layer, chords: chords, range: range,
                                                    height: g.rollHeight, pxPerSecond: g.pxPerSecond)
                        }
                    }
                    // Room for the whole name on what's left of the bar.
                    if rect.maxX - left >= stuck + nameWidth + 3 {
                        context.draw(name, at: CGPoint(x: left + stuck, y: rect.midY), anchor: .leading)
                    }
                }
            }
            .frame(width: Self.width, height: g.rollHeight)
            .offset(x: left)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

#Preview {
    PianoRollView(
        notes: [
            NoteEvent(startTime: 0, endTime: 2, pitch: 60, amplitude: 0.9),
            NoteEvent(startTime: 0, endTime: 2, pitch: 64, amplitude: 0.7),
            NoteEvent(startTime: 0, endTime: 2, pitch: 67, amplitude: 0.5),
            NoteEvent(startTime: 0.5, endTime: 0.7, pitch: 71, amplitude: 0.8),
            NoteEvent(startTime: 1.0, endTime: 1.2, pitch: 74, amplitude: 0.6),
        ],
        chords: [ChordSegment(startTime: 0, endTime: 2, label: "C")],
        duration: 3,
        isLive: false,
        beatTimes: [0, 0.5, 1, 1.5, 2, 2.5, 3],
        downbeatTimes: [0, 2]
    )
}
