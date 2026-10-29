import AppKit
import NookCore
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Main-actor façade over `ShelfStore` for the UI: imports, exports, drag-out bookkeeping,
/// status banners and native panels. Independent of the Assistant and Music features.
@MainActor
@Observable
final class ShelfController {
    struct Banner: Identifiable, Equatable {
        enum Tone: Equatable { case info, success, warning, failure }
        let id = UUID()
        var text: String
        var tone: Tone
        var undoItemIDs: [UUID] = []
        static func == (a: Banner, b: Banner) -> Bool { a.id == b.id }
    }

    private(set) var items: [ShelfItem] = []
    private(set) var recentlyRemoved: [ShelfItem] = []
    private(set) var storageBytes: Int64 = 0
    private(set) var importsInFlight = 0
    private(set) var unavailableReason: String?
    var selection: Set<UUID> = []
    var banner: Banner?
    var reconciliationNotice: String?
    /// The most recent removal, for ⌘Z (outlives the banner).
    private(set) var lastRemoval: [UUID] = []
    var cleanupCandidates: [ShelfItem] = []
    /// Items currently being dragged out (held busy in the store).
    private(set) var draggingIDs: Set<UUID> = []

    @ObservationIgnored let store: ShelfStore?
    @ObservationIgnored private let settings: SettingsService
    @ObservationIgnored private let diagnostics: DiagnosticsService
    @ObservationIgnored let thumbnails = ThumbnailProvider()
    @ObservationIgnored var interaction: InteractionLocking?
    @ObservationIgnored var sendToAssistant: ((String) -> Void)?
    /// Tells the window coordinator a drag-out started/ended so the panel never collapses mid-drag.
    @ObservationIgnored var dragActivity: ((Bool) -> Void)?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "Nook.ShelfPromises"
        q.qualityOfService = .userInitiated
        return q
    }()

    init(settings: SettingsService, diagnostics: DiagnosticsService, root: URL? = nil) {
        self.settings = settings
        self.diagnostics = diagnostics
        do {
            let layout = ShelfLayout(root: try root ?? ShelfLayout.defaultRoot(productName: "Nook"))
            store = ShelfStore(layout: layout)
        } catch {
            store = nil
            unavailableReason = error.localizedDescription
        }
    }

    var layout: ShelfLayout? { store?.layout }

    // MARK: Lifecycle

    func open() async {
        guard let store else { return }
        do {
            let report = try await store.open()
            diagnostics.lastReconciliation = report
            diagnostics.record("shelf", "Opened. \(report.summary)")
            if report.needsAttention { reconciliationNotice = report.summary }
            let purged = await store.purgeRecentlyRemoved(retentionDays: settings.settings.recentlyRemovedRetentionDays)
            if purged > 0 { diagnostics.record("shelf", "Deleted \(purged) recently removed item(s) past retention") }
            await refresh()
            evaluateCleanupPolicy()
        } catch {
            unavailableReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            diagnostics.record("shelf", "Open failed: \(error.localizedDescription)")
        }
    }

    func refresh() async {
        guard let store else { return }
        let all = await store.allItems()
        items = all.filter(\.isVisible)
        recentlyRemoved = all.filter { !$0.isVisible }.sorted { ($0.removedAt ?? .distantPast) > ($1.removedAt ?? .distantPast) }
        storageBytes = await store.storageUsage().bytes
        selection = selection.intersection(Set(items.map(\.id)))
    }

    func contentURL(_ item: ShelfItem) -> URL? { layout?.content(of: item) }

    // MARK: Banners

    func show(_ text: String, tone: Banner.Tone, undo: [UUID] = [], duration: Duration = .seconds(4)) {
        let banner = Banner(text: text, tone: tone, undoItemIDs: undo)
        self.banner = banner
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: undo.isEmpty ? duration : .seconds(8))
            guard !Task.isCancelled, self?.banner?.id == banner.id else { return }
            self?.banner = nil
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
    }

    // MARK: Import

    func importFiles(_ urls: [URL], origin: ShelfItem.Origin) {
        guard let store, !urls.isEmpty else { return }
        importsInFlight += urls.count
        let policy = settings.settings.duplicatePolicy
        Task {
            var added = 0, duplicates = 0
            var failures: [String] = []
            await withTaskGroup(of: Result<ShelfItem, Error>.self) { group in
                for url in urls {
                    group.addTask {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        do { return .success(try await store.importFile(at: url, origin: origin, duplicatePolicy: policy)) }
                        catch { return .failure(error) }
                    }
                }
                for await result in group {
                    switch result {
                    case .success: added += 1
                    case .failure(ShelfError.duplicate): duplicates += 1
                    case .failure(let error): failures.append(self.message(for: error))
                    }
                }
            }
            importsInFlight -= urls.count
            await refresh()
            diagnostics.record("shelf", "Import: \(added) added, \(duplicates) duplicate(s), \(failures.count) failed")
            reportImport(added: added, duplicates: duplicates, failures: failures)
        }
    }

    private func reportImport(added: Int, duplicates: Int, failures: [String]) {
        if let first = failures.first {
            let prefix = added > 0 ? "Added \(added). " : ""
            let more = failures.count > 1 ? " (+\(failures.count - 1) more)" : ""
            show(prefix + first + more, tone: .failure, duration: .seconds(7))
        } else if added > 0 {
            let base = added == 1 ? "Added to Shelf" : "Added \(added) items to Shelf"
            show(duplicates > 0 ? "\(base) · \(duplicates) already there, skipped" : base, tone: .success)
        } else if duplicates > 0 {
            show(duplicates == 1 ? "Already on the Shelf" : "Those items are already on the Shelf", tone: .info)
        }
    }

    func importText(_ text: String, origin: ShelfItem.Origin, title: String? = nil) {
        guard let store else { return }
        importsInFlight += 1
        Task {
            defer { importsInFlight -= 1 }
            do {
                _ = try await store.importText(text, origin: origin, title: title)
                await refresh()
                show(origin == .note ? "Note saved to Shelf" : "Text added to Shelf", tone: .success)
            } catch {
                show(message(for: error), tone: .failure)
            }
        }
    }

    /// Files promised by the drag source (Mail attachments, Photos, browsers…). They are delivered into
    /// a private `incoming/` folder first; if Nook quits before importing, the next launch picks them up.
    func importPromises(_ receivers: [NSFilePromiseReceiver]) {
        guard let layout, !receivers.isEmpty else { return }
        let destination = layout.incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            show("Couldn't prepare to receive the files.", tone: .failure)
            return
        }
        importsInFlight += receivers.count
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: promiseQueue) { url, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.importsInFlight -= 1 }
                    if let error {
                        self.show("The app you dragged from couldn't provide the file: \(error.localizedDescription)", tone: .failure)
                        return
                    }
                    await self.importReceivedFile(url, cleaningUp: destination)
                }
            }
        }
    }

    private func importReceivedFile(_ url: URL, cleaningUp directory: URL) async {
        guard let store else { return }
        do {
            _ = try await store.importFile(at: url, origin: .promise, duplicatePolicy: settings.settings.duplicatePolicy)
            show("Added to Shelf", tone: .success)
        } catch ShelfError.duplicate {
            show("Already on the Shelf", tone: .info)
        } catch {
            show(message(for: error), tone: .failure)
            return    // keep the received file so the next launch can retry
        }
        // The received copy is ours (in incoming/); the Shelf now has its own verified copy.
        try? FileManager.default.removeItem(at: url)
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: directory)
        }
        await refresh()
    }

    /// Raw image data (e.g. dragged from a web page without a file).
    func importImageData(_ data: Data, type: UTType) {
        guard let layout else { return }
        let dir = layout.incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
        let url = dir.appendingPathComponent("Image \(stamp).\(type.preferredFilenameExtension ?? "png")")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: [.withoutOverwriting])
        } catch {
            show("Couldn't save the dropped image.", tone: .failure)
            return
        }
        Task { await importReceivedFile(url, cleaningUp: dir) }
    }

    /// Reads the pasteboard on explicit user request (Paste button / ⌘V).
    func paste(from pasteboard: NSPasteboard = .general) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            importFiles(urls, origin: .paste)
        } else if let string = pasteboard.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            importText(string, origin: .paste)
        } else if let data = pasteboard.data(forType: .png) {
            importImageData(data, type: .png)
        } else if let data = pasteboard.data(forType: .tiff), let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            importImageData(png, type: .png)
        } else {
            show("Nothing on the clipboard that Nook can store.", tone: .info)
        }
    }

    func presentAddFilesPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Add to Shelf"
        panel.message = "Choose files or folders to copy onto the Shelf. The originals stay where they are."
        runPanel(panel) { [weak self] response in
            guard response == .OK else { return }
            self?.importFiles(panel.urls, origin: .filePicker)
        }
    }

    // MARK: Selection helpers (keyboard)

    var selectedItems: [ShelfItem] { items.filter { selection.contains($0.id) } }

    func undoLastRemoval() {
        guard !lastRemoval.isEmpty else { return }
        undoRemoval(lastRemoval)
    }

    // MARK: Removal (always recoverable first)

    func remove(_ ids: [UUID]) {
        guard let store, !ids.isEmpty else { return }
        Task {
            var removed: [UUID] = []
            for id in ids where !(await store.isBusy(id)) {
                if (try? await store.markRecentlyRemoved(id)) != nil { removed.append(id) }
            }
            await refresh()
            if !removed.isEmpty {
                lastRemoval = removed
                show(removed.count == 1 ? "Removed from Shelf" : "Removed \(removed.count) items", tone: .info, undo: removed)
            }
        }
    }

    func undoRemoval(_ ids: [UUID]) {
        guard let store else { return }
        Task {
            for id in ids { try? await store.restore(id) }
            await refresh()
            banner = nil
            if Set(ids) == Set(lastRemoval) { lastRemoval = [] }
            show(ids.count == 1 ? "Restored" : "Restored \(ids.count) items", tone: .success)
        }
    }

    func restore(_ id: UUID) { undoRemoval([id]) }

    func deletePermanently(_ ids: [UUID]) {
        guard let store else { return }
        Task {
            for id in ids { try? await store.remove(id) }
            await refresh()
        }
    }

    func confirmClearShelf() {
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Clear the Shelf?"
        alert.informativeText = "\(items.count) item(s) will move to Recently Removed and be deleted after \(settings.settings.recentlyRemovedRetentionDays) day(s). Originals elsewhere on your Mac are not affected."
        alert.addButton(withTitle: "Clear Shelf")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if runAlert(alert) == .alertFirstButtonReturn {
            remove(items.map(\.id))
        }
    }

    func confirmEmptyRecentlyRemoved() {
        guard !recentlyRemoved.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(recentlyRemoved.count) recently removed item(s) now?"
        alert.informativeText = "Nook's stored copies will be deleted permanently. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if runAlert(alert) == .alertFirstButtonReturn {
            deletePermanently(recentlyRemoved.map(\.id))
        }
    }

    // MARK: Cleanup policy (never silent)

    func evaluateCleanupPolicy() {
        guard let store else { return }
        let policy = settings.settings.cleanup
        Task {
            let busy = await store.busyItems()
            cleanupCandidates = policy.candidates(in: await store.allItems(), now: Date(), busy: busy)
        }
    }

    func reviewCleanup() {
        guard !cleanupCandidates.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(cleanupCandidates.count) item(s) matching your cleanup policy?"
        let names = cleanupCandidates.prefix(12).map { "• \($0.displayName)" }.joined(separator: "\n")
        let more = cleanupCandidates.count > 12 ? "\n…and \(cleanupCandidates.count - 12) more" : ""
        alert.informativeText = names + more + "\n\nThey'll move to Recently Removed first, so you can still restore them."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Not Now")
        if runAlert(alert) == .alertFirstButtonReturn {
            remove(cleanupCandidates.map(\.id))
            cleanupCandidates = []
        }
    }

    // MARK: Export (Save As / Move To)

    func presentSaveAs(_ item: ShelfItem) {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.storedFilename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "Save a copy of “\(item.displayName)”. The Shelf keeps its copy."
        if item.kind == .text { panel.allowedContentTypes = [.plainText] }
        runPanel(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            // NSSavePanel already asked the user to confirm replacing an existing file.
            let confirmedReplace = FileManager.default.fileExists(atPath: url.path)
            Task {
                do {
                    let placed = try await store.export(item.id, toDirectory: url.deletingLastPathComponent(), preferredName: url.lastPathComponent,
                                                        conflict: confirmedReplace ? .replace : .fail, mode: .copy)
                    self.show("Saved “\(placed.lastPathComponent)”", tone: .success)
                } catch {
                    self.show(self.message(for: error) + " The Shelf copy is unchanged.", tone: .failure, duration: .seconds(7))
                }
            }
        }
    }

    func presentMoveTo(_ ids: [UUID]) {
        let targets = items.filter { ids.contains($0.id) }
        guard store != nil, !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        panel.message = targets.count == 1
            ? "Choose where to move “\(targets[0].displayName)”. It leaves the Shelf only after the copy is verified."
            : "Choose where to move \(targets.count) items. Each leaves the Shelf only after its copy is verified."
        runPanel(panel) { [weak self] response in
            guard let self, response == .OK, let directory = panel.url else { return }
            Task { await self.move(targets, to: directory) }
        }
    }

    private func move(_ targets: [ShelfItem], to directory: URL) async {
        guard let store else { return }
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        var moved = 0
        var keepBothForAll = false
        for item in targets {
            var resolution: ConflictResolution = keepBothForAll ? .keepBoth : .fail
            while true {
                do {
                    _ = try await store.export(item.id, toDirectory: directory, conflict: resolution, mode: .move)
                    moved += 1
                    break
                } catch ShelfError.destinationExists where resolution == .fail {
                    switch askConflict(name: item.storedFilename, folder: directory.lastPathComponent, multiple: targets.count > 1) {
                    case .keepBoth: resolution = .keepBoth
                    case .keepBothAll: resolution = .keepBoth; keepBothForAll = true
                    case .replace: resolution = .replace
                    case .cancel:
                        await refresh()
                        show(moved > 0 ? "Moved \(moved); stopped at “\(item.displayName)”." : "Move cancelled. Nothing changed.", tone: .info)
                        return
                    }
                } catch {
                    await refresh()
                    show("“\(item.displayName)”: \(message(for: error)) It's still on the Shelf.", tone: .failure, duration: .seconds(8))
                    return
                }
            }
        }
        await refresh()
        show(moved == 1 ? "Moved to “\(directory.lastPathComponent)”" : "Moved \(moved) items to “\(directory.lastPathComponent)”", tone: .success)
    }

    enum ConflictChoice { case keepBoth, keepBothAll, replace, cancel }

    private func askConflict(name: String, folder: String, multiple: Bool) -> ConflictChoice {
        let alert = NSAlert()
        alert.messageText = "“\(name)” already exists in “\(folder)”."
        alert.informativeText = "Keep both (the moved item gets a new name), replace the existing item, or cancel. Replacing can't be undone."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        if multiple {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Keep both for all remaining conflicts"
        }
        let response = runAlert(alert)
        switch response {
        case .alertFirstButtonReturn: return alert.suppressionButton?.state == .on ? .keepBothAll : .keepBoth
        case .alertSecondButtonReturn:
            let confirm = NSAlert()
            confirm.messageText = "Replace “\(name)”?"
            confirm.informativeText = "The existing item in “\(folder)” will be replaced."
            confirm.addButton(withTitle: "Replace")
            confirm.addButton(withTitle: "Cancel")
            confirm.buttons.first?.hasDestructiveAction = true
            return runAlert(confirm) == .alertFirstButtonReturn ? .replace : .cancel
        default: return .cancel
        }
    }

    // MARK: Clipboard, reveal, assistant

    func copyToClipboard(_ item: ShelfItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if item.kind == .text, let store {
            Task {
                if let text = try? await store.readText(item.id) {
                    pb.setString(text, forType: .string)
                    show("Text copied", tone: .success)
                }
            }
        } else if let url = contentURL(item) {
            pb.writeObjects([url as NSURL])
            show("Copied — paste in Finder to make a copy", tone: .success)
        }
    }

    func reveal(_ item: ShelfItem) {
        guard let url = contentURL(item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealStorageFolder() {
        guard let root = layout?.root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func sendTextToAssistant(_ item: ShelfItem) {
        guard item.kind == .text, let store else { return }
        Task {
            if let text = try? await store.readText(item.id) { sendToAssistant?(text) }
        }
    }

    func rename(_ item: ShelfItem, to name: String) {
        guard let store else { return }
        Task {
            try? await store.rename(item.id, displayName: name)
            await refresh()
        }
    }

    // MARK: Drag-out bookkeeping

    func dragBegan(_ ids: [UUID]) {
        draggingIDs.formUnion(ids)
        dragActivity?(true)
        guard let store else { return }
        Task { for id in ids { try? await store.beginTransfer(id) } }
    }

    /// Called with the operation AppKit reports when the drag session ends.
    func dragEnded(_ ids: [UUID], operation: NSDragOperation, endedInsideNook: Bool) {
        draggingIDs.subtract(ids)
        dragActivity?(false)
        guard let store else { return }
        let resolution = DragOutPolicy.resolve(operationRawValue: operation.rawValue, endedInsideNook: endedInsideNook)
        let behavior = settings.settings.afterDragOut
        diagnostics.record("shelf", "Drag-out ended: op=\(operation.rawValue) resolution=\(resolution)")
        Task {
            for id in ids { await store.endTransfer(id) }
            guard resolution == .accepted, behavior == .hideRecoverably else { return }
            for id in ids { try? await store.markRecentlyRemoved(id) }
            await refresh()
            lastRemoval = ids
            show(ids.count == 1 ? "Moved out of the Shelf" : "Moved \(ids.count) items out", tone: .success, undo: ids)
        }
    }

    // MARK: Modal helpers

    /// Nook is a background (accessory) app, so it activates briefly to show a native panel and then
    /// hands activation back to the app the user was in.
    private func runPanel(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        interaction?.beginInteraction()
        let previous = Self.activateForModal()
        panel.level = .modalPanel
        panel.begin { [weak self] response in
            self?.interaction?.endInteraction()
            completion(response)
            Self.restoreActivation(previous)
        }
    }

    @discardableResult
    func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        interaction?.beginInteraction()
        let previous = Self.activateForModal()
        defer {
            interaction?.endInteraction()
            Self.restoreActivation(previous)
        }
        alert.window.level = .modalPanel
        return alert.runModal()
    }

    private static func activateForModal() -> NSRunningApplication? {
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        return previous == NSRunningApplication.current ? nil : previous
    }

    private static func restoreActivation(_ previous: NSRunningApplication?) {
        // Don't steal focus back from the Settings window if the user opened it meanwhile.
        guard let previous, !NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue == "NookSettings" }) else { return }
        previous.activate()
    }
}

/// Implemented by the window coordinator so modal UI can hold the panel open.
@MainActor
protocol InteractionLocking: AnyObject {
    func beginInteraction()
    func endInteraction()
}

/// Thumbnails for visible tiles only, cached with a hard count limit.
@MainActor
final class ThumbnailProvider {
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 120
        return c
    }()

    func cached(_ id: UUID) -> NSImage? { cache.object(forKey: id.uuidString as NSString) }

    func thumbnail(for id: UUID, url: URL, size: CGSize) async -> NSImage? {
        if let hit = cached(id) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: [.thumbnail, .icon])
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        cache.setObject(image, forKey: id.uuidString as NSString)
        return image
    }
}
