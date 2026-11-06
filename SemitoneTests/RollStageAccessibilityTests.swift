import XCTest
import SwiftUI
import UIKit
@testable import Semitone

/// VoiceOver can't pull the keyboard round the corner, so the roll offers
/// the switch as a named action. XCUITest has no way to perform a custom
/// accessibility action, so this hosted test shows the real roll in a window
/// and goes through UIKit's accessibility elements the way VoiceOver does:
/// it finds the action on an element VoiceOver can focus and performs it.
final class RollStageAccessibilityTests: XCTestCase {
    private var savedLayout: Any?
    private var window: UIWindow?

    override func setUpWithError() throws {
        savedLayout = UserDefaults.standard.object(forKey: RollLayout.storageKey)
        try Self.enableAccessibility()
    }

    /// SwiftUI builds its accessibility elements only for an assistive
    /// technology or UI automation. A test host has neither, so turn on
    /// automation the way accessibility test tools do (the simulator's
    /// libAccessibility; test code only).
    private static func enableAccessibility() throws {
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(library, "_AXSSetAutomationEnabled") else {
            throw XCTSkip("Accessibility automation can't be turned on here.")
        }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: SetEnabled.self)(1)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        if let savedLayout { UserDefaults.standard.set(savedLayout, forKey: RollLayout.storageKey) }
        else { UserDefaults.standard.removeObject(forKey: RollLayout.storageKey) }
    }

    /// An eight-second take cued at 0:02.
    @MainActor
    private func cuedModel() async throws -> TranscriberViewModel {
        let model = TranscriberViewModel()
        model.aiProviderRaw = "off"
        model.useAICleanup = false
        let notes = (0..<16).map { i in
            NoteEvent(startTime: Double(i) * 0.5, endTime: Double(i) * 0.5 + 0.4, pitch: 60 + i % 5, amplitude: 0.7)
        }
        try await model.regressionInstallTake(notes: notes, duration: 8)
        model.cue(at: 2, settled: true)
        return model
    }

    /// Shows `view` full screen in a window of its own, above the test host's.
    @MainActor
    private func show(_ view: some View) throws -> UIView {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        self.window = window
        return host.view
    }

    @MainActor
    func testVoiceOverActionsSwitchBetweenTheRollLayouts() async throws {
        UserDefaults.standard.set(RollLayout.horizontal.rawValue, forKey: RollLayout.storageKey)
        let model = try await cuedModel()
        let roll = try show(RollStage(viewModel: model))

        // On the horizontal roll, an element VoiceOver lands on carries the action.
        let toFalling = try await action(named: "Switch to falling notes", in: roll)
        XCTAssertNil(Self.find("Switch to horizontal roll", in: roll), "Only the way to the other layout is offered.")
        XCTAssertTrue(toFalling.perform(), "The action reports that it ran.")
        try await waitUntil(timeout: 3) {
            UserDefaults.standard.string(forKey: RollLayout.storageKey) == RollLayout.falling.rawValue
        }
        XCTAssertEqual(model.playhead, 2, "The cue stays where it was.")

        // And back from the falling notes.
        let toHorizontal = try await action(named: "Switch to horizontal roll", in: roll)
        XCTAssertTrue(toHorizontal.perform())
        try await waitUntil(timeout: 3) {
            UserDefaults.standard.string(forKey: RollLayout.storageKey) == RollLayout.horizontal.rawValue
        }
        XCTAssertEqual(model.playhead, 2)
    }

    /// An iPhone on its side (compact height) always shows the falling notes,
    /// whatever layout is chosen for upright, so VoiceOver is offered no
    /// switch there, and the upright choice is left as it was.
    @MainActor
    func testOnItsSideTheFallingNotesShowWithNoSwitchAction() async throws {
        UserDefaults.standard.set(RollLayout.horizontal.rawValue, forKey: RollLayout.storageKey)
        let model = try await cuedModel()
        let roll = try show(RollStage(viewModel: model).environment(\.verticalSizeClass, .compact))

        let notes = try await element(labelled: "Falling notes", in: roll)
        XCTAssertTrue(notes.accessibilityValue?.hasSuffix("0:02") == true,
                      "The cue is on the hit line: \(notes.accessibilityValue ?? "nil")")
        XCTAssertNil(Self.first(in: roll) { $0.accessibilityLabel == "Piano keyboard" }, "No horizontal roll on its side.")
        XCTAssertNil(Self.find("Switch to falling notes", in: roll))
        XCTAssertNil(Self.find("Switch to horizontal roll", in: roll))
        XCTAssertEqual(UserDefaults.standard.string(forKey: RollLayout.storageKey), RollLayout.horizontal.rawValue)
    }

    /// While recording the falling notes can't be scrubbed, but VoiceOver
    /// still finds them, with the live edge's time, and can switch layouts,
    /// as a sighted user can by pulling the keyboard round.
    @MainActor
    func testWhileRecordingTheFallingNotesKeepTheirElementAndSwitchAction() async throws {
        UserDefaults.standard.set(RollLayout.falling.rawValue, forKey: RollLayout.storageKey)
        let model = try await cuedModel()
        model.regressionSetRecordingEdge(at: 8)
        let roll = try show(RollStage(viewModel: model))

        let notes = try await element(labelled: "Falling notes", in: roll)
        XCTAssertTrue(notes.accessibilityValue?.hasPrefix("Recording") == true, notes.accessibilityValue ?? "nil")
        let toHorizontal = try await action(named: "Switch to horizontal roll", in: roll)
        XCTAssertTrue(toHorizontal.perform())
        try await waitUntil(timeout: 3) {
            UserDefaults.standard.string(forKey: RollLayout.storageKey) == RollLayout.horizontal.rawValue
        }
    }

    /// VoiceOver's bar steps on the falling notes start from the moment on
    /// the hit line, which during playback is the clock's: the model's
    /// playhead is published only a few times a second, so from it, "next
    /// bar" just after a bar line went back to the bar just reached.
    @MainActor
    func testFallingNotesBarStepsDuringPlaybackStartFromTheHitLine() async throws {
        let clock = PlaybackClock()
        clock.start(at: 4.05)   // just past bar 3
        var seeks: [Double] = []
        let notes = (0..<16).map { i in
            NoteEvent(startTime: Double(i) * 0.5, endTime: Double(i) * 0.5 + 0.4, pitch: 60 + i % 5, amplitude: 0.7)
        }
        let roll = try show(FallingNotesView(notes: notes, chords: [], time: 3.9, duration: 8, isLive: false,
                                             clock: clock, beatTimes: stride(from: 0.0, through: 8, by: 0.5).map { $0 },
                                             downbeatTimes: [0, 2, 4, 6, 8], onSeek: { seeks.append($0) }))
        let scrub = try await element(labelled: "Falling notes", in: roll)
        // The follow puts the clock's time on the hit line on its first
        // display frame, scrolling the notes to it: 0:04.05 of an 8 s take
        // at 120 pt a second is 474 pt from the top.
        try await waitUntil(timeout: 3) {
            guard let scroll = Self.scrollView(in: roll) else { return false }
            return abs(scroll.contentOffset.y + scroll.adjustedContentInset.top - 474) < 1
        }
        scrub.accessibilityIncrement()
        XCTAssertEqual(seeks, [6], "Next bar from 0:04.05 is bar 4, not bar 3 again.")
        scrub.accessibilityDecrement()
        XCTAssertEqual(seeks, [6, 4])
    }

    /// The first scroll view under `view` (the falling notes' scrubber).
    @MainActor
    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for subview in view.subviews {
            if let scroll = scrollView(in: subview) { return scroll }
        }
        return nil
    }

    /// A custom action found on a focusable element, and that element's label.
    private struct FoundAction {
        let action: UIAccessibilityCustomAction
        let element: NSObject

        @MainActor
        func perform() -> Bool {
            if let handler = action.actionHandler { return handler(action) }
            guard let target = action.target as? NSObject else { return false }
            return target.perform(action.selector, with: action) != nil
        }
    }

    /// Waits for an element VoiceOver can focus (not a plain container)
    /// whose custom actions include `name`.
    @MainActor
    private func action(named name: String, in view: UIView, timeout: TimeInterval = 3) async throws -> FoundAction {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            if let found = Self.find(name, in: view) { return found }
            guard Date() < deadline else {
                XCTFail("No focusable element offers “\(name)”. Elements: \(Self.describe(view))")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Waits for an element VoiceOver can focus with this label.
    @MainActor
    private func element(labelled label: String, in view: UIView, timeout: TimeInterval = 3) async throws -> NSObject {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            if let found = Self.first(in: view, where: { $0.accessibilityLabel == label }) { return found }
            guard Date() < deadline else {
                XCTFail("No focusable element is labelled “\(label)”. Elements: \(Self.describe(view))")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The first element VoiceOver can focus that matches.
    @MainActor
    private static func first(in root: NSObject, where matches: (NSObject) -> Bool) -> NSObject? {
        var found: NSObject?
        visit(root) { element in
            guard found == nil, element.isAccessibilityElement, matches(element) else { return }
            found = element
        }
        return found
    }

    @MainActor
    private static func find(_ name: String, in root: NSObject) -> FoundAction? {
        var found: FoundAction?
        visit(root) { element in
            guard found == nil, element.isAccessibilityElement,
                  let action = element.accessibilityCustomActions?.first(where: { $0.name == name }) else { return }
            found = FoundAction(action: action, element: element)
        }
        return found
    }

    @MainActor
    private static func describe(_ root: NSObject) -> String {
        var lines: [String] = []
        visit(root) { element in
            guard element.isAccessibilityElement else { return }
            let actions = element.accessibilityCustomActions?.map(\.name) ?? []
            lines.append("\(element.accessibilityLabel ?? "?") \(actions)")
        }
        return lines.joined(separator: "; ")
    }

    /// Every element under `root`, as UIKit hands them to VoiceOver.
    @MainActor
    private static func visit(_ root: NSObject, depth: Int = 0, _ body: (NSObject) -> Void) {
        guard depth < 40 else { return }
        body(root)
        if let elements = root.accessibilityElements as? [NSObject], !elements.isEmpty {
            for element in elements { visit(element, depth: depth + 1, body) }
            return
        }
        let count = root.accessibilityElementCount()
        if count > 0, count != NSNotFound {
            for i in 0..<count {
                if let element = root.accessibilityElement(at: i) as? NSObject { visit(element, depth: depth + 1, body) }
            }
            return
        }
        if let view = root as? UIView {
            for subview in view.subviews { visit(subview, depth: depth + 1, body) }
        }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else {
                XCTFail("Timed out after \(timeout) seconds.")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
