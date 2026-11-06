import SwiftUI

/// The centre of the bottom row, after Voice Memos: a round Liquid Glass
/// button around a red disc carrying the white Semitone clef. While a take
/// is recording the disc shrinks to a stop square and a ring of ticks around
/// it follows the microphone's live input level.
struct RecordButton: View {
    let mode: HomeMode
    let isRecording: Bool
    /// Seconds recorded so far, read out while recording.
    var elapsed: Double = 0
    let meter: InputLevelMeter
    let action: () -> Void

    static let size: CGFloat = 76
    private static let disc: CGFloat = 60
    private static let stop: CGFloat = 24
    /// The red disc's share of the button's width: the record transition's
    /// piano emerges disc-sized.
    static let discRatio = disc / size

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Told where the button is and when it starts a take, so the piano
    /// can fly out of the disc (`RecordTransition`).
    @Environment(RecordTransition.self) private var transition: RecordTransition?

    var body: some View {
        Button {
            if !isRecording { transition?.armRecordTap() }
            action()
        } label: {
            ZStack {
                if isRecording {
                    InputLevelRing(meter: meter)
                        .transition(.opacity)
                }
                face
            }
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
        }
        .buttonStyle(RecordPressStyle())
        .glassEffect(.regular.tint(HomeTheme.controlTint).interactive(), in: Circle())
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.36, dampingFraction: 0.78),
                   value: isRecording)
        .sensoryFeedback(.impact(weight: .medium), trigger: isRecording)
        .accessibilityLabel(isRecording ? "Stop Listening" : "Start Listening")
        .accessibilityValue(isRecording ? "Recording, \(Self.clock(elapsed)), \(mode.title)" : "")
        .accessibilityHint(isRecording ? "" : mode.caption)
        .accessibilityIdentifier("home-record")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            transition?.recordButtonMoved(to: frame)
        }
    }

    /// The red disc with the clef, which shrinks into the stop square.
    private var face: some View {
        let side = isRecording ? Self.stop : Self.disc
        let shape = RoundedRectangle(cornerRadius: isRecording ? 7 : Self.disc / 2, style: .continuous)
        return shape
            .fill(HomeTheme.record)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                                  startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3)),
                                   lineWidth: 1)
            }
            .overlay {
                SemitoneGlyph(color: .white, height: 29)
                    .offset(x: 0.5)
                    .scaleEffect(isRecording ? 0.3 : 1)
                    .opacity(isRecording ? 0 : 1)
            }
            .frame(width: side, height: side)
            .shadow(color: HomeTheme.record.opacity(0.35), radius: isRecording ? 3 : 4, y: 2)
    }

    /// "0:12".
    static func clock(_ seconds: Double) -> String {
        let s = seconds.isFinite ? max(Int(seconds), 0) : 0
        return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
    }
}

/// The disc gives a little under the finger (or dims, with Reduce Motion);
/// the glass around it responds on its own.
private struct RecordPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .brightness(configuration.isPressed && reduceMotion ? -0.08 : 0)
            .saturation(isEnabled ? 1 : 0.4)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Sixty fine ticks around the stop square, each as long as the input level
/// was a moment ago: the newest at twelve o'clock, older ones clockwise, so
/// the last two seconds of sound wrap the button. With Reduce Motion every
/// tick shows the current level instead, so nothing travels round.
struct InputLevelRing: View {
    let meter: InputLevelMeter

    private static let ticks = 60
    private static let inner: CGFloat = 24.5
    private static let minLength: CGFloat = 2.5
    private static let maxLength: CGFloat = 11

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Read here, not in the Canvas closure, so Observation redraws the ring.
        let history = meter.history
        let level = meter.level
        let still = reduceMotion
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            var path = Path()
            for i in 0..<Self.ticks {
                let sample = still ? level : history[history.count - 1 - i * history.count / Self.ticks]
                let a = Double(i) / Double(Self.ticks) * 2 * .pi - .pi / 2
                let (dx, dy) = (CGFloat(cos(a)), CGFloat(sin(a)))
                let outer = Self.inner + Self.minLength + CGFloat(sample) * (Self.maxLength - Self.minLength)
                path.move(to: CGPoint(x: c.x + Self.inner * dx, y: c.y + Self.inner * dy))
                path.addLine(to: CGPoint(x: c.x + outer * dx, y: c.y + outer * dy))
            }
            context.stroke(path, with: .color(HomeTheme.record), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
        .frame(width: RecordButton.size, height: RecordButton.size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    @Previewable @State var meter = InputLevelMeter()
    @Previewable @State var recording = true
    VStack(spacing: 40) {
        RecordButton(mode: .piano, isRecording: false, meter: meter) {}
        RecordButton(mode: .song, isRecording: recording, elapsed: 12, meter: meter) { recording.toggle() }
    }
    .padding(60)
    .background(HomeTheme.ground)
    .task { meter.start(rms: InputLevelMeter.demoSource()) }
}
#endif
