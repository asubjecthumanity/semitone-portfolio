import Foundation

/// One chord row of the AI-generated chart.
nonisolated struct AIChord: Codable, Hashable {
    let startTime: Double
    let endTime: Double
    let symbol: String
    let romanNumeral: String?
    let confidence: Double

    var isCertain: Bool { confidence >= 0.5 }
}

/// Musical interpretation produced by asking a text model to read the detected
/// notes back into a chart. Advisory only: deterministic detection stays the
/// source of truth, the model just adds key/function/simplification.
nonisolated struct ChartSuggestion: Codable, Hashable {
    var key: String
    var timeSignature: String?
    var bpm: Double?
    var chords: [AIChord]
    var observation: String?
    var confidence: Double
}

/// Outcome of an AI cleanup pass: the corrected notes plus what changed.
nonisolated struct CleanupResult: Hashable {
    let notes: [NoteEvent]
    let removed: Int
    let shifted: Int
    let merged: Int
    let confidence: Double
    let summary: String?

    var changeCount: Int { removed + shifted + merged }
}

/// Talks to a hosted text LLM so the pitch-faithful but "dumb" detection gets
/// a readable chart: key, chord symbols with roman-numeral function, and a
/// simplified timeline. Always ships a confidence so the UI can show doubt.
///
/// The classic by-ear failure mode is a model confidently hallucinating a
/// plausible-but-wrong chord, so the request sends the *detected notes as a
/// compact text table* — never raw audio, which is private, slow, and noisy
/// for pitch — and asks the model to label the evidence honestly.
nonisolated enum AIChartInterpreter {
    /// Seconds of trail sent on each live "chart this recent bit" request.
    static let trailingWindow = 10.0

    private static let systemPrompt = """
    You are the "theory brain" of a by-ear music practice app. You receive a
    machine-detected sketch of a performance: one JSON array entry per detected
    note as [startSeconds, endSeconds, "C4", velocity0to127, isLeadLine0or1].
    The sketch is approximate; it includes accompaniment, may contain octave
    doubles, dyads, and passing tones, and is not quantized.

    Return ONLY JSON with this exact schema:
    {
      "key": string,          // e.g. "G major" or "E minor"; "" if undecidable
      "timeSignature": string,// e.g. "4/4"
      "bpm": number,          // perceived tempo in beats/minute, or null
      "chords": [
        {
          "startTime": number,
          "endTime": number,
          "symbol": string,     // e.g. "C", "Am7", "F/G", "Bdim"
          "romanNumeral": string | null, // e.g. "I", "vi", "V/ii"
          "confidence": number  // 0..1
        }
      ],
      "observation": string | null, // one short learner tip, or null
      "confidence": number          // 0..1, overall
    }

    Rules:
    - Chords must span most of the timeline contiguously with no big gaps.
    - A chord's root (or slash bass) must be present in the detected notes of
      its span; never invent pitches the sketch does not contain.
    - When a span is thin (fewer than 3 distinct pitches) omit it or set its
      confidence below 0.4.
    - Prefer the simplest credible symbol; reserve added/19th chords for clear
      evidence.
    - Use isLeadLine to name the melody and to decide the key.
    - Be honest about confidence: noisy or sparse sketches get low numbers.
    """

    private static let cleanupPrompt = """
    You clean up a machine transcription of a piano performance. You receive a
    JSON array, one entry per detected note:
    [id, startSeconds, endSeconds, "C4", velocity0to127, isLeadLine0or1].
    The detector is pitch-accurate but makes these mistakes:
    - Overtone leakage: a quiet phantom note starting at the same moment as a
      louder note exactly 12, 19 or 24 semitones away from it.
    - Sub-octave ghosts: a quiet note 12 or 24 semitones BELOW a louder note
      with the same onset.
    - A single sustained note split into consecutive fragments of the same
      pitch with only a tiny gap between them. (But if other notes start at
      the same moment as the second fragment, it was re-struck as part of a
      chord — leave it.)
    - A stray very short, quiet note that fits no chord and no line.
    - Occasionally a whole note landing an octave away from the line it
      belongs to.

    Return ONLY JSON with this schema:
    {
      "remove": [id, ...],
      "shift": [{"id": id, "semitones": -12}, ...],
      "merge": [[id, id, ...], ...],
      "confidence": number,
      "summary": string
    }
    Rules:
    - You may only remove, shift by ±12/±24, or merge. Never add notes.
    - Merge only consecutive fragments of the same pitch (after any shift).
    - Be conservative: when unsure, leave the note alone. Prefer removing
      quiet overtone ghosts over loud notes. Keep lead-line notes unless
      they are clearly phantom.
    - "summary" is one short sentence describing what you changed and why.
    """

    /// Session-wide quarantine: once a request is refused with 429 (quota) we
    /// stop calling the provider entirely and every ask degrades to the
    /// on-device chart so the app still does the part it can.
    actor QuotaGuard {
        static let shared = QuotaGuard()
        private var blockedUntil = Date.distantPast

        /// Providers' 429s are usually per-minute limits, so back off for a
        /// minute rather than the whole session.
        func block(for seconds: TimeInterval = 60) {
            blockedUntil = max(blockedUntil, Date().addingTimeInterval(seconds))
        }
        var isBlocked: Bool { Date() < blockedUntil }
    }

    nonisolated enum Failure: LocalizedError, Equatable {
        case emptyInput
        case badStatus(Int, String)
        case unparseable(String)
        case invalidCleanup(String)
        case noContent
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .emptyInput: "No notes to chart."
            case .noContent: "The AI returned an empty chart."
            case .transport(let cause): "Could not reach the AI service: \(cause)"
            case .badStatus(let code, let body): "AI request failed (\(code)): \(body)"
            case .unparseable(let raw): "The AI returned unreadable JSON: \(raw)"
            case .invalidCleanup(let reason): "The AI returned conflicting cleanup operations: \(reason)"
            }
        }
    }

    nonisolated struct Provider {
        enum Kind: String { case openAI, anthropic, groq, semitone, mock }

        let kind: Kind
        let model: String
        let apiKey: String
        let baseURL: URL
    }

    /// A configured backend. `.mock` needs no key and answers from the
    /// on-device ChordAnalyzer so the whole pipeline runs offline.
    nonisolated struct Client: Sendable {
        let provider: Provider

        nonisolated static let mock = Client(provider: Provider(
            kind: .mock, model: "", apiKey: "",
            baseURL: URL(string: "https://example.invalid")!
        ))

        nonisolated static func openAI(apiKey: String, model: String = "gpt-4o-mini") -> Client {
            Client(provider: Provider(
                kind: .openAI, model: model, apiKey: apiKey,
                baseURL: URL(string: "https://api.openai.com/v1/chat/completions")!
            ))
        }

        nonisolated static func anthropic(apiKey: String, model: String = "claude-haiku-4-5-20251001") -> Client {
            Client(provider: Provider(
                kind: .anthropic, model: model, apiKey: apiKey,
                baseURL: URL(string: "https://api.anthropic.com/v1/messages")!
            ))
        }

        /// Free tier with real capacity (1,000 req/day as of 2026). Drop-in
        /// OpenAI-compatible request shape; good enough quality for charting.
        nonisolated static func groq(apiKey: String, model: String = "openai/gpt-oss-120b") -> Client {
            Client(provider: Provider(
                kind: .groq, model: model, apiKey: apiKey,
                baseURL: URL(string: "https://api.groq.com/openai/v1/chat/completions")!
            ))
        }

        /// Semitone's own AI service (the semitone-ai Worker): no key on the
        /// phone. It holds the Groq key and this file's two prompts (copied
        /// there by Tools/AIProxy/export_prompts.py), so a request carries only
        /// which job it is and the take's notes, plus this install's id, which
        /// the service counts against a daily cap.
        nonisolated static let semitoneServiceURL = URL(string: "https://semitone-ai.freemanmiller.net/v1/complete")!

        nonisolated static func semitone() -> Client {
            Client(provider: Provider(kind: .semitone, model: "", apiKey: "", baseURL: semitoneServiceURL))
        }

        /// A random id for this install, made once and kept in UserDefaults:
        /// what the service counts a phone's daily cleanups by. It names no one.
        nonisolated static var installID: String {
            let d = UserDefaults.standard
            if let id = d.string(forKey: "aiInstallID"), UUID(uuidString: id) != nil { return id }
            let id = UUID().uuidString
            d.set(id, forKey: "aiInstallID")
            return id
        }

        /// Key from SEMITONE_AI_KEY, provider from SEMITONE_AI_PROVIDER
        /// (openai|anthropic|groq). Without one it's Semitone's own service,
        /// so a TestFlight or App Store build has AI with nothing to set up;
        /// SEMITONE_AI_MOCK=1 forces the offline mock.
        nonisolated static func makeDefault() -> Client {
            let env = ProcessInfo.processInfo.environment
            if env["SEMITONE_AI_MOCK"] == "1" { return mock }
            guard let key = env["SEMITONE_AI_KEY"], !key.isEmpty else { return semitone() }
            let client: Client
            switch env["SEMITONE_AI_PROVIDER"] {
            case "anthropic": client = anthropic(apiKey: key)
            case "groq": client = groq(apiKey: key)
            default: client = openAI(apiKey: key)
            }
            return client
        }

        /// Provider + key chosen in-app (Settings) first ("semitone" needs no
        /// key), then the SEMITONE_AI_* environment (Xcode scheme), else
        /// Semitone's own service; "off" is the offline mock.
        nonisolated static func configured() -> Client {
            let d = UserDefaults.standard
            if d.string(forKey: "aiProvider") == "semitone" { return semitone() }
            if let raw = d.string(forKey: "aiProvider"), raw != "off",
               let key = d.string(forKey: "aiKey")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                switch raw {
                case "anthropic": return anthropic(apiKey: key)
                case "groq": return groq(apiKey: key)
                case "openai": return openAI(apiKey: key)
                default: break
                }
            }
            if d.string(forKey: "aiProvider") == "off" { return mock }
            return makeDefault()
        }

        func chart(notes: [NoteEvent], melody: [NoteEvent]) async throws -> ChartSuggestion {
            guard !notes.isEmpty else { throw Failure.emptyInput }
            let blocked = await QuotaGuard.shared.isBlocked
            if provider.kind == .mock || blocked {
                return Self.mockChart(notes: notes)
            }
            let text = Self.detectionPayload(notes: notes, melody: melody)
            let data = try await complete(system: AIChartInterpreter.systemPrompt, user: text, maxTokens: 1500)
            return try Self.decodeChart(from: data)
        }

        /// Asks the model for corrections to the raw detection and applies only
        /// the ones that survive validation. The model can remove notes, move a
        /// note by whole octaves, or merge fragments of one sustained note; it
        /// can never add a pitch the detector didn't hear.
        func cleanup(notes: [NoteEvent], melody: [NoteEvent]) async throws -> CleanupResult {
            guard !notes.isEmpty else { throw Failure.emptyInput }
            let blocked = await QuotaGuard.shared.isBlocked
            if provider.kind == .mock || blocked {
                return CleanupResult(notes: notes, removed: 0, shifted: 0, merged: 0,
                                     confidence: 0, summary: "AI provider not configured.")
            }
            let sorted = notes.sorted { ($0.startTime, $0.pitch) < ($1.startTime, $1.pitch) }
            let text = Self.cleanupPayload(notes: sorted, melody: melody)
            var data = try await complete(system: AIChartInterpreter.cleanupPrompt, user: text, maxTokens: 2500)
            if Self.jsonObject(in: String(decoding: data, as: UTF8.self)) == nil {
                // Reasoning models occasionally return an empty message; one retry.
                data = try await complete(system: AIChartInterpreter.cleanupPrompt, user: text, maxTokens: 2500)
            }
            return try Self.applyCleanup(from: data, to: sorted, melody: melody)
        }

        /// One chat completion, unwrapped to the assistant's text for any provider.
        private func complete(system: String, user: String, maxTokens: Int) async throws -> Data {
            switch provider.kind {
            case .mock:
                throw Failure.noContent

            case .openAI, .groq:
                var body: [String: Any] = [
                    "model": provider.model,
                    "temperature": 0.2,
                    "response_format": ["type": "json_object"],
                    "messages": [
                        ["role": "system", "content": system],
                        ["role": "user", "content": user],
                    ],
                ]
                do {
                    let data = try await Self.send(
                        body: body,
                        to: provider.baseURL,
                        header: "Authorization",
                        value: "Bearer \(provider.apiKey)",
                        extraHeaders: [:]
                    )
                    return Self.chatContent(from: data)
                } catch Failure.badStatus(400, let detail) where detail.contains("json_validate_failed") {
                    // Groq's strict JSON mode intermittently rejects its own
                    // output; plain text plus our extractor is more reliable.
                    body["response_format"] = nil
                    let data = try await Self.send(
                        body: body,
                        to: provider.baseURL,
                        header: "Authorization",
                        value: "Bearer \(provider.apiKey)",
                        extraHeaders: [:]
                    )
                    return Self.chatContent(from: data)
                }

            case .semitone:
                // The service adds the prompt for the job; the phone says which.
                let body: [String: Any] = [
                    "task": system == AIChartInterpreter.cleanupPrompt ? "cleanup" : "chart",
                    "input": user,
                    "max_tokens": maxTokens,
                ]
                do {
                    let data = try await Self.send(body: body, to: provider.baseURL,
                                                   header: "X-Semitone-Device", value: Self.installID,
                                                   extraHeaders: [:])
                    return Self.chatContent(from: data)
                } catch Failure.badStatus(429, let detail) where detail.contains("daily_limit") {
                    // Today's cap is used up: stop asking for an hour (the
                    // caps reset at midnight UTC) and use the on-device chart.
                    await QuotaGuard.shared.block(for: 3600)
                    throw Failure.badStatus(429, "Today's AI cleanups are used up. They come back tomorrow.")
                }

            case .anthropic:
                let body: [String: Any] = [
                    "model": provider.model,
                    "max_tokens": maxTokens,
                    "system": system,
                    "messages": [[
                        "role": "user",
                        "content": [["type": "text", "text": user]],
                    ]],
                ]
                let data = try await Self.send(
                    body: body,
                    to: provider.baseURL,
                    header: "x-api-key",
                    value: provider.apiKey,
                    extraHeaders: ["anthropic-version": "2023-06-01"]
                )
                return Self.textBlock(from: data)
            }
        }

        // MARK: - Cleanup parsing

        private struct RawCleanup: Decodable {
            struct Shift: Decodable {
                var id: Int?
                var semitones: Int?
            }
            var remove: [Int]?
            var shift: [Shift]?
            var merge: [[Int]]?
            var confidence: Double?
            var summary: String?
        }

        /// Guard rails measured against the reference clip: without them the
        /// model deleted a real melody note and fused notes that were actually
        /// re-struck at chord changes.
        private static let maxRemovableAmplitude = 0.6
        private static let maxRemovableLeadAmplitude = 0.3
        private static let restrikeWindow = 0.06
        /// On the reference clip a real octave double sat at 0.79× its mate
        /// and a genuine overtone ghost at 0.62×.
        private static let leakAmplitudeRatio = 0.7

        static func applyCleanup(
            from data: Data,
            to notes: [NoteEvent],
            melody: [NoteEvent]
        ) throws -> CleanupResult {
            let raw = String(decoding: data, as: UTF8.self)
            guard let json = jsonObject(in: raw), let jsonData = json.data(using: .utf8) else {
                throw Failure.unparseable(String(raw.prefix(300)))
            }
            let ops = try JSONDecoder().decode(RawCleanup.self, from: jsonData)

            // IDs always refer to the immutable input, not notes already edited
            // by an earlier operation. Repeated equivalent operations count once.
            let validIDs = Set(notes.indices)
            let removeIDs = Set((ops.remove ?? []).filter { validIDs.contains($0) })
            var shifts: [Int: Int] = [:]
            for shift in ops.shift ?? [] {
                guard let id = shift.id, validIDs.contains(id),
                      let semitones = shift.semitones, [-24, -12, 12, 24].contains(semitones) else { continue }
                if let previous = shifts[id], previous != semitones {
                    throw Failure.invalidCleanup("multiple shifts for note \(id)")
                }
                shifts[id] = semitones
            }
            var mergeGroups: [[Int]] = []
            var seenGroups: Set<[Int]> = []
            var mergeIDs: Set<Int> = []
            for group in ops.merge ?? [] {
                let ids = Array(Set(group.filter { validIDs.contains($0) })).sorted()
                guard ids.count >= 2, seenGroups.insert(ids).inserted else { continue }
                guard mergeIDs.isDisjoint(with: ids) else {
                    throw Failure.invalidCleanup("a note belongs to multiple merge groups")
                }
                mergeIDs.formUnion(ids)
                mergeGroups.append(ids)
            }
            let shiftIDs = Set(shifts.keys)
            guard removeIDs.isDisjoint(with: shiftIDs), removeIDs.isDisjoint(with: mergeIDs),
                  shiftIDs.isDisjoint(with: mergeIDs) else {
                throw Failure.invalidCleanup("a note is used by more than one operation type")
            }

            var working: [Int: NoteEvent] = [:]
            for (id, note) in notes.enumerated() { working[id] = note }
            let onsets = notes.map(\.startTime)

            /// Another note starting together with this one means a chord was
            /// struck here — so a same-pitch fragment starting here is a
            /// genuine re-strike, not a split.
            func coincidesWithOtherOnset(_ note: NoteEvent, id: Int) -> Bool {
                onsets.enumerated().contains { other, t in
                    other != id && abs(t - note.startTime) <= restrikeWindow
                }
            }

            /// A note may be deleted only if the detector's own evidence
            /// supports it: it is faint, or it is at most half as loud as a
            /// note struck at the same moment a harmonic interval away
            /// (the overtone-leak signature).
            func looksRemovable(_ note: NoteEvent, id: Int) -> Bool {
                if note.amplitude < maxRemovableLeadAmplitude { return true }
                guard note.amplitude < maxRemovableAmplitude else { return false }
                if Self.isLead(note, in: melody) { return false }
                return notes.enumerated().contains { other, mate in
                    other != id
                        && abs(mate.startTime - note.startTime) <= restrikeWindow
                        && [12, 19, 24].contains(abs(mate.pitch - note.pitch))
                        && note.amplitude <= leakAmplitudeRatio * mate.amplitude
                }
            }

            var removed = 0
            for id in removeIDs.sorted() {
                guard let note = working[id], looksRemovable(note, id: id) else { continue }
                working[id] = nil
                removed += 1
            }

            var shifted = 0
            for (id, semitones) in shifts.sorted(by: { $0.key < $1.key }) {
                let note = notes[id]
                let pitch = note.pitch + semitones
                guard (21...108).contains(pitch) else { continue }
                working[id] = NoteEvent(startTime: note.startTime, endTime: note.endTime,
                                        pitch: pitch, amplitude: note.amplitude).with(voice: note.voice)
                shifted += 1
            }

            var merged = 0
            for group in mergeGroups {
                let members = group.compactMap { working[$0] != nil ? ($0, working[$0]!) : nil }
                    .sorted { ($0.1.startTime, $0.0) < ($1.1.startTime, $1.0) }
                guard members.count >= 2 else { continue }
                // Merge only same-pitch fragments that are (nearly) touching;
                // a gap means the note really was re-struck.
                var run: [(Int, NoteEvent)] = [members[0]]
                func flush() {
                    guard run.count >= 2 else { return }
                    let first = run[0].1
                    let combined = NoteEvent(
                        startTime: first.startTime,
                        endTime: run.map { $0.1.endTime }.max() ?? first.endTime,
                        pitch: first.pitch,
                        amplitude: run.map { $0.1.amplitude }.max() ?? first.amplitude,
                        voice: first.voice
                    )
                    for (id, _) in run.dropFirst() { working[id] = nil }
                    working[run[0].0] = combined
                    merged += run.count - 1
                }
                for member in members.dropFirst() {
                    let last = run.last!.1
                    if member.1.pitch == last.pitch,
                       member.1.startTime - last.endTime <= 0.2,
                       !coincidesWithOtherOnset(member.1, id: member.0) {
                        run.append(member)
                    } else {
                        flush()
                        run = [member]
                    }
                }
                flush()
            }

            let cleaned = working.values.sorted { ($0.startTime, $0.pitch) < ($1.startTime, $1.pitch) }
            return CleanupResult(
                notes: cleaned,
                removed: removed,
                shifted: shifted,
                merged: merged,
                confidence: ops.confidence ?? 0,
                summary: ops.summary
            )
        }

        /// Same table as the chart payload, prefixed with a stable id per row
        /// so the model can refer back to notes.
        static func cleanupPayload(notes: [NoteEvent], melody: [NoteEvent]) -> String {
            let rows = notes.enumerated().map { id, note -> String in
                let velocity = min(127, max(1, Int(note.amplitude * 127)))
                let isLead = Self.isLead(note, in: melody) ? 1 : 0
                return "[\(id), \(fmt(note.startTime)), \(fmt(note.endTime)), \"\(note.noteName)\", \(velocity), \(isLead)]"
            }
            return "[\n" + rows.joined(separator: ",\n") + "\n]"
        }

        // MARK: - Networking

        private static func send(
            body: [String: Any],
            to baseURL: URL,
            header: String,
            value: String,
            extraHeaders: [String: String]
        ) async throws -> Data {
            var request = URLRequest(url: baseURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 45
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(value, forHTTPHeaderField: header)
            for (field, fieldValue) in extraHeaders {
                request.setValue(fieldValue, forHTTPHeaderField: field)
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw Failure.transport(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else {
                throw Failure.unparseable(String(decoding: data, as: UTF8.self))
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 429 {
                    await QuotaGuard.shared.block()
                }
                let snippet = String(decoding: data.prefix(400), as: UTF8.self)
                throw Failure.badStatus(http.statusCode, snippet)
            }
            return data
        }

        /// OpenAI-style APIs wrap the answer in `choices[0].message.content`;
        /// unwrap it so decodeChart sees the chart JSON, not the envelope.
        private static func chatContent(from data: Data) -> Data {
            struct Reply: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable { let content: String? }
                    let message: Message
                }
                let choices: [Choice]
            }
            if let reply = try? JSONDecoder().decode(Reply.self, from: data),
               let text = reply.choices.first?.message.content {
                return Data(text.utf8)
            }
            return data
        }

        /// Anthropic wraps the answer in `content[].text`; unwrap it so
        /// decodeChart can read it like any other JSON payload.
        private static func textBlock(from data: Data) -> Data {
            struct Reply: Decodable {
                struct Content: Decodable { let text: String? }
                let content: [Content]
            }
            if let reply = try? JSONDecoder().decode(Reply.self, from: data),
               let text = reply.content.compactMap(\.text).first {
                return Data(text.utf8)
            }
            return data
        }

        // MARK: - Parsing & payload

        private static func decodeChart(from data: Data) throws -> ChartSuggestion {
            let raw = String(decoding: data, as: UTF8.self)
            guard let json = jsonObject(in: raw),
                  let jsonData = json.data(using: .utf8) else {
                throw Failure.unparseable(String(raw.prefix(300)))
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            // Decode into fully-optional scaffolding first: cheaper models
            // drift from the schema (drop a field, type a null oddly), and
            // that must not kill an otherwise usable chart.
            let rawChart = try decoder.decode(RawChart.self, from: jsonData)
            let chords = (rawChart.chords ?? [])
                .compactMap { raw -> AIChord? in
                    guard let symbol = raw.symbol?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !symbol.isEmpty,
                          let start = raw.startTime, start.isFinite,
                          let end = raw.endTime, end.isFinite, end > start,
                          let confidence = raw.confidence, confidence >= 0 else { return nil }
                    return AIChord(
                        startTime: start,
                        endTime: end,
                        symbol: symbol,
                        romanNumeral: raw.romanNumeral,
                        confidence: confidence
                    )
                }
                .sorted { $0.startTime < $1.startTime }

            guard !chords.isEmpty || (rawChart.key?.isEmpty == false) else {
                throw Failure.noContent
            }
            return ChartSuggestion(
                key: rawChart.key ?? "",
                timeSignature: rawChart.timeSignature,
                bpm: rawChart.bpm,
                chords: chords,
                observation: rawChart.observation,
                confidence: rawChart.confidence ?? 0
            )
        }

        private struct RawChord: Decodable {
            var startTime: Double?
            var endTime: Double?
            var symbol: String?
            var romanNumeral: String?
            var confidence: Double?
        }

        private struct RawChart: Decodable {
            var key: String?
            var timeSignature: String?
            var bpm: Double?
            var chords: [RawChord]?
            var observation: String?
            var confidence: Double?
        }

        /// The model may wrap the schema in a ```json fence; claw the object out.
        private static func jsonObject(in raw: String) -> String? {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("```") {
                s = s
                    .replacingOccurrences(of: "```json", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let open = s.firstIndex(of: "{"),
                  let close = s.lastIndex(of: "}"),
                  open < close else { return nil }
            return String(s[open...close])
        }

        /// Compact, model-friendly rendering of the detected notes. isLeadLine
        /// flags the deterministic melody so the model knows what to sing.
        static func detectionPayload(notes: [NoteEvent], melody: [NoteEvent]) -> String {
            let sorted = notes.sorted { ($0.startTime, $0.pitch) < ($1.startTime, $1.pitch) }
            let rows = sorted.map { note -> String in
                let velocity = min(127, max(1, Int(note.amplitude * 127)))
                let isLead = Self.isLead(note, in: melody) ? 1 : 0
                return "[\(fmt(note.startTime)), \(fmt(note.endTime)), \"\(note.noteName)\", \(velocity), \(isLead)]"
            }
            return "[\n" + rows.joined(separator: ",\n") + "\n]"
        }

        /// Match melody membership by pitch and overlapping time, rather than
        /// marking every occurrence of a pitch heard anywhere in the lead.
        private static func isLead(_ note: NoteEvent, in melody: [NoteEvent]) -> Bool {
            melody.contains {
                $0.pitch == note.pitch && $0.startTime < note.endTime && $0.endTime > note.startTime
            }
        }

        private static func fmt(_ value: Double) -> String {
            String(format: "%.2f", value)
        }

        /// Offline stand-in: reuse the on-device template match so the wiring
        /// and header can be tested without a key.
        static func mockChart(notes: [NoteEvent]) -> ChartSuggestion {
            let chords = ChordAnalyzer.segments(notes).map {
                AIChord(
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    symbol: $0.label,
                    romanNumeral: nil,
                    confidence: 0.35
                )
            }
            return ChartSuggestion(
                key: "", timeSignature: "4/4", bpm: nil,
                chords: chords, observation: nil, confidence: 0.35
            )
        }
    }
}
