import SwiftUI

/// The Semitone clef (clef plus bean), cropped to the glyph and tinted, from
/// the intro's artwork (IntroClef + IntroBean, white on a 1024 px square).
struct SemitoneGlyph: View {
    var color: Color = HomeTheme.navy
    /// The glyph's height in points; the width follows (about 0.6 of it).
    var height: CGFloat

    /// The glyph's bounds on the 1024 px artwork.
    private static let bounds = CGRect(x: 351, y: 243, width: 322, height: 538)
    static let aspect = bounds.width / bounds.height

    var body: some View {
        let scale = height / Self.bounds.height
        let side = 1024 * scale
        // Decorative: a named image is otherwise read out by its asset name
        // ("IntroClef", "IntroBean"), even inside an accessibility-hidden view.
        ZStack {
            Image(decorative: "IntroClef").resizable().renderingMode(.template)
            Image(decorative: "IntroBean").resizable().renderingMode(.template)
        }
        .foregroundStyle(color)
        .frame(width: side, height: side)
        .offset(x: (side - Self.bounds.width * scale) / 2 - Self.bounds.minX * scale,
                y: (side - Self.bounds.height * scale) / 2 - Self.bounds.minY * scale)
        .frame(width: Self.bounds.width * scale, height: height)
        .clipped()
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 20) {
        SemitoneGlyph(height: 24)
        SemitoneGlyph(color: .white, height: 29)
            .padding(14)
            .background(HomeTheme.record, in: Circle())
    }
    .padding()
}
