import Foundation

// render: writes the synthetic benchmark songs (<name>.wav + <name>.json) into a folder.
//
//   render <outDir> [--count N] [--seed S] [--only name[,name...]] [--verbose]
//
// The default is the standard set: dev01...dev08 and test01...test08 from seed 2026.

private let usage = """
    usage: render <outDir> [--count N] [--seed S] [--only name[,name...]] [--verbose]

      --count N   songs per split (default \(SongSet.defaultCountPerSplit): dev01...dev08, test01...test08)
      --seed S    master seed (default \(SongSet.defaultSeed)); the same seed always gives the same songs
      --only      render just these songs of the set, e.g. --only dev03,test07
      --verbose   also print each part's program, solo level and mixer gain
    """

private struct UsageError: Error {
    var message: String
}

private struct Arguments {
    var outDir: URL
    var countPerSplit = SongSet.defaultCountPerSplit
    var seed = SongSet.defaultSeed
    var only: Set<String> = []
    var verbose = false

    init(_ args: [String]) throws {
        var rest = args[...]
        var outDir: String?
        func value(_ flag: String) throws -> String {
            guard let value = rest.popFirst() else { throw UsageError(message: "\(flag) needs a value") }
            return value
        }
        while let arg = rest.popFirst() {
            switch arg {
            case "--count":
                guard let n = Int(try value(arg)), n > 0 else { throw UsageError(message: "--count must be a positive integer") }
                countPerSplit = n
            case "--seed":
                guard let s = UInt64(try value(arg)) else { throw UsageError(message: "--seed must be a non-negative integer") }
                seed = s
            case "--only":
                only.formUnion(try value(arg).split(separator: ",").map(String.init))
            case "--verbose", "-v":
                verbose = true
            case "--help", "-h":
                throw UsageError(message: "")
            default:
                guard !arg.hasPrefix("-"), outDir == nil else { throw UsageError(message: "unexpected argument \(arg)") }
                outDir = arg
            }
        }
        guard let outDir else { throw UsageError(message: "missing <outDir>") }
        self.outDir = URL(fileURLWithPath: outDir, isDirectory: true)
    }
}

@main
struct RenderMain {
    static func main() {
        do {
            try run(Arguments(Array(CommandLine.arguments.dropFirst())))
        } catch let error as UsageError {
            if !error.message.isEmpty { printError("render: \(error.message)") }
            printError(usage)
            exit(2)
        } catch {
            printError("render: \(error)")
            exit(1)
        }
    }

    private static func run(_ args: Arguments) throws {
        var specs = SongSet.standard(seed: args.seed, countPerSplit: args.countPerSplit)
        if !args.only.isEmpty {
            let unknown = args.only.subtracting(specs.map(\.name))
            guard unknown.isEmpty else { throw UsageError(message: "no song named \(unknown.sorted().joined(separator: ", ")) in the set") }
            specs = specs.filter { args.only.contains($0.name) }
        }
        try FileManager.default.createDirectory(at: args.outDir, withIntermediateDirectories: true)

        let renderer = try SongRenderer()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let started = Date()
        var audioSeconds = 0.0

        for spec in specs {
            let songStarted = Date()
            let song = GeneratedSong.generate(spec)
            let rendered = try renderer.render(song)
            let truth = rendered.truth
            try AudioWriter.writeWAV(rendered.samples, sampleRate: renderer.options.sampleRate,
                                     to: args.outDir.appendingPathComponent("\(spec.name).wav"))
            try encoder.encode(truth).write(to: args.outDir.appendingPathComponent("\(spec.name).json"))
            audioSeconds += truth.duration

            let counts = PartRole.allCases.map { role in "\(role.rawValue) \(truth.notes.filter { $0.role == role }.count)" }
            let key = song.key.name
            let flags = [song.reverb.map { "reverb \($0.room.rawValue) \(Int($0.wetDryMix))%" }, song.tempoDrift ? "drift" : nil]
                .compactMap { $0 }
            print("\(spec.name)  \(pad(spec.style.rawValue, 8)) \(truth.beatsPerBar)/4 "
                  + String(format: "%3.0f BPM  ", truth.bpm) + pad(key, 3)
                  + String(format: " %6.2f s  ", truth.duration)
                  + counts.joined(separator: "  ") + "  drums \(truth.drums.count)"
                  + (flags.isEmpty ? "" : "  [" + flags.joined(separator: ", ") + "]")
                  + String(format: "  %.1f s", Date().timeIntervalSince(songStarted)))
            if args.verbose {
                print("       form: \(song.form)")
                for (i, part) in song.parts.enumerated() {
                    print("       " + pad(part.kind.rawValue, 6)
                          + String(format: " program %3d  solo %6.1f dBFS  level %+5.1f dB  gain %.3f",
                                   part.program, rendered.soloRMSdB[i], part.levelDB, rendered.gains[i]))
                }
            }
            if rendered.droppedNotes > 0 { printError("warning: \(spec.name): \(rendered.droppedNotes) notes dropped") }
        }
        print(String(format: "%d songs, %.1f min of audio, rendered in %.1f s -> %@", specs.count, audioSeconds / 60,
                     Date().timeIntervalSince(started), args.outDir.path))
    }
}

private func pad(_ text: String, _ width: Int) -> String {
    text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0)
}

private func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
