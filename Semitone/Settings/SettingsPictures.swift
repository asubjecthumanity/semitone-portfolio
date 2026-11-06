import SwiftUI

/// A few seconds of a take, for the small pictures on a Tone's Settings:
/// the notes sounding then, the pitches they span, and the beats.
struct TakeGlimpse {
    var notes: [NoteEvent]
    var start: Double
    var end: Double
    var low: Int
    var high: Int
    var beats: [Double] = []
    var downbeats: [Double] = []

    var span: Double { max(end - start, 0.001) }

    /// `seconds` of `notes` from the first one still sounding at `time`
    /// (or the take's first note), with at least an octave of pitches.
    static func at(_ time: Double, notes: [NoteEvent], seconds: Double = 4, grid: BeatGrid = .empty) -> TakeGlimpse? {
        let sounding = notes.filter { $0.endTime > time }
        guard let first = (sounding.isEmpty ? notes : sounding).map(\.startTime).min() else { return nil }
        let start = max(0, first - 0.15)
        let end = start + seconds
        let shown = notes.filter { $0.endTime > start && $0.startTime < end }
        let (low, high) = pitchRange(shown.map(\.pitch))
        return TakeGlimpse(notes: shown, start: start, end: end, low: low, high: high,
                           beats: grid.beats.filter { $0 >= start && $0 <= end },
                           downbeats: grid.downbeats.filter { $0 >= start && $0 <= end })
    }

    /// The lowest and highest of `pitches`, widened to an octave or more.
    static func pitchRange(_ pitches: [Int]) -> (low: Int, high: Int) {
        guard var low = pitches.min(), var high = pitches.max() else { return (60, 72) }
        var above = true
        while high - low < 12 {
            if (above && high < 108) || low <= 21 { high += 1 } else { low -= 1 }
            above.toggle()
        }
        return (low, high)
    }

    /// A made-up phrase for when nothing has been heard yet: a stand-in
    /// that shows what each layout looks like, not a take.
    static let sample: TakeGlimpse = {
        let melody = [(0.1, 76), (0.6, 74), (1.1, 72), (1.6, 74), (2.1, 76), (2.6, 76), (3.1, 79)]
        let bass = [(0.1, 48), (2.1, 43)]
        var notes = melody.map { NoteEvent(startTime: $0.0, endTime: $0.0 + 0.42, pitch: $0.1, amplitude: 0.8, voice: .melody) }
        notes += bass.map { NoteEvent(startTime: $0.0, endTime: $0.0 + 1.9, pitch: $0.1, amplitude: 0.8, voice: .bass) }
        for (t, chord) in [(0.6, [60, 64, 67]), (1.6, [60, 64, 67]), (2.6, [59, 62, 67]), (3.6, [59, 62, 67])] {
            notes += chord.map { NoteEvent(startTime: t, endTime: t + 0.4, pitch: $0, amplitude: 0.6, voice: .chords) }
        }
        return TakeGlimpse(notes: notes, start: 0, end: 4, low: 43, high: 79,
                           beats: stride(from: 0.1, through: 4, by: 0.5).map { $0 }, downbeats: [0.1, 2.1])
    }()
}

private func isBlackKey(_ pitch: Int) -> Bool {
    [1, 3, 6, 8, 10].contains(((pitch % 12) + 12) % 12)
}

/// A part's colour as the roll draws it (`Voice.color`, the parts' calm
/// fills; unsplit notes take the chords' cornflower).
private func rollColor(_ voice: Voice) -> Color { voice.color }

/// The take in one roll style, the way that layout draws it: the
/// horizontal roll with its key strip at the left, or falling notes over a
/// keyboard. The parts keep their colours on the roll.
struct RollStylePicture: View {
    let layout: RollLayout
    let glimpse: TakeGlimpse

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(SettingsTheme.picture))
            switch layout {
            case .horizontal: drawRoll(in: &context, size: size)
            case .falling: drawFalling(in: &context, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    /// Chords first, so a line over a held chord stays whole (as on the roll).
    private var notesInDrawingOrder: [NoteEvent] {
        glimpse.notes.sorted { $0.voice.drawnBeneath && !$1.voice.drawnBeneath }
    }

    private func drawRoll(in context: inout GraphicsContext, size: CGSize) {
        let keys: CGFloat = 12
        let rows = CGFloat(glimpse.high - glimpse.low + 1)
        let row = size.height / rows
        let x = { (t: Double) in keys + CGFloat((t - glimpse.start) / glimpse.span) * (size.width - keys) }
        context.fill(Path(CGRect(x: 0, y: 0, width: keys, height: size.height)), with: .color(RollTheme.whiteKey))
        for pitch in glimpse.low...glimpse.high where isBlackKey(pitch) {
            let y = CGFloat(glimpse.high - pitch) * row
            context.fill(Path(CGRect(x: 0, y: y + row * 0.1, width: 7, height: max(1, row * 0.8))),
                         with: .color(RollTheme.blackKey))
        }
        context.fill(Path(CGRect(x: keys - 0.5, y: 0, width: 0.5, height: size.height)), with: .color(Color(.separator)))
        for beat in glimpse.beats {
            let downbeat = glimpse.downbeats.contains(beat)
            context.fill(Path(CGRect(x: x(beat), y: 0, width: downbeat ? 1.5 : 1, height: size.height)),
                         with: .color(downbeat ? SettingsTheme.ink.opacity(0.6) : Color(.separator)))
        }
        let height = min(max(row * 0.8, 2), 4.5)
        for note in notesInDrawingOrder {
            let x0 = max(keys, x(note.startTime)), x1 = min(size.width, x(note.endTime))
            guard x1 > x0 else { continue }
            let y = (CGFloat(glimpse.high - note.pitch) + 0.5) * row - height / 2
            let bar = Path(roundedRect: CGRect(x: x0, y: y, width: max(x1 - x0, 2), height: height),
                           cornerRadius: height / 2)
            context.fill(bar, with: .color(rollColor(note.voice).opacity(0.4 + 0.6 * note.amplitude)))
        }
    }

    private func drawFalling(in context: inout GraphicsContext, size: CGSize) {
        let keyboard: CGFloat = 16
        let hit = size.height - keyboard
        // White keys across the take's pitches, black keys between them.
        let low = isBlackKey(glimpse.low) ? glimpse.low - 1 : glimpse.low
        let high = isBlackKey(glimpse.high) ? glimpse.high + 1 : glimpse.high
        let whites = (low...high).filter { !isBlackKey($0) }
        let white = size.width / CGFloat(max(whites.count, 1))
        let black = white * 0.6
        func keyX(_ pitch: Int) -> (x: CGFloat, width: CGFloat) {
            let index = CGFloat(whites.filter { $0 < pitch }.count)
            return isBlackKey(pitch) ? (index * white - black / 2, black) : (index * white, white)
        }
        let y = { (t: Double) in hit - CGFloat((t - glimpse.start) / glimpse.span) * hit }
        for beat in glimpse.beats {
            let downbeat = glimpse.downbeats.contains(beat)
            context.fill(Path(CGRect(x: 0, y: y(beat), width: size.width, height: downbeat ? 1.5 : 1)),
                         with: .color(downbeat ? SettingsTheme.ink.opacity(0.55) : Color(.separator)))
        }
        for note in notesInDrawingOrder {
            let top = max(0, y(note.endTime)), bottom = min(hit, y(note.startTime))
            guard bottom > top else { continue }
            let key = keyX(note.pitch)
            let width = max(key.width * 0.7, 2)
            let base: Color = note.voice == .none && isBlackKey(note.pitch) ? Voice.blackKeyNote : rollColor(note.voice)
            let bar = Path(roundedRect: CGRect(x: key.x + (key.width - width) / 2, y: top, width: width,
                                               height: max(bottom - top, 2)), cornerRadius: min(width / 2, 2))
            context.fill(bar, with: .color(base.opacity(0.4 + 0.55 * note.amplitude)))
        }
        context.fill(Path(CGRect(x: 0, y: hit, width: size.width, height: keyboard)), with: .color(RollTheme.whiteKey))
        for (index, _) in whites.enumerated() where index > 0 {
            context.fill(Path(CGRect(x: CGFloat(index) * white - 0.25, y: hit, width: 0.5, height: keyboard)),
                         with: .style(RollTheme.keySeam))
        }
        for pitch in low...high where isBlackKey(pitch) {
            let key = keyX(pitch)
            context.fill(Path(roundedRect: CGRect(x: key.x, y: hit, width: key.width, height: keyboard * 0.58),
                              cornerRadius: 1), with: .color(RollTheme.blackKey))
        }
        context.fill(Path(CGRect(x: 0, y: hit - 0.5, width: size.width, height: 1)),
                     with: .style(RollTheme.hitLine))
    }
}

/// One detection preset's picture: the open take's notes as that preset
/// keeps them (fainter notes paler), over the same seconds and pitches as
/// the others, so the cards compare. Where the take's notes aren't the
/// quick detector's (or there's no take), `notes` is nil and a small
/// drawing of the preset's character stands in, the same on every take.
struct PresetPicture: View {
    let mode: DetectionMode
    let notes: [NoteEvent]?
    var start = 0.0
    var end = 1.0
    var low = 60
    var high = 72

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(SettingsTheme.picture))
            if let notes {
                draw(notes, in: &context, size: size)
            } else {
                drawGlyph(in: &context, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ notes: [NoteEvent], in context: inout GraphicsContext, size: CGSize) {
        let inset: CGFloat = 4
        let span = max(end - start, 0.001)
        let rows = CGFloat(high - low + 1)
        let row = (size.height - 2 * inset) / rows
        let height = min(max(row * 0.85, 2), 4)
        let middle = (low + high) / 2
        for note in notes {
            let x0 = inset + CGFloat((max(note.startTime, start) - start) / span) * (size.width - 2 * inset)
            let x1 = inset + CGFloat((min(note.endTime, end) - start) / span) * (size.width - 2 * inset)
            let y = inset + (CGFloat(high - note.pitch) + 0.5) * row - height / 2
            let color = note.pitch > middle ? SettingsTheme.note : SettingsTheme.noteLow
            context.fill(Path(roundedRect: CGRect(x: x0, y: y, width: max(x1 - x0, 2), height: height),
                              cornerRadius: height / 2),
                         with: .color(color.opacity(0.35 + 0.65 * note.amplitude)))
        }
    }

    /// (x, y, width, thickness, low hand) in a 72 × 42 box, after the board.
    private var glyph: [(CGFloat, CGFloat, CGFloat, CGFloat, Bool)] {
        switch mode {
        case .gentle:
            [(4, 8, 7, 4, false), (13, 16, 5, 4, false), (20, 6, 7, 4, false), (29, 21, 5, 4, false),
             (36, 12, 7, 4, false), (45, 4, 5, 4, false), (52, 10, 7, 4, false), (61, 17, 6, 4, false),
             (8, 29, 5, 4, true), (22, 34, 4, 4, true), (33, 30, 6, 4, true), (48, 35, 4, 4, true), (58, 31, 6, 4, true)]
        case .dense:
            [(5, 8, 26, 6, false), (34, 14, 32, 6, false), (5, 29, 62, 6, true)]
        case .custom:
            []
        case .auto, .piano:
            [(5, 9, 14, 4, false), (21, 17, 10, 4, false), (33, 7, 14, 4, false), (49, 13, 12, 4, false),
             (5, 31, 30, 4, true), (38, 33, 28, 4, true)]
        }
    }

    private func drawGlyph(in context: inout GraphicsContext, size: CGSize) {
        let sx = size.width / 72, sy = size.height / 42
        if mode == .custom {
            // The custom pad: a grid with its dot.
            var grid = Path()
            for i in 1..<4 {
                let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
                grid.move(to: CGPoint(x: x, y: 4)); grid.addLine(to: CGPoint(x: x, y: size.height - 4))
                grid.move(to: CGPoint(x: 4, y: y)); grid.addLine(to: CGPoint(x: size.width - 4, y: y))
            }
            context.stroke(grid, with: .color(SettingsTheme.ring.opacity(0.5)), lineWidth: 0.5)
            context.fill(Path(ellipseIn: CGRect(x: size.width * 0.62 - 5, y: size.height * 0.38 - 5, width: 10, height: 10)),
                         with: .color(SettingsTheme.note))
            return
        }
        for (x, y, width, thickness, lowHand) in glyph {
            context.fill(Path(roundedRect: CGRect(x: x * sx, y: y * sy, width: width * sx, height: thickness * sy),
                              cornerRadius: thickness * sy / 2),
                         with: .color(lowHand ? SettingsTheme.noteLow : SettingsTheme.note))
        }
        if mode == .auto {
            let star = Path { p in
                let c = CGPoint(x: size.width - 9 * sx, y: 9 * sy), r = 6 * sy, i = 2 * sy
                p.move(to: CGPoint(x: c.x, y: c.y - r))
                p.addLine(to: CGPoint(x: c.x + i, y: c.y - i)); p.addLine(to: CGPoint(x: c.x + r, y: c.y))
                p.addLine(to: CGPoint(x: c.x + i, y: c.y + i)); p.addLine(to: CGPoint(x: c.x, y: c.y + r))
                p.addLine(to: CGPoint(x: c.x - i, y: c.y + i)); p.addLine(to: CGPoint(x: c.x - r, y: c.y))
                p.addLine(to: CGPoint(x: c.x - i, y: c.y - i)); p.closeSubpath()
            }
            context.fill(star, with: .color(SettingsTheme.accent))
        }
    }
}

/// The bars of the open take as the roll draws them: beat lines, darker
/// bar lines with their numbers, the notes in their parts' colours and,
/// on the Beat grid page, the chord names. Redrawn as the take's grid
/// changes, so tempo, meter and bar-line choices show here as they land on
/// the roll. Faded where the roll hides the grid.
struct BeatGridPicture: View {
    let grid: BeatGrid
    let notes: [NoteEvent]
    var chords: [ChordSegment] = []
    var duration: Double
    /// Starts on the bar this time falls in.
    var time: Double
    var bars = 4
    var showsChords = false
    var gridShown = true

    /// The stretch to draw: `bars` bars from the one `time` is in (or the
    /// take's last `bars`), or the whole grid when it's shorter.
    static func window(grid: BeatGrid, time: Double, duration: Double, bars: Int) -> (start: Double, end: Double)? {
        let downbeats = grid.downbeats
        if downbeats.count > bars {
            let current = downbeats.lastIndex { $0 <= time } ?? 0
            let first = min(current, downbeats.count - 1 - bars)
            return (downbeats[first], downbeats[first + bars])
        }
        guard let start = downbeats.first ?? grid.beats.first else { return nil }
        let end = max(grid.beats.last ?? 0, duration)
        return end > start ? (start, end) : nil
    }

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(SettingsTheme.picture))
            guard let window = Self.window(grid: grid, time: time, duration: duration, bars: bars) else { return }
            let span = window.end - window.start
            let inset: CGFloat = 4
            let x = { (t: Double) in inset + CGFloat((t - window.start) / span) * (size.width - 2 * inset) }
            let chordBand: CGFloat = showsChords ? 18 : 0
            if showsChords {
                for chord in chords where chord.endTime > window.start && chord.startTime < window.end {
                    context.draw(Text(chord.label).font(.system(size: 13, weight: .heavy)).foregroundStyle(SettingsTheme.chord),
                                 at: CGPoint(x: x(max(chord.startTime, window.start)) + 3, y: 1), anchor: .topLeading)
                }
            }
            let gridOpacity = gridShown ? 1.0 : 0.35
            for beat in grid.beats where beat >= window.start && beat < window.end {
                context.fill(Path(CGRect(x: x(beat), y: chordBand, width: 1, height: size.height - chordBand)),
                             with: .color(Color(.separator).opacity(gridOpacity)))
            }
            for (index, downbeat) in grid.downbeats.enumerated() where downbeat >= window.start && downbeat < window.end {
                context.fill(Path(CGRect(x: x(downbeat), y: chordBand, width: 1.5, height: size.height - chordBand)),
                             with: .color(SettingsTheme.ink.opacity(0.6 * gridOpacity)))
                context.draw(Text("\(index + 1)").font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(SettingsTheme.ink.opacity(gridOpacity)),
                             at: CGPoint(x: x(downbeat) + 3, y: chordBand + 1), anchor: .topLeading)
            }
            let shown = notes.filter { $0.endTime > window.start && $0.startTime < window.end }
                .sorted { $0.voice.drawnBeneath && !$1.voice.drawnBeneath }
            let (low, high) = TakeGlimpse.pitchRange(shown.map(\.pitch))
            let top = chordBand + 14, bottom = size.height - 3
            let row = (bottom - top) / CGFloat(high - low + 1)
            let height = min(max(row * 0.85, 2), 4)
            for note in shown {
                let x0 = x(max(note.startTime, window.start)), x1 = x(min(note.endTime, window.end))
                let y = top + (CGFloat(high - note.pitch) + 0.5) * row - height / 2
                context.fill(Path(roundedRect: CGRect(x: x0, y: y, width: max(x1 - x0 - 1, 2), height: height),
                                  cornerRadius: height / 2),
                             with: .color(rollColor(note.voice).opacity(0.4 + 0.6 * note.amplitude)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// How densely the beats fall at each tempo choice: half as many, as
/// detected (bar lines darker), twice as many.
struct TempoTicks: View {
    let octave: Int

    var body: some View {
        Canvas { context, size in
            let count = octave < 0 ? 4 : octave > 0 ? 13 : 7
            for i in 0..<count {
                let x = (size.width - 1.5) * CGFloat(i) / CGFloat(count - 1)
                let bar = octave == 0 && i % 4 == 0
                context.fill(Path(roundedRect: CGRect(x: x, y: 0, width: 1.5, height: size.height), cornerRadius: 0.75),
                             with: .color(bar ? SettingsTheme.accent : SettingsTheme.ring))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Where beat 1 sits after the bar-line nudges: a row of beats with the
/// bar line moved that many beats from where it was detected (the middle).
struct BarShiftPicture: View {
    let shift: Int

    var body: some View {
        Canvas { context, size in
            let beats = 9
            let step = (size.width - 2) / CGFloat(beats - 1)
            context.fill(Path(roundedRect: CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2), cornerRadius: 1),
                         with: .color(Color(.systemGray5)))
            for i in 0..<beats {
                context.fill(Path(CGRect(x: CGFloat(i) * step, y: size.height * 0.2, width: 1.5, height: size.height * 0.6)),
                             with: .color(SettingsTheme.ring))
            }
            let index = min(max(beats / 2 + shift, 0), beats - 1)
            let x = CGFloat(index) * step - 0.75
            context.fill(Path(roundedRect: CGRect(x: x, y: 0, width: 3, height: size.height), cornerRadius: 1.5),
                         with: .color(SettingsTheme.accent))
            context.draw(Text("1").font(.system(size: 11, weight: .heavy)).foregroundStyle(SettingsTheme.accent),
                         at: CGPoint(x: x + 7, y: 1), anchor: .topLeading)
        }
        .accessibilityHidden(true)
    }
}
