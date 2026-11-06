import SwiftUI
import UIKit

/// The two Settings sheets (S03 · Picture choices): Home's grouped ground,
/// white cards with compact 44 pt rows, picture cards for the choices that
/// change what you see, and navy for what's chosen. The app is light only
/// now (`RootView`), so only the light values show; the dark ones that
/// 0.96 gave a Tone's Settings are kept, unused, where they were.
enum SettingsTheme {
    /// The sheet's ground: #F2F2F7, as on Home.
    static let ground = Color(.systemGroupedBackground)
    /// Cards: white, or #1C1C1E in dark mode.
    static let card = Color(.secondarySystemGroupedBackground)
    /// The ground of a picture inside a card.
    static let picture = adaptive(0xF4F5F8, 0x2C2C2E)
    /// What's chosen: switches, the chosen card's ring and tick, the values
    /// of pop-ups. Navy, 16.6:1 on a card; in dark mode a light navy, 9.6:1
    /// on the dark card.
    static let accent = adaptive(0x0F1E3A, 0xA9C3F5)
    /// Ticks and text on the accent (white, 16.6:1; navy on the light navy, 9.3:1).
    static let onAccent = adaptive(0xFFFFFF, 0x0F1E3A)
    /// The second line on the chosen "Auto" chip (11.0:1 on navy, 5.4:1 on the light navy).
    static let onAccentSecondary = adaptive(0xC9D3E8, 0x2E4470)
    /// Headers, footers and values: 5.4:1 on the ground and 6.0:1 on a card
    /// (the system's secondary label is 3.4:1); 9.5:1 and 7.7:1 in dark mode.
    static let secondary = adaptive(0x636366, 0xAEAEB2)
    /// An unchosen radio, chevrons and the tempo ticks (non-text: 3.4:1 on
    /// white, 5.0:1 on the dark card).
    static let ring = adaptive(0x8A8A8E, 0x8A8A8E)
    /// Chord names in pictures: navy, as the roll writes them (15.2:1 on
    /// the picture's ground; the blue before was 5.3:1).
    static let chord = Color(hex: 0x0F1E3A)
    /// Bar numbers and downbeat lines in pictures (15.9:1).
    static let ink = adaptive(0x1C1C1E, 0xF2F2F7)
    /// A take's notes on the Detection presets' pictures, the lower half
    /// lighter: blues a quarter calmer than 0.96's (#3D5FA8 and #A3B6DE),
    /// at the same lightness (5.6:1 on the picture's ground, and 1.9:1).
    static let note = Color(hex: 0x476197)
    static let noteLow = Color(hex: 0xA8B6D4)
    /// The "Experimental" chip (5.6:1; 8.1:1 dark).
    static let experimentalInk = adaptive(0x9A4D00, 0xF8B47C)
    static let experimentalFill = adaptive(0xFFF3E3, 0x3A2611)
    /// A destructive row, like Revert to raw: the record red (#C63639, 5.3:1
    /// on a card), from Home.
    static let destructive = HomeTheme.record

    static let cardRadius: CGFloat = 20

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// A titled group of settings: a header, its controls, and a footer that
/// says what they do. The header carries `settings-section-<id>` for UI tests.
struct SettingsSection<Content: View>: View {
    let title: String
    let id: String
    var footer: Text?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SettingsTheme.secondary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("settings-section-\(id)")
                .padding(.horizontal, 4)
            content
            if let footer {
                SettingsFooter(footer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The small print under a group.
struct SettingsFooter: View {
    let text: Text
    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(.footnote)
            .foregroundStyle(SettingsTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// White rows on a rounded card, with hairlines between them (put
/// `SettingsDivider` where one goes).
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsTheme.card,
                        in: RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous))
    }
}

/// The hairline between two rows, inset like the system's.
struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 16)
    }
}

/// A row's padding: at least 44 pt tall, 16 pt in from the card's edges.
extension View {
    func settingsRow() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

/// A switch row. The whole row is the target, not only the switch: at
/// least 44 pt tall, and a tap anywhere on it flips the switch. To
/// VoiceOver and UI tests the row is a container with the switch in it.
struct SettingsToggleRow<Label: View>: View {
    @Binding var isOn: Bool
    /// What VoiceOver reads, where the label has more than one layout.
    var spoken: String?
    @ViewBuilder var label: Label
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Toggle(isOn: $isOn) { label }
            .modifier(SpokenLabel(text: spoken))
            .tint(SettingsTheme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if isEnabled { isOn.toggle() } }
            .accessibilityElement(children: .contain)
    }
}

/// Replaces a control's spoken label when there's one to give.
private struct SpokenLabel: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text {
            content.accessibilityLabel(text)
        } else {
            content
        }
    }
}

extension SettingsToggleRow where Label == SettingsToggleTitle {
    /// A title, with a second line under it when there's one.
    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { SettingsToggleTitle(title: title, subtitle: subtitle) }
    }
}

struct SettingsToggleTitle: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(SettingsTheme.secondary)
            }
        }
    }
}

/// A title with its value at the far side, or, when the two don't fit on
/// one line (accessibility text sizes), the value under the title rather
/// than both broken up word by word.
struct SettingsTitleValue<Title: View, Value: View>: View {
    @ViewBuilder var title: Title
    @ViewBuilder var value: Value

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                title.lineLimit(1)
                Spacer(minLength: 8)
                value.lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                value
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A row that opens a page of its own: its title, its value, a chevron.
struct SettingsLinkRow<Value: Hashable>: View {
    let title: String
    let value: String
    let destination: Value

    var body: some View {
        NavigationLink(value: destination) {
            HStack(spacing: 8) {
                SettingsTitleValue {
                    Text(title)
                        .foregroundStyle(Color.primary)
                } value: {
                    Text(value)
                        .foregroundStyle(SettingsTheme.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(SettingsTheme.ring)
                    .accessibilityHidden(true)
            }
            .settingsRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityAddTraits(.isButton)
    }
}

/// A pop-up row: the title, then the choice in the accent with the system's
/// up-down chevrons. The menu holds `content` (a `Picker`).
struct SettingsMenuRow<Content: View>: View {
    let title: String
    let value: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            SettingsTitleValue {
                Text(title)
                    .foregroundStyle(Color.primary)
            } value: {
                HStack(spacing: 4) {
                    Text(value)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                }
                .foregroundStyle(SettingsTheme.accent)
            }
            .settingsRow()
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(hint ?? "")
    }
}

/// A picture card's radio: a navy disc with a tick when chosen, an empty
/// ring when not.
struct SettingsRadioMark: View {
    let isOn: Bool
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 20

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(SettingsTheme.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(SettingsTheme.onAccent)
            } else {
                Circle().strokeBorder(SettingsTheme.ring, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "Experimental", on a soft orange chip.
struct ExperimentalChip: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flask")
                .imageScale(.small)
            Text("Experimental")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(SettingsTheme.experimentalInk)
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(SettingsTheme.experimentalFill, in: Capsule())
    }
}

/// Closes the Settings sheet from any page in it (a pushed page's own
/// `dismiss` would only go back a page).
struct CloseSettingsAction {
    var close: () -> Void = {}
    func callAsFunction() { close() }
}

extension EnvironmentValues {
    @Entry var closeSettings = CloseSettingsAction()
}

/// The scaffold both sheets share: a scrolling column on the grouped ground
/// under a large title, and the system's Liquid Glass close button (a pushed
/// page gets the glass back button beside it).
struct SettingsPage<Content: View>: View {
    let title: String
    var large = false
    @ViewBuilder var content: Content
    @Environment(\.closeSettings) private var closeSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(SettingsTheme.ground.ignoresSafeArea())
        .navigationTitle(title)
        .toolbarTitleDisplayMode(large ? .inlineLarge : .inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .close) {
                    closeSettings()
                }
                .accessibilityLabel("Close Settings")
                .accessibilityIdentifier("settings-close")
            }
        }
    }
}

/// The sheet around a Settings menu: its navigation stack, the navy accent,
/// and the close action every page's close button uses.
struct SettingsSheet<Root: View>: View {
    @ViewBuilder var root: Root
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack { root }
            .tint(SettingsTheme.accent)
            .environment(\.closeSettings, CloseSettingsAction { dismiss() })
    }
}
