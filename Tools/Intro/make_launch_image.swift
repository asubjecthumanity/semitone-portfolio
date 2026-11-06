import AppKit

// Renders the launch screen's image (Info.plist UILaunchScreen › UIImageName
// = LaunchClef): the faint clef the intro opens on, on a clear square the
// size of the intro's logo, at 1x, 2x and 3x. iOS shows it unscaled at the
// screen's center, over the LaunchBackground navy, exactly where IntroView
// draws its first frame. Keep `size` and `opacity` in step with
// IntroGeometry.size and IntroGeometry.ghostOpacity.
//
//   swiftc -O Tools/Intro/make_launch_image.swift -o /tmp/make_launch_image && /tmp/make_launch_image
//
// Run from the repo root. Writes Semitone/Assets.xcassets/LaunchClef.imageset.

let size = 240
let opacity: CGFloat = 0.14
let assets = "Semitone/Assets.xcassets/"
guard let clef = NSImage(contentsOfFile: assets + "IntroClef.imageset/clef.png")?
    .cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("Run from the repo root.") }

let folder = URL(fileURLWithPath: assets + "LaunchClef.imageset")
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var entries: [String] = []
for scale in 1...3 {
    let px = size * scale
    let context = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.setAlpha(opacity)
    context.draw(clef, in: CGRect(x: 0, y: 0, width: px, height: px))
    let name = scale == 1 ? "launch-clef.png" : "launch-clef@\(scale)x.png"
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appending(path: name))
    entries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "universal",
          "scale" : "\(scale)x"
        }
    """)
}
let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: folder.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(folder.path)")
