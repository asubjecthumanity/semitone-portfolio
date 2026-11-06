import Foundation

// Checks HarmonicPercussive: exact medians, reconstruction, separation, speed.
// Build: see Tools/MusicBench/tests/run_hpss_test.sh

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "PASS " : "FAIL ") + what)
    if !ok { failures += 1 }
}

// 1. Median networks against sorting, sizes 1...33.
var rng = SystemRandomNumberGenerator()
for size in stride(from: 1, through: 33, by: 2) {
    let net = MedianNetwork(size: size)
    let length = 257
    let set = LaneSet(count: net.lanes + 1, length: length)
    var ok = true
    for _ in 0..<20 {
        var rows: [[Float]] = []
        for j in 0..<size {
            let row = (0..<length).map { _ in Float.random(in: -5...5, using: &rng).rounded() }  // ties included
            rows.append(row)
            set[j].update(from: row, count: length)
        }
        net.fillSentinels(set)
        let med = net.run(set)
        for c in 0..<length {
            let expect = rows.map { $0[c] }.sorted()[size / 2]
            if med[c] != expect { ok = false }
        }
    }
    set.deallocate()
    check(ok, "median network size \(size)")
}

// 2. Reconstruction and 3. separation on a tone plus clicks.
let sr = 22050.0
let seconds = 6.0
let n = Int(sr * seconds)
var tone = [Float](repeating: 0, count: n)
var clicks = [Float](repeating: 0, count: n)
for i in 0..<n {
    let t = Double(i) / sr
    tone[i] = Float(0.3 * sin(2 * .pi * 440 * t) + 0.15 * sin(2 * .pi * 880 * t))
}
var i = Int(0.25 * sr)
while i < n - 200 {
    for k in 0..<200 { clicks[i + k] = Float.random(in: -0.8...0.8, using: &rng) * Float(exp(-Double(k) / 30)) }
    i += Int(0.5 * sr)
}
let mix = zip(tone, clicks).map(+)
guard let out = HarmonicPercussive.separate(mix) else { fatalError("separate returned nil") }
let recon = zip(out.harmonic, out.percussive).map(+)
let err = zip(recon, mix).map { abs($0 - $1) }.max() ?? 1
check(err < 1e-3, String(format: "reconstruction max error %.2e", err))

func energy(_ x: [Float]) -> Double { x.reduce(0) { $0 + Double($1 * $1) } }
func proj(_ a: [Float], _ b: [Float]) -> Double { zip(a, b).reduce(0) { $0 + Double($1.0 * $1.1) } / energy(b) }
let toneInHarmonic = proj(out.harmonic, tone)
let clicksInPercussive = proj(out.percussive, clicks)
let toneInPercussive = proj(out.percussive, tone)
print(String(format: "tone in harmonic %.3f, tone in percussive %.3f, clicks in percussive %.3f", toneInHarmonic, toneInPercussive, clicksInPercussive))
check(toneInHarmonic > 0.9 && toneInPercussive < 0.1, "tone goes to harmonic")
check(clicksInPercussive > 0.6, "clicks go to percussive")

// 4. Speed on 60 s of noise-ish audio.
let long = (0..<Int(sr * 60)).map { _ in Float.random(in: -0.5...0.5, using: &rng) }
let t0 = Date()
_ = HarmonicPercussive.separate(long)
let dt = Date().timeIntervalSince(t0)
print(String(format: "60 s of audio separated in %.2f s", dt))

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
