import AppKit
import NookCore
import Observation
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// UI state shared between the coordinator (AppKit) and the SwiftUI content.
@MainActor
@Observable
final class NotchModel {
    var isOpen = false
    var isLarge = false
    var selectedTab: NookTab = .shelf
    var dropTargetActive = false
    var closedSize = CGSize(width: 185, height: 32)
    var notchWidth: CGFloat = 185
    var headerHeight: CGFloat = 32
    var hasNotch = true
    var pinned = false
    var state: NotchState = .idle
    /// Closed-notch "now playing" peek (album art left, waves right).
    var peekVisible = false
    var peekSize = CGSize(width: 269, height: 32)
    var peekWing: CGFloat = 42

    var openSize: CGSize { isLarge ? Nook.Metrics.largeSize : Nook.Metrics.compactSize }
}

/// The single floating panel. Borderless, non-activating (hovering never steals focus from the
/// frontmost app), joins all Spaces, and sits just above the menu bar.
final class NotchPanel: NSPanel {
    weak var quickLook: QuickLookCoordinator?
    var onCancel: () -> Void = {}

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        // Explicitly false so transparent pixels still receive the pointer (the activation strip
        // may be nearly transparent on displays without a notch).
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = false
        setAccessibilityLabel("Nook")
        setAccessibilitySubrole(.floatingWindow)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel() }

    // Quick Look panel control via the responder chain.
    // These informal-protocol callbacks are always delivered on the main thread.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLook != nil }
    }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel?.dataSource = quickLook
            panel?.delegate = quickLook
        }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook?.panelClosed() }
    }
}

/// Root AppKit view: hosts the SwiftUI content, reports pointer enter/exit through a tracking
/// area (no global mouse polling), and is the native drag destination for the whole panel.
final class NookRootView: NSView {
    struct Callbacks {
        var pointerEntered: () -> Void = {}
        var pointerExited: () -> Void = {}
        var dragEntered: () -> Void = {}
        var dragExited: () -> Void = {}
        var performDrop: (NSPasteboard) -> Bool = { _ in false }
        var dropFinished: () -> Void = {}
    }

    var callbacks = Callbacks()
    private var trackingArea: NSTrackingArea?

    static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    init(hosting: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForDraggedTypes(Self.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { callbacks.pointerEntered() }
    override func mouseExited(with event: NSEvent) { callbacks.pointerExited() }

    // MARK: Drag destination

    private func isAcceptable(_ info: NSDraggingInfo) -> Bool {
        // Drags that started on Nook's own Shelf are never re-imported.
        if info.draggingSource is ShelfDragSourceView { return false }
        return info.draggingPasteboard.availableType(from: Self.acceptedTypes) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isAcceptable(sender) else { return [] }
        callbacks.dragEntered()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isAcceptable(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        callbacks.dragExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { isAcceptable(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        callbacks.performDrop(sender.draggingPasteboard)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        callbacks.dropFinished()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // Covers drops that were rejected or ended elsewhere after passing over Nook.
        callbacks.dropFinished()
    }
}

/// Decodes a drop onto Nook into Shelf imports, preferring real file URLs, then file promises,
/// then text, then raw image data.
@MainActor
enum DropReader {
    @discardableResult
    static func importDrop(_ pasteboard: NSPasteboard, into shelf: ShelfController) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            shelf.importFiles(urls, origin: .drop)
            return true
        }
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            shelf.importPromises(receivers)
            return true
        }
        if let string = pasteboard.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            shelf.importText(string, origin: .drop)
            return true
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let url = urls.first {
            shelf.importText(url.absoluteString, origin: .drop)
            return true
        }
        if let png = pasteboard.data(forType: .png) {
            shelf.importImageData(png, type: .png)
            return true
        }
        if let tiff = pasteboard.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            shelf.importImageData(png, type: .png)
            return true
        }
        return false
    }
}
