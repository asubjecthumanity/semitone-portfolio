import SwiftUI
import UIKit

/// The record transition's piano and the red disc it comes out of, flown
/// by Core Animation rather than SwiftUI.
///
/// The flight starts at the tap, and a moment later the transcription
/// screen is pushed under the veil. Building that screen holds up the main
/// thread for a third of a second or so (in the simulator's debug build;
/// less on a phone in a release build, but never nothing), and anything
/// SwiftUI animates stands still for it: the piano froze beside the disc,
/// then set off late. Core Animation's keyframes are played by the render
/// server, which doesn't wait for the main thread, so the piano spirals
/// out and turns over the veil right through the stall, on time.
///
/// The keyframes are `RecordFlight`'s poses, sampled 120 times a second
/// (`RecordFlight.keyframes()`), so the path, the turn and the timing are
/// the ones the tests check; the view only hands them over. They are set
/// again only if the flight changes course: the keyboard laid out
/// somewhere other than where it was expected, or scrolled to other keys.
struct RecordFlightPianoLayer: UIViewRepresentable {
    let flight: RecordTransition.Flight
    /// The overlay's place in the window: the flight's positions are the
    /// window's.
    let origin: CGPoint
    /// The piano has flown its course and lies on the keyboard's frame.
    let flown: (Int) -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Increase Contrast and Bold Text, which the keyboard on screen is
    /// drawn with (its seams firmer, its note names bolder): the piano is
    /// drawn off screen, outside the window's environment, so it is handed
    /// them, or it would land a shade lighter than the keyboard it becomes
    /// and the keyboard would visibly darken at the swap.
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.legibilityWeight) private var legibilityWeight

    func makeUIView(context: Context) -> RecordFlightCanvas {
        RecordFlightCanvas()
    }

    func updateUIView(_ canvas: RecordFlightCanvas, context: Context) {
        canvas.flown = flown
        canvas.fly(flight, origin: origin, look: RecordFlightCanvas.Look(
            scale: displayScale, dynamicTypeSize: dynamicTypeSize,
            contrast: colorSchemeContrast, legibilityWeight: legibilityWeight))
    }

    /// However the flight ends (landing, being cancelled, the safety
    /// timeout), the canvas leaves the screen here. Its animations are held
    /// on the layers after they finish (`isRemovedOnCompletion` is false, so
    /// the piano stays on the keyboard until the swap), and Core Animation
    /// keeps an animation's delegate, the canvas, alive: left as they are,
    /// every take's piano, its pictures and its keyframes would never be let
    /// go.
    static func dismantleUIView(_ canvas: RecordFlightCanvas, coordinator: ()) {
        canvas.tearDown()
    }
}

/// The layers the piano flies in, over the veil:
///
/// - the disc, a copy of the record button's, shrinking away as the piano
///   leaves it;
/// - the shadow, cast by the piano while it is airborne. It is drawn from
///   its own outline (`shadowPath`), so it costs nothing per frame, and on
///   a layer that is never turned, so it always falls down the screen, not
///   whichever way the piano faces;
/// - the spin, at the piano's centre, which turns;
/// - the piano itself, the keyboard's own drawing at the keyboard's own
///   size, which is only scaled (inside the turn, so it is scaled along and
///   across its keys, as `RecordFlight.Pose.scale` means). At the end of
///   the flight it is unscaled, unturned and exactly on the keyboard.
final class RecordFlightCanvas: UIView, CAAnimationDelegate {
    var flown: ((Int) -> Void)?

    private let disc = CALayer()
    private let shadow = CALayer()
    private let spin = CALayer()
    private let piano = CALayer()

    /// What the screen draws with, which the piano, drawn off screen, has
    /// to be drawn with too to match the keyboard.
    struct Look: Equatable {
        var scale: CGFloat
        var dynamicTypeSize: DynamicTypeSize
        var contrast: ColorSchemeContrast
        var legibilityWeight: LegibilityWeight?
    }

    /// What the piano is drawn as: rendered again only if it changes.
    private struct Face: Equatable {
        var layout: RollLayout
        var size: CGSize
        var scrollY: CGFloat
        var look: Look
    }

    /// Where it is flying: flown again only if it changes.
    private struct Course: Equatable {
        var id: Int
        var path: RecordFlight
        var origin: CGPoint
    }

    private var face: Face?
    private var discFace: (side: CGFloat, scale: CGFloat)?
    private var course: Course?
    private var isReleased = false

    /// The disc's copy is drawn this much bigger all round, for its shadow.
    private static let discMargin: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        shadow.shadowColor = UIColor.black.cgColor
        shadow.shadowOpacity = 0
        layer.addSublayer(disc)
        layer.addSublayer(shadow)
        layer.addSublayer(spin)
        spin.addSublayer(piano)
        // The spin is a point at the piano's centre: the piano hangs from
        // it, centred, and turns with it.
        spin.bounds = .zero
        piano.position = .zero
        piano.contentsGravity = .resize
        disc.contentsGravity = .resize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows `flight`: draws the piano and the disc if they have changed,
    /// and sets them off on its course if that has; or, the flight let go,
    /// fades them where they are.
    func fly(_ flight: RecordTransition.Flight, origin: CGPoint, look: Look) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !isReleased else { return }
        if flight.released {
            release()
            return
        }

        let path = flight.path
        let scale = look.scale
        let newFace = Face(layout: flight.layout, size: path.pianoSize, scrollY: flight.scrollY, look: look)
        if newFace != face {
            face = newFace
            piano.contents = Self.render(RecordFlightPiano(layout: newFace.layout, size: newFace.size,
                                                           scrollY: newFace.scrollY)
                                            .environment(\.dynamicTypeSize, look.dynamicTypeSize)
                                            .environment(\.legibilityWeight, look.legibilityWeight)
                                            // The window's own contrast can't be set on a view, so
                                            // the roll's lines are told it directly (`RollLine`).
                                            .environment(\.rollContrast, look.contrast),
                                         scale: scale)
            piano.contentsScale = scale
            piano.bounds = CGRect(origin: .zero, size: newFace.size)
        }
        if discFace?.side != path.startSide || discFace?.scale != scale {
            discFace = (path.startSide, scale)
            disc.contents = Self.render(RecordDiscCopy(side: path.startSide).padding(Self.discMargin), scale: scale)
            disc.contentsScale = scale
            let side = path.startSide + 2 * Self.discMargin
            disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        }

        let newCourse = Course(id: flight.id, path: path, origin: origin)
        if newCourse != course {
            course = newCourse
            setOff(newCourse)
        }
    }

    /// Sets the disc and the piano off on `course`, from the tap: set
    /// again mid-flight (the keyboard laid out elsewhere), they carry on
    /// from where the flight has got to on the new course.
    private func setOff(_ course: Course) {
        let path = course.path
        let poses = path.keyframes()
        let origin = course.origin
        // Timed from the first frame the flight is drawn in: Core Animation
        // starts an animation whose `beginTime` is 0 as its transaction is
        // committed, so none of the flight is spent before it can be seen.
        // Set again on a new course, it keeps that start, already fixed.
        let begin = spin.animation(forKey: "position")?.beginTime ?? 0
        let duration = RecordFlight.duration * RecordTransition.timeScale

        func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.calculationMode = .linear
            animation.beginTime = begin
            animation.duration = duration
            // Held at the first pose until the tap's frame and at the last
            // (on the keyboard) until the landing swaps it for the keyboard.
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
            return animation
        }

        let centres = poses.map { CGPoint(x: $0.center.x - origin.x, y: $0.center.y - origin.y) }
        let position = keyframes("position", centres.map { NSValue(cgPoint: $0) })
        position.delegate = self
        position.setValue(course.id, forKey: Self.flightKey)
        spin.add(position, forKey: "position")
        // Turned by the angle itself rather than by matrices, so the one
        // clockwise turn is exactly that, however coarse the keyframes.
        spin.add(keyframes("transform.rotation.z", poses.map { $0.rotation * .pi / 180 }), forKey: "rotation")
        piano.add(keyframes("transform", poses.map {
            NSValue(caTransform3D: CATransform3DMakeScale($0.scale.width, $0.scale.height, 1))
        }), forKey: "transform")
        piano.add(keyframes("opacity", poses.map { Float($0.opacity) }), forKey: "opacity")

        // The shadow: the piano's outline, scaled, turned and placed as the
        // piano is, offset down the screen and blurred as it is airborne.
        let size = path.pianoSize
        let outlines = zip(poses, centres).map { pose, centre -> CGPath in
            let turn = CGAffineTransform(rotationAngle: pose.rotation * .pi / 180)
            let w = size.width * pose.scale.width / 2, h = size.height * pose.scale.height / 2
            let corners = [CGPoint(x: -w, y: -h), CGPoint(x: w, y: -h), CGPoint(x: w, y: h), CGPoint(x: -w, y: h)]
                .map { $0.applying(turn) }
                .map { CGPoint(x: centre.x + $0.x, y: centre.y + $0.y) }
            let outline = CGMutablePath()
            outline.addLines(between: corners)
            outline.closeSubpath()
            return outline
        }
        shadow.add(keyframes("shadowPath", outlines), forKey: "shadowPath")
        shadow.add(keyframes("shadowOpacity", poses.map { Float(0.24 * $0.lift * $0.opacity) }), forKey: "shadowOpacity")
        shadow.add(keyframes("shadowRadius", poses.map { 10 * $0.lift }), forKey: "shadowRadius")
        shadow.add(keyframes("shadowOffset", poses.map { NSValue(cgSize: CGSize(width: 0, height: 5 * $0.lift)) }),
                   forKey: "shadowOffset")

        // The disc, where the record button's is, over the veil as Home
        // dissolves round it, giving way as the piano comes out of it.
        disc.position = CGPoint(x: path.start.x - origin.x, y: path.start.y - origin.y)
        let discs = (0..<poses.count).map {
            RecordTakeOff.disc(at: Double($0) / Double(poses.count - 1) * RecordFlight.duration)
        }
        disc.add(keyframes("transform", discs.map {
            NSValue(caTransform3D: CATransform3DMakeScale($0.scale, $0.scale, 1))
        }), forKey: "transform")
        disc.add(keyframes("opacity", discs.map { Float($0.opacity) }), forKey: "opacity")

        // Where it all ends, should the animations ever be taken off.
        if let last = poses.last, let centre = centres.last {
            spin.position = centre
            spin.transform = CATransform3DMakeRotation(last.rotation * .pi / 180, 0, 0, 1)
            piano.transform = CATransform3DMakeScale(last.scale.width, last.scale.height, 1)
            piano.opacity = Float(last.opacity)
            disc.opacity = 0
        }
    }

    /// Let go short of the keyboard: the disc and the piano stop where they
    /// are and fade, as the keyboard fades in.
    private func release() {
        isReleased = true
        if let now = spin.presentation() {
            spin.position = now.position
            spin.transform = now.transform
        }
        if let now = piano.presentation() {
            piano.transform = now.transform
            piano.opacity = now.opacity
        }
        if let now = shadow.presentation() {
            shadow.shadowPath = now.shadowPath
            shadow.shadowOpacity = now.shadowOpacity
            shadow.shadowRadius = now.shadowRadius
            shadow.shadowOffset = now.shadowOffset
        }
        if let now = disc.presentation() {
            disc.transform = now.transform
            disc.opacity = now.opacity
        }
        for part in [spin, piano, shadow, disc] { part.removeAllAnimations() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.15
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.opacity = 0
        layer.add(fade, forKey: "release")
    }

    /// Off the screen for good: every animation taken off its layer, which
    /// lets go of the canvas they name as their delegate, and nothing more
    /// said to the transition.
    func tearDown() {
        isReleased = true
        flown = nil
        for part in [spin, piano, shadow, disc, layer] { part.removeAllAnimations() }
    }

    private static let flightKey = "recordFlight"

    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        // Not one taken off for a new course, or let go.
        guard finished, !isReleased, let id = animation.value(forKey: Self.flightKey) as? Int,
              id == course?.id else { return }
        flown?(id)
    }

    /// `view` drawn once into an image, as SwiftUI draws it on screen.
    @MainActor
    private static func render(_ view: some View, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = scale
        return renderer.cgImage
    }
}

/// The record button's red disc and white clef, as `RecordButton` draws
/// them, `side` across.
private struct RecordDiscCopy: View {
    let side: CGFloat

    var body: some View {
        Circle()
            .fill(HomeTheme.record)
            .overlay {
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                                     startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3)),
                                      lineWidth: 1)
            }
            .overlay {
                SemitoneGlyph(color: .white, height: side * 29 / 60)
                    .offset(x: 0.5)
            }
            .frame(width: side, height: side)
            .shadow(color: HomeTheme.record.opacity(0.35), radius: 4, y: 2)
    }
}

/// The flying piano: the roll's own keyboard, drawn as the roll draws it,
/// at the keyboard's size and showing its keys.
private struct RecordFlightPiano: View {
    let layout: RollLayout
    let size: CGSize
    let scrollY: CGFloat

    var body: some View {
        Group {
            switch layout {
            case .horizontal: RollKeyboardFace(scrollY: scrollY)
            case .falling: FallingKeyboardFace(width: size.width)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
