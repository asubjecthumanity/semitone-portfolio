import SwiftUI

/// A Tone's Settings (the transcription screen's gear): how Tones are shown
/// and read, the three groups the owner gave this menu. Roll style and the
/// Detection presets as pictures of the open take, and its beat grid, with a
/// page of its own for meter, tempo and bar lines. What's app-wide (the
/// piano model for new takes, the AI provider, links, credits) is in Home's
/// Settings; transcribing the take again, its piano model and its AI cleanup
/// act on the take, so they're in its long-press menu on Home
/// (`ToneTranscriptionMenu`).
///
/// Most of these are still one stored choice for every Tone, as in 0.97:
/// the roll style, the detection preset and custom pad, Show beat grid,
/// beats per bar and the downbeat note. Changing one re-reads the open
/// Tone at once, and other Tones when they're next opened (a Tone that shows
/// the quick detector's notes takes the new preset's notes then). Only the
/// tempo and bar-line nudges are the open take's own. The footers say which.
struct ToneSettingsView: View {
    @ObservedObject var viewModel: TranscriberViewModel
    @AppStorage(RollLayout.storageKey) private var rollLayoutRaw = RollLayout.horizontal.rawValue
    /// Where the pictures look: the playhead when the sheet opened, so
    /// playback underneath doesn't scroll them.
    @State private var time: Double
    /// The presets' own notes for their pictures, when the take shows the
    /// quick detector's notes (`TranscriberViewModel.presetNotes`).
    @State private var presets: PresetGlimpse?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var presetWidth: CGFloat = 84

    enum Page: Hashable {
        case beatGrid
    }

    /// The presets left to right, as the board lays them out.
    static let presetOrder: [DetectionMode] = [.auto, .gentle, .piano, .dense, .custom]

    init(viewModel: TranscriberViewModel) {
        self.viewModel = viewModel
        _time = State(initialValue: viewModel.isRecording ? max(0, viewModel.duration - 4) : viewModel.playhead)
    }

    private var rollLayout: RollLayout { RollLayout(rawValue: rollLayoutRaw) ?? .horizontal }

    var body: some View {
        SettingsSheet {
            SettingsPage(title: "Settings", large: true) {
                rollStyle
                detection
                beatGrid
            }
            .accessibilityIdentifier("tone-settings-sheet")
            .navigationDestination(for: Page.self) { _ in
                BeatGridSettingsPage(viewModel: viewModel, time: time)
            }
        }
        .sensoryFeedback(.selection, trigger: rollLayoutRaw)
        .sensoryFeedback(.selection, trigger: viewModel.detectionMode)
        .task(id: PresetKey(viewModel)) { await loadPresets() }
        .task(id: CustomKey(viewModel)) { await reloadCustomPreset() }
    }

    // MARK: Roll style

    /// The take as it looks, or a stand-in phrase before anything's heard.
    private var glimpse: TakeGlimpse {
        TakeGlimpse.at(time, notes: viewModel.visibleNotes, grid: viewModel.showBeatGrid ? viewModel.beatGrid : .empty)
            ?? .sample
    }

    private var rollStyle: some View {
        SettingsSection(
            title: "Roll style", id: "roll-style",
            footer: Text("Sets how Tones are laid out while the phone is upright. You can also hold the roll's keyboard and pull it round the corner. Turn the phone on its side and they always show falling notes.")
        ) {
            let glimpse = glimpse
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 12) { rollCards(glimpse) }
                } else {
                    HStack(alignment: .top, spacing: 12) { rollCards(glimpse) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Roll style")
        }
    }

    private func rollCards(_ glimpse: TakeGlimpse) -> some View {
        ForEach(RollLayout.allCases, id: \.self) { layout in
            let chosen = layout == rollLayout
            Button {
                rollLayoutRaw = layout.rawValue
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    RollStylePicture(layout: layout, glimpse: glimpse)
                        .frame(height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    HStack(spacing: 7) {
                        SettingsRadioMark(isOn: chosen)
                        Text(layout.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous))
                .overlay {
                    if chosen {
                        RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                            .strokeBorder(SettingsTheme.accent, lineWidth: 2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous))
            }
            .buttonStyle(PressScaleStyle(scale: 0.98))
            .accessibilityLabel(layout.label)
            .accessibilityAddTraits(chosen ? .isSelected : [])
            .accessibilityHint(layout == .falling
                               ? "Notes fall onto a keyboard at the bottom, like a piano tutorial."
                               : "Time runs left to right past a keyboard at the left.")
            .accessibilityIdentifier("roll-style-\(layout.rawValue)")
        }
    }

    // MARK: Detection

    /// Whether the presets' pictures can be the take's own notes: only the
    /// quick detector's notes change with the preset.
    private var presetsShowTake: Bool {
        viewModel.notesSource == .quick && !viewModel.isRecording && !viewModel.isTranscribing
    }

    private var detection: some View {
        SettingsSection(title: "Detection", id: "detection") {
            presetRow
            Text(readout)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(SettingsTheme.secondary)
                .padding(.horizontal, 4)
                .accessibilityLabel(readoutSpoken)
                .accessibilityIdentifier("detection-readout")
            if viewModel.detectionMode == .custom {
                SettingsCard {
                    CustomPadView(viewModel: viewModel)
                        .padding(12)
                }
            }
            SettingsFooter(Text(detectionFooter))
        }
    }

    private var presetRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Self.presetOrder) { mode in presetCard(mode) }
            }
            .scrollTargetLayout()
            .padding(.vertical, 6)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .padding(.horizontal, -16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Detection preset")
    }

    private func presetCard(_ mode: DetectionMode) -> some View {
        let chosen = viewModel.detectionMode == mode
        let shown = presetsShowTake ? presets : nil
        return Button {
            viewModel.detectionMode = mode
        } label: {
            VStack(spacing: 4) {
                PresetPicture(mode: mode, notes: shown?.notes[mode], start: shown?.start ?? 0, end: shown?.end ?? 1,
                              low: shown?.low ?? 60, high: shown?.high ?? 72)
                    .frame(height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(mode.label(for: viewModel.transcriptionMode))
                    .font(.footnote.weight(chosen ? .bold : .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(6)
            .frame(width: presetWidth)
            .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if chosen {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(SettingsTheme.accent, lineWidth: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if chosen {
                    SettingsRadioMark(isOn: true)
                        .padding(2)
                        .background(SettingsTheme.card, in: Circle())
                        .offset(x: 5, y: -5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(scale: 0.96))
        .accessibilityLabel(mode.label(for: viewModel.transcriptionMode))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityHint(mode.detail(for: viewModel.transcriptionMode))
        .accessibilityIdentifier("preset-\(mode.rawValue)")
    }

    /// The thresholds in use, as the old list showed them.
    private var readout: String {
        let config = viewModel.config
        return "Note \(config.onsetThreshold.formatted(.number.precision(.fractionLength(2)))) · Sustain \(config.frameThreshold.formatted(.number.precision(.fractionLength(2)))) · Shortest \(Int(config.minNoteLengthMs)) ms"
    }

    private var readoutSpoken: String {
        let config = viewModel.config
        return "Note sensitivity \(config.onsetThreshold.formatted(.number.precision(.fractionLength(2)))), sustain sensitivity \(config.frameThreshold.formatted(.number.precision(.fractionLength(2)))), shortest note \(Int(config.minNoteLengthMs)) milliseconds"
    }

    private var detectionFooter: String {
        switch viewModel.notesSource {
        case .piano:
            "This Tone shows the piano model's notes, so presets only change the quick detector's live view while recording, and these pictures are the same on every take. To use them on this Tone, turn its piano model off: on Home, touch and hold the Tone, then choose Transcription. The preset is one choice for all Tones."
        case .music:
            "This Tone's notes were split into melody, chords and bass, so presets only change the quick detector's live view while recording, and these pictures are the same on every take. The preset is one choice for all Tones."
        default:
            "\(viewModel.detectionMode.detail(for: viewModel.transcriptionMode))\nOne preset for all Tones: changing it re-analyzes this Tone at once, with no need to record again, and other Tones that show the quick detector's notes the next time they're opened\(presetsShowTake && presets != nil ? ". Each picture is this Tone as that preset hears it" : "")."
        }
    }

    // MARK: Beat grid

    private var beatGrid: some View {
        SettingsSection(
            title: "Beat grid", id: "beat-grid",
            footer: Text("Show beat grid, beats per bar and the downbeat note are for all Tones. Tempo and bar nudges apply to the open Tone until another opens; they aren't saved with it.")
        ) {
            SettingsCard {
                NavigationLink(value: Page.beatGrid) {
                    VStack(spacing: 0) {
                        BeatGridPicture(grid: viewModel.beatGrid, notes: viewModel.visibleNotes,
                                        duration: viewModel.duration, time: time, gridShown: viewModel.showBeatGrid)
                            .frame(height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                if viewModel.beatGrid.beats.isEmpty {
                                    Text("No beat grid yet")
                                        .font(.footnote)
                                        .foregroundStyle(SettingsTheme.secondary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                        HStack(spacing: 8) {
                            SettingsTitleValue {
                                Text(BeatGridSettingsPage.detected(viewModel.beatGrid) ?? "Meter, tempo and bar lines")
                                    .monospacedDigit()
                                    .foregroundStyle(Color.primary)
                            } value: {
                                Text(BeatGridSettingsPage.adjustments(viewModel))
                                    .foregroundStyle(SettingsTheme.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(SettingsTheme.ring)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Beat grid")
                .accessibilityValue("\(BeatGridSettingsPage.detected(viewModel.beatGrid) ?? "Not detected yet"), \(BeatGridSettingsPage.adjustments(viewModel))")
                .accessibilityHint("Beats per bar, tempo and bar lines")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("tone-beat-grid")
                SettingsDivider()
                SettingsToggleRow(title: "Show beat grid", isOn: $viewModel.showBeatGrid)
                    .accessibilityIdentifier("tone-show-beat-grid")
            }
        }
    }

    // MARK: Preset pictures

    /// Loads the presets' notes once per take (and again if it's
    /// re-transcribed), over the seconds the roll picture shows.
    private func loadPresets() async {
        guard presetsShowTake, let window = TakeGlimpse.at(time, notes: viewModel.visibleNotes) else {
            presets = nil
            return
        }
        guard let byMode = await viewModel.presetNotes(for: Self.presetOrder,
                                                       customLengthMs: viewModel.customNoteLenMs,
                                                       customThreshold: viewModel.customFrameThreshold,
                                                       from: window.start, to: window.end),
              !Task.isCancelled else { return }
        presets = PresetGlimpse(notes: byMode, start: window.start, end: window.end)
    }

    /// Redraws the Custom card as the pad moves, once it rests a moment.
    private func reloadCustomPreset() async {
        guard let current = presets else { return }
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard let custom = await viewModel.presetNotes(for: [.custom], customLengthMs: viewModel.customNoteLenMs,
                                                       customThreshold: viewModel.customFrameThreshold,
                                                       from: current.start, to: current.end)?[.custom],
              !Task.isCancelled else { return }
        presets?.notes[.custom] = custom
    }

    /// What the preset pictures load for: the take and how it's shown.
    private struct PresetKey: Equatable {
        let duration: Double
        let mode: TranscriptionMode
        let quick: Bool
        let count: Int

        @MainActor init(_ viewModel: TranscriberViewModel) {
            duration = viewModel.duration
            mode = viewModel.transcriptionMode
            quick = viewModel.notesSource == .quick && !viewModel.isRecording && !viewModel.isTranscribing
            count = viewModel.hasContent ? 1 : 0
        }
    }

    private struct CustomKey: Equatable {
        let length: Double
        let threshold: Double

        @MainActor init(_ viewModel: TranscriberViewModel) {
            length = viewModel.customNoteLenMs
            threshold = viewModel.customFrameThreshold
        }
    }
}

/// The presets' notes over one stretch of the take, with the pitches they
/// span between them, so the cards share a scale.
struct PresetGlimpse {
    var notes: [DetectionMode: [NoteEvent]]
    let start: Double
    let end: Double
    let low: Int
    let high: Int

    init(notes: [DetectionMode: [NoteEvent]], start: Double, end: Double) {
        self.notes = notes
        self.start = start
        self.end = end
        (low, high) = TakeGlimpse.pitchRange(notes.values.flatMap { $0.map(\.pitch) })
    }
}

/// Beats per bar, tempo and bar lines, under a picture of the open take's
/// bars that redraws as each choice lands (S03's second page). The help is
/// the old Beat grid footer, split up by what it explains. Beats per bar and
/// the downbeat note are one stored choice for every Tone (the beat tracker
/// reads them for each take opened, and MIDI export's bars follow); the
/// tempo and bar-line nudges are the open take's and reset for the next.
struct BeatGridSettingsPage: View {
    @ObservedObject var viewModel: TranscriberViewModel
    /// The playhead when Settings opened: the picture starts on its bar.
    let time: Double
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var chipWidth: CGFloat = 46

    /// "4 beats per bar · 104 BPM", once there's a grid.
    static func detected(_ grid: BeatGrid) -> String? {
        guard grid.bpm > 0 else { return nil }
        return "\(grid.beatsPerMeasure) beats per bar · \(Int(grid.bpm.rounded())) BPM"
    }

    /// This take's tempo and bar-line corrections, or "As detected".
    static func adjustments(_ viewModel: TranscriberViewModel) -> String {
        var parts: [String] = []
        if viewModel.tempoOctave < 0 { parts.append("½×") }
        if viewModel.tempoOctave > 0 { parts.append("2×") }
        if viewModel.barShift != 0 { parts.append(shiftText(viewModel.barShift)) }
        return parts.isEmpty ? "As detected" : parts.joined(separator: " · ")
    }

    static func shiftText(_ shift: Int) -> String {
        shift == 0 ? "as detected" : "\(shift > 0 ? "+" : "−")\(abs(shift)) beat\(abs(shift) == 1 ? "" : "s")"
    }

    private var hasBeats: Bool { !viewModel.beatGrid.beats.isEmpty }

    var body: some View {
        SettingsPage(title: "Beat grid") {
            preview
            beatsPerBar
            tempo
            bars
        }
        .accessibilityIdentifier("beat-grid-page")
        .sensoryFeedback(.selection, trigger: viewModel.beatsPerMeasure)
        .sensoryFeedback(.selection, trigger: viewModel.tempoOctave)
        .sensoryFeedback(.selection, trigger: viewModel.barShift)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCard {
                BeatGridPicture(grid: viewModel.beatGrid, notes: viewModel.visibleNotes, chords: viewModel.chordSegments,
                                duration: viewModel.duration, time: time, showsChords: true,
                                gridShown: viewModel.showBeatGrid)
                    .frame(height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        if !hasBeats {
                            Text("The beat grid is tracked once a take is finished.")
                                .font(.footnote)
                                .foregroundStyle(SettingsTheme.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                        }
                    }
                    .padding([.horizontal, .top], 8)
                SettingsToggleRow(title: "Show beat grid", isOn: $viewModel.showBeatGrid)
                    .accessibilityIdentifier("beat-grid-show")
            }
            SettingsFooter(detectedText)
                .accessibilityIdentifier("beat-grid-detected")
        }
    }

    private var detectedText: Text {
        let help = "Beats follow the performance's tempo, speeding up and slowing down gradually, and bar lines go where bass notes and chord changes land."
        guard let detected = Self.detected(viewModel.beatGrid) else { return Text(help) }
        return Text("\(Text("Detected: \(detected).").fontWeight(.semibold).foregroundStyle(Color.primary)) \(help)")
    }

    private var beatsPerBar: some View {
        SettingsSection(
            title: "Beats per bar", id: "beats-per-bar",
            footer: Text("Odd meters: pick the count you'd tap (10/8 grouped 5 + 5 → 5). This is for all Tones: each one's bars, and its MIDI export, follow it.")
        ) {
            ChipRows(minWidth: chipWidth) {
                ForEach([0, 2, 3, 4, 5, 6, 7], id: \.self) { count in beatsChip(count) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Beats per bar")
        }
    }

    private func beatsChip(_ count: Int) -> some View {
        let chosen = viewModel.beatsPerMeasure == count
        return Button {
            viewModel.beatsPerMeasure = count
        } label: {
            VStack(spacing: count == 0 ? 1 : 5) {
                if count == 0 {
                    Text("Auto")
                        .font(.footnote.weight(.bold))
                    Text("3 to 5")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(chosen ? SettingsTheme.onAccentSecondary : SettingsTheme.secondary)
                } else {
                    Text("\(count)")
                        .font(.body.weight(.semibold))
                    HStack(spacing: 2) {
                        ForEach(0..<count, id: \.self) { beat in
                            Circle()
                                .fill(beat == 0 ? (chosen ? SettingsTheme.onAccent : SettingsTheme.accent)
                                                : (chosen ? SettingsTheme.onAccentSecondary : SettingsTheme.ring))
                                .frame(width: 4, height: 4)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(chosen ? SettingsTheme.onAccent : Color.primary)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(chosen ? SettingsTheme.accent : SettingsTheme.card,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressScaleStyle(scale: 0.95))
        .accessibilityLabel(count == 0 ? "Auto, 3 to 5" : "\(count) beats")
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("beats-per-bar-\(count)")
    }

    private var tempo: some View {
        SettingsSection(
            title: "Tempo", id: "tempo",
            footer: Text("If the tempo reads twice or half as fast as you'd count it, use ½× or 2×.")
        ) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 8) { tempoCards }
                } else {
                    HStack(spacing: 8) { tempoCards }
                }
            }
            .disabled(!hasBeats && viewModel.tempoOctave == 0)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tempo")
        }
    }

    private var tempoCards: some View {
        ForEach([(-1, "½×", "Half tempo"), (0, "As detected", "As detected"), (1, "2×", "Double tempo")], id: \.0) { octave, title, spoken in
            let chosen = viewModel.tempoOctave == octave
            Button {
                viewModel.tempoOctave = octave
            } label: {
                VStack(spacing: 8) {
                    TempoTicks(octave: octave)
                        .frame(width: 90, height: 12)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(SettingsTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    if chosen {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(SettingsTheme.accent, lineWidth: 2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressScaleStyle(scale: 0.96))
            .accessibilityLabel(spoken)
            .accessibilityAddTraits(chosen ? .isSelected : [])
            .accessibilityIdentifier("tempo-\(octave)")
        }
    }

    private var bars: some View {
        SettingsSection(
            title: "Bars", id: "bars",
            footer: Text("If bar lines are a beat early or late, nudge them. Tempo and bar nudges apply to the open Tone only and aren't saved with it: they reset whenever a Tone opens, even this one. The downbeat note is for all Tones.")
        ) {
            SettingsCard {
                VStack(spacing: 0) {
                    BarShiftPicture(shift: viewModel.barShift)
                        .frame(height: 20)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    SettingsTitleValue {
                        Text("Bar lines")
                    } value: {
                        nudges
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                }
                .disabled(!hasBeats)
                SettingsDivider()
                SettingsMenuRow(title: "Downbeat note",
                                value: viewModel.downbeatPitch.map { NoteEvent.name(for: $0) } ?? "Auto",
                                hint: "A note the player puts on beat 1 anchors each bar.") {
                    Picker("Downbeat note", selection: $viewModel.downbeatPitch) {
                        Text("Auto").tag(Int?.none)
                        ForEach(downbeatOptions, id: \.self) { pitch in
                            Text(NoteEvent.name(for: pitch)).tag(Int?.some(pitch))
                        }
                    }
                }
                .disabled(viewModel.notes.isEmpty)
                .accessibilityIdentifier("beat-grid-downbeat")
            }
        }
    }

    private var nudges: some View {
        HStack(spacing: 0) {
            nudge(-1, systemImage: "chevron.left", label: "Move bar lines a beat earlier", id: "bar-lines-earlier")
            Text(Self.shiftText(viewModel.barShift))
                .monospacedDigit()
                .foregroundStyle(SettingsTheme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(minWidth: 92)
                .accessibilityLabel("Bar lines, \(Self.shiftText(viewModel.barShift))")
                .accessibilityIdentifier("bar-lines-value")
            nudge(1, systemImage: "chevron.right", label: "Move bar lines a beat later", id: "bar-lines-later")
        }
    }

    private func nudge(_ step: Int, systemImage: String, label: String, id: String) -> some View {
        Button {
            viewModel.barShift += step
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(SettingsTheme.accent)
                .frame(width: 40, height: 32)
                .background(SettingsTheme.accent.opacity(0.08), in: Capsule())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.92))
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// Pitches that could plausibly anchor a measure — the notes the take
    /// actually plays, low to high, capped so the menu stays usable.
    private var downbeatOptions: [Int] {
        var pitches = Set(viewModel.notes.map(\.pitch))
        // Keep a persisted choice selectable even if this take never plays it.
        if let chosen = viewModel.downbeatPitch { pitches.insert(chosen) }
        return Array(pitches.sorted().prefix(36))
    }
}

/// Equal-width chips in as few rows as fit, as even as they can be: the
/// seven beats-per-bar chips are one row at the default text size and
/// 4 + 3 (not 6 + 1) when they're too wide for one.
struct ChipRows: Layout {
    var minWidth: CGFloat
    var spacing: CGFloat = 6

    private func grid(width: CGFloat, count: Int) -> (columns: Int, rows: Int, chip: CGFloat) {
        guard count > 0 else { return (1, 0, width) }
        let fit = max(1, min(count, Int((width + spacing) / (minWidth + spacing))))
        let rows = (count + fit - 1) / fit
        let columns = (count + rows - 1) / rows
        return (columns, rows, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    private func rowHeight(_ subviews: Subviews, chip: CGFloat) -> CGFloat {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: chip, height: nil)).height }.max() ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minWidth + spacing) * CGFloat(subviews.count) - spacing
        let grid = grid(width: width, count: subviews.count)
        let height = rowHeight(subviews, chip: grid.chip)
        return CGSize(width: width, height: CGFloat(grid.rows) * height + CGFloat(max(grid.rows - 1, 0)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = grid(width: bounds.width, count: subviews.count)
        let height = rowHeight(subviews, chip: grid.chip)
        for (index, subview) in subviews.enumerated() {
            let row = index / grid.columns, column = index % grid.columns
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(column) * (grid.chip + spacing),
                                      y: bounds.minY + CGFloat(row) * (height + spacing)),
                          proposal: ProposedViewSize(width: grid.chip, height: height))
        }
    }
}

/// 2-D control: horizontal = note-length sensitivity (short ⇄ long allowed),
/// vertical = quiet-note sensitivity (keep faint notes ⇄ reject them).
/// VoiceOver adjusts the shortest note by swiping up and down, and the
/// quiet cutoff with its actions.
struct CustomPadView: View {
    @ObservedObject var viewModel: TranscriberViewModel

    private var xFraction: Double {
        min(max((viewModel.customNoteLenMs - CustomPad.minX) / (CustomPad.maxX - CustomPad.minX), 0), 1)
    }

    private var yFraction: Double {
        min(max((viewModel.customFrameThreshold - CustomPad.minY) / (CustomPad.maxY - CustomPad.minY), 0), 1)
    }

    private var lengthText: String { "\(Int(viewModel.customNoteLenMs)) ms" }
    private var cutoffText: String { viewModel.customFrameThreshold.formatted(.number.precision(.fractionLength(2))) }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(SettingsTheme.picture)
                    Path { path in
                        for i in 1..<4 {
                            let x = geo.size.width * CGFloat(i) / 4
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geo.size.height))
                            let y = geo.size.height * CGFloat(i) / 4
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                    }
                    .stroke(Color(.systemGray4), lineWidth: 0.5)

                    Circle()
                        .fill(SettingsTheme.accent)
                        .frame(width: 22, height: 22)
                        .position(
                            x: geo.size.width * xFraction,
                            y: geo.size.height * (1 - yFraction)
                        )
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let x = min(max(value.location.x / geo.size.width, 0), 1)
                        let y = min(max(value.location.y / geo.size.height, 0), 1)
                        viewModel.customNoteLenMs = CustomPad.minX + x * (CustomPad.maxX - CustomPad.minX)
                        viewModel.customFrameThreshold = CustomPad.minY + (1 - y) * (CustomPad.maxY - CustomPad.minY)
                    }
                )
            }
            .frame(height: 170)
            .accessibilityElement()
            .accessibilityLabel("Custom detection pad")
            .accessibilityValue("Shortest note \(lengthText), quiet cutoff \(cutoffText)")
            .accessibilityHint("Swipe up or down to change the shortest note. Actions change the quiet cutoff.")
            .accessibilityAdjustableAction { direction in
                let step = (CustomPad.maxX - CustomPad.minX) / 20
                switch direction {
                case .increment: viewModel.customNoteLenMs = min(CustomPad.maxX, viewModel.customNoteLenMs + step)
                case .decrement: viewModel.customNoteLenMs = max(CustomPad.minX, viewModel.customNoteLenMs - step)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Keep quieter notes") {
                viewModel.customFrameThreshold = max(CustomPad.minY, viewModel.customFrameThreshold - 0.02)
            }
            .accessibilityAction(named: "Drop quieter notes") {
                viewModel.customFrameThreshold = min(CustomPad.maxY, viewModel.customFrameThreshold + 0.02)
            }
            .accessibilityIdentifier("custom-pad")

            HStack {
                Text("Shortest note: \(lengthText)")
                Spacer()
                Text("Quiet cutoff: \(cutoffText)")
            }
            .font(.caption)
            .foregroundStyle(SettingsTheme.secondary)
            .monospacedDigit()
            .accessibilityHidden(true)
        }
    }
}
