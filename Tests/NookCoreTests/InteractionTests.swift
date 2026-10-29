import CoreGraphics
import Foundation
import Testing
@testable import NookCore

@Suite("Notch state machine")
struct NotchStateMachineTests {
    @Test func hoverExpandsAfterDelayAndCollapsesAfterLeaving() {
        var m = NotchStateMachine()
        #expect(m.handle(.pointerEnteredActivation) == [.startActivationTimer])
        #expect(m.state == .hovering)
        #expect(m.handle(.activationDelayElapsed) == [.expand(focusShelf: false)])
        #expect(m.state == .expanding)
        m.context.pointerInside = true
        #expect(m.handle(.expandAnimationFinished) == [])
        #expect(m.state == .expanded)
        m.context.pointerInside = false
        #expect(m.handle(.pointerExited) == [.startCollapseTimer])
        #expect(m.handle(.collapseDelayElapsed) == [.collapse])
        #expect(m.state == .collapsing)
        m.handle(.collapseAnimationFinished)
        #expect(m.state == .idle)
    }

    @Test func briefPassOverNotchDoesNotExpand() {
        var m = NotchStateMachine()
        m.handle(.pointerEnteredActivation)
        #expect(m.handle(.pointerExited) == [.cancelActivationTimer])
        #expect(m.state == .idle)
        // A late timer callback after leaving must not expand.
        #expect(m.handle(.activationDelayElapsed) == [])
        #expect(m.state == .idle)
    }

    @Test func movingBetweenActivationAreaAndPanelDoesNotFlicker() {
        var m = NotchStateMachine(state: .expanded)
        #expect(m.handle(.pointerExited) == [.startCollapseTimer])
        #expect(m.handle(.pointerEnteredPanel) == [.cancelCollapseTimer])
        #expect(m.state == .expanded)
        // Timer fires anyway (race) while pointer is inside: no collapse.
        m.context.pointerInside = true
        #expect(m.handle(.collapseDelayElapsed) == [])
        #expect(m.state == .expanded)
    }

    @Test func reenteringWhileCollapsingReopens() {
        var m = NotchStateMachine(state: .collapsing)
        #expect(m.handle(.pointerEnteredPanel) == [.expand(focusShelf: false)])
        #expect(m.state == .expanding)
    }

    @Test func pinnedOrInteractingNeverAutoCollapses() {
        var m = NotchStateMachine(state: .expanded, context: NotchContext(pinned: true))
        #expect(m.handle(.pointerExited) == [])
        #expect(m.handle(.collapseDelayElapsed) == [])
        #expect(m.state == .expanded)

        var typing = NotchStateMachine(state: .expanded, context: NotchContext(interactionLock: true))
        #expect(typing.handle(.pointerExited) == [])
        #expect(typing.handle(.collapseDelayElapsed) == [])
        #expect(typing.state == .expanded)
    }

    @Test func fileDragOpensShelfDropTargetFromIdle() {
        var m = NotchStateMachine()
        let effects = m.handle(.dragEntered)
        #expect(m.state == .dragTargetActive)
        #expect(effects.contains(.expand(focusShelf: true)))
        #expect(effects.contains(.showDropTarget(true)))
        // Pointer movement during a drag is ignored.
        #expect(m.handle(.pointerExited) == [])
        #expect(m.handle(.collapseDelayElapsed) == [])
        #expect(m.handle(.dropFinished) == [.showDropTarget(false)])
        #expect(m.state == .expanded)
    }

    @Test func dragThatLeavesWithoutDroppingCollapsesLater() {
        var m = NotchStateMachine()
        m.handle(.dragEntered)
        #expect(m.handle(.dragExited) == [.showDropTarget(false), .startCollapseTimer])
        #expect(m.state == .expanded)
    }

    @Test func draggingOutOfShelfHoldsPanelOpen() {
        var m = NotchStateMachine(state: .expanded)
        #expect(m.handle(.shelfDragBegan) == [.cancelCollapseTimer])
        #expect(m.state == .draggingFromShelf)
        #expect(m.handle(.pointerExited) == [])
        #expect(m.handle(.collapseDelayElapsed) == [])
        #expect(m.handle(.shelfDragEnded) == [.startCollapseTimer])
        #expect(m.state == .expanded)
    }

    @Test func keyboardToggleWorksWithHoverDisabled() {
        var m = NotchStateMachine(context: NotchContext(hoverEnabled: false))
        #expect(m.handle(.pointerEnteredActivation) == [])
        #expect(m.state == .idle)
        #expect(m.handle(.toggleRequested) == [.cancelActivationTimer, .expand(focusShelf: false)])
        m.handle(.expandAnimationFinished)
        #expect(m.handle(.toggleRequested) == [.cancelCollapseTimer, .collapse])
        #expect(m.state == .collapsing)
    }

    @Test func suspensionIgnoresEverythingUntilResumed() {
        var m = NotchStateMachine(state: .expanded)
        #expect(m.handle(.suspend).contains(.collapse))
        #expect(m.state == .suspended)
        #expect(m.handle(.pointerEnteredActivation) == [])
        #expect(m.handle(.dragEntered) == [])
        #expect(m.handle(.toggleRequested) == [])
        m.handle(.resume)
        #expect(m.state == .idle)
    }

    @Test func escapeClosesEvenWhenPinned() {
        var m = NotchStateMachine(state: .expanded, context: NotchContext(pinned: true))
        #expect(m.handle(.closeRequested) == [.cancelCollapseTimer, .collapse])
    }
}

@Suite("Notch geometry")
struct NotchGeometryTests {
    // The measured values of this MacBook Pro's built-in display (points).
    let builtIn = DisplayDescriptor(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663, height: 32),
        auxiliaryTopRight: CGRect(x: 848, y: 950, width: 664, height: 32),
        isBuiltIn: true, scale: 2
    )

    @Test func derivesNotchFromAuxiliaryAreas() throws {
        let notch = try #require(NotchGeometry.notchRect(for: builtIn))
        #expect(notch == CGRect(x: 663, y: 950, width: 185, height: 32))
    }

    @Test func nowPlayingPeekWidensTheNotchBandEvenly() {
        let layout = NotchGeometry.layout(for: builtIn, calibration: ActivationCalibration(), expandedSize: CGSize(width: 640, height: 300))
        #expect(layout.peekRect == CGRect(x: 621, y: 950, width: 269, height: 32))
        #expect(layout.peekRect.midX == 755.5, "centred on the notch")
        #expect(layout.peekWing == 42)
        // A calibrated (thin) activation strip doesn't shrink the peek: it covers the whole notch band.
        let thin = NotchGeometry.layout(for: builtIn, calibration: ActivationCalibration(height: 10), expandedSize: CGSize(width: 640, height: 300))
        #expect(thin.peekRect.height == 32 && thin.peekRect.maxY == 982)
    }

    @Test func activationMatchesNotchByDefault() {
        let layout = NotchGeometry.layout(for: builtIn, calibration: ActivationCalibration(), expandedSize: CGSize(width: 640, height: 300))
        #expect(layout.activationRect == CGRect(x: 663, y: 950, width: 185, height: 32))
        #expect(layout.expandedRect.maxY == 982)
        #expect(layout.expandedRect.midX == 755.5, "exactly centred on the notch")
        #expect(layout.expandedRect.width == 641, "odd width keeps whole-point origin")
        #expect(layout.expandedRect.minX == layout.expandedRect.minX.rounded())
    }

    @Test func calibrationWidensAndShifts() {
        let cal = ActivationCalibration(extraWidth: 40, height: 10, horizontalOffset: 20)
        let layout = NotchGeometry.layout(for: builtIn, calibration: cal, expandedSize: CGSize(width: 640, height: 300))
        #expect(layout.activationRect.width == 225)
        #expect(layout.activationRect.height == 10)
        #expect(layout.activationRect.maxY == 982)
        #expect(abs(layout.activationRect.midX - 775.5) < 0.6)
    }

    @Test func displayWithoutNotchUsesTopCenterFallback() {
        let external = DisplayDescriptor(
            frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415),
            safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil, isBuiltIn: false, scale: 2
        )
        let layout = NotchGeometry.layout(for: external, calibration: ActivationCalibration(), expandedSize: CGSize(width: 640, height: 300))
        #expect(layout.hasNotch == false)
        #expect(layout.activationRect.width == NotchGeometry.fallbackActivationWidth)
        #expect(layout.activationRect.height == 25)
        #expect(abs(layout.activationRect.midX - CGFloat(2792)) < 0.01)
    }

    @Test func panelStaysOnScreenWhenOffsetIsExtreme() {
        let cal = ActivationCalibration(extraWidth: 0, height: 0, horizontalOffset: 10_000)
        let layout = NotchGeometry.layout(for: builtIn, calibration: cal, expandedSize: CGSize(width: 640, height: 300))
        #expect(layout.expandedRect.maxX <= builtIn.frame.maxX)
        #expect(layout.activationRect.maxX <= builtIn.frame.maxX)
    }
}

@Suite("Settings validation")
struct SettingsTests {
    @Test func defaultsAreValid() {
        #expect(NookSettings().validated() == NookSettings())
    }

    @Test func outOfRangeValuesAreClamped() {
        var s = NookSettings()
        s.activationDelay = 99
        s.collapseDelay = -3
        s.contextMessageLimit = 0
        s.maxResponseTokens = 10_000_000
        s.progressRefreshSeconds = .nan
        s.calibration = ActivationCalibration(extraWidth: 9_999, height: -5, horizontalOffset: 0)
        s.productName = "   "
        let v = s.validated()
        #expect(v.activationDelay == 1.5)
        #expect(v.collapseDelay == 0.15)
        #expect(v.contextMessageLimit == 2)
        #expect(v.maxResponseTokens == 16_384)
        #expect(v.progressRefreshSeconds == 5)
        #expect(v.calibration.extraWidth == 240)
        #expect(v.calibration.height == 0)
        #expect(v.productName == "Nook")
    }

    @Test func remoteEndpointIsRejectedOnLoad() {
        var s = NookSettings()
        s.ollamaEndpoint = "http://192.168.1.20:11434"
        #expect(s.validated().ollamaEndpoint == "http://127.0.0.1:11434")
    }

    @Test func invalidHotKeyFallsBackToDefault() {
        var s = NookSettings()
        s.hotKey = HotKeySpec(keyCode: 0, modifiers: HotKeySpec.shift)   // ⇧A would hijack typing
        #expect(s.validated().hotKey == .default)
    }

    @Test func corruptOrPartialDataIsTolerated() throws {
        #expect(NookSettings.decode(Data("garbage".utf8)) == NookSettings())
        #expect(NookSettings.decode(nil) == NookSettings())
        let partial = Data(#"{"hoverEnabled": false, "collapseDelay": "oops", "futureKey": 1}"#.utf8)
        let decoded = NookSettings.decode(partial)
        #expect(decoded.hoverEnabled == false)
        #expect(decoded.collapseDelay == NookSettings().collapseDelay)
    }

    @Test func roundTrips() throws {
        var s = NookSettings()
        s.preferredModel = "llama3.2:3b"
        s.afterDragOut = .keep
        s.cleanup = CleanupPolicy(enabled: true, maxAgeDays: 14, maxTotalBytes: 5_000_000_000)
        #expect(NookSettings.decode(s.encoded()) == s)
    }
}
