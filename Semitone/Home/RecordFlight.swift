import CoreGraphics
import Foundation

/// The path of the record transition's piano, as plain arithmetic: where it
/// is, how far it has turned and how big it is at any moment of the flight,
/// so the view only places it and the tests can check the motion without
/// a screen.
///
/// Tapping record on Home to start a take sends a piano keyboard out of the
/// red record disc, and the flight has three beats that overlap:
///
/// 1. It spirals out. It starts disc-sized and transparent at the disc's
///    centre and grows as its centre runs out along a clockwise spiral round
///    the disc, the radius growing from nothing, and rises to the middle of
///    the screen.
/// 2. It spins once clockwise, a single eased turn of exactly 360° from just
///    after it leaves the disc until it is well into its glide, so it ends
///    turned the way it started: the way the keyboard it becomes lies
///    (upright down the left edge for the horizontal roll, low notes at the
///    bottom; flat along the bottom for falling notes).
/// 3. It flows to the keyboard: setting off before the spiral is quite done,
///    along a curve up and to the left (or down to the falling notes' keys),
///    growing into exactly the keyboard's frame, where the real keyboard
///    takes over.
///
/// Positions are in the window's coordinates (y runs down), so "clockwise"
/// is an angle that grows as `atan2(dy, dx)` measures it. Times are in
/// seconds of the flight; `pose(at:)` takes the flight's progress, 0 to 1.
///
/// Core Animation flies it (`RecordFlightCanvas`), from `keyframes()`: the
/// render server plays it on the wall clock, so it carries on smoothly
/// through the stall of pushing the transcription screen, which holds up
/// the main thread and everything SwiftUI animates.
nonisolated struct RecordFlight: Equatable {
    /// The centre of the red record disc.
    var start: CGPoint
    /// The disc's width: the piano's longer side as it emerges.
    var startSide: CGFloat
    /// The roll's keyboard on screen, or where it is about to be. The piano
    /// is drawn at this size throughout and only scaled, turned and moved,
    /// so at the end it lies exactly over the keyboard.
    var destination: CGRect
    /// The window the piano flies across.
    var bounds: CGRect

    /// The whole flight. Brisk: it mustn't feel like waiting, and the take
    /// is already recording under it.
    static let duration: Double = 1.3

    /// Beat 1: out along the spiral, growing, to the middle of the screen.
    /// It runs on into the glide rather than stopping for it (see `pose`).
    static let spiralTime: ClosedRange<Double> = 0...0.7
    /// It fades in over the first moment, out of the disc.
    static let appearTime: ClosedRange<Double> = 0...0.1
    /// Beat 2: the one clockwise turn, across nearly the whole flight, so
    /// it is still turning as the glide sets off and the piano never sits
    /// still.
    static let spinTime: ClosedRange<Double> = 0.08...0.95
    /// Beat 3: the glide into the keyboard's frame, setting off before the
    /// spiral is quite done. With the two apart (the spiral over at 0.55 s,
    /// the glide not until 0.74 s) the piano hung mid-screen for a fifth of
    /// a second with its turn all but over, and the flight read as spin,
    /// wait, glide rather than one movement.
    static let flowTime: ClosedRange<Double> = 0.58...1.3
    /// The shadow it casts while airborne goes over the last moment, so it
    /// lands as flat as the keyboard it becomes.
    static let touchdownTime: ClosedRange<Double> = 1.1...1.3

    /// How far round the disc the spiral sweeps: a turn and a bit less, so
    /// it reads as a spiral without wandering off the screen's sides.
    static let spiralSweep = 1.15 * Double.pi
    /// The spiral is narrower than it is tall: a phone is, and a full
    /// circle's width would carry the piano off the sides.
    static let spiralSquash: CGFloat = 0.55
    /// Below the disc's centre the spiral is squashed this much more.
    static let belowDiscSquash: CGFloat = 0.35
    /// The radius grows as this power of the way along, so the piano curls
    /// tight round the disc before it swings wide.
    static let spiralGrowth: Double = 1.5

    struct Pose: Equatable {
        /// Where the piano's centre is.
        var center: CGPoint
        /// Degrees, clockwise.
        var rotation: Double
        /// Of the keyboard's own width and height (before it is turned).
        var scale: CGSize
        var opacity: Double
        /// How airborne it looks, 0 to 1: its shadow's strength.
        var lift: Double
    }

    /// The piano's size: the keyboard's.
    var pianoSize: CGSize { destination.size }

    private var longSide: CGFloat { max(pianoSize.width, pianoSize.height, 1) }
    private var shortSide: CGFloat { max(min(pianoSize.width, pianoSize.height), 1) }
    /// The keys run along the keyboard's longer side.
    private var runsAcross: Bool { pianoSize.width >= pianoSize.height }

    /// As it emerges, along the keys: a little inside the disc.
    var startScale: CGFloat { min(startSide * 0.8 / longSide, 1) }

    /// As it emerges, across the keys: a short, thick bar rather than a
    /// sliver, so it reads as a keyboard from the first moment.
    var startThickness: CGFloat { min(max(startSide * 0.28 / shortSide, startScale), 1) }

    /// Mid-air, between the spiral and the glide, along the keys: its
    /// longer side about two thirds of the screen's width (less on a short
    /// screen), big enough to read as a keyboard and small enough to turn
    /// without leaving the screen. Never smaller than it started, nor
    /// bigger than it lands.
    var midScale: CGFloat {
        let side = min(bounds.width * 0.62, bounds.height * 0.36)
        return min(max(side / longSide, startScale), 1)
    }

    /// Mid-air, across the keys: nearly the keyboard's own width (46 pt),
    /// while the keys are shortened along it. The horizontal roll's
    /// keyboard is a long, thin column (56 by 700 pt or so); scaled down
    /// whole it was a barcode in the air, not a piano. It stretches out to
    /// its own proportions as it flows into place.
    var midThickness: CGFloat { min(max(46 / shortSide, midScale), 1) }

    /// The piano's size scaled `along` its keys and `across` them.
    private func scale(along: CGFloat, across: CGFloat) -> CGSize {
        runsAcross ? CGSize(width: along, height: across) : CGSize(width: across, height: along)
    }

    /// Where the spiral ends: up the screen from the disc, a little below
    /// its middle, so the glide to the keyboard rises rather than drops.
    var midpoint: CGPoint {
        // Clear of the top while it turns, its longer side then sweeping a circle.
        let rise = min(bounds.height * 0.36, max(start.y - bounds.minY - longSide * midScale / 2 - 8, 0))
        return CGPoint(x: bounds.midX, y: start.y - rise)
    }

    // MARK: Beat 1: the spiral

    /// The spiral's angle round the disc where it ends (pointing at the
    /// midpoint), measured in the squashed plane the spiral is drawn in.
    private var spiralEndAngle: Double {
        let m = midpoint
        return atan2(Double(m.y - start.y), Double((m.x - start.x) / Self.spiralSquash))
    }

    private var spiralRadius: Double {
        let m = midpoint
        return hypot(Double((m.x - start.x) / Self.spiralSquash), Double(m.y - start.y))
    }

    /// The angle round the disc `u` of the way along the spiral (0 to 1):
    /// it only grows, which on a screen whose y runs down is clockwise.
    func spiralAngle(at u: Double) -> Double {
        spiralEndAngle - Self.spiralSweep * (1 - Self.clamp(u))
    }

    /// The point `u` of the way along the spiral: the disc's centre at 0,
    /// the midpoint at 1.
    func spiralPoint(at u: Double) -> CGPoint {
        let u = Self.clamp(u)
        let r = spiralRadius * pow(u, Self.spiralGrowth)
        let a = spiralAngle(at: u)
        // Below the disc it is flatter still: the record button sits just
        // above the bottom of the screen.
        let dy = CGFloat(r * sin(a))
        return CGPoint(x: start.x + Self.spiralSquash * CGFloat(r * cos(a)),
                       y: start.y + (dy > 0 ? dy * Self.belowDiscSquash : dy))
    }

    // MARK: Beat 3: the glide

    /// The curve's bend. Towards a keyboard at the side (the horizontal
    /// roll's, down the left edge), the curve bows up first, so the piano
    /// flows up and over to the left rather than sliding across; towards the
    /// falling notes' keys, below, it runs straight down.
    private var flowControl: CGPoint {
        let m = midpoint, d = CGPoint(x: destination.midX, y: destination.midY)
        let sideways = abs(d.x - m.x) > abs(d.y - m.y)
        let lift = sideways ? bounds.height * 0.14 : 0
        return CGPoint(x: d.x + (m.x - d.x) * 0.3, y: min(m.y, d.y) - lift)
    }

    /// The point `v` of the way along the glide (0 to 1): the midpoint at 0,
    /// the keyboard's centre at 1.
    func flowPoint(at v: Double) -> CGPoint {
        let v = CGFloat(Self.clamp(v))
        let m = midpoint, c = flowControl, d = CGPoint(x: destination.midX, y: destination.midY)
        let a = (1 - v) * (1 - v), b = 2 * (1 - v) * v, e = v * v
        return CGPoint(x: a * m.x + b * c.x + e * d.x, y: a * m.y + b * c.y + e * d.y)
    }

    // MARK: The pose

    /// The piano `progress` of the way through the flight (0 to 1).
    func pose(at progress: Double) -> Pose {
        let t = Self.clamp(progress) * Self.duration
        let spiral = Self.fraction(t, of: Self.spiralTime)
        let u = Self.unwind(spiral)
        // It stays small while it curls round the disc, near the bottom of
        // the screen, and grows as it rises.
        let k = CGFloat(Self.easeInOut(spiral))
        let v = Self.glide(Self.fraction(t, of: Self.flowTime))
        // Where the spiral and the glide overlap their movements add: the
        // last of the spiral's run in to the midpoint, and the first of the
        // glide's way out of it. So the piano carries the spiral's speed
        // straight on into the glide, with no seam where one hands over to
        // the other and no moment at rest between them. Outside the overlap
        // it is one or the other alone, so it starts exactly in the disc and
        // ends exactly on the keyboard.
        let center: CGPoint
        if t <= Self.flowTime.lowerBound {
            center = spiralPoint(at: u)
        } else if spiral >= 1 {
            center = flowPoint(at: v)
        } else {
            let s = spiralPoint(at: u), f = flowPoint(at: v), m = midpoint
            center = CGPoint(x: f.x + (s.x - m.x), y: f.y + (s.y - m.y))
        }
        // The size likewise: the spiral's growth to its mid-air size, and
        // the glide's on from there to the keyboard's, added.
        let scale = v >= 1 ? CGSize(width: 1, height: 1) // Exactly the keyboard's size, not a rounding short of it.
            : self.scale(along: startScale + (midScale - startScale) * k + (1 - midScale) * CGFloat(v),
                         across: startThickness + (midThickness - startThickness) * k + (1 - midThickness) * CGFloat(v))
        let appear = Self.fraction(t, of: Self.appearTime)
        let touchdown = Self.fraction(t, of: Self.touchdownTime)
        return Pose(center: center, rotation: Self.rotation(at: t), scale: scale,
                    opacity: appear, lift: min(appear, 1 - Self.easeInOut(touchdown)))
    }

    /// The flight sampled for Core Animation: `count` poses evenly spaced
    /// from the tap to the landing, which it plays one after the other in
    /// straight lines. At 120 a second, as the fastest screens draw, the
    /// straight lines are finer than a frame, and a step of the turn is a
    /// few degrees at most, so the piano turns the way the poses do.
    func keyframes(count: Int = RecordFlight.keyframeCount) -> [Pose] {
        let count = max(count, 2)
        return (0..<count).map { pose(at: Double($0) / Double(count - 1)) }
    }

    /// The flight's poses, one every 1/120 s.
    static let keyframeCount = Int((duration * 120).rounded()) + 1

    /// The turn `t` seconds in: 0 before it starts, exactly 360 after, and
    /// eased in and out between, one confident clockwise turn. The gentler
    /// sine ease rather than the cubic: the cubic was all but done (350° of
    /// the 360) well before its end, so the piano looked to stop turning
    /// and wait before it glided.
    static func rotation(at t: Double) -> Double {
        360 * easeInOutSine(fraction(t, of: spinTime))
    }

    // MARK: Easing

    static func clamp(_ x: Double) -> Double { min(max(x.isFinite ? x : 0, 0), 1) }

    /// How far `t` is through `range`, 0 to 1.
    static func fraction(_ t: Double, of range: ClosedRange<Double>) -> Double {
        clamp((t - range.lowerBound) / max(range.upperBound - range.lowerBound, 1e-9))
    }

    static func easeOut(_ x: Double) -> Double {
        let x = clamp(x)
        return 1 - pow(1 - x, 3)
    }

    static func easeInOut(_ x: Double) -> Double {
        let x = clamp(x)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// Half a cosine: eased in and out, but never so slow at either end
    /// that it looks to have stopped.
    static func easeInOutSine(_ x: Double) -> Double {
        (1 - cos(.pi * clamp(x))) / 2
    }

    /// The spiral's timing: a quick start out of the disc, easing off into
    /// the middle of the screen, but not so quick that the tight curl round
    /// the disc is over before the piano has faded in; and arriving with
    /// some speed left, which the glide takes on. The CSS-style cubic
    /// Bézier (0.2, 0.25, 0.35, 0.85).
    static func unwind(_ x: Double) -> Double {
        cubicBezier(x, 0.2, 0.25, 0.35, 0.85)
    }

    /// The glide's timing: already moving as it sets off (the spiral hands
    /// it its speed, rather than its starting from rest), then a long
    /// settle, so the landing is too slow to see a seam. The CSS-style cubic
    /// Bézier (0.3, 0.12, 0.35, 1).
    static func glide(_ x: Double) -> Double {
        cubicBezier(x, 0.3, 0.12, 0.35, 1)
    }

    /// A timing curve from (0, 0) to (1, 1) with control points (x1, y1)
    /// and (x2, y2): the curve's height where it is `x` across.
    static func cubicBezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let x = clamp(x)
        guard x > 0, x < 1 else { return x }
        func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let r = 1 - s
            return 3 * r * r * s * a + 3 * r * s * s * b + s * s * s
        }
        // Bisection: the curve's x only grows with its parameter.
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bezier(mid, x1, x2) < x { lo = mid } else { hi = mid }
        }
        return bezier((lo + hi) / 2, y1, y2)
    }
}

/// What showing the transcription screen does, decided as Home asks for it.
nonisolated enum RecordTakeOff: Equatable {
    /// As always: the screen slides in.
    case push
    /// The record transition: the piano coming out of the record disc as a
    /// veil of Home's grey rises over Home, the screen pushed under the
    /// veil, then the rest of the piano's flight as the veil clears.
    case fly
    /// Reduce Motion (or no record button to fly from): the veil alone,
    /// Home crossfading to the transcription screen.
    case crossfade
    /// A flight is already on its way, its push with it: nothing more.
    case wait

    /// Only Home's record button starting a take flies: not stopping one,
    /// not opening or importing a Tone, and not a tap that showed a busy
    /// take instead of starting one.
    static func decide(recordTapped: Bool, startedTake: Bool, inFlight: Bool,
                       reduceMotion: Bool, knowsRecordButton: Bool) -> RecordTakeOff {
        if inFlight { return .wait }
        guard recordTapped, startedTake else { return .push }
        return reduceMotion || !knowsRecordButton ? .crossfade : .fly
    }

    /// How long it lasts in all, on the veil's clock: its rise over Home,
    /// then, once the transcription screen is under it, the rest. (A
    /// flight's piano, on the wall clock, takes as long.)
    var duration: Double {
        switch self {
        case .fly: RecordFlight.duration
        case .crossfade: Self.veilRise + 0.3
        case .push, .wait: 0
        }
    }

    /// How long the veil takes to cover Home, after which the transcription
    /// screen is pushed under it. Short: it is the one moment of the
    /// transition that could feel like waiting.
    static let veilRise: Double = 0.1

    /// The longest the push waits for the veil to cover Home, in case its
    /// frames never come: a little longer than the rise takes at its
    /// slowest (a frame's step at most each frame, `RecordFlightClock`).
    static let pushTimeout: Double = 0.4

    /// When a flight's veil has cleared: well before the piano starts its
    /// glide into the roll, so the roll is there to glide into.
    static let veilCleared: Double = 0.5

    /// How much of the veil there is `t` seconds into the transition (on
    /// its own clock, `RecordFlightClock`): rising over Home from nothing,
    /// whole as the transcription screen is pushed under it, then clearing,
    /// the roll showing through as it goes.
    func veil(at t: Double) -> Double {
        let rise = RecordFlight.easeOut(RecordFlight.fraction(t, of: 0...Self.veilRise))
        switch self {
        case .fly: return rise * (1 - RecordFlight.easeInOut(RecordFlight.fraction(t, of: Self.veilRise...Self.veilCleared)))
        case .crossfade: return rise * (1 - RecordFlight.easeInOut(RecordFlight.fraction(t, of: Self.veilRise...duration)))
        case .push, .wait: return 0
        }
    }

    /// The red disc's copy over the veil, which the piano comes out of: whole
    /// as the flight sets off, shrinking away as the piano leaves it.
    static func disc(at t: Double) -> (scale: Double, opacity: Double) {
        let gone = RecordFlight.easeInOut(RecordFlight.fraction(t, of: 0.02...0.3))
        return (1 - 0.35 * gone, 1 - gone)
    }
}

/// The veil's own clock: how far into the transition it is, in seconds of
/// its timing. (The piano flies on the wall clock, in Core Animation.)
///
/// It moves on by each frame's step rather than by the wall clock, and never
/// more than `longestStep` at once. Pushing the transcription screen stalls
/// the main thread (about a third of a second in the simulator's debug
/// build), and an animation on the wall clock would come out of the stall
/// with the veil half gone in one frame; on this clock it clears in full
/// view of the roll, from where it was.
///
/// It also waits at `limit`: the end of the veil's rise, until the
/// transcription screen has been pushed under the veil, so the veil never
/// clears to show Home again.
nonisolated struct RecordFlightClock: Equatable {
    /// The longest step one frame moves the transition on: a frame at
    /// 20 fps, which a busy phone may well manage; anything longer is a
    /// stall, and counts as no more than this.
    static let longestStep: Double = 0.05

    private(set) var time: Double = 0
    private var lastTick: Double?

    /// The transition's time at the frame drawn at `now` (seconds, any
    /// steady clock), going no further than `limit`. `scale` is real
    /// seconds per second of the transition's timing (1, except to slow it
    /// for UI tests). The first tick only starts the clock.
    mutating func tick(at now: Double, limit: Double, scale: Double = 1) -> Double {
        defer { lastTick = now }
        guard let lastTick else { return time }
        let step = min(max(now - lastTick, 0), Self.longestStep) / max(scale, 1e-9)
        time = max(time, min(time + step, limit))
        return time
    }
}
