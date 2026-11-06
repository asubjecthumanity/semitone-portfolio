//
//  SemitoneApp.swift
//  Semitone
//
//  Created by Freeman M on 7/9/26.
//

import SwiftUI

@main
struct SemitoneApp: App {
    /// Whether the intro has played in this process: it plays on a cold
    /// launch only, never on a return from the background. DEBUG test
    /// launches start with it played (see `IntroLaunch`).
    @State private var introPlayed = IntroLaunch.skipsIntro

    var body: some Scene {
        WindowGroup {
            IntroCoordinator(played: $introPlayed) {
                RootView()
            }
        }
    }
}
