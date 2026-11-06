import SwiftUI

/// The mode picker left of the record button: an icon-only Liquid Glass
/// capsule with a segment for each mode (Instrument · Piano · Song). The
/// selected mode sits on a navy thumb that glides between segments; its name
/// shows in the label over the record button. Locked while recording.
/// VoiceOver reads it as a tab bar of three selectable buttons, "2 of 3".
struct ModeSegments: View {
    @Binding var mode: HomeMode
    /// Recording: the icons and thumb dim and the segments don't respond.
    var isLocked = false
    /// After a tap picks a mode (also the one already selected).
    var onSelect: (HomeMode) -> Void = { _ in }

    static let segmentWidth: CGFloat = 44
    static let height: CGFloat = 48
    static let width = segmentWidth * CGFloat(HomeMode.allCases.count)
    private static let thumbSize: CGFloat = 40

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumb

    var body: some View {
        // Locked, the glass stays whole and only its icons and thumb dim (in
        // `segment`): the library scrolls under the controls with no fade, so
        // a capsule dimmed glass and all let the rows show through it crisp.
        HStack(spacing: 0) {
            ForEach(HomeMode.allCases) { item in
                segment(item)
            }
        }
        .frame(width: Self.width, height: Self.height)
        // Pinned light: the library's navy thumbnails pass under it (`HomeTheme.controlTint`).
        .glassEffect(.regular.tint(HomeTheme.controlTint).interactive(!isLocked), in: Capsule())
        .disabled(isLocked)
        .sensoryFeedback(.selection, trigger: mode)
        // A custom tab bar for VoiceOver (UIKit's pattern): the "Mode" node isn't an
        // element itself and carries the tab bar trait, its children are the three
        // buttons, so each is read with its place, "2 of 3". (Checked in the app's
        // accessibility tree; XCUI lists the group as Other, not as a TabBar. A
        // segmented Picker as an accessibilityRepresentation was tried and dropped:
        // its segment frames overrun the capsule and the "Mode" label is lost.)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isLocked ? "Mode, locked while recording" : "Mode")
        .accessibilityAddTraits(.isTabBar)
        .accessibilityIdentifier("home-mode")
    }

    private func segment(_ item: HomeMode) -> some View {
        let selected = item == mode
        return Button {
            select(item)
        } label: {
            ZStack {
                if selected {
                    Circle()
                        .fill(HomeTheme.navy)
                        .overlay {
                            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.24), .clear],
                                                                 startPoint: .top, endPoint: .center), lineWidth: 1)
                        }
                        .shadow(color: HomeTheme.navy(0.28), radius: 3, y: 2)
                        .matchedGeometryEffect(id: "thumb", in: thumb)
                }
                ModeGlyph(mode: item)
                    .foregroundStyle(selected ? Color.white : HomeTheme.controlSecondary)
            }
            .frame(width: Self.thumbSize, height: Self.thumbSize)
            // Locked, the thumb and icons dim. In here, inside the glass: an
            // opacity on the glass view reaches neither its glass nor this.
            .opacity(isLocked ? 0.4 : 1)
            // The end thumbs sit 4 pt in from the capsule's ends, like the middle one.
            .padding(.leading, item == .instrument ? 4 : 0)
            .padding(.trailing, item == .song ? 4 : 0)
            .frame(width: Self.segmentWidth, height: Self.height,
                   alignment: item == .instrument ? .leading : item == .song ? .trailing : .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(SegmentPressStyle())
        .accessibilityLabel(item.title)
        .accessibilityHint(item.caption)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("home-mode-\(item.rawValue)")
        .accessibilityShowsLargeContentViewer {
            Label { Text(item.title) } icon: { ModeGlyph(mode: item) }
        }
    }

    private func select(_ item: HomeMode) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) {
            mode = item
        }
        onSelect(item)
    }
}

/// A segment's press: its icon shrinks a touch, or dims with Reduce Motion.
private struct SegmentPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// The mode icons: a single note (Instrument), a small keyboard (Piano) and
/// stacked lanes of notes (Song). 24-unit artwork with round 1.9-unit strokes.
struct ModeGlyph: View {
    let mode: HomeMode
    var size: CGFloat = 21
    var lineWidth: CGFloat = 1.9

    var body: some View {
        let scale = size / 24
        ZStack {
            ModeGlyphShape(mode: mode, filled: false)
                .stroke(style: StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round, lineJoin: .round))
            ModeGlyphShape(mode: mode, filled: true)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct ModeGlyphShape: Shape {
    let mode: HomeMode
    /// The solid parts (the note head, the black keys); otherwise the strokes.
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        func line(_ path: inout Path, _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
            path.move(to: p(x0, y0))
            path.addLine(to: p(x1, y1))
        }
        var path = Path()
        switch mode {
        case .instrument:
            // A tilted note head (filled and outlined) with its stem and flag.
            let head = Path(ellipseIn: CGRect(x: -3.3, y: -2.5, width: 6.6, height: 5))
                .applying(CGAffineTransform(rotationAngle: -20 * .pi / 180))
                .applying(CGAffineTransform(translationX: 9, y: 17.4))
                .applying(CGAffineTransform(scaleX: s, y: s))
                .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
            path.addPath(head)
            if !filled {
                line(&path, 12.1, 16.6, 12.1, 3.8)
                path.addCurve(to: p(17.5, 9.6), control1: p(13.6, 5.8), control2: p(16.7, 6.5))
            }
        case .piano:
            if filled {
                path.addRoundedRect(in: CGRect(origin: p(6.3, 5), size: CGSize(width: 2.4 * s, height: 8 * s)),
                                    cornerSize: CGSize(width: 0.6 * s, height: 0.6 * s))
                path.addRoundedRect(in: CGRect(origin: p(15.3, 5), size: CGSize(width: 2.4 * s, height: 8 * s)),
                                    cornerSize: CGSize(width: 0.6 * s, height: 0.6 * s))
            } else {
                path.addRoundedRect(in: CGRect(origin: p(3, 5), size: CGSize(width: 18 * s, height: 14 * s)),
                                    cornerSize: CGSize(width: 2.5 * s, height: 2.5 * s))
                line(&path, 12, 5, 12, 19)
                line(&path, 7.5, 13, 7.5, 19)
                line(&path, 16.5, 13, 16.5, 19)
            }
        case .song:
            if !filled {
                for (x0, x1, y) in [(4.0, 10.0, 6.5), (13, 20, 6.5), (4, 14, 12), (17, 20, 12),
                                    (4, 7, 17.5), (10, 14, 17.5), (17, 20, 17.5)] as [(CGFloat, CGFloat, CGFloat)] {
                    line(&path, x0, y, x1, y)
                }
            }
        }
        return path
    }
}

#Preview {
    @Previewable @State var mode = HomeMode.piano
    VStack(spacing: 30) {
        ModeSegments(mode: $mode)
        ModeSegments(mode: $mode, isLocked: true)
    }
    .padding(40)
    .background(HomeTheme.ground)
}
