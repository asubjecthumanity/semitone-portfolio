import SwiftUI

/// The app's root: Home (the Tones library and the record controls), with
/// the transcription screen pushed on top for a take being recorded,
/// imported or reopened. Back returns to the library.
///
/// A take started with Home's record button doesn't slide in: a piano
/// spirals out of the record disc, spins once and flows into the roll's
/// keyboard while Home dissolves into the roll behind it (`RecordTransition`,
/// flown in `RecordFlightOverlay` over the whole stack, so it lives through
/// the push).
struct RootView: View {
    @StateObject private var viewModel = TranscriberViewModel()
    @State private var path: [Route] = RootView.launchPath
    @State private var transition = RecordTransition()
    /// The record transition's push is on its way, a veil's rise after the
    /// tap. Home is no longer the screen in front meanwhile: an error the
    /// take hits at once (the microphone refused) is the transcription
    /// screen's to show, as it was when the push came with the tap, not
    /// Home's alert to raise and then lose as the screen arrives over it.
    @State private var pushPending = false
    @AppStorage(RollLayout.storageKey) private var rollLayoutRaw = RollLayout.horizontal.rawValue
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    enum Route: Hashable {
        case transcription
    }

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(viewModel: viewModel, isFrontmost: path.isEmpty && !pushPending) {
                showTranscription()
            }
            .navigationDestination(for: Route.self) { _ in
                ContentView(viewModel: viewModel)
            }
        }
        .environment(transition)
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { transition.safeArea = $0 }
        .overlay {
            RecordFlightOverlay(transition: transition)
                .ignoresSafeArea()
        }
        // The whole app is light only, whatever the system setting: Home, the
        // transcription screen in Home's look (`RollTheme`), and every sheet
        // and menu, which take this from the window. Info.plist's
        // UIUserInterfaceStyle says so too, for anything UIKit presents
        // before or outside SwiftUI. (The launch screen needs neither: its
        // colour, LaunchBackground, is brand navy with no dark variant.)
        .preferredColorScheme(.light)
        .onOpenURL { url in
            // A file opened in Semitone or a link from the share extension lands
            // on the transcription screen, where its progress and errors show.
            viewModel.handleIncoming(url)
            if path.isEmpty { path.append(.transcription) }
        }
        .task {
            if viewModel.autoloadSampleIfRequested(), path.isEmpty { path.append(.transcription) }
        }
        #if DEBUG
        .task {
            // -semitone-record-transition-autotap: the record tap, made for
            // a screen recording of the transition (the demo's, so no microphone).
            guard RecordTransition.autoTaps else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            guard path.isEmpty, !viewModel.isBusy else { return }
            transition.armRecordTap()
            viewModel.toggleRecording()
            showTranscription()
        }
        #endif
        .onChange(of: path) { _, now in
            guard now.isEmpty else { return }
            // Back on Home: nothing keeps playing behind the library, and
            // nothing is left in the air.
            transition.cancel()
            if viewModel.isPlaying { viewModel.stopPlayback() }
        }
        .onChange(of: scenePhase) { _, phase in
            transition.sceneChanged(to: phase)
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            // The take failed before its push: push now, so the
            // transcription screen's alert shows without waiting out the veil.
            if message != nil, pushPending { pushQuietly() }
        }
        .onChange(of: viewModel.isStartingTake) { _, starting in
            guard !starting else { return }
            transition.takeDoneStarting()
            // Done starting, and not recording: the take couldn't start, so
            // the piano has no keyboard to land on.
            if !viewModel.isRecording { transition.takeFailed() }
        }
    }

    /// Home asks for the transcription screen: after its record button
    /// starts a take, under the record transition; otherwise sliding in as
    /// it always has. The take is already recording either way: the
    /// transition only changes how the screen arrives.
    private func showTranscription() {
        // The record transition's push is already on its way: it is this one.
        guard path.isEmpty, !pushPending else { return }
        let decision = transition.takeOff(startedTake: viewModel.isStartingTake || viewModel.isRecording,
                                          layout: RollLayout.shown(chosen: chosenLayout, isPhoneLandscape: isPhoneLandscape),
                                          isPhoneLandscape: isPhoneLandscape, reduceMotion: transitionReducesMotion)
        switch decision {
        case .push:
            path.append(.transcription)
        case .fly, .crossfade:
            // Already recording rather than starting: no start to wait out
            // with an empty roll (`RecordTransition.startedTakeFromHome`).
            if !viewModel.isStartingTake { transition.takeDoneStarting() }
            // Once the veil has hidden Home, and without the slide: the
            // roll appears where Home was, under the veil and the piano.
            pushPending = true
            transition.whenVeiled {
                if pushPending { pushQuietly() }
            }
            Task { @MainActor in
                // Should the veil never get there (the app leaving the
                // screen at the tap), the screen is pushed all the same.
                try? await Task.sleep(for: .seconds(RecordTakeOff.pushTimeout * RecordTransition.timeScale))
                if pushPending { pushQuietly() }
            }
        case .wait:
            // The flight's push is on its way.
            break
        }
    }

    /// The record transition's push: the transcription screen without the
    /// slide, appearing where Home was under the veil, and the flight told
    /// it can carry on. Only while Home is still at the root (going back,
    /// or another push, may have come first).
    private func pushQuietly() {
        pushPending = false
        guard path.isEmpty else { return }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { path.append(.transcription) }
        transition.screenPushed()
    }

    private var chosenLayout: RollLayout { RollLayout(rawValue: rollLayoutRaw) ?? .horizontal }
    private var isPhoneLandscape: Bool { verticalSizeClass == .compact }

    private var transitionReducesMotion: Bool {
        #if DEBUG
        if RecordTransition.forcesReduceMotion { return true }
        #endif
        return reduceMotion
    }

    /// Simulator UI fixtures open straight on the transcription screen.
    private static var launchPath: [Route] {
        #if DEBUG
        if RegressionUIFixture.selected != nil { return [.transcription] }
        #endif
        return []
    }
}
