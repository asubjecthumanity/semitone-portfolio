import XCTest
import CoreGraphics
@testable import Semitone

/// The arithmetic of pulling the keyboard round the corner: progress as the
/// finger's angle round the hinge, where a let-go lands, how each face of the
/// card turns, and which layout shows on an iPhone on its side.
final class RollFlipTests: XCTestCase {
    /// An iPhone 17 Pro's roll: 402 × 636 pt below the parts bar; the play
    /// line 56 pt in, at the keyboard's edge, the falling notes' keys 96 pt tall.
    private let size = CGSize(width: 402, height: 636)
    private var hinge: CGPoint { RollFlip.hinge(in: size, playLineX: 56, fallingKeyboardHeight: 96) }

    private func at(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: hinge.x + dx, y: hinge.y + dy) }

    @MainActor
    func testTheHingeIsWhereThePlayLineMeetsTheHitLine() {
        XCTAssertEqual(hinge, CGPoint(x: 56, y: 540))
        XCTAssertEqual(RollFlip.hinge(in: CGSize(width: 100, height: 50), playLineX: 56, fallingKeyboardHeight: 96).y, 0,
                       "Never above the roll.")
        // The roll's own play line is the keyboard's edge: the hinge is the
        // corner where the two keyboards meet.
        XCTAssertEqual(PianoRollView.keyboardWidth + RollGeometry().playLineInset, 56)
    }

    /// Up along the keyboard is 0, the diagonal (edge-on) is halfway, along
    /// the bottom is 1; the angle, not the distance, decides.
    func testProgressIsTheFingersAngleRoundTheHinge() {
        var flip = RollFlip(from: .horizontal, hinge: hinge, touch: at(-30, -300))
        XCTAssertEqual(flip.pivot, hinge, "A touch well above the hinge measures round the hinge itself.")
        XCTAssertEqual(flip.progress, 0, "Starting on the keyboard, left of the play line: nothing yet.")
        flip.move(to: at(0, -200))
        XCTAssertEqual(flip.progress, 0, accuracy: 1e-9)
        flip.move(to: at(200 * tan(.pi / 6), -200))   // 30° round
        XCTAssertEqual(flip.progress, 1.0 / 3, accuracy: 1e-9)
        flip.move(to: at(150, -150))
        XCTAssertEqual(flip.progress, 0.5, accuracy: 1e-9, "On the diagonal the card is edge-on.")
        flip.move(to: at(40, -40))
        XCTAssertEqual(flip.progress, 0.5, accuracy: 1e-9, "Only the angle counts, not how far out.")
        flip.move(to: at(200, -200 * tan(.pi / 6)))  // 60° round
        XCTAssertEqual(flip.progress, 2.0 / 3, accuracy: 1e-9)
        flip.move(to: at(250, 0))
        XCTAssertEqual(flip.progress, 1, accuracy: 1e-9)
        flip.move(to: at(250, 60))
        XCTAssertEqual(flip.progress, 1, "Past the bottom edge it stays landed.")
        flip.move(to: at(-60, -250))
        XCTAssertEqual(flip.progress, 0, "Back past the keyboard it stays on the roll.")
    }

    /// The angle is followed continuously: a finger that wanders round below
    /// the hinge and back doesn't wrap a whole turn and snap the card over.
    func testTheAngleNeverJumpsAWholeTurn() {
        var flip = RollFlip(from: .horizontal, hinge: hinge, touch: at(-30, -300))
        // Round the left side and down under the hinge: further from the
        // falling notes all the way, never past 180° into "landed".
        for step in 0...12 {
            let a = -Double(step) / 12 * 170 * .pi / 180
            flip.move(to: CGPoint(x: hinge.x + 200 * sin(a), y: hinge.y - 200 * cos(a)))
            XCTAssertEqual(flip.progress, 0, "step \(step)")
        }
        XCTAssertLessThan(flip.angle, -2.9)
        // And back up and round to the right.
        for step in 0...20 {
            let a = (-170 + Double(step) / 20 * 260) * .pi / 180
            flip.move(to: CGPoint(x: hinge.x + 200 * sin(a), y: hinge.y - 200 * cos(a)))
        }
        XCTAssertEqual(flip.progress, 1, accuracy: 1e-9)
    }

    /// A touch low on the keyboard, near or below the hinge, measures round a
    /// point further down, so a few points of finger don't swing the card
    /// over (or the wrong way round).
    func testATouchNearTheHingeMeasuresRoundAPointBeyondIt() {
        var low = RollFlip(from: .horizontal, hinge: hinge, touch: at(-30, 40))
        XCTAssertEqual(low.pivot, CGPoint(x: hinge.x, y: hinge.y + 40 + RollFlip.minimumRadius))
        XCTAssertEqual(low.progress, 0)
        low.move(to: at(10, 40))
        XCTAssertLessThan(low.progress, 0.1, "Just past the play line it has barely begun.")
        low.move(to: at(RollFlip.minimumRadius, 40))
        XCTAssertEqual(low.progress, 0.5, accuracy: 1e-9)
        low.move(to: at(250, 40))
        XCTAssertGreaterThan(low.progress, 0.7, "Pulled right along the bottom, it goes on over.")
    }

    /// The way back: hold the falling notes' keys and pull up round the
    /// corner to the left edge.
    func testPullingTheFallingKeysUpRoundTheCornerComesBack() {
        var flip = RollFlip(from: .falling, hinge: hinge, touch: at(150, 40))
        XCTAssertEqual(flip.pivot, hinge)
        XCTAssertEqual(flip.progress, 1, "On the keys, below the hit line: still the falling notes.")
        flip.move(to: at(150, -150))
        XCTAssertEqual(flip.progress, 0.5, accuracy: 1e-9)
        flip.move(to: at(10, -300))
        XCTAssertLessThan(flip.progress, 0.05)
        XCTAssertEqual(flip.settles(predictedEnd: at(10, -310)), .horizontal)

        // From the bass end, left of the hinge: round a point further left.
        var bass = RollFlip(from: .falling, hinge: hinge, touch: at(-40, 40))
        XCTAssertEqual(bass.pivot.x, hinge.x - 40 - RollFlip.minimumRadius)
        XCTAssertEqual(bass.progress, 1)
        bass.move(to: at(-40, -RollFlip.minimumRadius))
        XCTAssertEqual(bass.progress, 0.5, accuracy: 1e-9)
    }

    /// Let go past halfway and it lands; short of it, it falls back. A flick
    /// counts by where it would carry the card.
    func testWhereALetGoLands() {
        var flip = RollFlip(from: .horizontal, hinge: hinge, touch: at(-30, -300))
        flip.move(to: at(200, -200 * tan(.pi / 6)))  // 66 %
        XCTAssertEqual(flip.settles(predictedEnd: at(200, -200 * tan(.pi / 6))), .falling)
        flip.move(to: at(200 * tan(.pi / 6), -200))  // 33 %
        XCTAssertEqual(flip.settles(predictedEnd: at(200 * tan(.pi / 6), -200)), .horizontal, "Falls back.")
        XCTAssertEqual(flip.settles(predictedEnd: at(400, -100)), .falling, "A flick round lands from 33 %.")
        flip.move(to: at(200, -200 * tan(.pi / 6)))
        XCTAssertEqual(flip.settles(predictedEnd: at(20, -400)), .horizontal, "A flick back falls back from 66 %.")
        // A flick carried right round under the hinge still counts as landed,
        // not as a whole turn back.
        XCTAssertEqual(flip.settles(predictedEnd: at(-20, 300)), .falling)
    }

    /// The horizontal roll turns 0° to 180° about the hinge's diagonal and the
    /// falling notes -180° to 0°, each showing until the edge-on moment.
    func testEachFaceTurnsAndShowsUntilHalfway() {
        XCTAssertEqual(RollFlip.face(.horizontal, at: 0).degrees, 0)
        XCTAssertTrue(RollFlip.face(.horizontal, at: 0).showing)
        XCTAssertFalse(RollFlip.face(.falling, at: 0).showing)
        XCTAssertEqual(RollFlip.face(.falling, at: 0).degrees, -180)
        XCTAssertEqual(RollFlip.face(.horizontal, at: 1.0 / 3).degrees, 60, accuracy: 1e-9)
        XCTAssertTrue(RollFlip.face(.horizontal, at: 0.49).showing)
        XCTAssertFalse(RollFlip.face(.horizontal, at: 0.5).showing)
        XCTAssertTrue(RollFlip.face(.falling, at: 0.5).showing)
        XCTAssertEqual(RollFlip.face(.falling, at: 2.0 / 3).degrees, -60, accuracy: 1e-9)
        XCTAssertEqual(RollFlip.face(.falling, at: 1).degrees, 0)
        XCTAssertEqual(RollFlip.distance(from: .falling, at: 0.25), 0.75)
        XCTAssertEqual(RollFlip.distance(from: .horizontal, at: 0.25), 0.25)
    }

    @MainActor
    func testTheSwitchActionsNameTheOtherLayout() {
        XCTAssertEqual(RollLayout.horizontal.switchActionName, "Switch to falling notes")
        XCTAssertEqual(RollLayout.falling.switchActionName, "Switch to horizontal roll")
        XCTAssertEqual(RollLayout.horizontal.other, .falling)
        XCTAssertEqual(RollLayout.falling.other, .horizontal)
    }

    /// The hint stays while the card turns (R01's 33% and 66% frames), and
    /// says what letting go will do: short of halfway it falls back, past
    /// it the card lands on the other layout.
    @MainActor
    func testTheHintSaysWhatLettingGoWillDo() {
        XCTAssertEqual(RollStage.hintText(from: .horizontal, pulled: 0), "Pull round to the bottom")
        XCTAssertEqual(RollStage.hintText(from: .horizontal, pulled: 0.33), "Let go: stays horizontal")
        XCTAssertEqual(RollStage.hintText(from: .horizontal, pulled: 0.66), "Let go: falling notes")
        XCTAssertEqual(RollStage.hintText(from: .falling, pulled: 0.05), "Pull round to the left")
        XCTAssertEqual(RollStage.hintText(from: .falling, pulled: 0.4), "Let go: stays falling notes")
        XCTAssertEqual(RollStage.hintText(from: .falling, pulled: 0.5), "Let go: horizontal roll")
        // Letting go of a still finger lands where the hint says.
        var flip = RollFlip(from: .horizontal, hinge: hinge, touch: at(-30, -300))
        for degrees in [10.0, 30, 44, 46, 60, 80] {
            let angle = degrees * .pi / 180
            let point = at(200 * sin(angle), -200 * cos(angle))
            flip.move(to: point)
            let hint = RollStage.hintText(from: .horizontal, pulled: RollFlip.distance(from: .horizontal, at: flip.progress))
            let lands = flip.settles(predictedEnd: point)
            XCTAssertEqual(lands, hint == "Let go: falling notes" ? .falling : .horizontal, "\(degrees)°: \(hint)")
        }
    }

    @MainActor
    func testAnIPhoneOnItsSideAlwaysShowsFallingNotes() {
        XCTAssertEqual(RollLayout.shown(chosen: .horizontal, isPhoneLandscape: false), .horizontal)
        XCTAssertEqual(RollLayout.shown(chosen: .falling, isPhoneLandscape: false), .falling)
        XCTAssertEqual(RollLayout.shown(chosen: .horizontal, isPhoneLandscape: true), .falling)
        XCTAssertEqual(RollLayout.shown(chosen: .falling, isPhoneLandscape: true), .falling)
    }

    /// On its side the notes fall slower, so about as much warning shows above
    /// the shorter keys as upright.
    func testLandscapeFallingNotesShowAboutThreeSecondsAhead() {
        // iPhone 17 Pro on its side: about 300 pt below the parts bar.
        let above = 300 - FallingGeometry.landscapeKeyboardHeight
        XCTAssertGreaterThan(Double(above / FallingGeometry.landscapePxPerSecond), 3)
        XCTAssertLessThan(Double(above / FallingGeometry.pxPerSecond), 2, "At the upright speed it would be under 2 s.")
        let scrub = FallingScrub(duration: 8, pxPerSecond: FallingGeometry.landscapePxPerSecond)
        XCTAssertEqual(scrub.offset(forTime: 2), 6 * 70)
        XCTAssertEqual(scrub.time(forOffset: scrub.offset(forTime: 3.25)), 3.25, accuracy: 1e-9)
    }
}
