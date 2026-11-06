import AppKit
import AVFoundation
import SwiftUI

// Renders the launch intro (Semitone/IntroView.swift) to an iPhone-shaped
// MP4, for checking it, or sharing it, without a phone.
//
//   swiftc -O -parse-as-library -default-isolation MainActor \
//       Semitone/IntroView.swift Tools/Intro/render.swift -o /tmp/render_intro
//   /tmp/render_intro intro.mp4 [app-screenshot.png] [reduce]
//
// Run from the repo root. Starts on the launch screen and ends on the app
// (the screenshot, or plain white).

@main
enum RenderIntro {
    static let fps = 60.0
    static let scale = 2.0
    static let canvas = CGSize(width: 390, height: 844)
    static let lead = 0.3                       // the launch screen, before the intro
    static let tail = 0.5                       // the app, after the intro

    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let out = URL(fileURLWithPath: args.first ?? "intro.mp4")
        let reduce = args.contains("reduce")
        let screenshot = args.dropFirst().first { $0.hasSuffix(".png") }.flatMap { NSImage(contentsOfFile: $0) }
        let assets = "Semitone/Assets.xcassets/"
        guard let clef = NSImage(contentsOfFile: assets + "IntroClef.imageset/clef.png"),
              let bean = NSImage(contentsOfFile: assets + "IntroBean.imageset/bean.png"),
              let launch = NSImage(contentsOfFile: assets + "LaunchClef.imageset/launch-clef@3x.png") else {
            fatalError("Run from the repo root (the logo pieces weren't found).")
        }
        let end = IntroTiming.end(reduceMotion: reduce)
        let total = lead + end + tail
        try await writeVideo(to: out, frames: Int(total * fps)) { t in
            ZStack {
                let reveal = IntroView.appReveal(at: max(t, 0), reduceMotion: reduce)
                Color.white                     // the window, behind the app
                Group {
                    if let screenshot { Image(nsImage: screenshot).resizable() } else { Color.white }
                }
                .scaleEffect(reveal.scale)
                .opacity(reveal.opacity)
                if t < 0 {
                    // The launch screen: navy and the launch image, unscaled at the center.
                    IntroView.navy
                    Image(nsImage: launch).resizable().frame(width: IntroGeometry.size, height: IntroGeometry.size)
                } else if t < end {
                    IntroView(t: t, reduceMotion: reduce, clef: Image(nsImage: clef), bean: Image(nsImage: bean))
                }
            }
        }
        print("wrote \(out.path)")
    }

    static func writeVideo(to url: URL, frames: Int, scene: (Double) -> some View) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = Int(canvas.width * scale), height = Int(canvas.height * scale)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            let renderer = ImageRenderer(content: scene(Double(frame) / fps - lead).frame(width: canvas.width, height: canvas.height))
            renderer.scale = scale
            guard let image = renderer.cgImage, let pool = adaptor.pixelBufferPool else { fatalError("render failed") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { fatalError("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            // Pool buffers are reused: clear what the last frame left.
            context?.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
