import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Where an import comes from.
enum ImportSource: Hashable {
    /// An audio or video file, from Files.
    case files
    /// A video's soundtrack, from Photos.
    case photos
    /// Experimental: a link to an audio or video file.
    case link
}

extension View {
    /// The import pickers (Files, Photos, a pasted link), shown while `source`
    /// is set. `onImport` runs as an import is handed to the view model.
    func importPickers(source: Binding<ImportSource?>, viewModel: TranscriberViewModel,
                       onImport: @escaping () -> Void = {}) -> some View {
        modifier(ImportPickers(source: source, viewModel: viewModel, onImport: onImport))
    }
}

private struct ImportPickers: ViewModifier {
    @Binding var source: ImportSource?
    @ObservedObject var viewModel: TranscriberViewModel
    let onImport: () -> Void

    @State private var pickedVideo: PhotosPickerItem?
    @State private var linkText = ""

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: showing(.files), allowedContentTypes: [.audio, .movie]) { result in
                if case .success(let url) = result {
                    viewModel.importMedia(url: url, isSecurityScoped: true)
                    onImport()
                }
            }
            .photosPicker(isPresented: showing(.photos), selection: $pickedVideo, matching: .videos)
            .onChange(of: pickedVideo) { _, item in
                guard let item else { return }
                pickedVideo = nil
                Task {
                    do {
                        guard let video = try await item.loadTransferable(type: PickedVideo.self) else { return }
                        viewModel.importMedia(url: video.url, isSecurityScoped: false, title: "Video")
                        onImport()
                    } catch {
                        viewModel.errorMessage = "Couldn't load that video: \(error.localizedDescription)"
                    }
                }
            }
            .alert("Import from link", isPresented: showing(.link)) {
                TextField("https://…", text: $linkText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Import") {
                    if let url = URL(string: linkText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        viewModel.importLink(url)
                        onImport()
                    }
                    linkText = ""
                }
                Button("Cancel", role: .cancel) { linkText = "" }
            } message: {
                Text("Experimental. Paste a link to an audio or video file. Instagram, TikTok and YouTube links aren't supported yet.")
            }
    }

    private func showing(_ which: ImportSource) -> Binding<Bool> {
        Binding(get: { source == which }, set: { if !$0, source == which { source = nil } })
    }
}
