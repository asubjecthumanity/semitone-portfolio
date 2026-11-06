import SwiftUI

/// The round Liquid Glass "+" right of the record button. Tapped, it turns
/// into "×" on a navy disc and three round glass buttons fan out of it in an
/// arc above: Files, Photos and Link (experimental; off until Settings turns
/// it on). × or a tap anywhere outside closes it. The choices morph out of
/// the "+" glass (they share its GlassEffectContainer and start on the "+"),
/// and fly back into it on closing; with Reduce Motion they fade in place
/// instead. VoiceOver reads them Files, Photos, Link, then the ×. While
/// recording the "+" dims (its glass stays whole) and doesn't respond.
struct ImportFan: View {
    @Binding var isOpen: Bool
    /// Link import is an experimental setting; while it's off, Link says so.
    let linkEnabled: Bool
    /// Recording: the "+" dims and doesn't respond.
    var isLocked = false
    /// The glass namespace for the "+" and its choices' glassEffectIDs.
    let glass: Namespace.ID
    let onPick: (ImportSource) -> Void

    static let size: CGFloat = 48
    static let choiceSize: CGFloat = 50
    /// The arc's radius from the "+" centre, and the turn between choices
    /// (from straight up, toward the record button).
    static let radius: CGFloat = 114
    static let step = Angle.degrees(29)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focus: Focus?
    /// The choices are in the view tree: from the tap that opens the fan
    /// until they're back in the "+" after it closes.
    @State private var shown = false
    /// Closing: the choices fly back into the "+" (they leave the tree after).
    @State private var tucked = false
    /// The choices whose icon and name are showing: each grows in as its glass
    /// leaves the "+".
    @State private var out: Set<String> = []
    /// The Experimental chip, beside Link once Link is in place.
    @State private var chipShown = false

    /// Out along the arc (a little overshoot), and back in (none, so nothing
    /// pokes out past the "+").
    private static let flyOut = Animation.spring(response: 0.44, dampingFraction: 0.76)
    private static let flyIn = Animation.smooth(duration: 0.3)

    private enum Focus: Hashable {
        case toggle
        case choice(String)
    }

    private struct Choice: Identifiable {
        let id: String
        let source: ImportSource
        let symbol: String
        let title: String
        let label: String
        var enabled = true
    }

    private var choices: [Choice] {
        [Choice(id: "files", source: .files, symbol: "folder", title: "Files",
                label: "Audio or video from Files"),
         Choice(id: "photos", source: .photos, symbol: "photo", title: "Photos",
                label: "Photos, use a video’s soundtrack"),
         Choice(id: "link", source: .link, symbol: "link", title: "Link",
                label: linkEnabled ? "Link, Experimental" : "Link, Experimental, off. Turn on in Settings",
                enabled: linkEnabled)]
    }

    var body: some View {
        // Import's own container, inside the bottom row's: the "+" morphs into
        // its choices here.
        GlassEffectContainer(spacing: 4) {
            ZStack {
                if shown {
                    ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                        choiceButton(choice, index: index)
                    }
                }
                if chipShown {
                    experimentalChip
                }
                toggle
            }
            .frame(width: Self.size, height: Self.size)
            // Its own accessibility container, so the sort priorities below
            // order the choices for VoiceOver rather than their places on the
            // arc (whose rows put Photos before Files).
            .accessibilityElement(children: .contain)
        }
        .onAppear { if isOpen { fan(open: true) } }
        .onChange(of: isOpen) { _, open in
            fan(open: open)
            // Move VoiceOver to the first choice, or back to the "+".
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(open ? 150 : 60))
                focus = open ? .choice("files") : .toggle
            }
        }
    }

    // MARK: The "+"

    private var toggle: some View {
        Button {
            isOpen.toggle()
        } label: {
            ZStack {
                // Open, the × sits on a navy disc in the glass, like the
                // selected mode's thumb. A disc in the content, not a navy
                // tint on the glass: the container spreads a tint change over
                // the glass around it (it flashed the choices and the chip
                // navy as they went), and a tint fades in steps, not smoothly.
                Circle()
                    .fill(HomeTheme.navy)
                    .padding(4)
                    .opacity(isOpen ? 1 : 0)
                Image(systemName: reduceMotion && isOpen ? "xmark" : "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .rotationEffect(.degrees(isOpen && !reduceMotion ? 45 : 0))
                    .foregroundStyle(isOpen ? Color.white : HomeTheme.controlInk)
                    // Locked, only the "+" dims; its glass stays whole, so the
                    // Tones scrolling under it stay frosted. (In here, inside
                    // the glass: an opacity on the glass view wouldn't reach it.)
                    .opacity(isLocked ? 0.4 : 1)
            }
            .frame(width: Self.size, height: Self.size)
            .contentShape(Circle())
        }
        .buttonStyle(GlassControlStyle())
        .glassEffect(.regular.tint(HomeTheme.controlTint).interactive(!isLocked), in: Circle())
        .glassEffectID("import", in: glass)
        .disabled(isLocked)
        .sensoryFeedback(.impact(weight: .light), trigger: isOpen)
        .accessibilityLabel(isOpen ? "Close Import" : "Import")
        .accessibilityHint(isOpen ? "" : "Shows ways to bring in audio or video.")
        .accessibilityIdentifier("home-import")
        .accessibilityFocused($focus, equals: .toggle)
    }

    // MARK: The fan

    /// Opening puts the choices in; each flies out of the "+" (`flight`) and
    /// its icon and name grow in (`land`). Closing flies them back into the
    /// "+" and then takes them out of the tree: a removal transition can't do
    /// it, as the container drops a removed view's glass at once.
    private func fan(open: Bool) {
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) {
                tucked = false
                shown = open
                out = open ? Set(choices.map(\.id)) : []
                chipShown = open
            }
        } else if open {
            if shown {
                // Reopened on the way back in: out again from where they are.
                withAnimation(Self.flyOut) { tucked = false }
                for (index, choice) in choices.enumerated() { land(choice.id, index: index) }
            } else {
                // Inserted in an animation: only then does the container draw
                // their glass during the flight (without one it holds the new
                // glass back until the flight is over, and they pop in late).
                withAnimation(Self.flyOut) {
                    tucked = false
                    shown = true
                }
            }
        } else {
            withAnimation(.easeOut(duration: 0.12)) { chipShown = false }
            withAnimation(Self.flyIn, completionCriteria: .logicallyComplete) {
                tucked = true
                out = []
            } completion: {
                // They're in the "+", out of sight: now out of the tree too.
                guard !isOpen else { return }
                withAnimation(.easeOut(duration: 0.25)) { shown = false }
            }
        }
    }

    /// As a choice's glass leaves the "+", its icon and name grow in, a beat
    /// after the one before. Once Link is in place, the Experimental chip
    /// appears beside it.
    private func land(_ id: String, index: Int) {
        guard isOpen, !reduceMotion else { return }
        withAnimation(Self.flyOut.delay(0.035 * Double(index))) {
            _ = out.insert(id)
        } completion: {
            if id == "link", isOpen {
                withAnimation(.easeOut(duration: 0.2)) { chipShown = true }
            }
        }
    }

    private func offset(_ index: Int) -> CGSize {
        let a = Self.step.radians * Double(index)
        return CGSize(width: -Self.radius * sin(a), height: -Self.radius * cos(a))
    }

    private func choiceButton(_ choice: Choice, index: Int) -> some View {
        let at = offset(index)
        let isOut = out.contains(choice.id)
        return Button {
            onPick(choice.source)
        } label: {
            VStack(spacing: 1) {
                Image(systemName: choice.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 20)
                Text(choice.title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(choice.id == "photos" ? -0.2 : 0)
            }
            .foregroundStyle(choice.enabled ? HomeTheme.controlInk : HomeTheme.controlDisabled)
            // Grows in as the glass leaves the "+" (`land`). In here, inside the
            // glass: an opacity outside it wouldn't reach the icon and name.
            .scaleEffect(isOut ? 1 : 0.6)
            .opacity(isOut ? 1 : 0)
            .frame(width: Self.choiceSize, height: Self.choiceSize)
            .contentShape(Circle())
        }
        .buttonStyle(GlassControlStyle())
        .glassEffect(.regular.tint(HomeTheme.controlTint).interactive(choice.enabled), in: Circle())
        .glassEffectID(choice.id, in: glass)
        // No glass effect of its own coming in: its glass leaves the "+" with
        // it (`flight`). (.matchedGeometry drew it lighter and short of its
        // place until the flight ended, then snapped; .materialize blurs it.)
        .glassEffectTransition(reduceMotion ? .materialize : .identity)
        .disabled(!choice.enabled)
        .offset(tucked ? .zero : at)
        .transition(flight(from: at, index: index))
        .onAppear { land(choice.id, index: index) }
        // On the way back into the "+", they're no longer choices.
        .allowsHitTesting(isOpen)
        .accessibilityHidden(!isOpen)
        .accessibilityLabel(choice.label)
        // Files, Photos, Link, then the × (priority 0).
        .accessibilitySortPriority(Double(choices.count - index))
        .accessibilityIdentifier("import-option-\(choice.id)")
        .accessibilityFocused($focus, equals: .choice(choice.id))
        .accessibilityAction(.escape) { isOpen = false }
        .accessibilityShowsLargeContentViewer {
            Label(choice.title, systemImage: choice.symbol)
        }
    }

    /// "Experimental · Off" beside Link (spoken as part of Link's label).
    private var experimentalChip: some View {
        let link = offset(2)
        return HStack(spacing: 4) {
            Image(systemName: "flask")
                .font(.system(size: 10, weight: .semibold))
            Text(linkEnabled ? "Experimental" : "Experimental · Off")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(HomeTheme.experimental)
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: 22)
        .fixedSize()
        .glassEffect(.regular.tint(HomeTheme.controlTint), in: Capsule())
        .glassEffectID("link-chip", in: glass)
        .glassEffectTransition(.materialize)
        // Its trailing edge 6 pt left of Link, centred on it.
        .frame(width: 0, height: 0, alignment: .trailing)
        .offset(x: link.width - Self.choiceSize / 2 - 6, y: link.height)
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Out of the "+" to its place on the arc, a beat after the one before.
    /// Only an offset: offset back by its place on the arc, a choice sits
    /// exactly on the "+", and the container moves its glass with it, so the
    /// glass leaves the "+". A scale in the transition put the glass off to
    /// the side of the "+" (below and right of it) at the start, and an
    /// opacity there doesn't reach the glass or its content, so the icon and
    /// name grow in inside the glass instead (`land`). (Closing is `tucked`.)
    private func flight(from at: CGSize, index: Int) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: FanFlight(offset: CGSize(width: -at.width, height: -at.height)),
                                 identity: FanFlight(offset: .zero))
                .animation(Self.flyOut.delay(0.035 * Double(index))),
            removal: .identity)
    }
}

/// A choice's flight: offset back by its place on the arc, it's on the "+".
private struct FanFlight: ViewModifier {
    let offset: CGSize

    func body(content: Content) -> some View {
        content.offset(offset)
    }
}

#Preview {
    @Previewable @State var open = true
    @Previewable @Namespace var glass
    ImportFan(isOpen: $open, linkEnabled: false, glass: glass) { _ in }
    .frame(width: 358, height: 220, alignment: .bottomTrailing)
    .padding()
    .background(HomeTheme.ground)
}
