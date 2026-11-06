import Foundation

/// Home's search: which Tones a query finds. Typed into the search field
/// over the library, it looks at what each Tone's row shows and a little
/// more: its title, its kind, its key and the chords it plays
/// (`TonePreview.key`, `TonePreview.chords`), so "Take", "piano", "E♭ minor"
/// and "Am F" all find something.
///
/// Query and fields are compared normalised (`normalise`): without case or
/// accents ("etude" finds "Evening étude"), ♭ and ♯ written b and #, and the
/// words "flat" and "sharp" after a note letter written the same way, so
/// "E♭", "Eb" and "e flat" are one thing. A Tone matches when the whole
/// query is part of its title from the start of a word ("take fi", "evening
/// et"), or when every word of the query finds something in it: a word of
/// its title it begins, its kind, its key, or a chord it plays. Not from the
/// middle of a word: a recording keeps the title it was given ("Recording
/// Oct 14, 2026 at 9:41 AM"), and "c", "d", "e" and "g" are all in
/// "recording", so a search for a chord or a key would find every one. For
/// the same reason a word that names a chord or a note ("a", "am") finds
/// only that word in a title, not every word it begins ("at").
///
/// A note name followed by "minor" or "major" is one word (a key) rather
/// than two, so "e minor" doesn't find a Tone in E major with an E minor
/// chord, or one titled "Evening" in C minor. A key finds a Tone in that key,
/// or one whose title names it ("Nocturne in E minor"): the key read from a
/// Tone's notes is often the relative major of the one it was written in.
///
/// Keys and chords are compared by pitch class, however they are spelled:
/// "D# minor" is E♭ minor and "Bb" is the A# the chord analyzer writes. A
/// chord word names its chord exactly ("C" isn't Cm7, and "G7" isn't G),
/// except that a chord without a slash bass finds its inversions too (the
/// harmony is C over E or not). A bare note name finds either key on it, and
/// "minor" or "major" alone every key of that mode.
///
/// Pure and nonisolated, so the unit tests can ask it directly; Home builds
/// one per query and asks it of each Tone.
nonisolated struct ToneSearch {
    /// What the search can see of a Tone. `key` and `chords` are known once
    /// its notes have been read (`TonePreviewStore`); until then it is found
    /// by its title and kind alone.
    struct Tone {
        var title: String
        var kind: TonePreview.Kind
        var key: MusicalKey? = nil
        var chords: [String] = []
    }

    /// One word of the query, after a note name and its mode are joined.
    private enum Term {
        /// "e minor", "eb major": this key and no other, or a title that
        /// names it (`phrase`, the two words as normalised).
        case key(tonic: Int, minor: Bool, phrase: String)
        case word(String)
    }

    /// The query as normalised (empty finds everything).
    private let query: String
    private let terms: [Term]

    init(_ text: String) {
        query = Self.normalise(text)
        var words = query.split(separator: " ").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"'()[]{}“”‘’"))
        }
        words.removeAll(where: \.isEmpty)
        var terms: [Term] = []
        var i = 0
        while i < words.count {
            if i + 1 < words.count, let note = Self.noteName(words[i]), let minor = Self.mode(words[i + 1]) {
                terms.append(.key(tonic: note, minor: minor, phrase: words[i] + " " + words[i + 1]))
                i += 2
            } else {
                terms.append(.word(words[i]))
                i += 1
            }
        }
        self.terms = terms
    }

    /// Nothing typed (or only spaces): every Tone matches.
    var isEmpty: Bool { query.isEmpty }

    func matches(_ tone: Tone) -> Bool {
        guard !isEmpty else { return true }
        let title = Self.normalise(tone.title)
        if Self.title(title, has: query) { return true }
        let titleWords = title.split { !Self.isWordCharacter($0) }
        let chords = tone.chords.compactMap(ChordSymbol.init)
        return terms.allSatisfy { term in
            switch term {
            case .key(let tonic, let minor, let phrase):
                return tone.key == MusicalKey(tonic: tonic, minor: minor) || Self.title(title, has: phrase)
            case .word(let word):
                let wanted = Self.chord(word)
                return titleWords.contains { wanted == nil ? $0.hasPrefix(word) : $0 == word }
                    || tone.kind.title.lowercased().hasPrefix(word)
                    || Self.word(word, findsKey: tone.key)
                    || wanted.map { wanted in chords.contains { Self.chord($0, is: wanted) } } ?? false
            }
        }
    }

    /// `part` is in the (normalised) title from the start of a word.
    private static func title(_ title: String, has part: String) -> Bool {
        title.ranges(of: part).contains { range in
            range.lowerBound == title.startIndex || !isWordCharacter(title[title.index(before: range.lowerBound)])
        }
    }

    /// A letter, a digit, or the # of a sharp ("c#" is one word).
    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "#" }

    // MARK: Words

    /// Lower case without accents, ♭ and ♯ as b and #, "e flat" and
    /// "f sharp" (or "e-flat") as "eb" and "f#", every run of spaces one
    /// space, trimmed.
    static func normalise(_ text: String) -> String {
        var s = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "♭", with: "b")
            .replacingOccurrences(of: "♯", with: "#")
        s = s.replacingOccurrences(of: #"\b([a-g])[\s-]*flat\b"#, with: "$1b", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b([a-g])[\s-]*sharp\b"#, with: "$1#", options: .regularExpression)
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A note name alone ("e", "eb", "d#") as its pitch class.
    private static func noteName(_ word: String) -> Int? {
        guard let note = note(prefixOf: word), note.rest.isEmpty else { return nil }
        return note.pc
    }

    /// "minor" or "major", or as much of either as names it ("min", "maj"):
    /// whether it's minor.
    private static func mode(_ word: String) -> Bool? {
        guard word.count >= 3 else { return nil }
        if "minor".hasPrefix(word) { return true }
        if "major".hasPrefix(word) { return false }
        return nil
    }

    private static let naturals: [Character: Int] = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11]

    /// A lower-case note name at the start of `word` (a letter and at most
    /// one b or #) as its pitch class, and what follows it.
    private static func note(prefixOf word: String) -> (pc: Int, rest: Substring)? {
        guard let letter = word.first, let natural = naturals[letter] else { return nil }
        var rest = word.dropFirst()
        var pc = natural
        switch rest.first {
        case "b": pc -= 1; rest = rest.dropFirst()
        case "#": pc += 1; rest = rest.dropFirst()
        default: break
        }
        return ((pc + 12) % 12, rest)
    }

    /// The word names the Tone's key, or the Tone is in a key of the mode it
    /// names: "eb" (either mode), "ebm" or "ebmin" (minor), "ebmaj"
    /// (major), "minor" and "major" (and "min", "maj") alone.
    private static func word(_ word: String, findsKey key: MusicalKey?) -> Bool {
        guard let key else { return false }
        if let minor = mode(word) { return minor == key.minor }
        guard let note = note(prefixOf: word), note.pc == key.tonic else { return false }
        if note.rest.isEmpty { return true }
        return (note.rest == "m" ? true : mode(String(note.rest))) == key.minor
    }

    /// The word as a chord symbol: "am" is Am, "bb7" B♭7, "c/e" C over E.
    /// `ChordSymbol` reads note names in capitals, so the root and the slash
    /// bass are given theirs (a "b" after them is still a flat).
    private static func chord(_ word: String) -> ChordSymbol? {
        let parts = word.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }
        return ChordSymbol(parts.joined(separator: "/"))
    }

    /// The Tone's chord is the one asked for: the same root and quality,
    /// and the same bass if one was asked for.
    private static func chord(_ chord: ChordSymbol, is wanted: ChordSymbol) -> Bool {
        chord.root == wanted.root && chord.quality == wanted.quality
            && (wanted.slashBass == nil || chord.slashBass == wanted.slashBass)
    }
}
