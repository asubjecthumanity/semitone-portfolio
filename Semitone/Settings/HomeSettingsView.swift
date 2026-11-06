import SwiftUI

/// Home's Settings (the masthead's glass gear): what applies to the whole
/// app and to takes still to come. Transcription (the piano model for new
/// Piano takes), AI cleanup, importing from links, and playback and
/// credits. Nothing here acts on a take: the one last opened may not be
/// on screen at all. A Tone's own Settings (`ToneSettingsView`) are behind
/// the transcription screen's gear, and its transcription
/// (`ToneTranscriptionMenu`) is in its long-press menu on Home.
struct HomeSettingsView: View {
    @ObservedObject var viewModel: TranscriberViewModel

    enum Page: Hashable {
        case aiCleanup
        case playback
    }

    var body: some View {
        SettingsSheet {
            SettingsPage(title: "Settings", large: true) {
                transcription
                ai
                experimental
                playback
            }
            .accessibilityIdentifier("home-settings-sheet")
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .aiCleanup: AICleanupSettingsPage(viewModel: viewModel)
                case .playback: PlaybackSettingsPage()
                }
            }
        }
    }

    private var transcription: some View {
        SettingsSection(
            title: "Transcription", id: "transcription",
            footer: Text("Choose Instrument, Piano or Song with the buttons beside the record button. With the piano model on, a Piano take is transcribed again once you stop recording or import a file, with a model trained on piano recordings: far more accurate for piano (almost no phantom octave notes), at a few seconds per minute of audio. The live view while recording always uses the quick detector. This is for new takes; to change it for one Tone, touch and hold the Tone, then choose Transcription.")
        ) {
            SettingsCard {
                SettingsToggleRow(title: "High-accuracy piano model", subtitle: "For new Piano takes",
                                  isOn: $viewModel.usePianoModel)
                    .accessibilityIdentifier("settings-piano-model-default")
            }
        }
    }

    private var ai: some View {
        SettingsSection(title: "AI", id: "ai") {
            SettingsCard {
                SettingsLinkRow(title: "AI cleanup", value: AICleanupSettingsPage.summary(viewModel),
                                destination: Page.aiCleanup)
                    .accessibilityIdentifier("settings-ai-cleanup")
            }
        }
    }

    private var experimental: some View {
        SettingsSection(
            title: "Import", id: "experimental",
            footer: Text("Adds Link to Import and accepts links shared to Semitone from other apps. Links straight to an audio or video file work. Instagram, TikTok and YouTube links aren't supported yet: save the video to Photos, then import it from Photos.")
        ) {
            SettingsCard {
                SettingsToggleRow(isOn: $viewModel.linkImportEnabled, spoken: "Import from links, Experimental") {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Text("Import from links")
                            ExperimentalChip()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Import from links")
                            ExperimentalChip()
                        }
                    }
                }
                .accessibilityIdentifier("settings-link-import")
            }
        }
    }

    private var playback: some View {
        SettingsSection(title: "Playback", id: "playback") {
            SettingsCard {
                SettingsLinkRow(title: "Playback and credits", value: "Yamaha grand", destination: Page.playback)
                    .accessibilityIdentifier("settings-playback")
            }
        }
    }
}

/// The AI provider, its key, and whether takes are cleaned up as they
/// finish. Cleaning up a Tone that's already made, or going back to its
/// raw notes, is under Transcription in that Tone's long-press menu on Home.
struct AICleanupSettingsPage: View {
    @ObservedObject var viewModel: TranscriberViewModel

    /// The provider's name for the row on Settings' first page.
    static func summary(_ viewModel: TranscriberViewModel) -> String {
        switch viewModel.aiProviderRaw {
        case "off": "Off"
        case "env": "Scheme key"
        case "semitone": "Semitone"
        default:
            viewModel.aiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No key" : providerName(viewModel.aiProviderRaw)
        }
    }

    private static func providerName(_ raw: String) -> String {
        switch raw {
        case "semitone": "Semitone"
        case "groq": "Groq"
        case "openai": "OpenAI"
        case "anthropic": "Anthropic"
        case "env": "Xcode scheme key"
        default: "Off"
        }
    }

    private var needsKey: Bool { !["off", "env", "semitone"].contains(viewModel.aiProviderRaw) }

    /// Where the key comes from, never the key itself.
    private var keyStatus: String {
        switch viewModel.aiProviderRaw {
        case "off":
            return "AI is off: nothing is sent anywhere."
        case "env":
            return "Uses the key in the Xcode scheme's environment."
        case "semitone":
            return "Semitone's own AI service: no key needed. A take's notes (never its audio) are sent to it, up to 40 times a day."
        default:
            if viewModel.aiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return viewModel.hasEnvironmentKey
                    ? "No key yet, so the Xcode scheme's key is used."
                    : "No key yet: paste one above to turn AI on."
            }
            return "Key saved on this device."
        }
    }

    var body: some View {
        SettingsPage(title: "AI cleanup") {
            SettingsSection(title: "AI service", id: "ai-provider", footer: Text(keyStatus)) {
                SettingsCard {
                    SettingsMenuRow(title: "Provider", value: Self.providerName(viewModel.aiProviderRaw)) {
                        Picker("Provider", selection: $viewModel.aiProviderRaw) {
                            Text("Off").tag("off")
                            Text("Semitone").tag("semitone")
                            if viewModel.hasEnvironmentKey {
                                Text("Xcode scheme key").tag("env")
                            }
                            Text("Groq").tag("groq")
                            Text("OpenAI").tag("openai")
                            Text("Anthropic").tag("anthropic")
                        }
                    }
                    .accessibilityIdentifier("settings-ai-provider")
                    if needsKey {
                        SettingsDivider()
                        SecureField("API key", text: $viewModel.aiKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .settingsRow()
                            .accessibilityIdentifier("settings-ai-key")
                    }
                }
            }
            SettingsSection(
                title: "Cleanup", id: "ai-cleanup-toggle",
                footer: Text("Sends the detected notes (never audio) to the model, which may only remove phantom notes, move a note by whole octaves, or merge fragments of one held note. Runs after each new take when it's on; changing a Tone's detection settings goes back to its raw detection. To clean up a Tone that's already made, or go back to its raw notes, touch and hold the Tone, then choose Transcription.")
            ) {
                SettingsCard {
                    SettingsToggleRow(title: "Clean up transcription with AI", isOn: $viewModel.useAICleanup)
                        .disabled(!viewModel.hasAIProvider)
                        .accessibilityIdentifier("settings-ai-cleanup-toggle")
                }
            }
        }
    }
}

/// The piano sound and its credits.
struct PlaybackSettingsPage: View {
    var body: some View {
        SettingsPage(title: "Playback and credits") {
            SettingsSection(
                title: "Playback", id: "playback-sound",
                footer: Text("Once the high-accuracy piano model has run, playback uses the dynamics and sustain pedal it heard. Song and Instrument takes play every part on the piano. Piano samples: YDP Grand Piano by FreePats, from Zenph Studios' Yamaha Disklavier Pro recordings, CC BY 3.0, shortened for size.")
            ) {
                SettingsCard {
                    LabeledContent("Piano sound") {
                        Text("Yamaha grand").foregroundStyle(SettingsTheme.secondary)
                    }
                    .settingsRow()
                }
            }
        }
    }
}
