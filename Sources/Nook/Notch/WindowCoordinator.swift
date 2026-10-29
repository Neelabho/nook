import AppKit
import NookCore
import SwiftUI

/// Owns the notch panel and drives `NotchStateMachine`: translates pointer, drag, keyboard and
/// system events into state-machine events, and performs the effects it returns (timers,
/// expand/collapse animations, window frames).
///
/// No polling: pointer enter/exit comes from a tracking area on the panel, timers exist only while a
/// transition is pending, and the outside-click monitor is installed only while the panel is open.
@MainActor
final class WindowCoordinator: NSObject, InteractionLocking {
    let model = NotchModel()
    let quickLook = QuickLookCoordinator()

    private let settings: SettingsService
    private let shelf: ShelfController
    private let diagnostics: DiagnosticsService
    private var panel: NotchPanel?
    private var machine = NotchStateMachine()
    private var layout: NotchLayout?
    private var hoverAvailable = true
    private var activationTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var interactionDepth = 0
    /// Opened by keyboard/menu: stay open until the pointer has visited and left, or Esc / outside click.
    private var explicitHold = false
    private var pointerVisited = false
    private var outsideClickMonitor: Any?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var rootContent: () -> AnyView
    /// Panel finished opening / finished closing (drives the now-playing peek).
    var onPanelOpened: () -> Void = {}
    var onPanelClosed: () -> Void = {}

    init(settings: SettingsService, shelf: ShelfController, diagnostics: DiagnosticsService, content: @escaping () -> AnyView) {
        self.settings = settings
        self.shelf = shelf
        self.diagnostics = diagnostics
        self.rootContent = content
        super.init()
        model.selectedTab = settings.settings.lastTab
        quickLook.interaction = self
    }

    // MARK: Setup

    func start() {
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 185, height: 32))
        let hosting = NSHostingView(rootView: rootContent())
        hosting.sizingOptions = []
        let root = NookRootView(hosting: hosting)
        root.callbacks = NookRootView.Callbacks(
            pointerEntered: { [weak self] in self?.pointerEntered() },
            pointerExited: { [weak self] in self?.pointerExited() },
            dragEntered: { [weak self] in self?.dragEntered() },
            dragExited: { [weak self] in self?.send(.dragExited) },
            performDrop: { [weak self] pasteboard in
                guard let self else { return false }
                return DropReader.importDrop(pasteboard, into: self.shelf)
            },
            dropFinished: { [weak self] in self?.send(.dropFinished) }
        )
        panel.contentView = root
        panel.quickLook = quickLook
        panel.onCancel = { [weak self] in self?.close() }
        self.panel = panel
        applyCollectionBehavior()
        observeSystem()
        updateDisplay()
        settings.onChange { [weak self] old, new in self?.settingsChanged(old: old, new: new) }
    }

    func stop() {
        activationTask?.cancel()
        collapseTask?.cancel()
        removeOutsideClickMonitor()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        panel?.orderOut(nil)
    }

    var panelWindow: NSWindow? { panel }
    var stateDescription: String { machine.state.rawValue }
    var layoutDescription: String {
        guard let layout else { return "No display" }
        func r(_ rect: CGRect) -> String { "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))" }
        return (layout.notchRect.map { "Notch \(r($0)); " } ?? "No notch (fallback strip); ") + "activation \(r(layout.activationRect)); panel \(r(layout.expandedRect))"
    }

    private func applyCollectionBehavior() {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if settings.settings.showInFullScreenSpaces { behavior.insert(.fullScreenAuxiliary) }
        panel?.collectionBehavior = behavior
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        observers.append((center, token))
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.updateDisplay() }
        observe(ws, NSWorkspace.willSleepNotification) { [weak self] in self?.send(.suspend) }
        observe(ws, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.send(.suspend) }
        observe(ws, NSWorkspace.didWakeNotification) { [weak self] in self?.resumeAfterWake() }
        observe(ws, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.resumeAfterWake() }
        observe(ws, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            guard let self, self.machine.state.isOpen, !self.model.pinned, self.interactionDepth == 0 else { return }
            self.close()
        }
        observe(.default, NSMenu.didBeginTrackingNotification) { [weak self] in
            guard let self, self.machine.state.isOpen else { return }
            self.menuTracking = true
            self.beginInteraction()
        }
        observe(.default, NSMenu.didEndTrackingNotification) { [weak self] in
            guard let self, self.menuTracking else { return }
            self.menuTracking = false
            self.endInteraction()
        }
    }

    private var menuTracking = false

    private func resumeAfterWake() {
        updateDisplay()
        send(.resume)
    }

    private func settingsChanged(old: NookSettings, new: NookSettings) {
        if old.calibration != new.calibration { updateDisplay() }
        if old.showInFullScreenSpaces != new.showInFullScreenSpaces { applyCollectionBehavior() }
        if old.hoverEnabled != new.hoverEnabled && !new.hoverEnabled && machine.state == .hovering {
            send(.pointerExited)
        }
    }

    // MARK: Display

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }

    /// Nook lives on the built-in display only. If it is unavailable (lid closed), hover is disabled
    /// and the keyboard shortcut / menu open the panel on the main display instead.
    func updateDisplay() {
        guard let panel else { return }
        let builtIn = NSScreen.screens.first(where: Self.isBuiltIn)
        guard let screen = builtIn ?? NSScreen.main else {
            panel.orderOut(nil)
            layout = nil
            return
        }
        hoverAvailable = builtIn != nil
        let descriptor = DisplayDescriptor(
            frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea,
            isBuiltIn: builtIn != nil, scale: screen.backingScaleFactor
        )
        let newLayout = NotchGeometry.layout(for: descriptor, calibration: settings.settings.calibration, expandedSize: model.openSize)
        layout = newLayout
        model.closedSize = newLayout.closedShapeSize
        model.hasNotch = newLayout.hasNotch
        model.notchWidth = newLayout.notchRect?.width ?? 0
        model.headerHeight = newLayout.notchRect?.height ?? newLayout.activationRect.height
        model.peekSize = newLayout.peekRect.size
        model.peekWing = newLayout.peekWing
        let frame = machine.state.isOpen || machine.state == .collapsing ? newLayout.expandedRect : closedFrame(newLayout)
        applyFrame(frame)
        if hoverAvailable || machine.state.isOpen {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
        diagnostics.displaySummary = "\(screen.localizedName) @\(Int(screen.backingScaleFactor))x, \(Int(screen.frame.width))×\(Int(screen.frame.height)) pt. \(layoutDescription)"
        diagnostics.record("display", diagnostics.displaySummary)
    }

    func setLarge(_ large: Bool) {
        guard model.isLarge != large, let panel else { return }
        let reduce = settings.effectiveReduceMotion
        if large {
            model.isLarge = true
            updateDisplay()
            panel.makeKey()
        } else {
            withAnimation(Nook.spring(reduceMotion: reduce), completionCriteria: .logicallyComplete) {
                model.isLarge = false
            } completion: { [weak self] in
                self?.updateDisplay()
            }
        }
    }

    // MARK: Now-playing peek

    /// The closed frame: the activation strip, widened to the peek band while the peek is shown.
    private func closedFrame(_ layout: NotchLayout, peek: Bool? = nil) -> CGRect {
        (peek ?? model.peekVisible) ? layout.peekRect.union(layout.activationRect) : layout.activationRect
    }

    private var isClosed: Bool { !machine.state.isOpen && machine.state != .collapsing }

    func setPeekVisible(_ visible: Bool) {
        guard model.peekVisible != visible else { return }
        let reduce = settings.effectiveReduceMotion
        let animation: Animation = reduce ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.86)
        if visible {
            // Grow the window first, then let the shape widen inside it.
            if isClosed, let layout { applyFrame(closedFrame(layout, peek: true)) }
            withAnimation(animation) { model.peekVisible = true }
        } else {
            withAnimation(animation, completionCriteria: .logicallyComplete) {
                model.peekVisible = false
            } completion: { [weak self] in
                // Shrink on the next run-loop turn (see collapse()).
                DispatchQueue.main.async {
                    guard let self, self.isClosed, !self.model.peekVisible, let layout = self.layout else { return }
                    self.applyFrame(self.closedFrame(layout))
                }
            }
        }
        diagnostics.record("notch", visible ? "Now-playing peek shown" : "Now-playing peek hidden")
    }

    // MARK: Input → events

    private func pointerInsidePanel() -> Bool {
        guard let panel else { return false }
        return panel.frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
    }

    private func pointerEntered() {
        pointerVisited = true
        send(machine.state.isOpen || machine.state == .collapsing ? .pointerEnteredPanel : .pointerEnteredActivation)
    }

    private func pointerExited() {
        if explicitHold && pointerVisited { explicitHold = false }
        send(.pointerExited)
    }

    private func dragEntered() {
        model.selectedTab = .shelf
        send(.dragEntered)
    }

    func toggle() {
        if machine.state.isOpen {
            close()
        } else {
            open(tab: nil)
        }
    }

    /// Explicit open from the keyboard shortcut or menu bar. Works with hover disabled.
    /// - Parameter takeKeyboardFocus: false for diagnostics, so the panel never captures typing
    ///   meant for the frontmost app.
    func open(tab: NookTab?, takeKeyboardFocus: Bool = true) {
        if let tab { model.selectedTab = tab }
        if machine.state == .suspended { send(.resume) }
        explicitHold = true
        pointerVisited = pointerInsidePanel()
        if machine.state.isOpen {
            send(.openRequested)
        } else {
            send(.openRequested)
        }
        if takeKeyboardFocus { panel?.makeKey() }
    }

    func close() {
        explicitHold = false
        send(.closeRequested)
    }

    func togglePinned() {
        model.pinned.toggle()
        if !model.pinned && !pointerInsidePanel() { send(.pointerExited) }
    }

    // MARK: Interaction lock

    func beginInteraction() { interactionDepth += 1 }

    func endInteraction() {
        interactionDepth = max(0, interactionDepth - 1)
        if interactionDepth == 0, machine.state == .expanded, !pointerInsidePanel() {
            send(.pointerExited)
        }
    }

    private var isTyping: Bool {
        guard let panel, panel.isKeyWindow else { return false }
        return panel.firstResponder is NSTextView
    }

    // MARK: State machine

    func send(_ event: NotchEvent) {
        machine.context = NotchContext(
            hoverEnabled: settings.settings.hoverEnabled && hoverAvailable,
            pinned: model.pinned,
            interactionLock: interactionDepth > 0 || explicitHold || isTyping,
            pointerInside: pointerInsidePanel()
        )
        let before = machine.state
        let effects = machine.handle(event)
        model.state = machine.state
        if before != machine.state {
            diagnostics.record("notch", "\(before.rawValue) → \(machine.state.rawValue) on \(event)")
        }
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: NotchEffect) {
        switch effect {
        case .startActivationTimer:
            activationTask?.cancel()
            let delay = settings.settings.activationDelay
            activationTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                // Exit events can be dropped on very fast flicks: confirm the pointer is still on
                // the notch (one read, not polling) before opening.
                self.send(self.pointerInsidePanel() ? .activationDelayElapsed : .pointerExited)
            }
        case .cancelActivationTimer:
            activationTask?.cancel()
            activationTask = nil
        case .startCollapseTimer:
            collapseTask?.cancel()
            let delay = settings.settings.collapseDelay
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.send(.collapseDelayElapsed)
            }
        case .cancelCollapseTimer:
            collapseTask?.cancel()
            collapseTask = nil
        case .expand(let focusShelf):
            expand(focusShelf: focusShelf)
        case .collapse:
            collapse()
        case .showDropTarget(let active):
            withAnimation(.easeOut(duration: 0.15)) { model.dropTargetActive = active }
        }
    }

    private func expand(focusShelf: Bool) {
        guard let panel, let layout else { return }
        if focusShelf { model.selectedTab = .shelf }
        applyFrame(layout.expandedRect)
        panel.orderFrontRegardless()
        installOutsideClickMonitor()
        onPanelOpened()
        withAnimation(Nook.spring(reduceMotion: settings.effectiveReduceMotion), completionCriteria: .logicallyComplete) {
            model.isOpen = true
        } completion: { [weak self] in
            self?.send(.expandAnimationFinished)
        }
    }

    private func collapse() {
        removeOutsideClickMonitor()
        settings.update { $0.lastTab = model.selectedTab }
        withAnimation(Nook.spring(reduceMotion: settings.effectiveReduceMotion), completionCriteria: .logicallyComplete) {
            model.isOpen = false
            model.dropTargetActive = false
        } completion: { [weak self] in
            // Resizing the window from inside SwiftUI's animation completion produced a corrupted
            // frame on macOS 26.5 (observed: requested 185×32 at y=950, got 475×268 at y=982, which
            // left the hover strip off-screen). Resize on the next run-loop turn instead.
            DispatchQueue.main.async { self?.finishCollapse() }
        }
    }

    private func finishCollapse() {
        guard machine.state == .collapsing, let panel, let layout else { return }
        // Hand keyboard focus back to the frontmost app: ordering out a key non-activating
        // panel returns key status to the active app's window.
        if panel.isKeyWindow { panel.orderOut(nil) }
        applyFrame(closedFrame(layout))
        if hoverAvailable { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        send(.collapseAnimationFinished)
        onPanelClosed()
    }

    /// Sets the panel frame and verifies it, because a wrong frame silently breaks hover.
    private func applyFrame(_ frame: CGRect) {
        guard let panel else { return }
        panel.setFrame(frame, display: true)
        if panel.frame != frame {
            diagnostics.record("notch", "Frame mismatch: wanted \(frame), got \(panel.frame); correcting")
            panel.setContentSize(frame.size)
            panel.setFrameOrigin(frame.origin)
        }
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        // Global mouse-down monitoring needs no special permission; it is installed only while open.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.model.pinned, self.interactionDepth == 0, self.machine.state.isOpen,
                      self.machine.state != .draggingFromShelf, self.machine.state != .dragTargetActive else { return }
                self.close()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    // MARK: Diagnostics snapshot

    /// Live facts for the diagnostics probe (`kill -USR1 <pid>`).
    func debugState() -> [String: Any] {
        func rect(_ r: CGRect?) -> [Int]? { r.map { [Int($0.minX), Int($0.minY), Int($0.width), Int($0.height)] } }
        return [
            "state": machine.state.rawValue,
            "isOpen": model.isOpen,
            "selectedTab": model.selectedTab.rawValue,
            "isLarge": model.isLarge,
            "pinned": model.pinned,
            "dropTargetActive": model.dropTargetActive,
            "panelFrame": rect(panel?.frame) as Any,
            "panelVisible": panel?.isVisible ?? false,
            "contentViewFrame": rect(panel?.contentView?.frame) as Any,
            "hostingFrame": rect(panel?.contentView?.subviews.first?.frame) as Any,
            "panelIsKey": panel?.isKeyWindow ?? false,
            "appIsActive": NSApp.isActive,
            "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?",
            "notchRect": rect(layout?.notchRect) as Any,
            "activationRect": rect(layout?.activationRect) as Any,
            "expandedRect": rect(layout?.expandedRect) as Any,
            "hoverAvailable": hoverAvailable,
            "interactionDepth": interactionDepth,
            "explicitHold": explicitHold,
            "outsideClickMonitor": outsideClickMonitor != nil,
            "pointer": [Int(NSEvent.mouseLocation.x), Int(NSEvent.mouseLocation.y)],
        ]
    }

    /// Renders the panel's own view hierarchy (no screen capture; behind-window blur is not included).
    func renderPanelPNG() -> Data? {
        guard let view = panel?.contentView, view.bounds.width > 0 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Drag-out notifications from the Shelf

    func shelfDragBegan() { send(.shelfDragBegan) }
    func shelfDragEnded() { send(.shelfDragEnded) }
}
