import SwiftUI
import UIKit

/// Magnetic snapping for the rolls. When a scroll comes to rest near a
/// measure line it settles onto it; near a beat line it settles onto that
/// with a smaller catch zone; anywhere else it stays put. The horizontal roll
/// snaps across, the falling notes up and down.
struct BeatSnapBehavior: ScrollTargetBehavior {
    /// Scroll offsets along `axis` that align each beat / measure line on screen.
    let beatOffsets: [CGFloat]
    let measureOffsets: [CGFloat]
    var axis: Axis = .horizontal

    /// Catch zones as fractions of the local beat spacing.
    nonisolated private static let beatPull: CGFloat = 0.3      // "slight" lock
    nonisolated private static let measurePull: CGFloat = 0.65  // "slightly bigger" lock

    init(beatOffsets: [CGFloat], measureOffsets: [CGFloat], axis: Axis = .horizontal) {
        // The falling notes' offsets run backwards in time; the search wants them ascending.
        self.beatOffsets = beatOffsets.sorted()
        self.measureOffsets = measureOffsets.sorted()
        self.axis = axis
    }

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let offset = axis == .horizontal ? target.rect.minX : target.rect.minY
        guard let snapped = Self.snapped(offset, beatOffsets: beatOffsets, measureOffsets: measureOffsets) else { return }
        if axis == .horizontal {
            let maxX = max(0, context.contentSize.width - context.containerSize.width)
            target.rect.origin.x = min(max(snapped, 0), maxX)
        } else {
            let maxY = max(0, context.contentSize.height - context.containerSize.height)
            target.rect.origin.y = min(max(snapped, 0), maxY)
        }
    }

    /// Where a scroll resting at `offset` settles, or nil to stay put.
    /// Offsets must be sorted ascending.
    nonisolated static func snapped(_ offset: CGFloat, beatOffsets: [CGFloat], measureOffsets: [CGFloat]) -> CGFloat? {
        guard beatOffsets.count >= 2 else { return nil }
        let spacing = localBeatSpacing(near: offset, in: beatOffsets)
        let beatRadius = min(max(spacing * beatPull, 6), 20)
        let measureRadius = min(max(spacing * measurePull, 14), 48)
        if let m = nearest(to: offset, in: measureOffsets), abs(m - offset) <= measureRadius { return m }
        if let b = nearest(to: offset, in: beatOffsets), abs(b - offset) <= beatRadius { return b }
        return nil
    }

    nonisolated private static func localBeatSpacing(near x: CGFloat, in beatOffsets: [CGFloat]) -> CGFloat {
        let i = insertionIndex(of: x, in: beatOffsets)
        let a = beatOffsets[max(0, min(i - 1, beatOffsets.count - 2))]
        let b = beatOffsets[max(1, min(i, beatOffsets.count - 1))]
        return max(b - a, 1)
    }

    nonisolated private static func nearest(to x: CGFloat, in offsets: [CGFloat]) -> CGFloat? {
        guard !offsets.isEmpty else { return nil }
        let i = insertionIndex(of: x, in: offsets)
        let candidates = [i - 1, i].filter { offsets.indices.contains($0) }.map { offsets[$0] }
        return candidates.min { abs($0 - x) < abs($1 - x) }
    }

    /// First index whose value is >= x (binary search; offsets are sorted).
    nonisolated private static func insertionIndex(of x: CGFloat, in offsets: [CGFloat]) -> Int {
        var lo = 0, hi = offsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if offsets[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// Turns on UIKit's directional lock for the enclosing scroll view: a drag
/// that starts mostly sideways stays sideways (and likewise vertically),
/// while a clearly diagonal drag still moves both ways. SwiftUI has no
/// modifier for this, so it reaches the backing UIScrollView.
struct DirectionalScrollLock: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) { uiView.apply() }

    final class Probe: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    scrollView.isDirectionalLockEnabled = true
                    return
                }
                view = current.superview
            }
        }
    }
}
