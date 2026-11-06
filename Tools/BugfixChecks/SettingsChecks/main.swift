import Foundation

func snapshot(_ mode: DetectionMode, length: Double = 150, threshold: Double = 0.4) -> DetectionSnapshot {
    DetectionSnapshot(mode: mode, customMinNoteLengthMs: length, customFrameThreshold: threshold)
}
var checks = 0
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { print("FAIL: \(message)"); exit(1) }
}
for mode in DetectionMode.allCases {
    let original = snapshot(mode)
    expect(original.hasSameNoteSettings(as: original), "Unchanged detector settings caused extraction")
    expect(original.hasSameNoteSettings(as: snapshot(mode, length: 180, threshold: 0.5)) == (mode != .custom),
           "Inactive custom values changed a preset, or active custom values were ignored")
    for other in DetectionMode.allCases where other != mode {
        expect(!original.hasSameNoteSettings(as: snapshot(other)), "Changing a detector mode reused old notes")
    }
}
expect(!snapshot(.custom).hasSameNoteSettings(as: snapshot(.custom, length: 180)), "Custom note length was ignored")
expect(!snapshot(.custom).hasSameNoteSettings(as: snapshot(.custom, threshold: 0.5)), "Custom threshold was ignored")
print("All \(checks) effective detector-setting checks passed.")
