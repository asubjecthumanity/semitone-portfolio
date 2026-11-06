import XCTest
import CoreGraphics
import SwiftUI
@testable import Semitone

/// The record transition's arithmetic: the piano spirals out of the record
/// disc clockwise, turns exactly once clockwise and lands exactly on the
/// roll's keyboard; only Home's record button starting a take flies; and
/// every way a flight ends shows the keyboard again.
final class RecordFlightTests: XCTestCase {
    /// An iPhone 17 Pro upright: the window 402 × 874 pt, the record button
    /// (76 pt, its disc 60) centred at the bottom, and the horizontal roll's
    /// keyboard as the simulator lays it out, below the navigation bar and
    /// the roll's header, down to the bottom edge.
    private let window = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let button = CGRect(x: 163, y: 761, width: 76, height: 76)
    private let column = CGRect(x: 0, y: 150, width: 56, height: 724)
    private let fallingKeys = CGRect(x: 0, y: 744, width: 402, height: 96)

    private func flight(to destination: CGRect) -> RecordFlight {
        RecordFlight(start: CGPoint(x: button.midX, y: button.midY), startSide: 60,
                     destination: destination, bounds: window)
    }

    private var samples: [Double] { (0...260).map { Double($0) / 260 } }

    // MARK: Beat 1: out of the disc

    func testItStartsInTheDiscTinyAndUnseen() {
        let pose = flight(to: column).pose(at: 0)
        XCTAssertEqual(pose.center, CGPoint(x: 201, y: 799), "Out of the disc's centre.")
        XCTAssertEqual(pose.opacity, 0)
        XCTAssertEqual(pose.rotation, 0)
        // About a tenth of the keyboard along its keys: no longer than the disc.
        XCTAssertLessThan(pose.scale.height, 0.1)
        XCTAssertLessThanOrEqual(pose.scale.height * column.height, 60)
        XCTAssertLessThanOrEqual(pose.scale.width * column.width, 60)
        XCTAssertEqual(flight(to: column).pose(at: 0.1).opacity, 1, "Seen within the first tenth of a second.")
    }

    /// Core Animation plays the flight from its poses 120 times a second,
    /// in straight lines between them: they must be the flight itself from
    /// the tap to the landing, and close enough together that the lines
    /// don't show and the turn can't go the wrong way between two of them.
    func testTheKeyframesAreTheFlightFinelyEnough() {
        for destination in [column, fallingKeys] {
            let f = flight(to: destination)
            let poses = f.keyframes()
            XCTAssertEqual(poses.count, RecordFlight.keyframeCount)
            XCTAssertEqual(poses.count, 157, "Every 1/120 s of 1.3 s, both ends included.")
            XCTAssertEqual(poses.first, f.pose(at: 0))
            XCTAssertEqual(poses.last, f.pose(at: 1), "Ends exactly on the keyboard.")
            for (a, b) in zip(poses, poses.dropFirst()) {
                let turn = b.rotation - a.rotation
                XCTAssertGreaterThanOrEqual(turn, 0, "Only ever clockwise.")
                XCTAssertLessThan(turn, 12, "A few degrees a step at most.")
                XCTAssertLessThan(hypot(b.center.x - a.center.x, b.center.y - a.center.y), 16,
                                  "No step long enough to see as a straight line.")
            }
            XCTAssertEqual(poses.last!.rotation - poses.first!.rotation, 360, accuracy: 1e-9)
        }
        XCTAssertEqual(flight(to: column).keyframes(count: 1).count, 2, "Never fewer than both ends.")
    }

    /// Round the disc's centre, its angle only grows: clockwise on a screen
    /// whose y runs down. And the radius only grows: a spiral out.
    func testTheSpiralRunsClockwiseOutward() {
        let f = flight(to: column)
        let start = f.start
        var lastAngle: Double?
        var lastRadius = 0.0
        var turned = 0.0
        for u in stride(from: 0.02, through: 1.0, by: 0.02) {
            let p = f.spiralPoint(at: u)
            // In the spiral's own plane (unsquashed), so the radius is comparable.
            let dx = Double(p.x - start.x) / Double(RecordFlight.spiralSquash)
            let rawDy = Double(p.y - start.y)
            let dy = rawDy > 0 ? rawDy / Double(RecordFlight.belowDiscSquash) : rawDy
            let angle = atan2(dy, dx)
            let radius = hypot(dx, dy)
            if let last = lastAngle {
                let step = (angle - last).remainder(dividingBy: 2 * .pi)
                XCTAssertGreaterThan(step, 0, "Clockwise at u = \(u).")
                turned += step
            }
            XCTAssertGreaterThanOrEqual(radius, lastRadius - 1e-9, "Outward at u = \(u).")
            lastAngle = angle
            lastRadius = radius
            // The spiral angle the maths reports grows too.
            XCTAssertGreaterThan(f.spiralAngle(at: u), f.spiralAngle(at: u - 0.02))
        }
        XCTAssertEqual(turned, RecordFlight.spiralSweep - 0.02 * RecordFlight.spiralSweep, accuracy: 1e-6,
                       "It sweeps round the disc, not back and forth.")
        XCTAssertEqual(f.spiralPoint(at: 0), start)
        XCTAssertEqual(f.spiralPoint(at: 1).x, f.midpoint.x, accuracy: 1e-9)
        XCTAssertEqual(f.spiralPoint(at: 1).y, f.midpoint.y, accuracy: 1e-9)
    }

    /// It rises up the screen to just below the middle and stays on screen
    /// as it turns there.
    func testTheSpiralRisesToTheMiddleOfTheScreen() {
        let f = flight(to: column)
        XCTAssertEqual(f.midpoint.x, window.midX)
        XCTAssertLessThan(f.midpoint.y, f.start.y - 250)
        XCTAssertGreaterThan(f.midpoint.y, window.midY - 1)
        let halfLength = column.height * f.midScale / 2
        XCTAssertGreaterThan(f.midpoint.y - halfLength, window.minY, "Turning, it stays below the top.")
        XCTAssertGreaterThan(f.midpoint.x - halfLength, window.minX, "And inside the sides.")
        for p in samples {
            let c = f.pose(at: p).center
            XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(c), "Its centre stays on screen at \(p).")
        }
    }

    // MARK: Beat 2: one clockwise turn

    func testItTurnsExactlyOnceClockwiseAndEndsAsItStarted() {
        let f = flight(to: column)
        var last = 0.0
        for p in samples {
            let r = f.pose(at: p).rotation
            XCTAssertGreaterThanOrEqual(r, last, "Never back the other way (at \(p)).")
            XCTAssertLessThanOrEqual(r, 360, "No extra partial turn.")
            last = r
        }
        XCTAssertEqual(f.pose(at: 1).rotation, 360, "Exactly one turn...")
        XCTAssertEqual(f.pose(at: 1).rotation.truncatingRemainder(dividingBy: 360), f.pose(at: 0).rotation,
                       "...so it lands turned as it started: the keyboard's own way up.")
        // The turn is done before the piano reaches the keyboard: it glides in upright.
        XCTAssertEqual(RecordFlight.rotation(at: RecordFlight.spinTime.upperBound), 360)
        XCTAssertLessThan(RecordFlight.spinTime.upperBound, RecordFlight.duration)
        // Eased: slow at either end, fastest in the middle, one confident turn.
        let early = RecordFlight.rotation(at: RecordFlight.spinTime.lowerBound + 0.05)
        let middle = RecordFlight.rotation(at: 0.47) - RecordFlight.rotation(at: 0.42)
        XCTAssertLessThan(early, middle)
    }

    /// The beats overlap: from just after the piano leaves the disc until
    /// it is nearly on the keyboard it is always visibly moving, never
    /// hanging mid-screen between the spin and the glide. Measured by the
    /// corner that moves furthest from one 1/120 s keyframe to the next
    /// (the turn moves the corners even when the centre is slow), against
    /// the fastest it ever moves.
    func testItNeverHangsBetweenTheBeats() {
        for destination in [column, fallingKeys] {
            let f = flight(to: destination)
            let poses = f.keyframes()
            func corners(_ pose: RecordFlight.Pose) -> [CGPoint] {
                let turn = CGAffineTransform(rotationAngle: pose.rotation * .pi / 180)
                let w = f.pianoSize.width * pose.scale.width / 2, h = f.pianoSize.height * pose.scale.height / 2
                return [CGPoint(x: -w, y: -h), CGPoint(x: w, y: -h), CGPoint(x: w, y: h), CGPoint(x: -w, y: h)]
                    .map { $0.applying(turn) }
                    .map { CGPoint(x: pose.center.x + $0.x, y: pose.center.y + $0.y) }
            }
            let travel = zip(poses, poses.dropFirst()).map { a, b in
                zip(corners(a), corners(b)).map { hypot($1.x - $0.x, $1.y - $0.y) }.max()!
            }
            let peak = travel.max()!
            let step = RecordFlight.duration / Double(poses.count - 1)
            for (i, moved) in travel.enumerated() {
                let t = Double(i) * step
                guard t >= 0.15, t <= 1.0 else { continue }
                XCTAssertGreaterThan(moved, 0.25 * peak,
                                     "Moving at \(t) s, not hanging (to \(destination)): \(moved) pt against \(peak).")
            }
        }
    }

    // MARK: Beat 3: into the keyboard

    func testItLandsExactlyOnTheKeyboard() {
        for destination in [column, fallingKeys] {
            let f = flight(to: destination)
            let pose = f.pose(at: 1)
            XCTAssertEqual(pose.center, CGPoint(x: destination.midX, y: destination.midY))
            XCTAssertEqual(pose.scale, CGSize(width: 1, height: 1))
            XCTAssertEqual(pose.opacity, 1)
            XCTAssertEqual(pose.lift, 0, "Flat as the keyboard: no shadow at the swap.")
            let landed = CGRect(x: pose.center.x - f.pianoSize.width * pose.scale.width / 2,
                                y: pose.center.y - f.pianoSize.height * pose.scale.height / 2,
                                width: f.pianoSize.width * pose.scale.width,
                                height: f.pianoSize.height * pose.scale.height)
            XCTAssertEqual(landed, destination)
            XCTAssertEqual(f.pose(at: 1.5), pose, "Past the end it stays put.")
        }
    }

    /// The glide only closes on the keyboard, and the piano only grows.
    func testTheGlideClosesInSteadilyAndThePianoOnlyGrows() {
        let f = flight(to: column)
        let target = CGPoint(x: column.midX, y: column.midY)
        var lastDistance = CGFloat.infinity
        var lastScale = CGSize.zero
        for p in samples {
            let pose = f.pose(at: p)
            XCTAssertGreaterThanOrEqual(pose.scale.width, lastScale.width - 1e-9, "At \(p).")
            XCTAssertGreaterThanOrEqual(pose.scale.height, lastScale.height - 1e-9, "At \(p).")
            lastScale = pose.scale
            guard p * RecordFlight.duration >= RecordFlight.flowTime.lowerBound + 0.12 else { continue }
            let distance = hypot(pose.center.x - target.x, pose.center.y - target.y)
            XCTAssertLessThanOrEqual(distance, lastDistance + 1e-6, "At \(p).")
            lastDistance = distance
        }
    }

    /// To the horizontal roll's keyboard it flows up and over to the left;
    /// mid-air it is a stubby keyboard, stretching to the column's own
    /// proportions as it lands.
    func testItFlowsUpToTheLeftSide() {
        let f = flight(to: column)
        let glide = stride(from: 0.0, through: 1.0, by: 0.05).map { f.flowPoint(at: $0) }
        XCTAssertLessThan(glide.map(\.y).min()!, f.midpoint.y - 20, "It rises on the way.")
        XCTAssertTrue(zip(glide, glide.dropFirst()).allSatisfy { $1.x <= $0.x + 1e-9 }, "Always leftward.")
        let mid = f.pose(at: RecordFlight.flowTime.lowerBound / RecordFlight.duration).scale
        XCTAssertGreaterThan(mid.width, mid.height * 1.5, "Thicker than a scaled-down column.")
        XCTAssertGreaterThanOrEqual(mid.width * column.width, 40)
    }

    /// To the falling notes' keys the piano lies flat, the keys running
    /// across; already a stubby keyboard, it is never squashed thinner.
    func testFallingNotesKeysRunAcross() {
        let f = flight(to: fallingKeys)
        let start = f.pose(at: 0).scale
        XCTAssertGreaterThan(start.height, start.width, "Emerging, thick across the keys.")
        let mid = f.pose(at: 0.5).scale
        XCTAssertGreaterThanOrEqual(mid.height, mid.width)
        XCTAssertLessThanOrEqual(fallingKeys.width * f.midScale, window.width * 0.62 + 1e-9, "It turns on screen.")
        XCTAssertEqual(f.pose(at: 1).center, CGPoint(x: fallingKeys.midX, y: fallingKeys.midY))
    }

    // MARK: Timing curves

    func testTimingCurvesRunFromStartToEndAndOnlyForward() {
        for curve in [RecordFlight.glide, RecordFlight.unwind, RecordFlight.easeOut, RecordFlight.easeInOut,
                      RecordFlight.easeInOutSine] {
            XCTAssertEqual(curve(0), 0)
            XCTAssertEqual(curve(1), 1)
            XCTAssertEqual(curve(-1), 0)
            XCTAssertEqual(curve(2), 1)
            var last = 0.0
            for x in stride(from: 0.0, through: 1.0, by: 0.01) {
                XCTAssertGreaterThanOrEqual(curve(x), last - 1e-9)
                last = curve(x)
            }
        }
        XCTAssertEqual(RecordFlight.cubicBezier(0.5, 0.5, 0.5, 0.5, 0.5), 0.5, accuracy: 1e-6, "A straight line.")
    }

    // MARK: Should this push fly?

    func testOnlyTheRecordButtonStartingATakeFlies() {
        func decide(tapped: Bool = true, started: Bool = true, inFlight: Bool = false,
                    reduceMotion: Bool = false, button: Bool = true) -> RecordTakeOff {
            RecordTakeOff.decide(recordTapped: tapped, startedTake: started, inFlight: inFlight,
                                 reduceMotion: reduceMotion, knowsRecordButton: button)
        }
        XCTAssertEqual(decide(), .fly)
        XCTAssertEqual(decide(tapped: false), .push, "Opening or importing a Tone slides in as before.")
        XCTAssertEqual(decide(tapped: false, started: false), .push)
        XCTAssertEqual(decide(started: false), .push, "A tap that showed a busy take instead of starting one.")
        XCTAssertEqual(decide(reduceMotion: true), .crossfade, "Reduce Motion: no spiral, no spin.")
        XCTAssertEqual(decide(button: false), .crossfade, "Nowhere to fly from.")
        XCTAssertEqual(decide(inFlight: true), .wait, "Never two flights at once.")
        XCTAssertEqual(decide(tapped: false, inFlight: true), .wait)
    }

    func testTheVeilCoversThenClears() {
        for kind in [RecordTakeOff.fly, .crossfade] {
            XCTAssertEqual(kind.veil(at: 0), 0, "\(kind) rises over Home from nothing.")
            XCTAssertEqual(kind.veil(at: RecordTakeOff.veilRise), 1, "\(kind) is whole as the screen is pushed under it.")
            XCTAssertEqual(kind.veil(at: kind.duration), 0, "\(kind) ends with it gone.")
        }
        XCTAssertEqual(RecordTakeOff.fly.veil(at: RecordTakeOff.veilCleared), 0, "The roll is clear before the glide.")
        XCTAssertGreaterThan(RecordTakeOff.fly.veil(at: RecordTakeOff.veilCleared - 0.1), 0)
        XCTAssertLessThan(RecordTakeOff.veilCleared, RecordFlight.flowTime.lowerBound)
        XCTAssertEqual(RecordTakeOff.push.veil(at: 0), 0)
        XCTAssertEqual(RecordTakeOff.disc(at: 0).opacity, 1, "The disc stays as Home dissolves round it.")
        XCTAssertEqual(RecordTakeOff.disc(at: 0.5).opacity, 0)
    }

    func testFallbackKeyboardsAreWhereTheRollPutsThem() {
        let safe = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        let left = RecordFlight.fallbackKeyboard(.horizontal, in: window, safeArea: safe, isPhoneLandscape: false)
        XCTAssertEqual(left, column, "Down the left edge below the navigation bar and header, to the bottom.")
        let bottom = RecordFlight.fallbackKeyboard(.falling, in: window, safeArea: safe, isPhoneLandscape: false)
        XCTAssertEqual(bottom, fallingKeys, "Along the bottom, above the home indicator.")
        let side = RecordFlight.fallbackKeyboard(.falling, in: CGRect(x: 0, y: 0, width: 874, height: 402),
                                                 safeArea: EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62),
                                                 isPhoneLandscape: true)
        XCTAssertEqual(side.height, FallingGeometry.landscapeKeyboardHeight)
        XCTAssertEqual(side.maxY, 402 - 21)
    }

    // MARK: The transition's clock

    /// Frame by frame it keeps time; a stall (the push building the
    /// transcription screen) counts as no more than one frame's step, so the
    /// veil pauses rather than coming out of it half gone.
    func testTheClockPausesForAStallRatherThanJumping() {
        var clock = RecordFlightClock()
        XCTAssertEqual(clock.tick(at: 100, limit: 2), 0, "The first frame starts it.")
        var now = 100.0
        for _ in 0..<6 { now += 1.0 / 60; _ = clock.tick(at: now, limit: 2) }
        XCTAssertEqual(clock.time, 0.1, accuracy: 1e-9)
        now += 0.3
        XCTAssertEqual(clock.tick(at: now, limit: 2), 0.1 + RecordFlightClock.longestStep, accuracy: 1e-9,
                       "A 0.3 s stall moves it on one capped step.")
        XCTAssertEqual(clock.tick(at: now, limit: 2), 0.15, accuracy: 1e-9, "The same frame twice: no step.")
        XCTAssertEqual(clock.tick(at: now - 1, limit: 2), 0.15, accuracy: 1e-9, "Never backwards.")
    }

    /// It waits at the limit (the end of the veil's rise, until the push),
    /// then carries on from there; slowed for UI tests, it runs slower.
    func testTheClockWaitsAtItsLimitThenCarriesOn() {
        var clock = RecordFlightClock()
        var now = 0.0
        _ = clock.tick(at: now, limit: RecordTakeOff.veilRise)
        for _ in 0..<30 { now += 1.0 / 60; _ = clock.tick(at: now, limit: RecordTakeOff.veilRise) }
        XCTAssertEqual(clock.time, RecordTakeOff.veilRise, "Held under the veil until the push.")
        now += 1.0 / 60
        XCTAssertEqual(clock.tick(at: now, limit: RecordFlight.duration), RecordTakeOff.veilRise + 1.0 / 60,
                       accuracy: 1e-9, "Then on from where it was, not from the wall clock.")
        for _ in 0..<200 { now += 1.0 / 60; _ = clock.tick(at: now, limit: RecordFlight.duration) }
        XCTAssertEqual(clock.time, RecordFlight.duration, "Exactly the end, never past it.")

        var slow = RecordFlightClock()
        _ = slow.tick(at: 0, limit: 2, scale: 8)
        XCTAssertEqual(slow.tick(at: 0.04, limit: 2, scale: 8), 0.005, accuracy: 1e-9)
    }

    // MARK: The transition's state

    @MainActor
    private func transitionOnHome() -> RecordTransition {
        let transition = RecordTransition()
        transition.windowChanged(to: window)
        transition.recordButtonMoved(to: button)
        return transition
    }

    @MainActor
    private func takeOff(_ transition: RecordTransition, armed: Bool = true, started: Bool = true,
                         reduceMotion: Bool = false) -> RecordTakeOff {
        if armed { transition.armRecordTap() }
        return transition.takeOff(startedTake: started, layout: .horizontal, isPhoneLandscape: false,
                                  reduceMotion: reduceMotion)
    }

    @MainActor
    func testAFlightHidesTheKeyboardUntilItEndsHoweverItEnds() {
        let transition = transitionOnHome()
        XCTAssertEqual(takeOff(transition), .fly)
        XCTAssertTrue(transition.hidesKeyboard)
        XCTAssertEqual(takeOff(transition), .wait, "A second tap mid-flight can't stack another.")
        transition.cancel()
        XCTAssertFalse(transition.hidesKeyboard, "Back on Home: shown again at once.")
        XCTAssertNil(transition.flight)
        XCTAssertEqual(transition.lastOutcome, .cancelled)

        XCTAssertEqual(takeOff(transition), .fly)
        transition.windowChanged(to: CGRect(x: 0, y: 0, width: 874, height: 402))
        XCTAssertFalse(transition.hidesKeyboard, "Turned mid-flight: let go, the keyboard fading in.")
        // Fading, or (with no view on screen to animate) already gone.
        XCTAssertTrue(transition.flight == nil || transition.flight?.released == true)
    }

    /// The microphone's permission prompt (and Control Centre) make the app
    /// inactive, still on screen: the flight carries on. Only the
    /// background ends it.
    @MainActor
    func testOnlyTheBackgroundCancelsAFlight() {
        let transition = transitionOnHome()
        XCTAssertEqual(takeOff(transition), .fly)
        transition.sceneChanged(to: .inactive)
        XCTAssertNotNil(transition.flight, "The first take's microphone prompt doesn't cut it short.")
        XCTAssertTrue(transition.hidesKeyboard)
        transition.sceneChanged(to: .active)
        XCTAssertNotNil(transition.flight)
        transition.sceneChanged(to: .background)
        XCTAssertNil(transition.flight)
        XCTAssertFalse(transition.hidesKeyboard)
        XCTAssertEqual(transition.lastOutcome, .cancelled)
    }

    /// Only a take Home's record button started shows the roll while it is
    /// still starting, and only until it is done starting.
    @MainActor
    func testTheEarlyRollIsOnlyForHomesTake() {
        let transition = transitionOnHome()
        XCTAssertFalse(transition.startedTakeFromHome)
        XCTAssertEqual(takeOff(transition, armed: false), .push)
        XCTAssertFalse(transition.startedTakeFromHome, "Opening a Tone, or any other push.")
        XCTAssertEqual(takeOff(transition), .fly)
        XCTAssertTrue(transition.startedTakeFromHome)
        transition.takeDoneStarting()
        XCTAssertFalse(transition.startedTakeFromHome, "Recording now, or failed: the usual rule again.")
        transition.cancel()
        XCTAssertEqual(takeOff(transition, reduceMotion: true), .crossfade)
        XCTAssertTrue(transition.startedTakeFromHome, "With Reduce Motion too.")
        transition.cancel()
        XCTAssertFalse(transition.startedTakeFromHome, "Back on Home.")
    }

    @MainActor
    func testOnlyAnArmedTapThatStartedATakeFlies() {
        let transition = transitionOnHome()
        XCTAssertEqual(takeOff(transition, armed: false), .push)
        XCTAssertNil(transition.flight)
        XCTAssertEqual(takeOff(transition, started: false), .push)
        XCTAssertEqual(takeOff(transition, reduceMotion: true), .crossfade)
        XCTAssertFalse(transition.hidesKeyboard, "Reduce Motion: the keyboard is simply there.")
    }

    @MainActor
    func testTheFlightAimsAtTheKeyboardOnceItIsLaidOut() {
        let transition = transitionOnHome()
        XCTAssertEqual(takeOff(transition), .fly)
        XCTAssertEqual(transition.flight?.landsOnKeyboard, false, "Before the push it aims at the guess.")
        transition.keyboardLaidOut(.horizontal, frame: CGRect(x: -201, y: -403, width: 56, height: 840))
        XCTAssertEqual(transition.flight?.landsOnKeyboard, false, "A layout passing through, off the window, is ignored.")
        let laidOut = CGRect(x: 0, y: 194, width: 56, height: 680)
        transition.keyboardLaidOut(.horizontal, frame: laidOut)
        XCTAssertEqual(transition.flight?.path.destination, laidOut)
        XCTAssertEqual(transition.flight?.landsOnKeyboard, true)
        transition.keyboardLaidOut(.falling, frame: fallingKeys)
        XCTAssertEqual(transition.flight?.path.destination, laidOut, "The other layout's keyboard isn't the target.")
        transition.keyboardScrolled(.horizontal, to: 120)
        XCTAssertEqual(transition.flight?.scrollY, 120, "The piano shows the keys the keyboard does.")
        transition.keyboardGone(.horizontal)
        XCTAssertFalse(transition.hidesKeyboard, "The take couldn't start: let go.")
    }

    /// The take couldn't start (the microphone refused) before the flight
    /// had set off, or even been pushed: it is let go there and then, never
    /// flown on to a keyboard that won't come.
    @MainActor
    func testATakeThatCouldntStartLetsThePianoGoBeforeItSetsOff() {
        let transition = transitionOnHome()
        XCTAssertEqual(takeOff(transition), .fly)
        XCTAssertEqual(transition.flight?.launched, false)
        transition.takeFailed()
        XCTAssertFalse(transition.hidesKeyboard)
        XCTAssertTrue(transition.flight == nil || transition.flight?.released == true)
        transition.launch(transition.flight?.id ?? 0)
        XCTAssertNotEqual(transition.flight?.launched, true, "Let go, it never sets off.")
        transition.takeFailed()
        XCTAssertTrue(transition.flight == nil || transition.flight?.released == true, "Twice is harmless.")
    }

    @MainActor
    func testTheArmLastsOnlyForTheTap() async {
        let transition = transitionOnHome()
        transition.armRecordTap()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(transition.takeOff(startedTake: true, layout: .horizontal, isPhoneLandscape: false,
                                          reduceMotion: false), .push,
                       "A push after the tap's own handling (a Tone opened later) isn't the record button's.")
    }
}
