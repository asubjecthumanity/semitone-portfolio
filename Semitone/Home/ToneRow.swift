import SwiftUI

/// One Tone in Home's library, a row of the list: a navy thumbnail of its
/// notes as they open (its kind told by their colours, Piano blue,
/// Instrument green, a song's parts in theirs), its title, then its kind,
/// key and length ("Song · E♭ minor · 5:30"), and the day it was made at
/// the trailing edge. VoiceOver reads the row as one element
/// (`accessibilityText`). The button around it, its long-press menu and
/// the separator under it are Home's (`HomeView.toneButton`).
struct ToneRow: View {
    let take: SavedTake
    /// Nil until it has loaded (the row is laid out meanwhile, without a key).
    let preview: TonePreview?
    @Environment(\.dynamicTypeSize) private var typeSize

    var kind: TonePreview.Kind { preview?.kind ?? Self.provisionalKind(take) }
    /// A song's parts: once its notes are read, else as saved (nil for an older take).
    var parts: [TonePreview.Part]? { preview?.parts ?? take.savedParts }

    static let thumbnailSize: CGFloat = 56
    static let thumbnailRadius: CGFloat = 12
    /// Where the words start, after the thumbnail: the separator under a
    /// row starts here too, as a list's does.
    static let textInset: CGFloat = thumbnailSize + 12
    /// With the default text size the row is this tall: the thumbnail and
    /// 8 pt above and below it.
    static let height: CGFloat = 72

    /// Before its notes are read, a tone's kind as saved, so the library is
    /// laid out right at once; for a take saved before kinds were kept, from
    /// its mode alone (an any-instrument take that's one line then shows as
    /// a song until its notes are read).
    static func provisionalKind(_ take: SavedTake) -> TonePreview.Kind {
        take.savedKind ?? (take.mode == TranscriptionMode.music.rawValue ? .song : .piano)
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            // The day beside the title, and the line under them the row's
            // whole width. Only the title gives way to the day (with larger
            // text it wraps to a second line), so every row is laid out the
            // same way, and a row keeps its layout when its key arrives and
            // lengthens the line under the title.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                        .frame(maxWidth: .infinity, alignment: .leading)
                    date
                }
                meta
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        .contentShape(Rectangle())
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The notes on the thumbnails' softer navy (`HomeTheme.tile`), inset a
    /// little from its edge.
    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: Self.thumbnailRadius, style: .continuous)
        return TonePreviewCanvas(kind: kind, preview: preview)
            .padding(7)
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .background {
                shape.fill(kind.tint.fill)
                    .overlay { shape.strokeBorder(kind.tint.edge, lineWidth: 0.5) }
            }
    }

    /// One line, or two with larger text, where a long title has the room
    /// to say more.
    private var title: some View {
        Text(take.title)
            .font(.headline)
            .foregroundStyle(.black)
            .lineLimit(typeSize > .large ? 2 : 1)
    }

    /// "Song · E♭ minor · 5:30"; "Instrument · 0:16" while its key isn't
    /// known (its notes not read yet, or too few to have one).
    private var meta: some View {
        Text(metaText)
            .font(.subheadline)
            .foregroundStyle(HomeTheme.secondary)
            .lineLimit(2)
    }

    var metaText: String {
        ([kind.title] + [preview?.key?.displayName].compactMap { $0 } + [Self.durationLabel(take.duration)])
            .joined(separator: " · ")
    }

    private var date: some View {
        Text(Self.dayLabel(take.createdAt))
            .font(.footnote)
            .foregroundStyle(HomeTheme.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// What VoiceOver reads for the row (internal for the unit tests): its
    /// title, kind (a song's parts named), length and notes, the day, then
    /// its key once that's known. The key comes last so the rest reads as
    /// it always has, whether or not the notes have been read yet.
    var accessibilityText: String {
        let what: String
        switch kind {
        case .piano: what = "Piano"
        // A take without notes (Prerelease 0.99 saved takes of drums alone)
        // has no line to speak of: its thumbnail is empty and it has "0 notes".
        case .instrument: what = take.noteCount == 0 ? "Instrument" : "Instrument, one line"
        case .song:
            if let parts, !parts.isEmpty {
                what = "Song in \(Self.partsWord(parts.count).lowercased()) \(parts.count == 1 ? "part" : "parts"): "
                    + parts.map(\.name).formatted(.list(type: .and))
            } else {
                what = "Song"
            }
        }
        // The row's own words (Today, Yesterday), with the month spelled out
        // for older takes.
        let day = Self.dayLabel(take.createdAt, month: .wide)
        let text = "\(take.title). \(what). \(Self.durationLabel(take.duration)), \(Self.notesLabel(take.noteCount)). \(day)"
        guard let key = preview?.key else { return text }
        return text + ". In \(key.displayName)."
    }

    // MARK: Formatting

    /// "1 note", "249 notes", "2,903 notes", to VoiceOver.
    static func notesLabel(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "note" : "notes")"
    }

    static func partsWord(_ n: Int) -> String {
        ["One", "Two", "Three", "Four"][min(max(n, 1), 4) - 1]
    }

    /// "Today", "Yesterday", "Oct 11", and for another year "Oct 11, 2025".
    static func dayLabel(_ date: Date, month: Date.FormatStyle.Symbol.Month = .abbreviated) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.component(.year, from: date) != calendar.component(.year, from: .now) {
            return date.formatted(.dateTime.month(month).day().year())
        }
        return date.formatted(.dateTime.month(month).day())
    }

    static func durationLabel(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.time(pattern: .minuteSecond))
    }
}

/// A Tone's notes as they open, its MIDI part, in its kind's colours on
/// the navy: rounded bars on the pitches they play, a piano's left hand
/// deeper, a song's parts each in its colour (the chords beneath the lines,
/// as on the roll). A row's thumbnail, and the empty library's sample card.
struct TonePreviewCanvas: View {
    let kind: TonePreview.Kind
    let preview: TonePreview?

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            draw(&context, size: size)
        }
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        guard let preview, !preview.roll.isEmpty else { return }
        // Bars as thick as the sketch's (6 pt) unless the roll spans many
        // semitones, when they thin so neighbouring notes don't merge.
        let h = min(6, max(3.5, size.height / CGFloat(preview.rollSpan + 1) * 2.4))
        let radius = CGSize(width: h / 2, height: h / 2)
        func rect(_ bar: TonePreview.Bar) -> CGRect? {
            let x = size.width * bar.x0
            // A note starting at the very edge would be a hairline sliver: skip
            // what can't show at least a round dot.
            guard size.width - x >= h else { return nil }
            let w = max(size.width * (bar.x1 - bar.x0) - 2, h)
            return CGRect(x: x, y: (size.height - h) * bar.y, width: min(w, size.width - x), height: h)
        }
        if kind == .song {
            // The chords first, so the lines are drawn over them.
            for part in [TonePreview.Part.chords, .bass, .countermelody, .melody] {
                var path = Path()
                for bar in preview.roll where bar.part == part {
                    if let r = rect(bar) { path.addRoundedRect(in: r, cornerSize: radius) }
                }
                context.fill(path, with: .color(ToneTint.part(part)))
            }
            return
        }
        let tint = kind.tint
        // The left hand deeper, where the take's hands part (none for one line).
        let split = kind == .piano ? preview.leftHandBelow ?? Int.min : Int.min
        var high = Path(), low = Path()
        for bar in preview.roll {
            guard let r = rect(bar) else { continue }
            if bar.pitch < split { low.addRoundedRect(in: r, cornerSize: radius) } else { high.addRoundedRect(in: r, cornerSize: radius) }
        }
        context.fill(low, with: .color(tint.noteLow))
        context.fill(high, with: .color(tint.note))
    }
}
