import AppKit
import NookCore
import Quartz
import SwiftUI

/// What a tile hands to AppKit when a drag starts.
struct DragPayload {
    let id: UUID
    let kind: ShelfItem.Kind
    let fileURL: URL?
    let text: String?
    let icon: NSImage
}

/// AppKit drag source covering a Shelf tile. SwiftUI's `onDrag` can't report whether the
/// destination accepted the drop, so drags out of the Shelf use `NSDraggingSession` directly.
///
/// Only `.copy` is offered to other apps: the destination always receives its own copy, and the
/// Shelf's file is never moved or deleted by the destination. The result of the session
/// (`draggingSession(_:endedAt:operation:)`) decides whether the item is hidden afterwards.
final class ShelfDragSourceView: NSView, NSDraggingSource {
    var payloads: () -> [DragPayload] = { [] }
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var makeMenu: () -> NSMenu? = { nil }
    var onDragBegan: ([UUID]) -> Void = { _ in }
    var onDragEnded: ([UUID], NSDragOperation, Bool) -> Void = { _, _, _ in }
    var accessibilityName = "Shelf item"

    private var mouseDownEvent: NSEvent?
    private var draggedIDs: [UUID] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2 {
            mouseDownEvent = nil
            onDoubleClick()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil { onClick(event.modifierFlags) }
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
        mouseDownEvent = nil

        let items = payloads()
        guard !items.isEmpty else { return }
        let asFiles = down.modifierFlags.contains(.option)
        var draggingItems: [NSDraggingItem] = []
        let origin = convert(down.locationInWindow, from: nil)
        for (index, payload) in items.enumerated() {
            let writer: NSPasteboardWriting
            if payload.kind == .text, !asFiles, let text = payload.text {
                let pbItem = NSPasteboardItem()
                pbItem.setString(text, forType: .string)
                writer = pbItem
            } else if let url = payload.fileURL {
                writer = url as NSURL
            } else {
                continue
            }
            let item = NSDraggingItem(pasteboardWriter: writer)
            let size: CGFloat = 56
            let offset = CGFloat(index) * 4
            item.setDraggingFrame(NSRect(x: origin.x - size / 2 + offset, y: origin.y - size / 2 - offset, width: size, height: size), contents: payload.icon)
            draggingItems.append(item)
        }
        guard !draggingItems.isEmpty else { return }
        draggedIDs = items.map(\.id)
        let session = beginDraggingSession(with: draggingItems, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
        onDragBegan(draggedIDs)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = makeMenu() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Never offer .move or .delete: the destination gets a copy; Nook decides what happens to its own copy.
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let insideNook = window?.frame.contains(screenPoint) ?? false
        let ids = draggedIDs
        draggedIDs = []
        onDragEnded(ids, operation, insideNook)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityName }
    override func accessibilityPerformPress() -> Bool { onDoubleClick(); return true }
}

struct ShelfDragSource: NSViewRepresentable {
    var accessibilityName: String
    var payloads: () -> [DragPayload]
    var onClick: (NSEvent.ModifierFlags) -> Void
    var onDoubleClick: () -> Void
    var makeMenu: () -> NSMenu?
    var onDragBegan: ([UUID]) -> Void
    var onDragEnded: ([UUID], NSDragOperation, Bool) -> Void

    func makeNSView(context: Context) -> ShelfDragSourceView { ShelfDragSourceView() }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) {
        view.accessibilityName = accessibilityName
        view.payloads = payloads
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.makeMenu = makeMenu
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// Native Quick Look for Shelf items (never opens or executes files).
@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// Only mutated on the main thread; read by Quick Look's data-source callbacks (also main thread).
    nonisolated(unsafe) private var urls: [URL] = []
    weak var interaction: InteractionLocking?
    private var locked = false

    func show(_ urls: [URL], selected: Int = 0, from window: NSWindow?) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        window?.makeKey()
        if !locked { interaction?.beginInteraction(); locked = true }
        panel.dataSource = self
        panel.delegate = self
        panel.level = .statusBar + 1
        panel.reloadData()
        panel.currentPreviewItemIndex = min(selected, urls.count - 1)
        panel.makeKeyAndOrderFront(nil)
    }

    func toggle(_ urls: [URL], from window: NSWindow?) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true {
            QLPreviewPanel.shared()?.orderOut(nil)
            panelClosed()
        } else {
            show(urls, from: window)
        }
    }

    func panelClosed() {
        if locked { interaction?.endInteraction(); locked = false }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { panelClosed() }
    }
}
