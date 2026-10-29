import AppKit

// Nook is an accessory app (LSUIElement): no Dock icon, no main menu; it lives in the notch
// and the menu bar.
// Diagnostics signals (probe / toggle) must never terminate Nook: ignore them from the first
// instruction; handlers are installed later. Previously a probe sent during launch killed the app.
signal(SIGUSR1, SIG_IGN)
signal(SIGUSR2, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Self-test runs are background-only so a normal Nook launch never mistakes them for another
    // running copy (the single-instance check skips `.prohibited` processes).
    app.setActivationPolicy(SelfTest.requested ? .prohibited : .accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
