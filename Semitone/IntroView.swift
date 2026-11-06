import SwiftUI

// The launch intro (about 1.8 s), on the icon's navy:
//
//   0.00  The clef draws on from the knob to the tail tip; the knob pops.
//   0.45  The bean springs in, sending out two rings like sound reaching an ear.
//   0.60  "Semitone" rises in under the icon.
//   0.62  A soft tap as the bean lands.
//   1.20  Everything zooms through and fades, and the app settles in.
//
// The launch screen (Info.plist UILaunchScreen) shows the faint clef that the
// intro opens on, at the same size and place, so the handoff can't be seen.
// `IntroView` is a pure function of time: one frame clock and no animation
// state, so it stays smooth, can be scrubbed in the preview, and can be
// rendered to video (Tools/Intro/render.swift).

/// Every time in the intro, in seconds from launch. Tune here.
enum IntroTiming {
    static let drawStart = 0.0
    static let drawDuration = 0.5
    static let beanStart = 0.45
    static let ringStagger = 0.1
    static let ringDuration = 0.4
    /// A soft tap as the bean lands.
    static let hapticAt = 0.62
    static let wordmarkStart = 0.6
    static let wordmarkDuration = 0.4
    static let exitStart = 1.2
    /// The logo is gone before the navy and the app cross over (to `end`).
    static let logoFadeDuration = 0.22
    static let revealStart = 1.32
    static let end = 1.8

    /// With Reduce Motion: the static logo fades up, then crossfades to the app.
    static let reducedFadeIn = 0.2
    static let reducedExitStart = 1.0
    static let reducedLogoFade = 0.12
    static let reducedRevealStart = 1.05
    static let reducedEnd = 1.3

    static func end(reduceMotion: Bool) -> Double { reduceMotion ? reducedEnd : end }
}

/// The springs behind each motion. Opacity uses linear or ease-out only.
enum IntroSprings {
    /// 0.9 → 1.03 → 1.0
    static let knobPop = Spring(response: 0.3, dampingRatio: 0.36)
    static let bean = Spring(response: 0.35, dampingRatio: 0.7)
    static let ring = Spring(response: 0.4, dampingRatio: 1)
    static let wordmark = Spring(response: 0.45, dampingRatio: 1)
    static let exitZoom = Spring(response: 0.6, dampingRatio: 1)
    static let appSettle = Spring(response: 0.5, dampingRatio: 1)
}

/// The logo's geometry, precomputed once. The clef and the bean are drawn in
/// place on a 1024 px artwork square, shown `size` points across.
enum IntroGeometry {
    /// The logo square on screen. The launch screen's LaunchClef image is
    /// rendered at this size (Tools/Intro/make_launch_image.swift).
    static let size: CGFloat = 240
    /// How strongly the undrawn clef shows, on the launch screen and as the
    /// draw-on begins.
    static let ghostOpacity = 0.14
    static let wordmarkOffset: CGFloat = 100
    static let ringDiameter: CGFloat = 46

    private static let artwork: CGFloat = 1024
    private static let k = size / artwork
    private static let knobCenter = CGPoint(x: 428, y: 403)
    private static let knobRadius: CGFloat = 68
    private static let beanCenter = CGPoint(x: 455.5, y: 567.5)
    /// The clef's centerline from the knob's center to the tail tip, taken
    /// from the artwork's skeleton (artwork px).
    private static let spinePoints: [CGPoint] = ([
        (428, 403), (388, 373), (380, 336), (396, 299), (426, 273), (463, 258), (503, 254), (543, 262),
        (577, 284), (600, 317), (615, 355), (623, 395), (624, 435), (619, 475), (610, 514), (596, 552),
        (578, 588), (555, 622), (529, 653), (499, 681), (467, 706), (434, 729), (399, 751), (360, 772),
    ] as [(CGFloat, CGFloat)]).map { CGPoint(x: $0.0 * k, y: $0.1 * k) }

    /// A stroke this wide along the spine covers the clef's thickest part.
    static let strokeWidth: CGFloat = 100 * k
    static let spine: Path = smoothPath(through: spinePoints)
    static let knob = Path(ellipseIn: CGRect(x: knobCenter.x * k - knobRadius * k, y: knobCenter.y * k - knobRadius * k,
                                             width: 2 * knobRadius * k, height: 2 * knobRadius * k))
    /// Everything but the knob, so the knob and the drawn stroke never overlap.
    static let allButKnob: Path = {
        var path = Path(CGRect(x: 0, y: 0, width: size, height: size))
        path.addPath(knob)
        return path
    }()
    static let knobAnchor = UnitPoint(x: knobCenter.x / artwork, y: knobCenter.y / artwork)
    static let beanAnchor = UnitPoint(x: beanCenter.x / artwork, y: beanCenter.y / artwork)
    static let beanPoint = CGPoint(x: beanCenter.x * k, y: beanCenter.y * k)

    /// A Catmull-Rom curve through `points`, as cubic Béziers.
    private static func smoothPath(through p: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: p[0])
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        return path
    }
}

/// The intro at time `t` (seconds from launch). Fills the screen, ignoring
/// the safe area, so the logo sits at the screen's center like the launch image.
struct IntroView: View {
    let t: Double
    var reduceMotion = false
    var clef = Image("IntroClef")
    var bean = Image("IntroBean")

    static let navy = Color(red: 15 / 255, green: 30 / 255, blue: 58 / 255)

    var body: some View {
        ZStack {
            Self.navy.opacity(navyOpacity)
            Group {
                if reduceMotion { staticLogo } else { animatedLogo }
            }
            .frame(width: IntroGeometry.size, height: IntroGeometry.size)
            .overlay { wordmark.offset(y: IntroGeometry.wordmarkOffset) }
            .scaleEffect(zoom)
            .opacity(logoOpacity)
        }
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel("Semitone")
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("launch-intro")
    }

    // MARK: Clef, bean and rings

    private var animatedLogo: some View {
        let drawn = easeOut(progress(IntroTiming.drawStart, IntroTiming.drawDuration))
        // Once drawn and the knob has settled, the plain clef (exact edges).
        let settled = t >= IntroTiming.drawStart + IntroTiming.drawDuration + 0.3
        let knobScale = 0.9 + 0.1 * spring(IntroSprings.knobPop, from: IntroTiming.drawStart)
        return ZStack {
            if settled {
                art(clef)
            } else {
                art(clef).opacity(IntroGeometry.ghostOpacity)
                art(clef)
                    .mask {
                        IntroGeometry.spine.trimmedPath(from: 0, to: drawn)
                            .stroke(style: StrokeStyle(lineWidth: IntroGeometry.strokeWidth, lineCap: .round, lineJoin: .round))
                    }
                    .mask { IntroGeometry.allButKnob.fill(style: FillStyle(eoFill: true)) }
                art(clef)
                    .mask { IntroGeometry.knob }
                    .scaleEffect(knobScale, anchor: IntroGeometry.knobAnchor)
                    .opacity(progress(IntroTiming.drawStart, 0.06))
            }
            rings
            if t >= IntroTiming.beanStart {
                art(bean).scaleEffect(spring(IntroSprings.bean, from: IntroTiming.beanStart), anchor: IntroGeometry.beanAnchor)
            }
        }
    }

    /// Reduce Motion: the whole logo fades up over the faint clef.
    private var staticLogo: some View {
        ZStack {
            art(clef).opacity(IntroGeometry.ghostOpacity)
            ZStack {
                art(clef)
                art(bean)
            }
            .opacity(progress(0, IntroTiming.reducedFadeIn))
        }
    }

    /// Two thin rings out from the bean, like sound arriving at an ear.
    private var rings: some View {
        Canvas { context, _ in
            for i in 0..<2 {
                let start = IntroTiming.beanStart + Double(i) * IntroTiming.ringStagger
                let x = t - start
                guard x >= 0, x <= IntroTiming.ringDuration else { continue }
                let scale = 0.4 + 1.8 * IntroSprings.ring.value(target: 1.0, time: x)
                let d = IntroGeometry.ringDiameter * scale
                let p = IntroGeometry.beanPoint
                context.stroke(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)),
                               with: .color(.white.opacity(0.5 * (1 - x / IntroTiming.ringDuration))), lineWidth: 1.5)
            }
        }
    }

    private func art(_ image: Image) -> some View {
        image.resizable().interpolation(.high)
    }

    // MARK: Wordmark

    private var wordmark: some View {
        let shown = reduceMotion ? progress(0, IntroTiming.reducedFadeIn)
            : easeOut(progress(IntroTiming.wordmarkStart, IntroTiming.wordmarkDuration))
        let settle = reduceMotion ? 1 : spring(IntroSprings.wordmark, from: IntroTiming.wordmarkStart)
        return Text("Semitone")
            .font(.system(size: 30, weight: .semibold, design: .serif))
            .tracking(4 - 3 * settle)
            .foregroundStyle(.white)
            .fixedSize()
            .offset(y: 8 * (1 - settle))
            .opacity(shown)
    }

    // MARK: Exit

    private var zoom: CGFloat {
        reduceMotion ? 1 : 1 + 0.6 * spring(IntroSprings.exitZoom, from: IntroTiming.exitStart)
    }

    /// The logo leaves ahead of the navy, so it never sits over the app.
    private var logoOpacity: Double {
        reduceMotion ? 1 - easeOut(progress(IntroTiming.reducedExitStart, IntroTiming.reducedLogoFade))
            : 1 - easeOut(progress(IntroTiming.exitStart, IntroTiming.logoFadeDuration))
    }

    private var navyOpacity: Double { 1 - Self.reveal(t, reduceMotion: reduceMotion) }

    /// How the app underneath shows at time `t`: it settles from 0.96 and
    /// fades up as the navy clears.
    static func appReveal(at t: Double, reduceMotion: Bool) -> (scale: CGFloat, opacity: Double) {
        guard !reduceMotion else { return (1, reveal(t, reduceMotion: true)) }
        let x = t - IntroTiming.revealStart
        let settle = x > 0 ? IntroSprings.appSettle.value(target: 1.0, time: x) : 0
        return (0.96 + 0.04 * settle, reveal(t, reduceMotion: false))
    }

    private static func reveal(_ t: Double, reduceMotion: Bool) -> Double {
        let start = reduceMotion ? IntroTiming.reducedRevealStart : IntroTiming.revealStart
        return easeOut(clamp((t - start) / (IntroTiming.end(reduceMotion: reduceMotion) - start)))
    }

    // MARK: Curves

    /// Progress through `duration` seconds from `start`, clamped to 0...1.
    private func progress(_ start: Double, _ duration: Double) -> Double { clamp((t - start) / duration) }

    /// A spring's travel (0 → 1, overshooting as it rings) since `start`.
    private func spring(_ spring: Spring, from start: Double) -> Double {
        t > start ? spring.value(target: 1.0, time: t - start) : 0
    }
}

private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

#if os(iOS)
import UIKit

/// Launches that open straight on the app, with no intro. DEBUG builds only:
/// UI tests tap as soon as the app is up, and the intro would take those taps
/// as "skip". A simulator fixture (-semitone-ui-fixture <name>) implies it,
/// -semitone-skip-intro asks for it on its own, and so does hosting unit tests
/// (XCTest sets XCTestConfigurationFilePath). Release builds always play it.
enum IntroLaunch {
    static var skipsIntro: Bool {
        #if DEBUG
        let process = ProcessInfo.processInfo
        return process.arguments.contains("-semitone-ui-fixture")
            || process.arguments.contains("-semitone-skip-intro")
            || process.environment["XCTestConfigurationFilePath"] != nil
        #else
        return false
        #endif
    }
}

/// Shows the intro over the app on a cold launch, then removes it. `played`
/// lives in the app's root state, so coming back from the background never
/// replays it. A tap anywhere skips to the app.
struct IntroCoordinator<Content: View>: View {
    @Binding var played: Bool
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = IntroClock()
    @State private var haptic = UIImpactFeedbackGenerator(style: .soft)

    var body: some View {
        // Paused once played, so the app's view stays put and nothing ticks.
        TimelineView(.animation(paused: played)) { timeline in
            let t = played ? 0 : clock.time(at: timeline.date)
            let reveal = played ? (scale: 1, opacity: 1) : IntroView.appReveal(at: t, reduceMotion: reduceMotion)
            content
                .scaleEffect(reveal.scale)
                .opacity(reveal.opacity)
                .overlay {
                    if !played {
                        IntroView(t: t, reduceMotion: reduceMotion)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: skip)
                            .onChange(of: t >= IntroTiming.hapticAt) { _, cue in
                                if cue { haptic.impactOccurred() }
                            }
                            .onChange(of: t >= IntroTiming.end(reduceMotion: reduceMotion)) { _, done in
                                if done { played = true }
                            }
                    }
                }
        }
        .statusBarHidden(!played)
        .onAppear {
            if !played { haptic.prepare() }
        }
    }

    private func skip() {
        withAnimation(.spring(response: 0.25, dampingFraction: 1)) { played = true }
    }
}

/// The intro's time, from its first frame. It follows the display but moves
/// at most `maxStep` a frame, so a stall while the app starts up pauses the
/// intro for a moment instead of skipping part of it.
final class IntroClock {
    static let maxStep = 0.05
    private var last: Date?
    private var t = 0.0

    func time(at date: Date) -> Double {
        if let last { t += min(max(date.timeIntervalSince(last), 0), Self.maxStep) }
        last = date
        return t
    }
}

#Preview("Intro") {
    IntroPreview()
}

/// Scrub the intro with the slider, or replay it in real time, over a
/// stand-in for the app.
private struct IntroPreview: View {
    @State private var t = 0.0
    @State private var playingSince: Date?
    @State private var reduceMotion = false

    private var end: Double { IntroTiming.end(reduceMotion: reduceMotion) }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.animation(paused: playingSince == nil)) { timeline in
                let time = playingSince.map { timeline.date.timeIntervalSince($0) } ?? t
                let reveal = IntroView.appReveal(at: time, reduceMotion: reduceMotion)
                ZStack {
                    standInApp
                        .scaleEffect(reveal.scale)
                        .opacity(reveal.opacity)
                    if time < end {
                        IntroView(t: time, reduceMotion: reduceMotion)
                    }
                }
                .clipped()
                .onChange(of: time >= end) { _, done in
                    if done, playingSince != nil {
                        playingSince = nil
                        t = end
                    }
                }
            }
            VStack(spacing: 10) {
                HStack {
                    Slider(value: $t, in: 0...end, onEditingChanged: { _ in playingSince = nil })
                    Text(String(format: "%.2f s", t)).monospacedDigit().frame(width: 60)
                }
                HStack {
                    Button("Replay", systemImage: "play.fill") {
                        t = 0
                        playingSince = Date()
                    }
                    .buttonStyle(.borderedProminent)
                    Toggle("Reduce Motion", isOn: $reduceMotion)
                }
            }
            .padding()
            .background(.bar)
        }
    }

    private var standInApp: some View {
        NavigationStack {
            List(1..<12) { Text("Take \($0)") }
                .navigationTitle("Semitone")
        }
    }
}
#endif
