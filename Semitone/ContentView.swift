import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum RollLayout: String, CaseIterable {
    case horizontal
    case falling

    /// The one stored choice for the phone upright. A Tone's Settings (the
    /// Roll style cards) and the roll itself (pulling the keyboard round the
    /// corner, or the VoiceOver switch) both read and write it, so each
    /// shows what the other last chose. On its side an iPhone shows falling
    /// notes without changing it (`shown(chosen:isPhoneLandscape:)`).
    static let storageKey = "rollLayout"

    var label: String {
        switch self {
        case .horizontal: "Horizontal roll"
        case .falling: "Falling notes"
        }
    }
}

/// The transcription screen: the piano roll (or falling notes) of the take
/// being recorded, imported or reopened, pushed from Home. In Home's look,
/// light only: the roll's white on Home's grey ground, navy ink, Liquid
/// Glass chips (`RollTheme`). Its gear opens the Tone's Settings, nothing
/// else: what its drop-down also held is on Home, importing under the "+",
/// the saved Tones as the library, and a Tone's MIDI export and
/// transcription in its long-press menu.
struct ContentView: View {
    @ObservedObject var viewModel: TranscriberViewModel
    @State private var showSettings = false
    /// Half-turns the gear has spun: one as the Settings open, one as they close.
    @State private var gearTurns = 0.0
    @State private var importSource: ImportSource?
    /// Compact on an iPhone on its side.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Increase Contrast: the part chips' dots take the parts' deeper fill,
    /// as the rolls' notes do (`Voice.fill(for:)`).
    @Environment(\.colorSchemeContrast) private var contrast
    /// The record transition, for whether Home's record button started the
    /// take that is starting (see `body`).
    @Environment(RecordTransition.self) private var transition: RecordTransition?

    var body: some View {
        Group {
            // A take being recorded shows the roll, empty until its first
            // notes. So does one Home's record button is still starting,
            // from the tap rather than the microphone's first buffer: the
            // record transition's piano lands on the roll's keyboard, which
            // has to be there. A take started here, from the empty state,
            // keeps the empty state until it is recording, as it always has.
            if viewModel.hasContent || viewModel.isRecording
                || (viewModel.isStartingTake && transition?.startedTakeFromHome == true) {
                VStack(spacing: 0) {
                    if viewModel.hasParts {
                        partsBar
                        Rectangle().fill(RollTheme.hairline).frame(height: 0.5)
                    }
                    roll
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RollTheme.ground.ignoresSafeArea())
        .overlay {
            if viewModel.isPreparingImport {
                ProgressView("Importing…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("import-progress")
            } else if viewModel.isTranscribing {
                ProgressView("Transcribing…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("transcribe-progress")
            }
        }
        .navigationTitle("Semitone")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(HomeTheme.navy)
                        .rotationEffect(.degrees(gearTurns * 180))
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("tone-settings")
            }
            ToolbarItem(placement: .principal) {
                StatusReadout(viewModel: viewModel)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    viewModel.togglePlayback()
                } label: {
                    NavyGlyph(systemName: viewModel.isPlaying ? "stop.fill" : "play.fill")
                        .font(.title3)
                }
                .accessibilityLabel(viewModel.isPlaying ? "Stop playback" : "Play")
                .accessibilityIdentifier("playback-button")
                // Stop always works; Play needs a part that's shown.
                .disabled(!viewModel.hasContent || (!viewModel.isPlaying && !viewModel.hasAudibleParts)
                          || viewModel.isRecording || viewModel.isTranscribing)
                Button {
                    viewModel.toggleRecording()
                } label: {
                    Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(HomeTheme.record)
                        .font(.title3)
                }
                .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Record")
                .accessibilityIdentifier("record-button")
                .disabled(viewModel.isTranscribing || viewModel.isStartingTake)
            }
        }
        .importPickers(source: $importSource, viewModel: viewModel)
        // Leaving mid-take would strand the microphone: back to Home once it's stopped.
        .navigationBarBackButtonHidden(viewModel.isRecording || viewModel.isStartingTake)
        .sheet(isPresented: $showSettings) {
            ToneSettingsView(viewModel: viewModel)
                .presentationDetents([.large])
        }
        // The gear turns as its Settings rise and again as they go.
        .onChange(of: showSettings) {
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { gearTurns += 1 }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        #if DEBUG
        .overlay(alignment: .bottomLeading) {
            if RegressionUIFixture.selected != nil, viewModel.regressionUIReady {
                RegressionStateLabel(viewModel: viewModel)
            }
        }
        #endif
    }

    /// The horizontal roll or the falling notes (`RollStage`): the layout
    /// chosen for the phone upright, the falling notes on its side.
    private var roll: some View {
        RollStage(viewModel: viewModel)
    }

    /// The parts of an any-instrument take. Tap one to hide and mute it.
    /// One row while the chips fit; otherwise (a countermelody on a narrow
    /// phone, large text) they wrap onto a second row, so no part's chip ends
    /// up off screen in a row nothing shows can scroll. The chord style
    /// pop-up rides beside the Chords chip, so it wraps with it; when that
    /// row would still run off screen (accessibility text sizes), the pop-up
    /// takes a row of its own under the chips instead of pushing the chip
    /// after it out of sight. Every target is 44 pt tall (the capsules stay
    /// small), so the rows need no padding. On an iPhone on its side, where
    /// every row would come out of the falling notes' few hundred points,
    /// the chips stay on one row and scroll sideways when they don't fit.
    private var partsBar: some View {
        let voices = Voice.parts.filter { viewModel.presentVoices.contains($0) }
        // The chips' glass shares a container, as Home's controls' does.
        // Spacing 0: glass only runs together where shapes touch. The chips
        // are 8 pt apart, but the Chords chip's pop-up only 4, which a
        // container spacing of 4 would let a press (interactive glass swells
        // a little) bridge.
        return GlassEffectContainer(spacing: 0) {
            if verticalSizeClass == .compact {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { partChips(voices) }
                    ScrollView(.horizontal) { HStack(spacing: 8) { partChips(voices) } }
                        .scrollIndicators(.hidden)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { partChips(voices) }
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) { partChips(Array(voices.prefix(2))) }
                        HStack(spacing: 8) { partChips(Array(voices.dropFirst(2))) }
                    }
                    stackedParts(voices)
                    ScrollView(.horizontal) { stackedParts(voices) }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Two rows of chips, then the chord style pop-up on a row of its own.
    private func stackedParts(_ voices: [Voice]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) { partChips(Array(voices.prefix(2)), styleBeside: false) }
            HStack(spacing: 8) { partChips(Array(voices.dropFirst(2)), styleBeside: false) }
            if viewModel.canChooseChordStyle {
                chordStyleMenu
            }
        }
    }

    private func partChips(_ voices: [Voice], styleBeside: Bool = true) -> some View {
        ForEach(voices, id: \.self) { voice in
            if styleBeside, voice == .chords, viewModel.canChooseChordStyle {
                HStack(spacing: 4) {
                    partChip(voice)
                    chordStyleMenu
                }
            } else {
                partChip(voice)
            }
        }
    }

    private func partChip(_ voice: Voice) -> some View {
        partChip(voice.label, voice: voice, hidden: viewModel.hiddenVoices.contains(voice)) {
            if viewModel.hiddenVoices.contains(voice) {
                viewModel.hiddenVoices.remove(voice)
            } else {
                viewModel.hiddenVoices.insert(voice)
            }
        }
    }

    /// The chords part as played or simplified (`ChordVoicer`): a pop-up, so
    /// the current choice is always written on it. Not while a refine pass
    /// runs: its preview is not the take the choice is saved with.
    private var chordStyleMenu: some View {
        Menu {
            Picker("Chord notes", selection: $viewModel.chordStyle) {
                ForEach(ChordStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(viewModel.chordStyle.label)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(HomeTheme.controlInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // Light glass, as Home's mode label (its ink 16.8:1 on it here).
            .glassEffect(.regular.tint(HomeTheme.controlTint).interactive(), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(viewModel.refineProgress != nil || viewModel.isTranscribing)
        .accessibilityLabel("Chord notes")
        .accessibilityValue(viewModel.chordStyle.label)
        .accessibilityHint("As played keeps the transcribed chord notes. Simplified shows, plays and exports plain chord shapes built from the chord names.")
        .accessibilityIdentifier("chord-style")
    }

    /// A part's chip: light Liquid Glass, as Home's controls and the chord
    /// pop-up beside it (over the ground the glass measures #FCFCFE to
    /// #FDFDFF), the same for a shown part as a hidden one, so the row stays
    /// calm; only what's on the glass changes. Shown: the name in navy
    /// (16.2 to 16.3:1, as measured) beside a dot of the part's colour,
    /// ringed in its deeper outline so the dot's edge reads on the glass
    /// whatever the colour (the rings 3.7:1 to 9.1:1; the pale aqua fill
    /// alone is 1.4:1). Hidden: the same glass, nothing faded, the name
    /// struck through in Home's secondary grey (5.8 to 5.9:1, as measured:
    /// still easy to read) beside an empty ring. Shown and hidden differ in
    /// the dot's fill, the strike and the ink's lightness, none of them a
    /// hue, so colour blindness doesn't hide which is which. The dots are
    /// the roll's part colours (`Voice.color`, whose distances are measured
    /// there; with Increase Contrast, the deeper fill the roll uses then),
    /// and the name says which part each is. (A navy pill for each shown
    /// part, as Home's selected mode, made a Song's row four heavy dark
    /// chips.)
    private func partChip(_ title: String, voice: Voice, hidden: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(hidden ? Color.clear : voice.fill(for: contrast))
                    .overlay { Circle().strokeBorder(voice.outline, lineWidth: hidden ? 1.5 : 1) }
                    .frame(width: 9, height: 9)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .strikethrough(hidden)
                    .foregroundStyle(hidden ? HomeTheme.secondary : HomeTheme.navy)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular.tint(HomeTheme.controlTint).interactive(), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassControlStyle())
        .accessibilityLabel(title)
        .accessibilityIdentifier("part-\(title.lowercased())")
        .accessibilityValue(hidden ? "Hidden" : "Shown")
        .accessibilityHint("Shows or hides this part. Hidden parts are muted and left out of MIDI exports.")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Listen to some music", systemImage: "pianokeys")
        } description: {
            Text("Tap record and play something, or import an audio file. Semitone sketches the notes it hears onto a piano roll.")
        } actions: {
            Button("Start Listening", systemImage: "record.circle") {
                viewModel.toggleRecording()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("empty-start-listening")
            .disabled(viewModel.isRecording || viewModel.isTranscribing || viewModel.isStartingTake)
            Button("Import Audio or Video", systemImage: "square.and.arrow.down") {
                importSource = .files
            }
            .accessibilityIdentifier("empty-import")
            .disabled(viewModel.isRecording || viewModel.isTranscribing || viewModel.isStartingTake)
        }
    }
}

/// The toolbar's readout: the chord at the playhead, the key, progress, and
/// the take's length. A view of its own because it reads the playhead,
/// which changes a few times a second during playback: only this re-renders
/// then, not the screen around it. It sits on Home's ground: the chord in
/// navy (14.9:1), the rest in Home's secondary grey (5.4:1; the system's
/// secondary label is 3.4:1 on white).
private struct StatusReadout: View {
    @ObservedObject var viewModel: TranscriberViewModel

    var body: some View {
        HStack(spacing: 6) {
            if let chord = viewModel.currentChord {
                // Long names (D#m7♭5/A) shrink a little rather than push the note count out.
                Text(chord)
                    .accessibilityIdentifier("current-chord")
                    .font(.headline)
                    // The system blue was 3.1:1 here; the rolls' navy is 14.9:1.
                    .foregroundStyle(RollInk.chord)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if let key = viewModel.chartKey {
                Text("Key: \(key)")
                    .font(.caption)
                    .foregroundStyle(RollInk.secondary)
            }
            if let progress = viewModel.refineProgress {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.transcriptionMode == .piano ? "pianokeys" : "music.quarternote.3")
                    ProgressView(value: progress)
                        .frame(width: 36)
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(RollInk.secondary)
                .fixedSize()
                .help(viewModel.transcriptionMode == .piano ? "Refining with the piano model" : "Splitting into melody, chords and bass")
            } else if viewModel.isCleaningUp || viewModel.isAnalyzingChart {
                ProgressView()
                    .controlSize(.small)
            } else if let cleanup = viewModel.cleanup, cleanup.changeCount > 0 {
                Label("AI −\(cleanup.removed)", systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(RollInk.secondary)
                    .help(cleanup.summary ?? "")
            } else if viewModel.chart != nil, viewModel.hasAIProvider {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(RollInk.secondary)
            }
            if viewModel.isRecording {
                Text("● REC \(viewModel.duration, format: .number.precision(.fractionLength(1)))s")
                    .font(.caption.monospacedDigit())
                    // The record red, 4.7:1 on the ground (the system red was 3.2:1).
                    .foregroundStyle(HomeTheme.record)
            } else if viewModel.hasContent {
                if viewModel.notesSource == .piano {
                    Image(systemName: "pianokeys")
                        .font(.caption)
                        .foregroundStyle(RollInk.secondary)
                        .help("Transcribed with the high-accuracy piano model")
                } else if viewModel.notesSource == .music {
                    Image(systemName: "music.quarternote.3")
                        .font(.caption)
                        .foregroundStyle(RollInk.secondary)
                        .help("Split into melody, chords and bass, and a countermelody where one stands out")
                }
                // The take's own notes: hiding a part or choosing Simplified
                // changes what the roll shows and plays, not the take.
                Text("\(viewModel.notes.count) notes · \(Duration.seconds(viewModel.duration).formatted(.time(pattern: .minuteSecond)))")
                    .font(.caption)
                    .foregroundStyle(RollInk.secondary)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
    }
}

/// A toolbar glyph in the brand navy, as Home's are; disabled (Play while
/// recording, or with nothing to play), Home's disabled grey instead
/// (`HomeTheme.controlDisabled`), since a set colour isn't dimmed for it.
private struct NavyGlyph: View {
    let systemName: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(isEnabled ? HomeTheme.navy : HomeTheme.controlDisabled)
    }
}

#if DEBUG
/// The fixture's state for UI tests (fixtures only), in a view of its own
/// for the same reason as `StatusReadout`.
private struct RegressionStateLabel: View {
    @ObservedObject var viewModel: TranscriberViewModel

    var body: some View {
        Text("Simulator regression fixture")
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("regression-state")
            .accessibilityValue(Text(verbatim: "cue=\(viewModel.playhead);playing=\(viewModel.isPlaying);chord=\(viewModel.currentChord ?? "none");visible=\(viewModel.visibleNotes.count);chordNotes=\(chordNotes);chordStyle=\(viewModel.chordStyle.rawValue);export=\(viewModel.canExport)"))
    }

    /// The visible chords part as "count/sum of pitches", for UI tests to
    /// tell two chord styles apart.
    private var chordNotes: String {
        let pitches = viewModel.visibleNotes.filter { $0.voice == .chords }.map(\.pitch)
        return "\(pitches.count)/\(pitches.reduce(0, +))"
    }
}
#endif

#Preview {
    NavigationStack {
        ContentView(viewModel: TranscriberViewModel())
    }
}

/// A file handed to the share sheet.
struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet (AirDrop, Save to Files, other apps) for some items.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A video picked in Photos, copied somewhere the app can read it.
nonisolated struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let copy = MediaImport.temporaryURL(name: received.file.deletingPathExtension().lastPathComponent,
                                                extension: received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedVideo(url: copy)
        }
    }
}
