import SwiftUI
import UIKit

// Pieces both roll layouts share: what changes every display frame, the
// display link that drives playback follow, a time index for the drawing that
// runs every frame, and text colours that stay readable on the part colours.

/// Values that change every display frame during playback or scrolling. Only
/// the small views that draw them (the header, the keyboard, the playhead
/// line, a pinned note name, the falling notes) read them, so the notes drawn
/// in tiles and the rest of the screen never re-render per frame.
@MainActor @Observable
final class RollLive {
    /// The horizontal roll's scroll offset, net of system content insets.
    var scroll: CGPoint = .zero
    /// Playback time for the frame being drawn, or nil when not playing.
    var time: Double?
}

/// VoiceOver's way to the other roll layout ("Switch to falling notes"),
/// which can't pull the keyboard round the corner. `RollStage` hands it down;
/// the roll's own elements carry it, since an action on the container around
/// them never reaches an element VoiceOver can focus. Equal by name, so a
/// fresh closure on every render doesn't touch the elements.
struct RollSwitchAction: Equatable {
    let name: String
    let perform: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.name == b.name }
}

extension EnvironmentValues {
    @Entry var rollSwitchAction: RollSwitchAction? = nil

    /// Increase Contrast, for the roll's lines drawn off screen. The
    /// record transition's piano is the keyboard drawn into an image,
    /// outside the window, whose environment always says standard contrast
    /// (and `colorSchemeContrast` can't be set); it passes the window's
    /// here, so its seams are as firm as the keyboard's it lands on. Nil
    /// everywhere else: the window's own.
    @Entry var rollContrast: ColorSchemeContrast? = nil
}

extension View {
    /// Adds the roll's switch action (if any) to this accessibility element.
    func rollSwitchAction() -> some View { modifier(RollSwitchActionModifier()) }
}

private struct RollSwitchActionModifier: ViewModifier {
    @Environment(\.rollSwitchAction) private var action

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if let action { Button(action.name, action: action.perform) }
        }
    }
}

/// Calls `onFrame` once per display frame with the time the frame will reach
/// the screen, asking for the display's full rate (120 Hz on ProMotion; the
/// Info.plist allows it on iPhone).
@MainActor
final class FrameTicker: NSObject {
    var onFrame: ((_ shownAt: CFTimeInterval, _ frameDuration: CFTimeInterval) -> Void)?
    private var link: CADisplayLink?

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The link retains its target, so it must be stopped to free the ticker.
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        onFrame?(link.targetTimestamp, link.targetTimestamp - link.timestamp)
    }
}

/// Finds the UIScrollView behind the SwiftUI ScrollView it's placed in (as a
/// background of the scroll content). The follow sets its offset directly:
/// SwiftUI's `scrollTo` runs through the scroll target behaviour (the beat
/// snap), which is meant for the user's own flicks, and animating each step
/// restarts overlapping animations.
struct ScrollViewFinder: UIViewRepresentable {
    let found: (UIScrollView) -> Void

    func makeUIView(context: Context) -> Probe { Probe(found: found) }
    func updateUIView(_ uiView: Probe, context: Context) {
        uiView.found = found
        uiView.find()
    }

    final class Probe: UIView {
        var found: (UIScrollView) -> Void
        init(found: @escaping (UIScrollView) -> Void) {
            self.found = found
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            find()
        }
        func find() {
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    found(scrollView)
                    return
                }
                view = current.superview
            }
        }
    }
}

extension UIScrollView {
    /// The user is holding, dragging or flinging it (not a programmatic move).
    var isUserMoving: Bool { isTracking || isDragging || isDecelerating }
}

/// The notes by when they sound, for drawing that runs every frame and only
/// needs the notes near one moment (the lit keys, the falling notes on
/// screen, a pinned note name): a query visits a few one-second buckets
/// instead of every note of a long take.
nonisolated struct NoteTimeIndex {
    let notes: [NoteEvent]
    private let buckets: [[Int32]]
    private static let bucketSeconds = 1.0

    init(_ notes: [NoteEvent]) {
        self.notes = notes
        let end = notes.map(\.endTime).max() ?? 0
        var buckets = [[Int32]](repeating: [], count: max(1, Int(end / Self.bucketSeconds) + 1))
        for (i, note) in notes.enumerated() {
            let first = Self.bucket(note.startTime, count: buckets.count)
            let last = Self.bucket(max(note.endTime, note.startTime), count: buckets.count)
            for b in first...last { buckets[b].append(Int32(i)) }
        }
        self.buckets = buckets
    }

    private static func bucket(_ t: Double, count: Int) -> Int {
        guard t.isFinite else { return 0 }
        return min(max(Int(t / bucketSeconds), 0), count - 1)
    }

    /// Calls `body` once for each note sounding at some moment in `range`
    /// (a note ending exactly at its lower bound counts), in no set order.
    func forEach(overlapping range: ClosedRange<Double>, _ body: (NoteEvent) -> Void) {
        guard !notes.isEmpty else { return }
        let first = Self.bucket(range.lowerBound, count: buckets.count)
        let last = Self.bucket(range.upperBound, count: buckets.count)
        for b in first...last {
            for i in buckets[b] {
                let note = notes[Int(i)]
                // A note spanning several buckets is visited from the first one in range.
                guard max(Self.bucket(note.startTime, count: buckets.count), first) == b,
                      note.startTime <= range.upperBound, note.endTime >= range.lowerBound else { continue }
                body(note)
            }
        }
    }

    func notes(overlapping range: ClosedRange<Double>) -> [NoteEvent] {
        var found: [NoteEvent] = []
        forEach(overlapping: range) { found.append($0) }
        return found
    }
}

/// The transcription screen's palette, in Home's look (`HomeTheme`), light
/// only like the rest of the app: Home's grouped grey around the roll, a
/// white roll with quiet rows and grid, and brand navy for the ink and the
/// accent (chord names, bar numbers, the play marker and hit line, the
/// black keys). The parts' colours are `Voice.color` and `Voice.outline`.
/// Plain sRGB colours, never resolved per light or dark appearance, so the
/// tiles and per-frame layers draw them as they are.
///
/// Increase Contrast: the system colours the roll drew before this look
/// (the parts, the separators, the greys) each had a firmer shade for it,
/// so these keep one too. Every line (`RollLine`) firms up: the bar, beat,
/// octave and chord lines, the hit line, the C lanes and the key seams to
/// 3:1 or better on white, the hairlines and faint lanes a step. The notes
/// and lit keys fill with their parts' deeper outline colours
/// (`Voice.fill(for:)`), and so do the part chips' dots. The ground, the
/// rows, the navy, the chips' glass and ink and Home itself stay as they
/// are (Home never followed it).
nonisolated enum RollTheme {
    /// The brand navy (16.6:1 on white, 14.9:1 on the ground).
    static let navy = Color(hex: 0x0F1E3A)
    /// Around the roll (the toolbar and parts bar): Home's ground, #F2F2F7.
    static let ground = Color(hex: 0xF2F2F7)
    /// The roll itself: its rows, header and the falling notes' ground.
    static let surface = Color.white
    /// The black keys' rows: a cool near-white, #F1F3F7 (1.11:1 on white,
    /// as quiet as the system grey #F2F2F7 it replaces).
    static let shadedRow = Color(hex: 0xF1F3F7)
    static let shadedRowRGB = RollInk.RGB(0xF1 / 255, 0xF3 / 255, 0xF7 / 255)

    /// Hairlines at the roll's edges: the header's foot, the keyboard's
    /// edge, the top of the falling notes' keys (navy at 15%, #DBDDE1;
    /// with Increase Contrast 35%, 2.2:1 on white).
    static let hairline = RollLine(navy, 0.15, increased: 0.35)
    /// Octave lines across the roll (navy at 20%, 1.5:1 on white; the
    /// system grey was 1.7:1; with Increase Contrast 50%, 3.3:1).
    static let octaveLine = RollLine(navy, 0.2, increased: 0.5)
    /// The beat grid, quieter than 0.96's black at 90% and 45% (17.5:1 and
    /// 3.4:1): bar lines navy at 55% (#7B8393, 3.8:1 on white), beat lines
    /// navy at 30% (#B7BBC4, 1.9:1). With Increase Contrast 80% and 50%
    /// (8.8:1 and 3.3:1).
    static let barLine = RollLine(navy, 0.55, increased: 0.8)
    static let beatLine = RollLine(navy, 0.3, increased: 0.5)
    /// Without a beat grid, a faint line a second (navy at 8%; with
    /// Increase Contrast 25%, 1.7:1).
    static let secondLine = RollLine(navy, 0.08, increased: 0.25)
    /// The dashed line at each chord change (navy at 32%, 2.0:1; it was the
    /// accent blue at 35%; with Increase Contrast 55%, 3.8:1).
    static let chordLine = RollLine(navy, 0.32, increased: 0.55)
    /// The falling notes' hit line, where they meet the keys (navy at 60%,
    /// 4.4:1 on white; it was the accent blue at 60%, 2.1:1; with Increase
    /// Contrast 85%, 10.5:1).
    static let hitLine = RollLine(navy, 0.6, increased: 0.85)
    /// The falling notes' key lanes and their C lanes (navy at 8% and 18%,
    /// 1.2:1 and 1.5:1 on white, as the system greys were; with Increase
    /// Contrast 25% and 50%, 1.7:1 and 3.3:1).
    static let lane = RollLine(navy, 0.08, increased: 0.25)
    static let octaveLane = RollLine(navy, 0.18, increased: 0.5)

    /// The keyboards: white keys, navy black keys (they were near-black
    /// #1F1F1F), and the seams between white keys (navy at 25%, 1.7:1 on
    /// a white key; with Increase Contrast 50%, 3.3:1).
    static let whiteKey = Color.white
    static let blackKey = navy
    static let keySeam = RollLine(navy, 0.25, increased: 0.5)
    /// The live edge while recording: the record red (#C63639, 5.3:1 on
    /// white), from Home.
    static let liveEdge = HomeTheme.record
}

/// One of the rolls' lines: `RollTheme.navy` at a quiet opacity, or at a
/// firmer one with Increase Contrast. A shape style, so a tile, a per-frame
/// layer (`GraphicsContext.Shading.style`) or a hairline view resolves it
/// from its own environment as it draws; resolving it is a comparison.
nonisolated struct RollLine: ShapeStyle {
    let standard: Color
    let increased: Color

    init(_ color: Color, _ opacity: Double, increased firmer: Double) {
        standard = color.opacity(opacity)
        increased = color.opacity(firmer)
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        (environment.rollContrast ?? environment.colorSchemeContrast) == .increased ? increased : standard
    }
}

/// Text colours on the rolls that read at 4.5:1 or better (WCAG AA for the
/// rolls' small text). The system blue is 3.5:1 on white, the system greys
/// 3.3-3.4:1, and white note names on the part colours 1.9-3.4:1, so the
/// rolls draw their own.
nonisolated enum RollInk {
    /// Chord names and bar numbers: the brand navy, 16.6:1 on white, 14.9:1
    /// on the shaded rows and on the ground (the chord blue #0066CC was 5.6:1).
    static let chord = RollTheme.navy
    /// Secondary text (counts, the key, the toolbar's icons), as on Home:
    /// #636366 is 6.0:1 on white and 5.4:1 on the ground the toolbar sits on.
    static let secondary = Color(hex: 0x636366)
    /// Labels on the keys (C4): a navy-tinted grey, #596377, 6.0:1 on a
    /// white key (the grey before it was 5.2:1).
    static let keyLabel = RGB(0x59 / 255, 0x63 / 255, 0x77 / 255)
    /// The navy, for note names on the parts' light fills where it reads.
    static let navyRGB = RGB(0x0F / 255, 0x1E / 255, 0x3A / 255)

    static let minimumContrast = 4.5

    /// A colour in gamma-encoded sRGB, as Core Graphics blends it.
    nonisolated struct RGB: Equatable {
        var r, g, b: Double
        init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

        static let white = RGB(1, 1, 1)
        static let black = RGB(0, 0, 0)

        /// `top` at `opacity` over this colour.
        func under(_ top: RGB, opacity: Double) -> RGB {
            let a = min(max(opacity, 0), 1)
            return RGB(top.r * a + r * (1 - a), top.g * a + g * (1 - a), top.b * a + b * (1 - a))
        }

        /// WCAG relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `preferred` if it reads at 4.5:1 on `background`, otherwise black or
    /// white, whichever reads better (one of them always clears 4.5:1).
    static func text(on background: RGB, preferred: RGB? = nil) -> RGB {
        if let preferred, contrast(preferred, background) >= minimumContrast { return preferred }
        return contrast(.black, background) >= contrast(.white, background) ? .black : .white
    }

    /// `color` as the environment draws it, in sRGB.
    static func rgb(_ color: Color, in environment: EnvironmentValues) -> RGB {
        let resolved = color.resolve(in: environment)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = resolved.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else {
            return RGB(Double(resolved.red), Double(resolved.green), Double(resolved.blue))
        }
        return RGB(Double(c[0]), Double(c[1]), Double(c[2]))
    }
}

/// Colours as the environment draws them, resolved once per appearance
/// (light or dark, increased contrast or not) for the whole app: resolving a
/// Color costs more than drawing a note, and some layers draw every frame.
struct PartPalette {
    private struct Key: Hashable {
        let color: Color
        let scheme: ColorScheme
        let contrast: ColorSchemeContrast
    }
    private static var cache: [Key: RollInk.RGB] = [:]
    private let environment: EnvironmentValues

    init(_ environment: EnvironmentValues) { self.environment = environment }

    func rgb(_ color: Color) -> RollInk.RGB {
        let key = Key(color: color, scheme: environment.colorScheme, contrast: environment.colorSchemeContrast)
        if let known = Self.cache[key] { return known }
        let rgb = RollInk.rgb(color, in: environment)
        Self.cache[key] = rgb
        return rgb
    }

    /// The part's fill for this appearance (`Voice.fill(for:)`).
    func fill(_ voice: Voice) -> Color { voice.fill(for: environment.colorSchemeContrast) }

    func rgb(_ voice: Voice) -> RollInk.RGB { rgb(fill(voice)) }
}
