import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Getting something to transcribe out of whatever was shared or picked:
/// videos become their soundtrack, and links (experimental) are downloaded
/// when they point at an audio or video file.
nonisolated enum MediaImport {
    enum Failure: LocalizedError {
        case noSound
        case unsupportedSite(String)
        case notMedia
        case download(String)

        var errorDescription: String? {
            switch self {
            case .noSound:
                "That video has no sound to transcribe."
            case .unsupportedSite(let site):
                "Semitone can't download from \(site) yet. Save the video to Photos (\(site)'s download button or a screen recording), then use Import from Photos."
            case .notMedia:
                "That link isn't an audio or video file."
            case .download(let reason):
                "The download didn't work: \(reason)"
            }
        }
    }

    /// An audio file for `url`: the file itself, or for a video its
    /// soundtrack, exported to a temporary .m4a.
    static func audioFile(for url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard !video.isEmpty else { return url }
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw Failure.noSound }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.noSound
        }
        let out = temporaryURL(name: url.deletingPathExtension().lastPathComponent, extension: "m4a")
        try await session.export(to: out, as: .m4a)
        return out
    }

    /// Sites whose share links point at a page, not a file: their videos
    /// can't be fetched without going around the site's terms.
    private static let pageSites: [(host: String, name: String)] = [
        ("instagram.com", "Instagram"), ("tiktok.com", "TikTok"), ("youtube.com", "YouTube"),
        ("youtu.be", "YouTube"), ("facebook.com", "Facebook"), ("x.com", "X"), ("twitter.com", "X"),
    ]

    /// Downloads a link to an audio or video file into the temporary folder.
    static func download(_ link: URL) async throws -> URL {
        let host = link.host()?.lowercased() ?? ""
        if let site = pageSites.first(where: { host == $0.host || host.hasSuffix("." + $0.host) }) {
            throw Failure.unsupportedSite(site.name)
        }
        guard ["http", "https"].contains(link.scheme?.lowercased() ?? "") else { throw Failure.notMedia }
        let (file, response): (URL, URLResponse)
        do {
            (file, response) = try await URLSession.shared.download(from: link)
        } catch {
            throw Failure.download(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.download("the server answered \(http.statusCode)")
        }
        // Trust the server's type, else the link's extension.
        let type = response.mimeType.flatMap { UTType(mimeType: $0) }
            ?? UTType(filenameExtension: link.pathExtension)
        guard let type, type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) else {
            try? FileManager.default.removeItem(at: file)
            throw Failure.notMedia
        }
        let name = link.deletingPathExtension().lastPathComponent
        let out = temporaryURL(name: name.isEmpty ? "Download" : name,
                               extension: type.preferredFilenameExtension ?? link.pathExtension)
        try FileManager.default.moveItem(at: file, to: out)
        return out
    }

    /// A unique file in the temporary folder that keeps a readable name.
    static func temporaryURL(name: String, extension ext: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name).appendingPathExtension(ext)
    }
}
