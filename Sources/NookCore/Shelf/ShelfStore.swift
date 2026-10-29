import Foundation

public enum DuplicatePolicy: String, Codable, Sendable, CaseIterable {
    /// An identical file (same name and SHA-256) already on the Shelf is not added again.
    case skipIdentical
    /// Every drop creates a new item.
    case keepBoth
}

public enum ConflictResolution: Sendable, Equatable {
    /// Use a Finder-style numbered name ("Report 2.pdf").
    case keepBoth
    /// Replace the existing destination item. Callers must have obtained explicit confirmation.
    case replace
    /// Throw `ShelfError.destinationExists`.
    case fail
}

public enum TransferMode: Sendable, Equatable {
    case copy
    case move
}

/// The Shelf's transactional storage engine.
///
/// Invariants:
/// - Sources are only ever read. Nothing in this type writes to, moves or deletes an import source.
/// - An item becomes visible only after its content has been copied, verified, and committed by an
///   atomic directory rename (`staging/<txn>` → `items/<id>`), with its sidecar metadata inside.
/// - The Shelf copy is removed by an export only after the destination copy has been verified.
/// - Items involved in a transfer are "busy" and can't be removed, cleaned up or exported twice.
public actor ShelfStore {
    public nonisolated let layout: ShelfLayout
    private let fileOps: ShelfFileOperations
    /// Files up to this size are verified with SHA-256 on both sides; larger ones by size.
    private let hashVerificationLimit: Int64
    private let now: @Sendable () -> Date
    /// Free space we always leave on the volume when importing.
    private let spaceMargin: Int64

    private var items: [ShelfItem] = []
    private var busy: Set<UUID> = []
    private var isOpen = false
    private var observers: [UUID: @Sendable ([ShelfItem]) -> Void] = [:]

    public static let maxTextBytes = 20 * 1024 * 1024

    public init(
        layout: ShelfLayout,
        fileOps: ShelfFileOperations = SystemFileOperations(),
        hashVerificationLimit: Int64 = 2 * 1024 * 1024 * 1024,
        spaceMargin: Int64 = 64 * 1024 * 1024,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.layout = layout
        self.fileOps = fileOps
        self.hashVerificationLimit = hashVerificationLimit
        self.spaceMargin = spaceMargin
        self.now = now
    }

    // MARK: Observation

    /// Registers a callback invoked (on the store's executor) with the full item list after each change.
    public func observe(_ callback: @escaping @Sendable ([ShelfItem]) -> Void) -> UUID {
        let token = UUID()
        observers[token] = callback
        callback(items)
        return token
    }

    public func removeObserver(_ token: UUID) { observers[token] = nil }

    private func notify() {
        let snapshot = items
        for callback in observers.values { callback(snapshot) }
    }

    // MARK: Open & reconcile

    /// Prepares storage and repairs anything left by an unexpected shutdown.
    @discardableResult
    public func open() async throws -> ReconciliationReport {
        let fm = FileManager.default
        do {
            for dir in [layout.root, layout.items, layout.staging, layout.trash, layout.incoming] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        } catch {
            throw ShelfError.storageUnavailable(error.localizedDescription)
        }

        var report = ReconciliationReport()

        // 1. Uncommitted imports: the staging copy was never visible and the source was never touched.
        report.discardedIncompleteImports = removeChildren(of: layout.staging)
        // 2. Deletions that were already decided but not finished.
        report.purgedPendingDeletions = removeChildren(of: layout.trash)

        // 3. Index.
        var indexItems: [ShelfItem] = []
        if fm.fileExists(atPath: layout.index.path) {
            do {
                let data = try Data(contentsOf: layout.index)
                indexItems = try JSONCoding.decoder().decode(ShelfIndexFile.self, from: data).items
            } catch {
                report.indexWasCorrupt = true
                let stamp = Int(now().timeIntervalSince1970)
                let aside = layout.root.appendingPathComponent("shelf-index.corrupt-\(stamp).json")
                try? fm.moveItem(at: layout.index, to: aside)
            }
        }

        // 4. Reconcile index with item directories.
        var byID: [UUID: ShelfItem] = [:]
        var order: [UUID] = []
        for item in indexItems where byID[item.id] == nil {
            byID[item.id] = item
            order.append(item.id)
        }
        let entries = (try? fm.contentsOfDirectory(at: layout.items, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var seen: Set<UUID> = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Hidden system files (e.g. Finder's .DS_Store after "Show in Finder") are not user data.
            if entry.lastPathComponent.hasPrefix(".") { continue }
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                report.unrecognizedEntries += 1
                continue
            }
            seen.insert(id)
            if var known = byID[id] {
                let exists = fm.fileExists(atPath: layout.content(of: known).path)
                if !exists && known.status != .missing {
                    known.status = .missing
                    report.missingItems += 1
                } else if exists && known.status == .missing {
                    known.status = .ready
                }
                byID[id] = known
            } else if let recovered = recoverItem(in: entry, id: id) {
                byID[id] = recovered
                order.append(id)
                report.recoveredItems += 1
            } else if (try? fm.contentsOfDirectory(atPath: entry.path))?.isEmpty == true {
                try? fm.removeItem(at: entry)        // empty shell, nothing to lose
            } else {
                report.unrecognizedEntries += 1
            }
        }
        for id in order where !seen.contains(id) {
            if var item = byID[id], item.status != .missing {
                item.status = .missing
                byID[id] = item
                report.missingItems += 1
            }
        }
        items = order.compactMap { byID[$0] }
        isOpen = true
        if report.recoveredItems > 0 || report.missingItems > 0 || report.indexWasCorrupt || !fm.fileExists(atPath: layout.index.path) {
            try? saveIndex()
        }

        // 5. Files delivered by drag promises but not yet imported (crash between receipt and import).
        let pending = Self.children(of: layout.incoming)
        for txnDir in pending {
            let files = Self.children(of: txnDir)
            var allImported = true
            for file in files {
                if (try? await importFile(at: file, origin: .recovered, duplicatePolicy: .skipIdentical)) != nil {
                    report.importedPendingPromises += 1
                } else {
                    allImported = false
                }
            }
            if allImported { try? FileManager.default.removeItem(at: txnDir) }
        }
        notify()
        return report
    }

    /// Rebuilds an item from its sidecar, or from its content alone if the sidecar is gone.
    private func recoverItem(in directory: URL, id: UUID) -> ShelfItem? {
        let fm = FileManager.default
        let sidecar = directory.appendingPathComponent(ShelfLayout.sidecarName)
        if let data = try? Data(contentsOf: sidecar),
           var item = try? JSONCoding.decoder().decode(ShelfItem.self, from: data),
           item.id == id,
           fm.fileExists(atPath: layout.content(of: item).path) {
            if item.status == .missing { item.status = .ready }
            if item.status == .ready { item.status = .recovered }
            return item
        }
        let children = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0 != ShelfLayout.sidecarName }
        guard children.count == 1, let name = children.first else { return nil }
        let content = directory.appendingPathComponent(name)
        let sniff = ContentSniffer.sniff(fileAt: content)
        let footprint = try? SafeFileOps.footprint(of: content)
        let isFolder = sniff.effective.conforms(to: .folder) || sniff.effective.conforms(to: .directory)
        var item = ShelfItem(
            id: id, kind: isFolder ? .folder : .file, displayName: name, originalFilename: name,
            storedFilename: name, contentType: sniff.effective.identifier,
            declaredContentType: sniff.declared?.identifier, typeMismatch: sniff.isMismatch,
            importedAt: (try? content.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now(),
            byteSize: footprint?.bytes, fileCount: footprint?.files, status: .recovered, origin: .recovered
        )
        if !isFolder, (footprint?.bytes ?? .max) <= 64 * 1024, sniff.effective.conforms(to: .plainText),
           let text = try? String(contentsOf: content, encoding: .utf8) {
            item.kind = .text
            item.textPreview = ShelfItem.makePreview(text)
        }
        try? writeSidecar(item, in: directory)
        return item
    }

    private static func children(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private func removeChildren(of directory: URL) -> Int {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for child in children where PathContainment.isContained(child, in: layout.root) {
            if (try? fm.removeItem(at: child)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: Queries

    public func allItems() -> [ShelfItem] { items }
    public func visibleItems() -> [ShelfItem] { items.filter(\.isVisible) }
    public func item(_ id: UUID) -> ShelfItem? { items.first { $0.id == id } }
    public func isBusy(_ id: UUID) -> Bool { busy.contains(id) }
    public func busyItems() -> Set<UUID> { busy }

    public func contentURL(for id: UUID) -> URL? {
        guard let item = item(id) else { return nil }
        return layout.content(of: item)
    }

    public func readText(_ id: UUID) throws -> String {
        guard let item = item(id), item.kind == .text else { throw ShelfError.itemNotFound }
        let url = layout.content(of: item)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ShelfError.sourceMissing }
        return text
    }

    /// Bytes used by stored content (including recently removed items still on disk).
    public func storageUsage() -> (bytes: Int64, itemCount: Int) {
        (items.reduce(0) { $0 + ($1.byteSize ?? 0) }, items.filter(\.isVisible).count)
    }

    // MARK: Import

    /// Copies a file or folder into the Shelf. The source is only read.
    @discardableResult
    public func importFile(at source: URL, origin: ShelfItem.Origin, duplicatePolicy: DuplicatePolicy = .skipIdentical) async throws -> ShelfItem {
        try requireOpen()
        if PathContainment.isContained(source, in: layout.items) {
            throw ShelfError.unsupportedItem("it is already on the Shelf")
        }
        let txn = UUID()
        let stagingDir = layout.staging.appendingPathComponent(txn.uuidString, isDirectory: true)
        let prepared: PreparedImport
        do {
            prepared = try await Self.stage(
                source: source, stagingDir: stagingDir, fileOps: fileOps,
                hashLimit: hashVerificationLimit, spaceMargin: spaceMargin
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            throw ShelfError.from(error)
        }

        if duplicatePolicy == .skipIdentical, let hash = prepared.sha256,
           let existing = items.first(where: { $0.isVisible && $0.sha256 == hash && $0.storedFilename == prepared.storedName }) {
            try? FileManager.default.removeItem(at: stagingDir)
            throw ShelfError.duplicate(existing: existing.id)
        }

        let item = ShelfItem(
            kind: prepared.isDirectory ? .folder : .file,
            displayName: prepared.storedName,
            originalFilename: source.lastPathComponent,
            storedFilename: prepared.storedName,
            contentType: prepared.sniff.effective.identifier,
            declaredContentType: prepared.sniff.declared?.identifier,
            typeMismatch: prepared.sniff.isMismatch,
            importedAt: now(),
            byteSize: prepared.bytes,
            fileCount: prepared.isDirectory ? prepared.files : nil,
            sha256: prepared.sha256,
            origin: origin
        )
        return try commit(item, stagingDir: stagingDir)
    }

    /// Stores text as a UTF-8 file-backed Shelf item.
    @discardableResult
    public func importText(_ text: String, origin: ShelfItem.Origin, title: String? = nil) async throws -> ShelfItem {
        try requireOpen()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ShelfError.unsupportedItem("the text is empty") }
        let data = Data(text.utf8)
        guard data.count <= Self.maxTextBytes else { throw ShelfError.textTooLarge }

        let firstLine = (title ?? trimmed.components(separatedBy: .newlines).first ?? "Note")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shortTitle = firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
        let storedName = FileNameSanitizer.sanitize(shortTitle, fallback: "Note") + ".txt"

        let txn = UUID()
        let stagingDir = layout.staging.appendingPathComponent(txn.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try data.write(to: stagingDir.appendingPathComponent(storedName), options: [.withoutOverwriting])
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            throw ShelfError.from(error)
        }
        let item = ShelfItem(
            kind: .text, displayName: shortTitle.isEmpty ? "Note" : shortTitle, originalFilename: nil,
            storedFilename: storedName, contentType: "public.utf8-plain-text", importedAt: now(),
            byteSize: Int64(data.count), sha256: nil, textPreview: ShelfItem.makePreview(text), origin: origin
        )
        return try commit(item, stagingDir: stagingDir)
    }

    /// Atomic commit: sidecar into staging, then one rename makes the item exist.
    private func commit(_ item: ShelfItem, stagingDir: URL) throws -> ShelfItem {
        do {
            try writeSidecar(item, in: stagingDir)
            try SafeFileOps.renameExclusive(from: stagingDir, to: layout.itemDirectory(item.id))
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            throw ShelfError.from(error)
        }
        items.append(item)
        // If the index write fails the item is still safe: reconciliation rebuilds it from its sidecar.
        try? saveIndex()
        notify()
        return item
    }

    struct PreparedImport: Sendable {
        var storedName: String
        var isDirectory: Bool
        var bytes: Int64
        var files: Int
        var sha256: String?
        var sniff: ContentSniffer.Result
    }

    /// Copy + verify into the staging directory, off the actor so imports can run in parallel.
    @concurrent
    static func stage(source: URL, stagingDir: URL, fileOps: ShelfFileOperations, hashLimit: Int64, spaceMargin: Int64) async throws -> PreparedImport {
        let fm = FileManager.default
        var src = source
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isReadableKey]
        guard fm.fileExists(atPath: src.path) else { throw ShelfError.sourceMissing }
        var values = try src.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true {
            src = src.resolvingSymlinksInPath()
            guard fm.fileExists(atPath: src.path) else { throw ShelfError.sourceMissing }
            values = try src.resourceValues(forKeys: keys)
        }
        let isDirectory = values.isDirectory == true
        guard isDirectory || values.isRegularFile == true else {
            throw ShelfError.unsupportedItem("it is not a regular file or folder")
        }
        guard values.isReadable != false else { throw ShelfError.permissionDenied }

        let sourceFootprint = try SafeFileOps.footprint(of: src)
        if let available = fileOps.availableCapacity(near: stagingDir.deletingLastPathComponent()),
           available < sourceFootprint.bytes + spaceMargin {
            throw ShelfError.insufficientSpace(needed: sourceFootprint.bytes, available: available)
        }
        try Task.checkCancellation()

        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let storedName = FileNameSanitizer.sanitize(src.lastPathComponent)
        let destination = stagingDir.appendingPathComponent(storedName, isDirectory: isDirectory)

        var copyError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: src, options: [.withoutChanges], error: &coordinationError) { readURL in
            do { try fileOps.copyItem(at: readURL, to: destination) } catch { copyError = error }
        }
        if let error = copyError ?? coordinationError { throw error }
        try Task.checkCancellation()

        // Verify.
        let copied = try SafeFileOps.footprint(of: destination)
        guard copied.bytes == sourceFootprint.bytes, copied.files == sourceFootprint.files else {
            throw ShelfError.verificationFailed
        }
        var hash: String?
        if !isDirectory && sourceFootprint.bytes <= hashLimit {
            let copiedHash = try SafeFileOps.sha256(of: destination)
            let sourceHash = try SafeFileOps.sha256(of: src)
            guard copiedHash == sourceHash else { throw ShelfError.verificationFailed }
            hash = copiedHash
        }
        return PreparedImport(
            storedName: storedName, isDirectory: isDirectory, bytes: copied.bytes, files: copied.files,
            sha256: hash, sniff: ContentSniffer.sniff(fileAt: destination)
        )
    }

    // MARK: Status changes

    /// Hides an item after a confirmed drag-out. Its content stays on disk (so a destination that reads
    /// the file lazily still finds it) until `purgeRecentlyRemoved` runs after the retention period.
    public func markRecentlyRemoved(_ id: UUID) throws {
        try update(id) { $0.status = .recentlyRemoved; $0.removedAt = self.now() }
    }

    public func restore(_ id: UUID) throws {
        try update(id) { item in
            item.status = FileManager.default.fileExists(atPath: self.layout.content(of: item).path) ? .ready : .missing
            item.removedAt = nil
        }
    }

    public func rename(_ id: UUID, displayName: String) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try update(id) { $0.displayName = String(name.prefix(200)) }
    }

    public func move(_ id: UUID, toIndex newIndex: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: max(0, min(newIndex, items.count)))
        try? saveIndex()
        notify()
    }

    private func update(_ id: UUID, _ change: (inout ShelfItem) -> Void) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw ShelfError.itemNotFound }
        change(&items[index])
        try? writeSidecar(items[index], in: layout.itemDirectory(id))
        try saveIndex()
        notify()
    }

    // MARK: Removal

    /// Permanently deletes a Shelf item's stored copy. Never touches anything outside the Shelf root.
    public func remove(_ id: UUID) throws {
        try requireOpen()
        guard busy.contains(id) == false else { throw ShelfError.itemBusy }
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw ShelfError.itemNotFound }
        let dir = layout.itemDirectory(id)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            let trashed = layout.trash.appendingPathComponent(id.uuidString, isDirectory: true)
            try? fm.removeItem(at: trashed)
            do {
                try SafeFileOps.renameExclusive(from: dir, to: trashed)
            } catch {
                throw ShelfError.from(error)
            }
            try? fm.removeItem(at: trashed)
        }
        items.remove(at: index)
        try? saveIndex()
        notify()
    }

    /// Removes every visible, non-busy item. Returns the number of items skipped because they were busy.
    @discardableResult
    public func clearAll() throws -> Int {
        var skipped = 0
        for item in items where item.isVisible {
            if busy.contains(item.id) { skipped += 1; continue }
            try remove(item.id)
        }
        return skipped
    }

    /// Deletes recently removed items whose retention period has ended.
    @discardableResult
    public func purgeRecentlyRemoved(retentionDays: Int) -> Int {
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        var purged = 0
        for item in items where item.status == .recentlyRemoved && (item.removedAt ?? .distantPast) < cutoff {
            if (try? remove(item.id)) != nil { purged += 1 }
        }
        return purged
    }

    // MARK: Transactions held by the UI (drag-out)

    /// Marks an item busy for the duration of an external transfer such as a drag session.
    public func beginTransfer(_ id: UUID) throws {
        guard item(id) != nil else { throw ShelfError.itemNotFound }
        guard !busy.contains(id) else { throw ShelfError.itemBusy }
        busy.insert(id)
    }

    public func endTransfer(_ id: UUID) { busy.remove(id) }

    // MARK: Export

    /// Copies (or moves) a Shelf item into `directory`.
    ///
    /// The destination is written via a temporary file and verified before it is placed with a
    /// no-overwrite rename (or, only for `.replace`, an atomic replace). For `.move`, the Shelf copy is
    /// removed only after the destination has been verified.
    @discardableResult
    public func export(
        _ id: UUID,
        toDirectory directory: URL,
        preferredName: String? = nil,
        conflict: ConflictResolution,
        mode: TransferMode
    ) async throws -> URL {
        try requireOpen()
        guard let item = item(id) else { throw ShelfError.itemNotFound }
        guard item.status != .missing else { throw ShelfError.sourceMissing }
        try beginTransfer(id)
        defer { busy.remove(id) }

        let source = layout.content(of: item)
        guard FileManager.default.fileExists(atPath: source.path) else {
            try? update(id) { $0.status = .missing }
            throw ShelfError.sourceMissing
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw ShelfError.destinationInvalid("it is not a folder")
        }
        if directory.standardizedFileURL.resolvingSymlinksInPath() == layout.root.standardizedFileURL.resolvingSymlinksInPath()
            || PathContainment.isContained(directory, in: layout.root) {
            throw ShelfError.destinationInvalid("it is inside Nook's own storage")
        }

        let name = FileNameSanitizer.sanitize(preferredName ?? item.storedFilename)
        let placed: URL
        do {
            placed = try await Self.transfer(
                source: source, sourceIsDirectory: item.kind == .folder, expectedHash: item.sha256,
                directory: directory, name: name, conflict: conflict, mode: mode, hashLimit: hashVerificationLimit
            )
        } catch {
            throw ShelfError.from(error)
        }

        if mode == .move {
            // Destination verified; now (and only now) drop the Shelf copy.
            busy.remove(id)
            try? remove(id)
        }
        return placed
    }

    @concurrent
    static func transfer(
        source: URL, sourceIsDirectory: Bool, expectedHash: String?, directory: URL, name: String,
        conflict: ConflictResolution, mode: TransferMode, hashLimit: Int64
    ) async throws -> URL {
        let fm = FileManager.default
        func target(_ n: String) -> URL { directory.appendingPathComponent(n, isDirectory: sourceIsDirectory) }

        var finalURL = target(name)
        var replacing = false
        if fm.fileExists(atPath: finalURL.path) {
            switch conflict {
            case .fail: throw ShelfError.destinationExists
            case .replace: replacing = true
            case .keepBoth: finalURL = try nextFreeName(for: name, in: directory, isDirectory: sourceIsDirectory)
            }
        }
        guard PathContainment.isContained(finalURL, in: directory) else {
            throw ShelfError.destinationInvalid("the name would leave the chosen folder")
        }

        let sourceFootprint = try SafeFileOps.footprint(of: source)

        // Same-volume move without a conflict: a single atomic rename.
        if mode == .move && !replacing && SafeFileOps.isSameVolume(source, directory) {
            do {
                try SafeFileOps.renameExclusive(from: source, to: finalURL)
                let moved = try SafeFileOps.footprint(of: finalURL)
                guard moved == sourceFootprint else { throw ShelfError.verificationFailed }
                return finalURL
            } catch let error as POSIXError where error.code == .EXDEV {
                // Fall through to copy + verify (e.g. firmlinked volumes report differently).
            } catch let error as POSIXError where error.code == .EEXIST {
                throw ShelfError.destinationExists
            }
        }

        // Copy to a temporary sibling (same volume as the destination), verify, then place.
        let tempDir = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: finalURL, create: true))
        let tempURL: URL
        if let tempDir, SafeFileOps.isSameVolume(tempDir, directory) {
            tempURL = tempDir.appendingPathComponent(name, isDirectory: sourceIsDirectory)
        } else {
            tempURL = directory.appendingPathComponent(".\(UUID().uuidString).nook-partial", isDirectory: sourceIsDirectory)
        }
        defer {
            try? fm.removeItem(at: tempURL)
            if let tempDir { try? fm.removeItem(at: tempDir) }
        }
        do {
            try fm.copyItem(at: source, to: tempURL)
        } catch {
            throw ShelfError.from(error)
        }
        try Task.checkCancellation()
        let copied = try SafeFileOps.footprint(of: tempURL)
        guard copied == sourceFootprint else { throw ShelfError.verificationFailed }
        if !sourceIsDirectory && copied.bytes <= hashLimit {
            let tempHash = try SafeFileOps.sha256(of: tempURL)
            let reference = try expectedHash ?? SafeFileOps.sha256(of: source)
            guard tempHash == reference else { throw ShelfError.verificationFailed }
        }

        if replacing {
            do {
                _ = try fm.replaceItemAt(finalURL, withItemAt: tempURL)
            } catch {
                throw ShelfError.from(error)
            }
        } else {
            var attempt = finalURL
            var tries = 0
            while true {
                do {
                    try SafeFileOps.renameExclusive(from: tempURL, to: attempt)
                    finalURL = attempt
                    break
                } catch let error as POSIXError where error.code == .EEXIST {
                    // Someone created the name after we checked: never overwrite.
                    guard conflict == .keepBoth, tries < 50 else { throw ShelfError.destinationExists }
                    tries += 1
                    attempt = try nextFreeName(for: name, in: directory, isDirectory: sourceIsDirectory)
                } catch {
                    throw ShelfError.from(error)
                }
            }
        }
        let placed = try SafeFileOps.footprint(of: finalURL)
        guard placed == sourceFootprint else { throw ShelfError.verificationFailed }
        return finalURL
    }

    static func nextFreeName(for name: String, in directory: URL, isDirectory: Bool) throws -> URL {
        for n in 2...10_000 {
            let candidate = directory.appendingPathComponent(FileNameSanitizer.numberedVariant(of: name, number: n), isDirectory: isDirectory)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw ShelfError.destinationExists
    }

    // MARK: Persistence

    private func requireOpen() throws {
        guard isOpen else { throw ShelfError.storageUnavailable("the Shelf has not been opened") }
    }

    private func saveIndex() throws {
        let data = try JSONCoding.encoder().encode(ShelfIndexFile(version: 1, items: items))
        try data.write(to: layout.index, options: [.atomic])
    }

    private func writeSidecar(_ item: ShelfItem, in directory: URL) throws {
        let data = try JSONCoding.encoder().encode(item)
        try data.write(to: directory.appendingPathComponent(ShelfLayout.sidecarName), options: [.atomic])
    }
}
