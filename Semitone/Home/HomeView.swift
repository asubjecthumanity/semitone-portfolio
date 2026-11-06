import SwiftUI

/// Home: the Semitone masthead with its Liquid Glass Settings button, the
/// Tones library under a big title (a search field, filter chips by kind,
/// then every Tone as a row of a list, newest first), and the floating
/// Liquid Glass controls at the bottom (the mode segments, the record button
/// with the mode's name over it, and the Import "+" that fans out its
/// choices), which the library scrolls under. Recording, importing or
/// opening a Tone shows the transcription screen via `showTranscription`.
/// A Tone's long-press menu renames it, exports its MIDI file (here, on
/// Home), transcribes it again (on the transcription screen, where the work
/// shows) and deletes it.
struct HomeView: View {
    @ObservedObject var viewModel: TranscriberViewModel
    /// Home is on screen (the transcription screen isn't pushed over it).
    let isFrontmost: Bool
    let showTranscription: () -> Void

    @AppStorage("homeMode") private var modeRaw = HomeMode.piano.rawValue
    @State private var importOpen = false
    /// What's typed into the search field (`ToneSearch`).
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// The kind chosen with the chips over the list; nil for All. Not kept:
    /// every launch shows the whole library.
    @State private var kindFilter: TonePreview.Kind?
    /// The search or a chip is reading every Tone's notes, so what it finds
    /// so far isn't all it will find.
    @State private var readingForSearch = false
    /// The mode label spells the mode out for a moment after a tap.
    @State private var spellingOut = false
    @State private var spellOutTap = 0
    @State private var importSource: ImportSource?
    @State private var showSettings = false
    @State private var renaming: SavedTake?
    @State private var newTitle = ""
    /// A Tone's MIDI file, ready to share.
    @State private var export: ExportedFile?
    /// A Tone is being opened for its MIDI file.
    @State private var preparingExport = false
    @State private var previews = TonePreviewStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The bottom controls' glass, so Import's choices morph out of the "+".
    @Namespace private var glass
    #if DEBUG
    /// -semitone-home-recording-preview: Home shows the recording look with a
    /// made-up input level (the simulator can't record), until the stop is tapped.
    @State private var recordingPreview = ProcessInfo.processInfo.arguments.contains("-semitone-home-recording-preview")
    #endif

    private var mode: Binding<HomeMode> {
        Binding(get: { HomeMode(rawValue: modeRaw) ?? .piano }, set: { modeRaw = $0.rawValue })
    }

    /// The record button's centre above the safe area's bottom edge.
    private static let rowMid: CGFloat = RecordButton.size / 2

    var body: some View {
        GeometryReader { geo in
            let rowWidth = geo.size.width - 32
            ZStack(alignment: .bottom) {
                // The Tones pass under the controls as they are: no fade.
                library
                    .accessibilityHidden(importOpen)

                if importOpen {
                    importBackdrop(in: geo.size)
                }

                // Where they are with the keyboard up too: it covers them
                // (they're for recording, not searching) rather than
                // pushing them up over the results.
                controls(rowWidth: rowWidth)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(.keyboard, edges: .bottom)

                if preparingExport {
                    exportProgress
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(HomeTheme.ground.ignoresSafeArea())
        .environment(\.colorScheme, .light)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle("Tones")
        .sheet(isPresented: $showSettings) {
            HomeSettingsView(viewModel: viewModel)
                .presentationDetents([.large])
        }
        .sheet(item: $export) { file in
            ShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
        .importPickers(source: $importSource, viewModel: viewModel, onImport: showTranscription)
        .alert("Rename tone", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Save") {
                if let take = renaming { viewModel.renameSavedTake(take, to: newTitle) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { isFrontmost && viewModel.errorMessage != nil },
                                    set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: viewModel.savedTakes) { _, takes in
            previews.retain(takes)
            // The last Tone deleted hides the field and the chips: the next
            // one isn't to appear under a search nobody can see.
            if takes.isEmpty { clearSearch() }
        }
        .onChange(of: isFrontmost) { _, front in
            if !front {
                importOpen = false
                searchFocused = false
            }
        }
        .onChange(of: importOpen) { _, open in if open { searchFocused = false } }
        .onChange(of: isRecording) { _, recording in if recording { setImport(open: false) } }
        // Also when the Tone couldn't be opened (the alert says why).
        .onChange(of: viewModel.isTranscribing) { _, transcribing in if !transcribing { preparingExport = false } }
        // While searching, or while a chip narrows the list, every Tone's
        // notes are read (one at a time, as the rows' own loads are): a key
        // or a chord finds Tones that haven't scrolled into view yet, and a
        // take saved before kinds were kept is filed under the kind its
        // notes show, not the one its mode guessed. The results grow as
        // they're read. A task cancelled for a new one leaves the flag to it.
        .task(id: isNarrowed ? viewModel.savedTakes : []) {
            guard isNarrowed else {
                readingForSearch = false
                return
            }
            readingForSearch = true
            for take in viewModel.savedTakes {
                guard !Task.isCancelled else { return }
                await loadPreview(take)
            }
            if !Task.isCancelled { readingForSearch = false }
        }
        // To VoiceOver, once typing pauses, how many Tones the search finds.
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard isSearching else { return }
            let n = shownTakes.count
            let found = n == 0 ? (readingForSearch ? "Searching" : "No Tones match") : n == 1 ? "1 Tone" : "\(n) Tones"
            AccessibilityNotification.Announcement(found).post()
        }
        .task(id: spellOutTap) {
            guard spellingOut else { return }
            do { try await Task.sleep(for: .seconds(1.8)) } catch { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.9)) {
                spellingOut = false
            }
        }
        #if DEBUG
        .task {
            if recordingPreview { viewModel.inputLevel.start(rms: InputLevelMeter.demoSource()) }
        }
        #endif
    }

    // MARK: Masthead

    /// The clef and wordmark, and Settings in Liquid Glass. It floats over the
    /// library, which scrolls under it into the system's hard edge (`library`).
    private var masthead: some View {
        HStack {
            HStack(spacing: 8) {
                // The clef is decorative (and hidden): the wordmark alone reads
                // as the app's name, so VoiceOver's cursor sits on the word.
                SemitoneGlyph(height: 21)
                Text("Semitone")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(HomeTheme.navy)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home-wordmark")
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(HomeTheme.navy)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(GlassControlStyle())
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("home-settings")
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .frame(height: 44)
        .padding(.bottom, 4)
    }

    // MARK: Library

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Tones")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.black)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 4)
                if viewModel.savedTakes.isEmpty {
                    emptyLibrary
                        .padding(.top, 18)
                } else {
                    searchField
                        .padding(.top, 12)
                    kindChips
                        .padding(.top, 6)
                    let shown = shownTakes
                    if shown.isEmpty && readingForSearch {
                        // Not "no Tones match" while there are Tones still to read.
                        ProgressView("Searching…")
                            .font(.subheadline)
                            .foregroundStyle(HomeTheme.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 36)
                            .accessibilityIdentifier("home-searching")
                    } else if shown.isEmpty {
                        noResults
                            .padding(.top, 36)
                    } else {
                        // One flat list, each row the lazy stack's own item:
                        // sections nested in it (0.90's days, a heading and
                        // its rows in one stack) could leave it placing and
                        // re-placing them without end.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(shown) { take in
                                toneButton(take, isLast: take.id == shown.last?.id)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            // Room to scroll the last rows up clear of the controls.
            .padding(.bottom, 170)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("home-library")
        // The hard edge, not the soft one: under the soft edge a navy
        // thumbnail stays dark enough to take the navy wordmark, the gear on
        // its (darkened) glass and the status bar's dark text out of sight.
        // The hard edge frosts the rows out from under the masthead.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollEdgeEffectHidden(true, for: .bottom)
        // After the identifier, which would otherwise reach the masthead's controls too.
        .safeAreaBar(edge: .top) { masthead }
        // Under the controls and the home indicator, but above the keyboard,
        // so the results of a search stay in sight while it's up.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// The search field over the list. Home hides the navigation bar, where
    /// a system search field would go, so it's one of its own, as iOS draws
    /// one: it scrolls away with the title. All of it takes a tap, not only
    /// the text's line.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(HomeTheme.secondary)
                .accessibilityHidden(true)
            // The prompt in the secondary grey rather than the system's
            // paler one, which reads at about 2:1 on the field.
            TextField("Search Tones", text: $query,
                      prompt: Text("Title, key or chord").foregroundStyle(HomeTheme.secondary))
                .font(.body)
                .foregroundStyle(.black)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searchFocused)
                .accessibilityLabel("Search Tones")
                .accessibilityAddTraits(.isSearchField)
                .accessibilityIdentifier("home-search")
            if !query.isEmpty {
                Button {
                    query = ""
                    // Back to the field: the button goes as it's tapped,
                    // which would leave VoiceOver's cursor somewhere else.
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(HomeTheme.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("home-search-clear")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, query.isEmpty ? 12 : 0)
        .frame(minHeight: 44)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { searchFocused = true }
        .background(HomeTheme.searchFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// All, Piano, Instrument, Song: the kinds the library holds, the chosen
    /// one in navy. In a row that scrolls sideways, so with larger text they
    /// run off the edge rather than clip.
    private var kindChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(nil)
                ForEach([TonePreview.Kind.piano, .instrument, .song], id: \.self) { chip($0) }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        // To the screen's edges, past the library's margins, so a chip
        // scrolled sideways isn't cut off 16 pt short of them.
        .padding(.horizontal, -16)
    }

    private func chip(_ kind: TonePreview.Kind?) -> some View {
        let selected = kindFilter == kind
        let name = kind?.title ?? "All"
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { kindFilter = kind }
        } label: {
            Text(name)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : HomeTheme.controlInk)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(selected ? HomeTheme.navy : Color.white, in: Capsule())
                // Drawn 34 pt tall, touched 44.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.95))
        .accessibilityAddTraits(selected ? .isSelected : [])
        // The mode buttons below have the same names: this says what it does.
        .accessibilityHint(kind == nil ? "Shows every Tone." : "Shows only \(name) Tones.")
        .accessibilityIdentifier("home-filter-\(name.lowercased())")
    }

    /// Something is typed into the search field.
    private var isSearching: Bool { !ToneSearch(query).isEmpty }

    /// The search or a chip leaves some Tones out.
    private var isNarrowed: Bool { isSearching || kindFilter != nil }

    /// Every Tone shown again: before a new one is made, which mustn't be
    /// hidden by a search or a chip left from before.
    private func clearSearch() {
        query = ""
        kindFilter = nil
    }

    /// The Tones the search and the chosen kind both let through, newest
    /// first. A Tone whose notes aren't read yet is found by its title and
    /// kind, and by its key and chords once they are.
    private var shownTakes: [SavedTake] {
        let search = ToneSearch(query)
        return viewModel.savedTakes.filter { take in
            let preview = previews.preview(for: take)
            let kind = preview?.kind ?? ToneRow.provisionalKind(take)
            guard kindFilter == nil || kind == kindFilter else { return false }
            return search.matches(.init(title: take.title, kind: kind, key: preview?.key, chords: preview?.chords ?? []))
        }
    }

    /// Nothing the search or the chosen kind lets through: what was looked
    /// for, and what to try.
    private var noResults: some View {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 6) {
            if !typed.isEmpty {
                Text("No Tones match “\(typed)”")
                    .font(.headline)
                    .foregroundStyle(.black)
                Text("Try a title, a key like E♭ minor, or a chord like Am.")
                    .font(.subheadline)
                    .foregroundStyle(HomeTheme.secondary)
            } else if let kindFilter {
                Text("No \(kindFilter.title) Tones yet")
                    .font(.headline)
                    .foregroundStyle(.black)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-no-results")
    }

    private func toneButton(_ take: SavedTake, isLast: Bool) -> some View {
        Button {
            open(take)
        } label: {
            ToneRow(take: take, preview: previews.preview(for: take))
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .frame(maxWidth: .infinity)
        .accessibilityHint("Opens it on the piano roll.")
        .accessibilityIdentifier("home-tone")
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                newTitle = take.title
                renaming = take
            }
            Button("Export MIDI file", systemImage: "square.and.arrow.up") {
                exportMIDI(take)
            }
            .disabled(!canExport(take))
            ToneTranscriptionMenu(tone: transcription(of: take)) { action in
                transcribe(take, action)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                viewModel.deleteSavedTake(take)
            }
        }
        // Outside the button, so it neither shrinks with a press nor lifts
        // with the long-press menu's preview.
        .overlay(alignment: .bottom) {
            if !isLast {
                HomeTheme.separator
                    .frame(height: 0.5)
                    .padding(.leading, ToneRow.textInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .task(id: take) { await loadPreview(take) }
    }

    /// Reads the Tone's notes for its row, unless they've been read. A take
    /// saved before kinds were kept then has its kind and parts noted, so
    /// from the next launch it's laid out right at once.
    private func loadPreview(_ take: SavedTake) async {
        if let built = await previews.load(take), take.kind == nil {
            viewModel.noteKind(take.noting(built.kind, parts: built.parts))
        }
    }

    /// No Tones yet: a sample card, navy like a Tone's thumbnail, with a few
    /// bars of notes and what to do.
    private var emptyLibrary: some View {
        let tint = ToneTint.piano
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ModeGlyph(mode: .piano, size: 14, lineWidth: 2.2)
                Text("No Tones yet")
                    .font(.footnote.weight(.bold))
            }
            .foregroundStyle(tint.label)
            .frame(minHeight: 18)
            TonePreviewCanvas(kind: .piano, preview: .sample)
                .frame(height: 72)
                .padding(.vertical, 10)
            Text("Your first Tone")
                .font(.title3.weight(.bold))
                .foregroundStyle(tint.title)
            Text("Choose Instrument, Piano or Song below, tap the red button and play. Or import a recording. Every take is kept here, with a preview of how it begins.")
                .font(.subheadline)
                .foregroundStyle(tint.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(tint.fill)
                .overlay { shape.strokeBorder(tint.edge, lineWidth: 0.5) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-empty")
    }

    /// While a Tone opens for its MIDI file (a second or two: its audio is
    /// read again for the beat grid the file's bars follow), on the bottom
    /// controls' light glass in their ink (10.5:1 even over navy), and
    /// nothing else takes a tap.
    private var exportProgress: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
            HStack(spacing: 10) {
                ProgressView()
                Text("Preparing MIDI file…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HomeTheme.controlInk)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .glassEffect(.regular.tint(HomeTheme.controlTint), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("home-export-progress")
        }
        .accessibilityAddTraits(.isModal)
        .transition(.opacity)
    }

    // MARK: Bottom controls

    /// Recording (or, in DEBUG, previewing the recording look).
    private var isRecording: Bool {
        #if DEBUG
        if recordingPreview { return true }
        #endif
        return viewModel.isRecording
    }

    private var elapsed: Double {
        #if DEBUG
        if recordingPreview { return 12 }
        #endif
        return viewModel.duration
    }

    /// The mode label over the record button, then the row: the mode
    /// segments, the record button and the Import "+", all Liquid Glass in
    /// one container. Import has a container of its own in it, where the "+"
    /// morphs into its choices. While recording, the segments and the "+" dim
    /// their icons and keep their glass whole.
    private func controls(rowWidth: CGFloat) -> some View {
        let recording = isRecording
        return GlassEffectContainer(spacing: 4) {
            VStack(spacing: 6) {
                ZStack {
                    if !importOpen {
                        modeLabel(recording: recording)
                            .transition(.opacity)
                    }
                }
                .frame(minHeight: 24)
                HStack(spacing: 0) {
                    ModeSegments(mode: mode, isLocked: recording, onSelect: spellOut)
                        .allowsHitTesting(!importOpen)
                        .accessibilityHidden(importOpen)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RecordButton(mode: mode.wrappedValue, isRecording: recording, elapsed: elapsed,
                                 meter: viewModel.inputLevel, action: recordTapped)
                        .allowsHitTesting(!importOpen)
                        .accessibilityHidden(importOpen)
                    ImportFan(isOpen: Binding(get: { importOpen }, set: { setImport(open: $0) }),
                              linkEnabled: viewModel.linkImportEnabled,
                              isLocked: recording,
                              glass: glass,
                              onPick: pick)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(width: rowWidth, height: RecordButton.size)
            }
        }
    }

    /// The selected mode's name; for a moment after a tap, its icon and what
    /// it listens for; while recording, the time so far.
    private func modeLabel(recording: Bool) -> some View {
        let mode = mode.wrappedValue
        let clock = RecordButton.clock(elapsed)
        let spoken = recording ? "Recording, \(clock), \(mode.title)"
            : spellingOut ? "\(mode.title): \(mode.summary)" : mode.title
        return HStack(spacing: 6) {
            if recording {
                Circle().fill(HomeTheme.record).frame(width: 7, height: 7)
                Text(clock)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(HomeTheme.controlInk)
                Text(mode.title)
                    .foregroundStyle(HomeTheme.controlSecondary)
            } else {
                if spellingOut {
                    ModeGlyph(mode: mode, size: 15, lineWidth: 2.2)
                        .foregroundStyle(HomeTheme.navy)
                }
                Text(mode.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(HomeTheme.controlInk)
                if spellingOut {
                    Text(mode.summary)
                        .foregroundStyle(HomeTheme.controlSecondary)
                }
            }
        }
        .font(.footnote)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .lineLimit(1)
        .padding(.leading, recording ? 10 : spellingOut ? 9 : 12)
        .padding(.trailing, 12)
        .frame(minHeight: 24)
        .fixedSize()
        .glassEffect(.regular.tint(HomeTheme.controlTint), in: Capsule())
        .glassEffectID("mode-label", in: glass)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("home-mode-label")
    }

    /// Behind the open fan: a soft light around it, and anywhere outside closes it.
    private func importBackdrop(in size: CGSize) -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { setImport(open: false) }
            RadialGradient(stops: [.init(color: .white.opacity(0.6), location: 0),
                                   .init(color: .white.opacity(0.28), location: 0.6),
                                   .init(color: .white.opacity(0), location: 1)],
                           center: .center, startRadius: 0, endRadius: 210)
                .frame(width: 420, height: 420)
                .position(x: size.width - 16 - ImportFan.size / 2 - 40, y: size.height - Self.rowMid - 76)
                .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    // MARK: Actions

    private func spellOut(_ mode: HomeMode) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.36, dampingFraction: 0.86)) {
            spellingOut = true
        }
        spellOutTap += 1
    }

    private func setImport(open: Bool) {
        guard open != importOpen else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.8)) {
            importOpen = open
        }
    }

    private func pick(_ source: ImportSource) {
        setImport(open: false)
        clearSearch()
        viewModel.prepareNewTake(mode: mode.wrappedValue.transcriptionMode)
        importSource = source
    }

    /// Idle: starts listening in the chosen mode. Recording: stops. Either
    /// way the take then shows on the transcription screen.
    private func recordTapped() {
        #if DEBUG
        if recordingPreview {
            recordingPreview = false
            viewModel.inputLevel.stop()
            return
        }
        #endif
        if viewModel.isRecording {
            viewModel.toggleRecording()
            showTranscription()
        } else {
            startListening()
        }
    }

    /// Starts listening in the chosen mode (the same path as the transcription
    /// screen's record button) and shows the take as it's heard.
    private func startListening() {
        clearSearch()
        if !viewModel.isBusy {
            viewModel.prepareNewTake(mode: mode.wrappedValue.transcriptionMode)
            viewModel.toggleRecording()
        }
        showTranscription()
    }

    /// Opens a Tone on the piano roll. While another take is still being
    /// recorded or transcribed, shows that one instead.
    private func open(_ take: SavedTake) {
        searchFocused = false
        if !viewModel.isBusy { viewModel.openSavedTake(take) }
        showTranscription()
    }

    // MARK: A Tone's long-press menu

    /// The Tone is the open one, its take loaded: the menu acts on it as it
    /// stands, with any hidden parts, chord style or AI cleanup on screen.
    private func isOpen(_ take: SavedTake) -> Bool {
        viewModel.openSavedTakeID == take.id && viewModel.hasContent
    }

    /// Another Tone can't be opened for its menu now: a take is being
    /// recorded, opened, imported or started, or the open one is being
    /// refined or cleaned up, which opening another would cut short.
    private var othersLocked: Bool {
        viewModel.isBusy || viewModel.refineProgress != nil || viewModel.isCleaningUp
    }

    /// As the transcription screen's Export allowed: the open Tone with a
    /// part shown and no pass running; another once it can be opened.
    private func canExport(_ take: SavedTake) -> Bool {
        isOpen(take) ? viewModel.canExport : !othersLocked && take.noteCount > 0
    }

    /// The MIDI file the transcription screen's menu made: the take as
    /// shown (hidden parts left out, the chords in its style), bars on its
    /// beat grid, chord names as markers. Another Tone is opened for it
    /// first, behind Home, as tapping its row would (the file's beat grid
    /// is tracked from its audio), and Home stays where it is.
    private func exportMIDI(_ take: SavedTake) {
        guard !isOpen(take) else {
            if let url = viewModel.exportMIDI() { export = ExportedFile(url: url) }
            return
        }
        viewModel.openSavedTake(take) {
            preparingExport = false
            // Opened, it may show none: a Tone of the quick detector's notes
            // is read again with today's detection preset.
            guard viewModel.canExport else {
                viewModel.errorMessage = "“\(take.title)” has no notes to export."
                return
            }
            if let url = viewModel.exportMIDI() { export = ExportedFile(url: url) }
        }
        withAnimation(.easeInOut(duration: 0.2)) { preparingExport = viewModel.isTranscribing }
    }

    /// The Tone's Transcription menu: the open Tone as it stands, another
    /// from its save and row.
    private func transcription(of take: SavedTake) -> ToneTranscriptionMenu.Tone {
        if isOpen(take) { return .init(open: viewModel) }
        let preview = previews.preview(for: take)
        // Before its notes are read, a Piano Tone is taken to have the
        // model's notes, as one recorded with the default does.
        return .init(saved: take, kind: preview?.kind ?? ToneRow.provisionalKind(take),
                     usesPianoModel: preview?.pianoModel ?? true, hasAIProvider: viewModel.hasAIProvider,
                     isLocked: othersLocked)
    }

    /// Opens the Tone, as tapping its row does, and does what was chosen
    /// there, where its progress shows; the open Tone acts at once.
    private func transcribe(_ take: SavedTake, _ action: ToneTranscriptionMenu.Action) {
        if isOpen(take) {
            viewModel.perform(action)
        } else {
            viewModel.openSavedTake(take) { viewModel.perform(action) }
        }
        showTranscription()
    }
}
