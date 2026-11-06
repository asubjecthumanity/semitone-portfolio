import SwiftUI
import UIKit

/// The falling notes' keyboard and time scale.
nonisolated enum FallingGeometry {
    static let minPitch = 21   // A0
    static let maxPitch = 108  // C8
    static let pxPerSecond: CGFloat = 120
    static let keyboardHeight: CGFloat = 96
    /// On an iPhone on its side the notes have about 220 pt above the keys
    /// instead of 500: at 120 pt/s that is under 2 s of warning, so they fall
    /// slower (3 s ahead), and the keys, 14 pt wide there, are a little shorter.
    static let landscapePxPerSecond: CGFloat = 70
    static let landscapeKeyboardHeight: CGFloat = 80

    static func isBlack(_ pitch: Int) -> Bool { RollGeometry.isBlack(pitch) }

    /// White keys below each pitch from A0 (to one past C8), looked up every
    /// frame rather than counted.
    static let whiteKeysBefore: [Int] = {
        var counts: [Int] = []
        var count = 0
        for pitch in minPitch...(maxPitch + 1) {
            counts.append(count)
            if pitch <= maxPitch, !isBlack(pitch) { count += 1 }
        }
        return counts
    }()

    static var whiteKeyCount: Int { whiteKeysBefore[maxPitch + 1 - minPitch] }

    static func whiteKeys(before pitch: Int) -> Int { whiteKeysBefore[pitch - minPitch] }

    /// Horizontal placement of a pitch, given the white-key width.
    static func xExtent(pitch: Int, whiteW: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let wb = CGFloat(whiteKeys(before: pitch))
        if isBlack(pitch) {
            let blackW = whiteW * 0.62
            return (wb * whiteW - blackW / 2, blackW)
        }
        return (wb * whiteW, whiteW)
    }
}

/// Scrubbing the falling notes: the scroll offset of the clear scroll view
/// over the notes, and the time it puts on the hit line. The offset runs from
/// 0 at the top (the take's end on the hit line) to `maxOffset` at the bottom
/// (0:00), so the notes follow the finger: pulling up lifts earlier notes
/// back out of the keys, pulling down runs them in.
nonisolated struct FallingScrub: Equatable {
    var duration: Double
    var pxPerSecond: CGFloat = FallingGeometry.pxPerSecond

    var maxOffset: CGFloat { CGFloat(max(duration, 0)) * pxPerSecond }

    func offset(forTime t: Double) -> CGFloat { CGFloat(duration - t) * pxPerSecond }

    /// The time on the hit line; past either end while the scroll rubber-bands.
    func time(forOffset y: CGFloat) -> Double { duration - Double(y / pxPerSecond) }

    /// The time to cue: within the take.
    func cueTime(forOffset y: CGFloat) -> Double { min(max(time(forOffset: y), 0), max(duration, 0)) }

    /// The scroll content: a screen of room below 0:00 so the take's end can
    /// reach the hit line, and every moment in between.
    func contentHeight(viewport: CGFloat) -> CGFloat { maxOffset + viewport }

    /// The scroll view's snap: a scrub let go comes to rest on a nearby bar
    /// or beat line (the horizontal roll's catch zones, on the vertical
    /// axis), and the time there is the cue.
    @MainActor func beatSnap(beatTimes: [Double], downbeatTimes: [Double]) -> BeatSnapBehavior {
        BeatSnapBehavior(beatOffsets: beatTimes.map(offset(forTime:)), measureOffsets: downbeatTimes.map(offset(forTime:)),
                         axis: .vertical)
    }

    /// The start of the next or previous bar (VoiceOver's adjustable action).
    /// Without a beat grid, two seconds at a time.
    static func adjacentBar(from t: Double, downbeats: [Double], forward: Bool, duration: Double) -> Double {
        let next: Double?
        if downbeats.isEmpty {
            next = forward ? t + 2 : t - 2
        } else if forward {
            next = downbeats.first { $0 > t + 0.01 }
        } else {
            next = downbeats.last { $0 < t - 0.01 }
        }
        return min(max(next ?? (forward ? duration : 0), 0), max(duration, 0))
    }

    /// "Bar 3 of 4, F, 0:04": where the hit line is, for VoiceOver. A bar
    /// line at the very end of the take starts no bar.
    static func spokenPosition(at t: Double, downbeats: [Double], chords: [ChordSegment], duration: Double) -> String {
        var parts: [String] = []
        let bars = downbeats.filter { $0 < duration - 0.01 }
        if let bar = bars.lastIndex(where: { $0 <= t + 0.01 }) {
            parts.append("Bar \(bar + 1) of \(bars.count)")
        }
        if let chord = chords.last(where: { $0.startTime <= t && t < $0.endTime }) {
            parts.append(chord.label)
        }
        let seconds = Int(max(t, 0).rounded(.down))
        parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        return parts.joined(separator: ", ")
    }
}

/// While recording, what was just played comes in at the top of the
/// falling notes and falls down its key lane, slipping under the keys (and
/// lighting them) the falling height's worth of seconds later. The same way
/// up as playback, later higher, so a note still sounding grows down from
/// the top. The top is the live edge (the latest moment the microphone has
/// handed over) less `transcriptionLag`, the moment the live transcription
/// is sure to have reached: with the live edge itself at the top, the notes
/// came in clumps partway down, wherever the transcription had got to.
nonisolated enum FallingLive {
    /// How far the live transcription can trail the live edge. The model
    /// runs on 2 s windows of the audio, one each time 1.64 s more is in,
    /// so what it has ends 0.17 to 1.81 s before the edge; then the model
    /// and the note pass take a moment (0.15 s allowed). So a note comes in
    /// at the top about 2 s after it's played. (One begun just before a
    /// window ends is too short to call until the next window, and comes
    /// in further down.)
    static let transcriptionLag = Double(BPConstants.windowSamples - BPConstants.overlapSamples / 2)
        / BPConstants.sampleRate + 0.15

    /// The time at the top of the notes with the live edge at `edge`.
    static func topTime(edge: Double) -> Double { edge - transcriptionLag }

    /// The time on the hit line, at the bottom of `height` points of notes,
    /// with the live edge at `edge`.
    static func hitLineTime(edge: Double, height: CGFloat, pxPerSecond: CGFloat) -> Double {
        topTime(edge: edge) - Double(height / pxPerSecond)
    }

    /// The model publishes the edge once per microphone buffer (a tenth of
    /// a second or so, about 12 pt of fall), each a few milliseconds early
    /// or late. So the edge on screen runs on with the display clock between
    /// publishes, easing onto where the last one puts it by now (`settle`),
    /// so neither the steps nor their unevenness show. It never goes back,
    /// and never runs more than about one buffer past the last edge
    /// published (`lead(step:)`): if the publishes stop, so does the edge.
    /// Far behind (the app was away), it goes straight there.
    ///
    /// While the model runs, buffers can wait and then come in together as
    /// one publish, a long step that lets the edge run further on; when the
    /// next publish is a single buffer, its limit can fall short of where
    /// the edge already is. The edge then waits there for the publishes to
    /// catch up rather than step back.
    ///
    /// `shown` is the edge on screen, `published` the last edge published,
    /// `sincePublished` seconds before the frame being drawn shows, and
    /// `step` how far that publish moved it (one buffer). `frame` is one
    /// display frame's time.
    static func glide(shown: Double, published: Double, sincePublished: Double, step: Double,
                      frame: Double) -> Double {
        let limit = published + lead(step: step)
        let target = published + max(sincePublished, 0)
        guard target - shown <= maxCatchUp else { return max(min(target, limit), shown) }
        let next = shown + frame + (target - shown - frame) * min(frame / settle, 1)
        return max(min(next, limit), shown)
    }

    /// How far the edge may run past the last one published: one buffer
    /// (whatever size the microphone hands over: about 0.1 s from the
    /// phone's own, more from a headset's), and a quarter more for publishes
    /// that arrive a little late.
    static func lead(step: Double) -> Double { min(max(step, 0.05), 0.3) * 1.25 }

    /// How quickly the edge eases onto the publishes, in seconds.
    static let settle = 0.25
    /// The step assumed until a second edge comes in.
    static let firstStep = 0.1
    /// Further behind than this, the edge jumps rather than catching up.
    static let maxCatchUp = 0.5
}

/// Synthesia-style layout: a horizontal piano keyboard pinned at the bottom
/// with note bars descending through key lanes toward it. The moment on the
/// hit line (where the notes meet the keys) is the cue: drag the notes to
/// move through the take, and play starts from the hit line, as the
/// horizontal roll starts from its play line. During playback the notes fall
/// with the playback clock, once per display frame; a drag then holds the
/// sound and scrubs, and playback carries on from wherever it lets go.
/// While recording, what was just played comes in at the top and falls
/// toward the keys (`FallingLive`).
struct FallingNotesView: View {
    let notes: [NoteEvent]
    let chords: [ChordSegment]
    /// The moment on the hit line when not playing: the cue. While
    /// recording, the live edge (the top of the notes is a little behind
    /// it: `FallingLive`).
    let time: Double
    /// The take's length: how far the notes can be scrubbed.
    var duration: Double = 0
    let isLive: Bool
    /// The playback clock while playing, nil when stopped.
    var clock: PlaybackClock? = nil
    /// Beat grid overlay (optional). Beats are horizontal lines at each beat time.
    var beatTimes: [Double] = []
    var downbeatTimes: [Double] = []
    /// A scrub while stopped: the hit line's time as the notes move, then
    /// `settled` once they come to rest.
    var onCue: ((_ time: Double, _ settled: Bool) -> Void)? = nil
    /// A drag began during playback: hold the sound.
    var onHold: (() -> Void)? = nil
    /// The held drag came to rest: play on from here.
    var onResume: ((_ time: Double) -> Void)? = nil
    /// VoiceOver's bar steps: move playback, or the cue when stopped, to
    /// this time at once (`TranscriberViewModel.seek(to:)`).
    var onSeek: ((_ time: Double) -> Void)? = nil
    /// How fast the notes fall and how tall the keys are: slower and shorter
    /// on an iPhone on its side.
    var pxPerSecond: CGFloat = FallingGeometry.pxPerSecond
    var keyboardHeight: CGFloat = FallingGeometry.keyboardHeight

    @State private var live = RollLive()
    @State private var follower = FallingFollower()
    @State private var index = NoteTimeIndex([])
    /// From touch-down until the notes come to rest: whether playback was on.
    @State private var scrubStartedPlaying: Bool?
    /// Bumped as a scrub runs past either end, for a soft tap.
    @State private var endBumps = 0
    @State private var pastEnd = false

    private var isPlaying: Bool { clock != nil }
    private var mapping: FallingScrub { FallingScrub(duration: duration, pxPerSecond: pxPerSecond) }
    /// What the notes show when nothing moves them.
    private var restingTime: Double { isLive ? time : min(max(time, 0), max(duration, 0)) }

    var body: some View {
        GeometryReader { geo in
            let whiteW = geo.size.width / CGFloat(FallingGeometry.whiteKeyCount)
            let fallingHeight = max(geo.size.height - keyboardHeight, 0)
            VStack(spacing: 0) {
                ZStack {
                    FallingNotesCanvas(live: live, index: index, chords: chords, beatTimes: beatTimes,
                                       downbeatTimes: downbeatTimes, isLive: isLive, whiteW: whiteW,
                                       pxPerSecond: pxPerSecond)
                    // No scrubbing while recording: the notes follow the live edge.
                    if isLive {
                        liveElement
                    } else {
                        scrubber(height: fallingHeight)
                    }
                }
                .frame(width: geo.size.width, height: fallingHeight)
                .clipped()
                FallingKeyboard(live: live, index: index, isLive: isLive, fallingHeight: fallingHeight,
                                pxPerSecond: pxPerSecond, whiteW: whiteW)
                    .frame(height: keyboardHeight)
            }
        }
        .onChange(of: notes, initial: true) { index = NoteTimeIndex(notes) }
        .onChange(of: mapping, initial: true) {
            follower.mapping = mapping
            if !isLive, !isPlaying, scrubStartedPlaying == nil { follower.show(restingTime, live: live) }
        }
        // Initial too: the notes can appear mid-take (the phone turned on its
        // side, or the roll flipped over to them).
        .onChange(of: time, initial: true) {
            if isLive {
                follower.record(upTo: time, live: live)
                return
            }
            // During playback `time` is the model's coarse playhead: the clock moves the notes.
            guard !isPlaying, scrubStartedPlaying == nil else { return }
            follower.show(restingTime, live: live)
        }
        .onChange(of: isLive) { _, recording in
            if recording {
                follower.record(upTo: time, live: live)
            } else {
                // The take is in: the cue goes back on the hit line, under the scrubber.
                follower.stop()
                if !isPlaying { follower.show(restingTime, live: live) }
            }
        }
        // Initial too: the notes can appear mid-play (the phone turned on its
        // side, or the roll flipped over to them), and follow at once.
        .onChange(of: isPlaying, initial: true) { _, playing in
            if playing, let clock {
                follower.start(clock: clock, live: live)
            } else if !playing, !isLive {
                follower.stop()
                if scrubStartedPlaying == nil { follower.show(restingTime, live: live) }
            }
        }
        .onDisappear {
            follower.stop()
            // Gone mid-scrub (the phone turned upright onto the other layout):
            // don't leave playback held.
            if let startedPlaying = scrubStartedPlaying {
                scrubStartedPlaying = nil
                follower.scrubbing = false
                let t = min(max(live.time ?? restingTime, 0), max(duration, 0))
                if startedPlaying { onResume?(t) } else { onCue?(t, true) }
            }
        }
    }

    /// A clear scroll view over the notes: its scrolling (momentum, the
    /// rubber band at either end, the beat snap) moves the hit line's time.
    private func scrubber(height: CGFloat) -> some View {
        let mapping = mapping
        return ScrollView(.vertical) {
            Color.clear
                .frame(height: mapping.contentHeight(viewport: height))
                .contentShape(Rectangle())
                .background(ScrollViewFinder { [follower, live] scrollView in
                    follower.attach(scrollView, live: live)
                })
        }
        .scrollIndicators(.hidden)
        // Only to start at the bottom. The follow puts the cue back whenever
        // the size changes (the phone turning); anchored through size changes
        // too, the scroll view would move the content the other way.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollTargetBehavior(mapping.beatSnap(beatTimes: beatTimes, downbeatTimes: downbeatTimes))
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, y in
            scrolled(to: y)
        }
        .onScrollPhaseChange { _, phase in phaseChanged(phase) }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: endBumps)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Falling notes")
        .accessibilityValue(FallingScrub.spokenPosition(at: restingTime, downbeats: downbeatTimes, chords: chords,
                                                        duration: duration))
        .accessibilityHint("Swipe up or down to move a bar at a time.")
        .accessibilityAdjustableAction { direction in
            // From the moment on the hit line now: during playback that's
            // the clock's, which the notes show, not the playhead, which is
            // published only a few times a second and can be a bar behind.
            let now = isPlaying ? (live.time ?? restingTime) : restingTime
            let target = FallingScrub.adjacentBar(from: now, downbeats: downbeatTimes,
                                                  forward: direction == .increment, duration: duration)
            onSeek?(target)
        }
        .rollSwitchAction()
        .accessibilityIdentifier("falling-notes-scrub")
    }

    /// While recording there's no scrubbing, but VoiceOver still finds the
    /// notes, with the live edge's time, and the switch to the other layout
    /// that a sighted user has in pulling the keyboard round the corner.
    private var liveElement: some View {
        Rectangle()
            .fill(Color.clear)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Falling notes")
            .accessibilityValue("Recording, \(FallingScrub.spokenPosition(at: time, downbeats: [], chords: chords, duration: time))")
            .accessibilityAddTraits(.updatesFrequently)
            .rollSwitchAction()
            .accessibilityIdentifier("falling-notes-live")
    }

    private func scrolled(to y: CGFloat) {
        guard scrubStartedPlaying != nil else {
            // A layout pass can move the clear content; put it back on the
            // cue once the pass is over (from inside it, during a turn's
            // animation, the two can fight).
            if !isPlaying, abs(y - mapping.offset(forTime: restingTime)) > 0.5 {
                follower.showSoon(restingTime, live: live)
            }
            return
        }
        let t = mapping.time(forOffset: y)
        if live.time != t { live.time = t }
        let beyond = y < -0.5 || y > mapping.maxOffset + 0.5
        if beyond != pastEnd {
            pastEnd = beyond
            if beyond { endBumps += 1 }
        }
        // Keep the start spot current as the notes move, so play pressed
        // while a flick is still gliding starts where it shows.
        if !isPlaying { onCue?(mapping.cueTime(forOffset: y), false) }
    }

    private func phaseChanged(_ phase: ScrollPhase) {
        switch phase {
        case .interacting:
            guard scrubStartedPlaying == nil else { return }
            scrubStartedPlaying = isPlaying
            if isPlaying {
                follower.scrubbing = true
                onHold?()
            }
        case .idle:
            guard let startedPlaying = scrubStartedPlaying else { return }
            scrubStartedPlaying = nil
            pastEnd = false
            follower.scrubbing = false
            let t = min(max(live.time ?? restingTime, 0), max(duration, 0))
            if startedPlaying {
                onResume?(t)
            } else {
                onCue?(t, true)
            }
        default:
            break
        }
    }
}

// MARK: - Follow

/// Moves the falling notes with the playback clock once per display frame,
/// and keeps the clear scroll view's offset on the same moment, so a drag
/// picks the notes up exactly where they are. Stands down while a drag holds
/// playback. While recording it moves the live edge on between the model's
/// publishes instead.
@MainActor
final class FallingFollower {
    weak var scrollView: UIScrollView?
    var mapping = FallingScrub(duration: 0)
    /// A drag holds playback: the notes follow the finger, not the clock.
    var scrubbing = false

    private let ticker = FrameTicker()
    private weak var clock: PlaybackClock?
    private weak var live: RollLive?
    /// Set when following (re)starts: decide once whether to hold.
    private var resuming = true
    /// Playback starts a hair before the cue: hold the notes until the clock
    /// reaches what they show, rather than lift them back for 60 ms.
    private var holdingAhead = false
    /// While recording: the live edge as last published, when it came in,
    /// and how far it moved then (one microphone buffer).
    private var recorded: (edge: Double, at: CFTimeInterval, step: Double)?

    func attach(_ scrollView: UIScrollView, live: RollLive) {
        guard self.scrollView !== scrollView else { return }
        self.scrollView = scrollView
        if let t = live.time, !scrubbing { setOffset(for: t) }
    }

    func start(clock: PlaybackClock, live: RollLive) {
        self.clock = clock
        self.live = live
        recorded = nil
        resuming = true
        holdingAhead = false
        // Play pressed while a flick still glides: playback starts where the
        // notes showed, so stop them there.
        if let scrollView, scrollView.isDecelerating, !scrollView.isTracking {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }
        ticker.onFrame = { [weak self] shownAt, _ in self?.frame(shownAt: shownAt) }
        ticker.start()
    }

    func stop() {
        ticker.stop()
        recorded = nil
    }

    /// While recording: the live edge as each publish of it comes in. From
    /// the first, the edge moves on once per display frame
    /// (`FallingLive.glide`) until `stop()`.
    func record(upTo edge: Double, live: RollLive) {
        let now = CACurrentMediaTime()
        if let last = recorded, edge >= last.edge {
            recorded = (edge, now, edge > last.edge ? edge - last.edge : last.step)
            return
        }
        // Recording has just started, or the notes have just appeared (or,
        // never in practice, the edge went back, which the glide won't
        // follow): from here at once.
        self.live = live
        clock = nil
        recorded = (edge, now, FallingLive.firstStep)
        if live.time != edge { live.time = edge }
        ticker.onFrame = { [weak self] shownAt, frameDuration in
            self?.recordingFrame(shownAt: shownAt, frameDuration: frameDuration)
        }
        ticker.start()
    }

    private var soon: Double?

    /// `show(t)` on the next turn of the run loop, once however often it's
    /// asked for meanwhile (with the latest time), unless playback or the
    /// finger has the notes by then.
    func showSoon(_ t: Double, live: RollLive) {
        let pending = soon != nil
        soon = t
        guard !pending else { return }
        DispatchQueue.main.async { [weak self, weak live] in
            guard let self, let t = soon else { return }
            soon = nil
            guard let live, !ticker.isRunning, !scrubbing else { return }
            show(t, live: live)
        }
    }

    /// Shows `t` on the hit line (stopped, or after a cue).
    func show(_ t: Double, live: RollLive) {
        self.live = live
        if live.time != t { live.time = t }
        setOffset(for: t)
    }

    private func setOffset(for t: Double) {
        guard let sv = scrollView, !sv.isUserMoving else { return }
        let y = min(max(mapping.offset(forTime: t), 0), mapping.maxOffset) - sv.adjustedContentInset.top
        if abs(sv.contentOffset.y - y) > 0.01 {
            sv.contentOffset = CGPoint(x: sv.contentOffset.x, y: y)
        }
    }

    private func frame(shownAt: CFTimeInterval) {
        guard let clock, let live else { return }
        if scrubbing || scrollView?.isUserMoving == true {
            resuming = true
            holdingAhead = false
            return
        }
        let t = clock.time(at: shownAt)
        var shown = t
        if resuming {
            resuming = false
            if let current = live.time, current > t, current - t < 0.1 { holdingAhead = true }
        }
        if holdingAhead, let current = live.time {
            if t >= current { holdingAhead = false } else { shown = current }
        }
        if live.time != shown { live.time = shown }
        setOffset(for: shown)
    }

    private func recordingFrame(shownAt: CFTimeInterval, frameDuration: CFTimeInterval) {
        guard let recorded, let live else { return }
        let shown = FallingLive.glide(shown: live.time ?? recorded.edge, published: recorded.edge,
                                      sincePublished: shownAt - recorded.at, step: recorded.step,
                                      frame: frameDuration)
        if live.time != shown { live.time = shown }
    }
}

// MARK: - Drawing

/// Sorted times from the first at or after `t` (binary search).
nonisolated func firstIndex(atOrAfter t: Double, in sorted: [Double]) -> Int {
    var lo = 0, hi = sorted.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if sorted[mid] < t { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

/// The notes, beat grid and chord names above the keys, drawn every frame
/// for the time on the hit line (only what's on screen). While recording,
/// that time is worked out from the live edge (`FallingLive`).
private struct FallingNotesCanvas: View {
    let live: RollLive
    let index: NoteTimeIndex
    let chords: [ChordSegment]
    let beatTimes: [Double]
    let downbeatTimes: [Double]
    let isLive: Bool
    let whiteW: CGFloat
    let pxPerSecond: CGFloat

    var body: some View {
        let shown = live.time ?? 0
        Canvas { context, size in
            let hitLine = size.height  // bottom edge = the keys
            let pps = pxPerSecond
            let width = size.width
            let time = isLive ? FallingLive.hitLineTime(edge: shown, height: hitLine, pxPerSecond: pps) : shown
            func y(_ t: Double) -> CGFloat { hitLine - CGFloat(t - time) * pps }
            let window = (time - 0.15)...(time + Double(hitLine / pps) + 0.15)

            // Beat grid: measure lines darkest and numbered, beat lines a step
            // lighter, in navy as on the horizontal roll (`RollTheme`).
            var bar = firstIndex(atOrAfter: window.lowerBound, in: downbeatTimes)
            var beat = firstIndex(atOrAfter: window.lowerBound, in: beatTimes)
            while beat < beatTimes.count, beatTimes[beat] <= window.upperBound {
                let t = beatTimes[beat]
                beat += 1
                while bar < downbeatTimes.count, downbeatTimes[bar] < t - 0.0005 { bar += 1 }
                let isBar = bar < downbeatTimes.count && abs(downbeatTimes[bar] - t) < 0.0005
                let beatY = y(t)
                context.stroke(
                    Path { $0.move(to: CGPoint(x: 0, y: beatY)); $0.addLine(to: CGPoint(x: width, y: beatY)) },
                    with: .style(isBar ? RollTheme.barLine : RollTheme.beatLine),
                    lineWidth: isBar ? 1.2 : 0.6
                )
                if isBar {
                    context.draw(
                        Text("\(bar + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(RollInk.chord),
                        at: CGPoint(x: width - 4, y: beatY - 9), anchor: .trailing
                    )
                }
            }

            // Notes: onset is the lower edge so it meets the keys first. The
            // chords part first, so the lines are drawn over it
            // (`Voice.drawnBeneath`). Each is the part's light fill at the
            // note's loudness with its deeper outline, as on the roll (with
            // Increase Contrast, the outline's colour fills it too).
            let firm = context.environment.colorSchemeContrast == .increased
            let onScreen = index.notes(overlapping: window).filter {
                $0.pitch >= FallingGeometry.minPitch && $0.pitch <= FallingGeometry.maxPitch
            }
            for beneath in [true, false] {
                for note in onScreen where note.voice.drawnBeneath == beneath {
                    let yBottom = y(note.startTime)
                    let yTop = y(note.endTime)
                    guard yBottom > 0, yTop < hitLine else { continue }
                    let ext = FallingGeometry.xExtent(pitch: note.pitch, whiteW: whiteW)
                    let rect = CGRect(x: ext.x + 0.5, y: yTop,
                                      width: ext.width - 1, height: max(yBottom - yTop, 4))
                    let path = Path(roundedRect: rect, cornerRadius: 3)
                    let onBlackKey = note.voice == .none && FallingGeometry.isBlack(note.pitch)
                    let outline = onBlackKey ? Voice.blackKeyNoteOutline : note.voice.outline
                    let fill = firm ? outline : onBlackKey ? Voice.blackKeyNote : note.voice.color
                    context.fill(path, with: .color(fill.opacity(0.4 + 0.55 * note.amplitude)))
                    context.stroke(path, with: .color(outline), lineWidth: 0.75)
                }
            }

            // Chord names just above a dashed divider at each change, so the
            // name of the chord on the hit line isn't cut off by the keys.
            for chord in chords where chord.startTime >= window.lowerBound - 0.2 && chord.startTime <= window.upperBound {
                let cy = y(chord.startTime)
                context.stroke(
                    Path { $0.move(to: CGPoint(x: 0, y: cy)); $0.addLine(to: CGPoint(x: width, y: cy)) },
                    with: .style(RollTheme.chordLine),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
                context.draw(
                    Text(chord.label).font(.system(size: 12, weight: .heavy)).foregroundStyle(RollInk.chord),
                    at: CGPoint(x: 4, y: cy - 1), anchor: .bottomLeading
                )
            }

            // The hit line where notes land on the keys.
            context.stroke(
                Path { $0.move(to: CGPoint(x: 0, y: hitLine - 0.5)); $0.addLine(to: CGPoint(x: width, y: hitLine - 0.5)) },
                with: .style(RollTheme.hitLine), lineWidth: 1
            )
        }
        // The key lanes never move: drawn once, behind.
        .background { FallingLanes(whiteW: whiteW).equatable() }
        .background(RollTheme.surface)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Vertical lane lines rising from every key boundary; notes stay within
/// these lanes. C boundaries are drawn a touch stronger.
private struct FallingLanes: View, Equatable {
    let whiteW: CGFloat

    var body: some View {
        Canvas { context, size in
            var lanes = Path(), octaves = Path()
            for pitch in FallingGeometry.minPitch...(FallingGeometry.maxPitch + 1)
                where !FallingGeometry.isBlack(min(pitch, FallingGeometry.maxPitch)) {
                let x = CGFloat(FallingGeometry.whiteKeys(before: pitch)) * whiteW
                if pitch % 12 == 0 {
                    octaves.move(to: CGPoint(x: x, y: 0)); octaves.addLine(to: CGPoint(x: x, y: size.height))
                } else {
                    lanes.move(to: CGPoint(x: x, y: 0)); lanes.addLine(to: CGPoint(x: x, y: size.height))
                }
            }
            context.stroke(lanes, with: .style(RollTheme.lane), lineWidth: 0.5)
            context.stroke(octaves, with: .style(RollTheme.octaveLane), lineWidth: 0.8)
        }
    }
}

/// The keyboard at the bottom, lit by the notes on the hit line. The keys are
/// drawn once; only the lit ones are drawn per frame.
private struct FallingKeyboard: View {
    let live: RollLive
    let index: NoteTimeIndex
    let isLive: Bool
    let fallingHeight: CGFloat
    let pxPerSecond: CGFloat
    let whiteW: CGFloat

    var body: some View {
        ZStack {
            FallingKeys(whiteW: whiteW).equatable()
            FallingLitKeys(live: live, index: index, isLive: isLive, fallingHeight: fallingHeight,
                           pxPerSecond: pxPerSecond, whiteW: whiteW)
        }
        .background(RollTheme.ground)
        .overlay(alignment: .top) {
            Rectangle().fill(RollTheme.hairline).frame(height: 0.5)
        }
        .allowsHitTesting(false)
        #if DEBUG
        // UI tests check the 88 keys span the screen (fixtures only).
        .accessibilityElement()
        .accessibilityLabel("Keys")
        .accessibilityIdentifier("falling-keyboard")
        .accessibilityHidden(RegressionUIFixture.selected == nil)
        #else
        .accessibilityHidden(true)
        #endif
        // The record transition's piano lands here, drawn as `FallingKeyboardFace`.
        .recordTransitionKeyboard(.falling)
    }

    /// One key, unlit or lit in a part's colour: white keys and navy black
    /// keys (`RollTheme`). A lit key is drawn whole (white or black first),
    /// covering the unlit key and its name.
    static func drawKey(_ pitch: Int, lit: (level: Double, color: Color, rgb: RollInk.RGB)?, whiteW: CGFloat,
                        height: CGFloat, in context: GraphicsContext) {
        let ext = FallingGeometry.xExtent(pitch: pitch, whiteW: whiteW)
        if FallingGeometry.isBlack(pitch) {
            let key = Path(roundedRect: CGRect(x: ext.x, y: 0, width: ext.width, height: height * 0.62), cornerRadius: 1.5)
            context.fill(key, with: .color(RollTheme.blackKey))
            if let lit { context.fill(key, with: .color(lit.color.opacity(lit.level))) }
            return
        }
        let rect = CGRect(x: ext.x, y: 0, width: ext.width, height: height)
        context.fill(Path(rect), with: .color(RollTheme.whiteKey))
        if let lit { context.fill(Path(rect), with: .color(lit.color.opacity(lit.level))) }
        context.stroke(Path(rect), with: .style(RollTheme.keySeam), lineWidth: 0.5)
        if pitch % 12 == 0 {
            // Grey on the white key (the system grey was 3.3:1), or black or
            // white once it's lit enough that grey wouldn't read.
            let key = lit.map { RollInk.RGB.white.under($0.rgb, opacity: $0.level) } ?? .white
            context.draw(
                Text("C\(pitch / 12 - 1)").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(RollInk.text(on: key, preferred: RollInk.keyLabel).color),
                at: CGPoint(x: rect.midX, y: height - 8)
            )
        }
    }
}

/// The keyboard as `FallingKeyboard` shows it with no key lit, `width`
/// wide: the record transition's flying piano, which lands on the keyboard
/// and has to be indistinguishable from it there.
struct FallingKeyboardFace: View {
    let width: CGFloat

    var body: some View {
        FallingKeys(whiteW: width / CGFloat(FallingGeometry.whiteKeyCount))
            .equatable()
            .background(RollTheme.ground)
            .overlay(alignment: .top) {
                Rectangle().fill(RollTheme.hairline).frame(height: 0.5)
            }
    }
}

/// All 88 keys, unlit, drawn once.
private struct FallingKeys: View, Equatable {
    let whiteW: CGFloat

    var body: some View {
        Canvas { context, size in
            for pitch in FallingGeometry.minPitch...FallingGeometry.maxPitch where !FallingGeometry.isBlack(pitch) {
                FallingKeyboard.drawKey(pitch, lit: nil, whiteW: whiteW, height: size.height, in: context)
            }
            for pitch in FallingGeometry.minPitch...FallingGeometry.maxPitch where FallingGeometry.isBlack(pitch) {
                FallingKeyboard.drawKey(pitch, lit: nil, whiteW: whiteW, height: size.height, in: context)
            }
        }
    }
}

/// The keys sounding at the hit line, drawn over the unlit keys every frame.
/// While recording too: the keys light as the notes coming in at the top
/// land on them, as in playback. (Lit for the live edge, they hardly ever
/// lit: the live transcription hasn't reached it yet.)
private struct FallingLitKeys: View {
    let live: RollLive
    let index: NoteTimeIndex
    let isLive: Bool
    /// The falling notes' height and speed: while recording, the moment on
    /// the hit line is worked out from the live edge as the notes' is.
    let fallingHeight: CGFloat
    let pxPerSecond: CGFloat
    let whiteW: CGFloat

    /// How brightly each key at the hit line is lit: 1 as its note lands,
    /// fading linearly to 0 as the note runs out.
    private func keyLevels(at time: Double) -> KeyLights {
        var levels = KeyLights()
        index.forEach(overlapping: (time - 0.05)...(time + 0.02)) { note in
            guard note.startTime <= time + 0.02, note.endTime > time else { return }
            levels.light(note, level: min((note.endTime - time) / max(note.endTime - note.startTime, 1e-6), 1))
        }
        return levels
    }

    var body: some View {
        let shown = live.time ?? 0
        let levels = keyLevels(at: isLive ? FallingLive.hitLineTime(edge: shown, height: fallingHeight,
                                                                    pxPerSecond: pxPerSecond) : shown)
        let lit = levels.pitches.filter { $0 >= FallingGeometry.minPitch && $0 <= FallingGeometry.maxPitch }
        if !lit.isEmpty {
            Canvas { context, size in
                let palette = PartPalette(context.environment)
                func light(_ pitch: Int) -> (level: Double, color: Color, rgb: RollInk.RGB)? {
                    levels[pitch].map { ($0.level, palette.fill($0.voice), palette.rgb($0.voice)) }
                }
                // White keys first; a lit white key covers the black keys
                // beside it, so those are drawn again over it.
                var black = Set(lit.filter(FallingGeometry.isBlack))
                for pitch in lit where !FallingGeometry.isBlack(pitch) {
                    FallingKeyboard.drawKey(pitch, lit: light(pitch), whiteW: whiteW, height: size.height, in: context)
                    for neighbour in [pitch - 1, pitch + 1] where neighbour >= FallingGeometry.minPitch
                        && neighbour <= FallingGeometry.maxPitch && FallingGeometry.isBlack(neighbour) {
                        black.insert(neighbour)
                    }
                }
                for pitch in black {
                    FallingKeyboard.drawKey(pitch, lit: light(pitch), whiteW: whiteW, height: size.height, in: context)
                }
            }
        }
    }
}

#Preview {
    FallingNotesView(
        notes: [
            NoteEvent(startTime: 0, endTime: 2, pitch: 60, amplitude: 0.9),
            NoteEvent(startTime: 0, endTime: 2, pitch: 64, amplitude: 0.7),
            NoteEvent(startTime: 0, endTime: 2, pitch: 67, amplitude: 0.5),
            NoteEvent(startTime: 0.5, endTime: 0.7, pitch: 71, amplitude: 0.8),
            NoteEvent(startTime: 1.0, endTime: 1.4, pitch: 73, amplitude: 0.6),
            NoteEvent(startTime: 1.5, endTime: 2.0, pitch: 76, amplitude: 0.7),
        ],
        chords: [ChordSegment(startTime: 0, endTime: 2, label: "C")],
        time: 0,
        duration: 2,
        isLive: false
    )
}
