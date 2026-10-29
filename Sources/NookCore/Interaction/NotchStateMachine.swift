import Foundation

/// Explicit interaction states for the notch surface.
public enum NotchState: String, Equatable, Sendable {
    case idle
    /// Pointer is in the activation region; waiting for the activation delay.
    case hovering
    case expanding
    case expanded
    /// A file/text drag is over Nook: shown as a Shelf drop target.
    case dragTargetActive
    /// The user is dragging an item out of the Shelf.
    case draggingFromShelf
    case collapsing
    /// No usable display or explicitly paused; hover is ignored.
    case suspended

    public var isOpen: Bool {
        switch self {
        case .expanding, .expanded, .dragTargetActive, .draggingFromShelf: return true
        case .idle, .hovering, .collapsing, .suspended: return false
        }
    }
}

public enum NotchEvent: Equatable, Sendable {
    case pointerEnteredActivation
    case pointerExited
    case pointerEnteredPanel
    case activationDelayElapsed
    case expandAnimationFinished
    case collapseDelayElapsed
    case collapseAnimationFinished
    case dragEntered
    case dragExited
    case dropFinished
    case shelfDragBegan
    case shelfDragEnded
    case toggleRequested            // keyboard shortcut / menu
    case openRequested               // explicit open (e.g. menu "Show Shelf")
    case closeRequested              // Escape, close button
    case suspend
    case resume
}

public enum NotchEffect: Equatable, Sendable {
    case startActivationTimer
    case cancelActivationTimer
    case startCollapseTimer
    case cancelCollapseTimer
    case expand(focusShelf: Bool)
    case collapse
    case showDropTarget(Bool)
}

/// Inputs that gate transitions but are owned elsewhere.
public struct NotchContext: Equatable, Sendable {
    public var hoverEnabled: Bool
    /// Pinned open by the user.
    public var pinned: Bool
    /// The user is actively interacting (typing, a menu/sheet/Quick Look is open, generation in progress
    /// while the field has focus). Suppresses hover-out collapse.
    public var interactionLock: Bool
    /// Whether the pointer is currently over the panel (checked when timers fire).
    public var pointerInside: Bool

    public init(hoverEnabled: Bool = true, pinned: Bool = false, interactionLock: Bool = false, pointerInside: Bool = false) {
        self.hoverEnabled = hoverEnabled
        self.pinned = pinned
        self.interactionLock = interactionLock
        self.pointerInside = pointerInside
    }
}

/// Pure reducer. All timing and animation happens in the app layer in response to effects,
/// which keeps this fully unit-testable and free of flicker-inducing re-entrancy.
public struct NotchStateMachine: Sendable {
    public private(set) var state: NotchState
    public var context: NotchContext

    public init(state: NotchState = .idle, context: NotchContext = NotchContext()) {
        self.state = state
        self.context = context
    }

    @discardableResult
    public mutating func handle(_ event: NotchEvent) -> [NotchEffect] {
        switch (state, event) {

        // Suspension overrides everything.
        case (.suspended, .resume):
            state = .idle
            return []
        case (.suspended, _):
            return []
        case (_, .suspend):
            let wasOpen = state.isOpen || state == .collapsing
            state = .suspended
            return [.cancelActivationTimer, .cancelCollapseTimer] + (wasOpen ? [.collapse] : [])

        // Hover in.
        case (.idle, .pointerEnteredActivation):
            guard context.hoverEnabled else { return [] }
            state = .hovering
            return [.startActivationTimer]
        case (.hovering, .pointerExited):
            state = .idle
            return [.cancelActivationTimer]
        case (.hovering, .activationDelayElapsed):
            state = .expanding
            return [.expand(focusShelf: false)]

        // Expansion.
        case (.expanding, .expandAnimationFinished):
            state = .expanded
            return context.pointerInside || context.pinned || context.interactionLock ? [] : [.startCollapseTimer]
        case (.expanded, .pointerEnteredPanel), (.expanded, .pointerEnteredActivation),
             (.expanding, .pointerEnteredPanel), (.expanding, .pointerEnteredActivation):
            return [.cancelCollapseTimer]
        case (.expanded, .pointerExited), (.expanding, .pointerExited):
            guard !context.pinned, !context.interactionLock else { return [] }
            return [.startCollapseTimer]
        case (.expanded, .collapseDelayElapsed), (.expanding, .collapseDelayElapsed):
            guard !context.pinned, !context.interactionLock, !context.pointerInside else { return [] }
            state = .collapsing
            return [.collapse]

        // Collapse.
        case (.collapsing, .collapseAnimationFinished):
            state = .idle
            return []
        case (.collapsing, .pointerEnteredPanel), (.collapsing, .pointerEnteredActivation):
            // Pointer came back while closing: reopen instead of flickering.
            guard context.hoverEnabled else { return [] }
            state = .expanding
            return [.expand(focusShelf: false)]

        // Drags into Nook.
        case (.idle, .dragEntered), (.hovering, .dragEntered), (.collapsing, .dragEntered),
             (.expanding, .dragEntered), (.expanded, .dragEntered):
            state = .dragTargetActive
            return [.cancelActivationTimer, .cancelCollapseTimer, .expand(focusShelf: true), .showDropTarget(true)]
        case (.dragTargetActive, .dragExited):
            state = .expanded
            return [.showDropTarget(false)] + (context.pinned || context.pointerInside ? [] : [.startCollapseTimer])
        case (.dragTargetActive, .dropFinished):
            state = .expanded
            return [.showDropTarget(false)]
        case (.dragTargetActive, _):
            return []

        // Drags out of the Shelf: never collapse mid-drag.
        case (.expanded, .shelfDragBegan), (.expanding, .shelfDragBegan):
            state = .draggingFromShelf
            return [.cancelCollapseTimer]
        case (.draggingFromShelf, .shelfDragEnded):
            state = .expanded
            return context.pointerInside || context.pinned || context.interactionLock ? [] : [.startCollapseTimer]
        case (.draggingFromShelf, _):
            return []

        // Explicit control (keyboard shortcut, menu bar). Works even when hover is disabled.
        case (.idle, .toggleRequested), (.hovering, .toggleRequested), (.collapsing, .toggleRequested),
             (.idle, .openRequested), (.hovering, .openRequested), (.collapsing, .openRequested):
            state = .expanding
            return [.cancelActivationTimer, .expand(focusShelf: false)]
        case (.expanded, .toggleRequested), (.expanding, .toggleRequested),
             (.expanded, .closeRequested), (.expanding, .closeRequested):
            state = .collapsing
            return [.cancelCollapseTimer, .collapse]
        case (.expanded, .openRequested), (.expanding, .openRequested):
            return [.cancelCollapseTimer]

        default:
            return []
        }
    }
}
