import XCTest
@testable import Semitone

/// The built-in "Semitone" AI provider: what a request to the semitone-ai
/// service carries (the job and the notes, never a prompt or a key), and
/// which client the app picks when nothing is chosen.
final class SemitoneAIServiceTests: XCTestCase {
    /// Answers every request to the service with a canned Groq-style reply
    /// and keeps what was sent.
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var requests: [(URLRequest, Data)] = []
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var reply = #"{"choices":[{"message":{"content":"{\"key\":\"C major\",\"chords\":[{\"symbol\":\"C\",\"start_time\":0,\"end_time\":2,\"confidence\":0.9}],\"confidence\":0.8}"}}]}"#

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == AIChartInterpreter.Client.semitoneServiceURL.host
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    body.append(buffer, count: n)
                }
            }
            Self.requests.append((request, body))
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.reply.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    override func setUp() {
        Stub.requests = []
        Stub.status = 200
        URLProtocol.registerClass(Stub.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(Stub.self)
        UserDefaults.standard.removeObject(forKey: "aiProvider")
    }

    private let notes = [NoteEvent(startTime: 0, endTime: 1, pitch: 60, amplitude: 0.6),
                         NoteEvent(startTime: 0, endTime: 1, pitch: 64, amplitude: 0.6),
                         NoteEvent(startTime: 0, endTime: 1, pitch: 67, amplitude: 0.6)]

    func testAChartRequestCarriesTheJobAndTheNotesOnly() async throws {
        let chart = try await AIChartInterpreter.Client.semitone().chart(notes: notes, melody: [])
        XCTAssertEqual(chart.key, "C major")
        let (request, body) = try XCTUnwrap(Stub.requests.first)
        XCTAssertEqual(request.url, AIChartInterpreter.Client.semitoneServiceURL)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "No key leaves the phone.")
        XCTAssertNotNil(UUID(uuidString: request.value(forHTTPHeaderField: "X-Semitone-Device") ?? ""))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["task"] as? String, "chart")
        XCTAssertTrue((json["input"] as? String)?.contains("C4") == true)
        XCTAssertNil(json["system"], "The service holds the prompt; the phone never sends one.")
        XCTAssertNil(json["messages"])
    }

    func testACleanupRequestSaysCleanup() async throws {
        Stub.reply = #"{"choices":[{"message":{"content":"{\"remove\":[],\"shift\":[],\"merge\":[],\"confidence\":0.5}"}}]}"#
        _ = try? await AIChartInterpreter.Client.semitone().cleanup(notes: notes, melody: [])
        let body = try XCTUnwrap(Stub.requests.first?.1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["task"] as? String, "cleanup")
    }

    func testTheInstallIDIsKept() {
        XCTAssertEqual(AIChartInterpreter.Client.installID, AIChartInterpreter.Client.installID)
    }

    func testChoosingSemitoneNeedsNoKey() {
        UserDefaults.standard.set("semitone", forKey: "aiProvider")
        XCTAssertEqual(AIChartInterpreter.Client.configured().provider.kind, .semitone)
        UserDefaults.standard.set("off", forKey: "aiProvider")
        XCTAssertEqual(AIChartInterpreter.Client.configured().provider.kind, .mock)
    }

    func testWithoutASchemeKeyTheDefaultIsTheService() throws {
        try XCTSkipIf(!(ProcessInfo.processInfo.environment["SEMITONE_AI_KEY"] ?? "").isEmpty,
                      "This test run has a scheme key, which comes first.")
        XCTAssertEqual(AIChartInterpreter.Client.makeDefault().provider.kind, .semitone)
    }
}
