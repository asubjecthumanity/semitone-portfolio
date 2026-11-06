import SwiftUI

/// How a Tone was transcribed, as a submenu of its long-press menu on Home:
/// Piano or Song (choosing the other transcribes the Tone again), the Tone's
/// high-accuracy piano model, and its AI cleanup (clean up now, the result,
/// revert to raw). These act on the take, so they are neither Home's
/// Settings (the app-wide transcription and AI choices, for new takes) nor
/// a Tone's Settings (how it's shown and read: roll style, detection and
/// beat grid, behind the transcription screen's gear), which the owner kept
/// to those three groups.
///
/// The open Tone's items read from the model, as the transcription screen's
/// menu showed them before it went (`Tone(open:)`); another Tone's from its
/// save (`Tone(saved:…)`), which keeps no AI cleanup to revert. Home opens
/// the Tone as its row does and then acts (`HomeView.transcribe`), so the
/// work shows on the transcription screen.
///
/// The kinds are Home's names. Piano is the piano pass; Instrument and Song
/// are the same pass (melody, chords and bass), told apart by what comes
/// out, so a take of that pass is called what Home calls its row and a
/// Piano take is offered "Song".
struct ToneTranscriptionMenu: View {
    let tone: Tone
    let perform: (Action) -> Void

    /// What the menu offers for one Tone, and how each item reads.
    struct Tone {
        /// The pass it was transcribed in.
        var mode: TranscriptionMode
        /// Home's name for its kind: Piano, Instrument or Song.
        var kindName: String
        /// A Piano Tone's notes are the high-accuracy piano model's.
        var usesPianoModel: Bool
        /// The piano-model switch can move (not while a refine pass runs).
        var canSwitchPianoModel: Bool
        /// An AI provider is chosen in Home's Settings.
        var hasAIProvider: Bool
        /// The open Tone's last AI cleanup.
        var cleanup: CleanupResult?
        /// Its raw notes are kept, to go back to (the open Tone, cleaned up).
        var canRevert: Bool
        var isCleaningUp: Bool
        var canCleanUp: Bool
        /// Nothing changes while a take is being opened, imported or started:
        /// the work under way would overwrite the choice (a reopened Tone's
        /// piano model, for one, comes from its save). A Tone that isn't open
        /// also waits while a take is recorded, or the open one refined or
        /// cleaned up, which opening it would cut short.
        var isLocked: Bool

        /// The open Tone, as the model has it.
        init(open viewModel: TranscriberViewModel) {
            mode = viewModel.transcriptionMode
            kindName = ToneTranscriptionMenu.kindName(viewModel)
            usesPianoModel = viewModel.takeUsesPianoModel
            canSwitchPianoModel = viewModel.refineProgress == nil
            hasAIProvider = viewModel.hasAIProvider
            cleanup = viewModel.cleanup
            canRevert = !viewModel.rawNotes.isEmpty
            isCleaningUp = viewModel.isCleaningUp
            canCleanUp = viewModel.hasAIProvider && !viewModel.notes.isEmpty && !viewModel.isCleaningUp
                && !viewModel.isRecording && viewModel.refineProgress == nil
            isLocked = viewModel.isTranscribing || viewModel.isPreparingImport || viewModel.isStartingTake
        }

        /// A Tone that isn't open, from its save: `kind` as its row has it,
        /// and whether its notes are the piano model's. `isLocked` while it
        /// can't be opened yet.
        init(saved take: SavedTake, kind: TonePreview.Kind, usesPianoModel: Bool, hasAIProvider: Bool,
             isLocked: Bool) {
            mode = TranscriptionMode(rawValue: take.mode) ?? .piano
            kindName = ToneTranscriptionMenu.kindName(kind)
            self.usesPianoModel = usesPianoModel
            canSwitchPianoModel = true
            self.hasAIProvider = hasAIProvider
            cleanup = nil
            canRevert = false
            isCleaningUp = false
            canCleanUp = hasAIProvider && take.noteCount > 0
            self.isLocked = isLocked
        }

        var showsAI: Bool { hasAIProvider || cleanup != nil || canRevert }
    }

    /// What the menu does to its Tone (`TranscriberViewModel.perform`).
    enum Action: Equatable {
        /// Transcribe it again in the other pass.
        case transcribe(TranscriptionMode)
        /// Turn its piano model off if it's on, on if it's off.
        case switchPianoModel
        case cleanUp
        case revertCleanup
    }

    /// Home's name for the open take's kind (`TonePreview.kind`): one
    /// melody line from the any-instrument pass is an Instrument.
    static func kindName(_ viewModel: TranscriberViewModel) -> String {
        switch viewModel.transcriptionMode {
        case .piano:
            return "Piano"
        case .music:
            let lines = viewModel.presentVoices.subtracting([.none])
            // The rule Home's rows use (TonePreview.kind): no parts other than a melody,
            // none at all included, is an Instrument take.
            return viewModel.hasContent && lines.isSubset(of: [.melody]) ? "Instrument" : "Song"
        }
    }

    static func kindName(_ kind: TonePreview.Kind) -> String { kind.title }

    /// Home's name for a kind the take isn't: what transcribing it again
    /// in that pass makes (a Song, unless it comes out as one line).
    private static func otherName(_ mode: TranscriptionMode) -> String {
        mode == .piano ? "Piano" : "Song"
    }

    private static func detail(_ mode: TranscriptionMode) -> String {
        mode == .piano ? "Solo piano" : "Melody, chords and bass"
    }

    private static func symbol(_ mode: TranscriptionMode) -> String {
        mode == .piano ? "pianokeys" : "music.quarternote.3"
    }

    var body: some View {
        Menu {
            // Each item says what it is, since a menu shows no section
            // titles: the kind the take is, checked, then the other, which
            // transcribes it again.
            Section {
                ForEach([tone.mode] + TranscriptionMode.allCases.filter { $0 != tone.mode }) { kind in
                    if kind == tone.mode {
                        Toggle(isOn: .constant(true)) {
                            Label("Transcribed as \(tone.kindName)", systemImage: Self.symbol(kind))
                        }
                    } else {
                        Button {
                            perform(.transcribe(kind))
                        } label: {
                            // A second Text is the item's subtitle.
                            Label("Transcribe again as \(Self.otherName(kind))", systemImage: Self.symbol(kind))
                            Text(Self.detail(kind))
                        }
                    }
                }
            }
            if tone.mode == .piano {
                Section {
                    Toggle(isOn: Binding(get: { tone.usesPianoModel }, set: { _ in perform(.switchPianoModel) })) {
                        Text("High-accuracy piano model")
                        Text("On this Tone")
                    }
                    .disabled(!tone.canSwitchPianoModel)
                }
            }
            if tone.showsAI {
                aiCleanup
            }
        } label: {
            Label("Transcription", systemImage: "waveform")
            Text(tone.kindName)
        }
        .disabled(tone.isLocked)
    }

    /// The take's AI cleanup: cleaning up now, with what the last one did
    /// under it, and going back to the raw notes. The provider is chosen in
    /// Home's Settings.
    @ViewBuilder
    private var aiCleanup: some View {
        Section {
            Button {
                perform(.cleanUp)
            } label: {
                Label(tone.cleanup == nil ? "Clean up with AI" : "Clean up again", systemImage: "wand.and.stars")
                Text(cleanupDetail)
            }
            .disabled(!tone.canCleanUp)
            if tone.canRevert {
                Button(role: .destructive) {
                    perform(.revertCleanup)
                } label: {
                    Label("Revert to raw", systemImage: "arrow.uturn.backward")
                    if let summary = tone.cleanup?.summary, !summary.isEmpty {
                        Text("AI: \(summary)")
                    }
                }
            }
        }
    }

    /// Under Clean up: what the last cleanup did, or what one sends.
    private var cleanupDetail: String {
        if tone.isCleaningUp { return "Working…" }
        guard let cleanup = tone.cleanup else {
            return tone.hasAIProvider ? "Sends the notes, never audio" : "Choose an AI provider in Settings on Home"
        }
        if cleanup.changeCount == 0 { return "Last time: nothing to change" }
        return "Last time: removed \(cleanup.removed), moved \(cleanup.shifted), merged \(cleanup.merged) · \(cleanup.confidence.formatted(.percent.precision(.fractionLength(0)))) sure"
    }
}

extension TranscriberViewModel {
    /// Does what the open Tone's Transcription menu chose.
    func perform(_ action: ToneTranscriptionMenu.Action) {
        switch action {
        case .transcribe(let mode):
            transcriptionMode = mode
        case .switchPianoModel:
            setTakeUsesPianoModel(!takeUsesPianoModel)
        case .cleanUp:
            runCleanup()
        case .revertCleanup:
            revertCleanup()
        }
    }
}
