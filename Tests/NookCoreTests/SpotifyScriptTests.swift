import AppKit
import Foundation
import Testing
@testable import NookCore

/// Compiles (never runs) the AppleScripts sent to Spotify. Compiling reads Spotify's scripting
/// dictionary but sends no Apple Events, so it neither launches Spotify nor prompts for consent.
@Suite("Spotify AppleScript compilation", .enabled(if: NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyScripts.bundleID) != nil))
struct SpotifyScriptTests {
    func compiles(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return "could not create script" }
        var error: NSDictionary?
        return script.compileAndReturnError(&error) ? nil : (error?[NSAppleScript.errorMessage] as? String ?? "unknown error")
    }

    @Test func statusScriptCompiles() {
        #expect(compiles(SpotifyScripts.status) == nil)
    }

    @Test(arguments: [SpotifyScripts.Verb.playPause, .next, .previous, .resume, .seek(seconds: 61.5), .volume(55), .volume(500)])
    func commandScriptsCompile(_ verb: SpotifyScripts.Verb) {
        #expect(compiles(SpotifyScripts.command(verb)) == nil)
    }

    @Test func numbersAreFormattedLocaleIndependently() {
        #expect(SpotifyScripts.command(.seek(seconds: 61.5)).contains("set player position to 61.50"))
        #expect(SpotifyScripts.command(.volume(500)).contains("set sound volume to 100"))
    }
}
