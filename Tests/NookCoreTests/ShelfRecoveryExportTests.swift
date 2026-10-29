import Foundation
import Testing
@testable import NookCore

@Suite("Shelf persistence & recovery")
struct ShelfRecoveryTests {
    @Test func itemsPersistAcrossReopen() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let a = try await store.importFile(at: try tmp.file("a.pdf", data: Fixtures.pdf("a")), origin: .drop)
        let t = try await store.importText("Remember the milk", origin: .note)

        // A brand-new store over the same root (simulates app/Mac restart).
        let reopened = ShelfStore(layout: store.layout, spaceMargin: 0)
        let report = try await reopened.open()
        #expect(report.needsAttention == false)
        let items = await reopened.visibleItems()
        #expect(items.map(\.id) == [a.id, t.id])
        #expect(try await reopened.readText(t.id) == "Remember the milk")
    }

    @Test func interruptedImportIsCleanedUpOnLaunch() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        // Simulate a crash mid-copy: a staging transaction with a partial file.
        let txn = store.layout.staging.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: txn, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: txn.appendingPathComponent("half.pdf"))

        let reopened = ShelfStore(layout: store.layout, spaceMargin: 0)
        let report = try await reopened.open()
        #expect(report.discardedIncompleteImports == 1)
        #expect(childCount(store.layout.staging) == 0)
        #expect(await reopened.visibleItems().isEmpty)
    }

    @Test func committedItemMissingFromIndexIsRecovered() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let item = try await store.importFile(at: try tmp.file("a.pdf", data: Fixtures.pdf()), origin: .drop)
        // Simulate a crash between the commit rename and the index write.
        try Data(#"{"version":1,"items":[]}"#.utf8).write(to: store.layout.index)

        let reopened = ShelfStore(layout: store.layout, spaceMargin: 0)
        let report = try await reopened.open()
        #expect(report.recoveredItems == 1)
        let recovered = try #require(await reopened.item(item.id))
        #expect(recovered.status == .recovered)
        #expect(recovered.sha256 == item.sha256)
    }

    @Test func corruptIndexIsSetAsideAndRebuiltFromSidecars() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        _ = try await store.importFile(at: try tmp.file("a.pdf", data: Fixtures.pdf("1")), origin: .drop)
        _ = try await store.importFile(at: try tmp.file("b.pdf", data: Fixtures.pdf("2")), origin: .drop)
        try Data("{ not json".utf8).write(to: store.layout.index)

        let reopened = ShelfStore(layout: store.layout, spaceMargin: 0)
        let report = try await reopened.open()
        #expect(report.indexWasCorrupt)
        #expect(report.recoveredItems == 2)
        #expect(await reopened.visibleItems().count == 2)
        let aside = try FileManager.default.contentsOfDirectory(atPath: store.layout.root.path).filter { $0.hasPrefix("shelf-index.corrupt-") }
        #expect(aside.count == 1)
    }

    @Test func missingContentIsReportedNotSilentlyDropped() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let item = try await store.importFile(at: try tmp.file("a.pdf", data: Fixtures.pdf()), origin: .drop)
        try FileManager.default.removeItem(at: store.layout.itemDirectory(item.id))

        let reopened = ShelfStore(layout: store.layout, spaceMargin: 0)
        let report = try await reopened.open()
        #expect(report.missingItems == 1)
        #expect(await reopened.item(item.id)?.status == .missing)
    }

    @Test func orphanedFileWithoutSidecarIsRecovered() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let id = UUID()
        let dir = store.layout.itemDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Fixtures.png(seed: 9).write(to: dir.appendingPathComponent("orphan.png"))

        let reopened = ShelfStore(layout: store.layout, spaceMargin: 0)
        let report = try await reopened.open()
        #expect(report.recoveredItems == 1)
        let item = try #require(await reopened.item(id))
        #expect(item.storedFilename == "orphan.png")
        #expect(item.contentType == "public.png")
        #expect(FileManager.default.fileExists(atPath: store.layout.sidecar(id).path))
    }

    @Test func finderMetadataIsNotReportedAsUnrecognized() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        try Data([0, 0, 0, 1]).write(to: store.layout.items.appendingPathComponent(".DS_Store"))
        let reopened = ShelfStore(layout: store.layout, spaceMargin: 0)
        let report = try await reopened.open()
        #expect(report.unrecognizedEntries == 0)
        #expect(report.needsAttention == false)
    }

    @Test func unrecognizedEntriesAreLeftUntouched() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let stray = store.layout.items.appendingPathComponent("not-a-uuid.txt")
        try Data("keep me".utf8).write(to: stray)
        let reopened = ShelfStore(layout: store.layout, spaceMargin: 0)
        let report = try await reopened.open()
        #expect(report.unrecognizedEntries == 1)
        #expect(FileManager.default.fileExists(atPath: stray.path))
    }

    @Test func pendingPromiseFilesAreImportedOnLaunch() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let txn = store.layout.incoming.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: txn, withIntermediateDirectories: true)
        try Fixtures.pdf().write(to: txn.appendingPathComponent("attachment.pdf"))

        let reopened = ShelfStore(layout: store.layout, spaceMargin: 0)
        let report = try await reopened.open()
        #expect(report.importedPendingPromises == 1)
        #expect(await reopened.visibleItems().first?.storedFilename == "attachment.pdf")
        #expect(childCount(store.layout.incoming) == 0)
    }

    @Test func recentlyRemovedKeepsContentUntilRetentionEnds() async throws {
        let tmp = TempDir()
        let clock = Clock()
        let store = try await makeStore(tmp, clock: clock)
        let item = try await store.importFile(at: try tmp.file("a.pdf", data: Fixtures.pdf()), origin: .drop)
        let url = try #require(await store.contentURL(for: item.id))

        try await store.markRecentlyRemoved(item.id)
        #expect(await store.visibleItems().isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path), "content must survive for lazy destinations")

        try await store.restore(item.id)
        #expect(await store.visibleItems().count == 1)

        try await store.markRecentlyRemoved(item.id)
        clock.advance(days: 3)
        #expect(await store.purgeRecentlyRemoved(retentionDays: 7) == 0)
        clock.advance(days: 5)
        #expect(await store.purgeRecentlyRemoved(retentionDays: 7) == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func busyItemsCannotBeRemovedOrCleared() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let a = try await store.importFile(at: try tmp.file("a.pdf", data: Fixtures.pdf("a")), origin: .drop)
        let b = try await store.importFile(at: try tmp.file("b.pdf", data: Fixtures.pdf("b")), origin: .drop)
        try await store.beginTransfer(a.id)
        await #expect(throws: ShelfError.itemBusy) { try await store.remove(a.id) }
        let skipped = try await store.clearAll()
        #expect(skipped == 1)
        #expect(await store.visibleItems().map(\.id) == [a.id])
        #expect(await store.item(b.id) == nil)
        await store.endTransfer(a.id)
        try await store.remove(a.id)
        #expect(await store.visibleItems().isEmpty)
        #expect(childCount(store.layout.trash) == 0)
    }
}

@Suite("Shelf export")
struct ShelfExportTests {
    @Test func copyExportVerifiesAndKeepsShelfItem() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let source = try tmp.file("Report.pdf", data: Fixtures.pdf())
        let item = try await store.importFile(at: source, origin: .drop)
        let dest = tmp.dir("dest")

        let placed = try await store.export(item.id, toDirectory: dest, conflict: .fail, mode: .copy)
        #expect(placed.lastPathComponent == "Report.pdf")
        #expect(try Fixtures.sha(placed) == Fixtures.sha(source))
        #expect(await store.visibleItems().count == 1)
        #expect(await store.isBusy(item.id) == false)
    }

    @Test func moveExportRemovesShelfCopyOnlyAfterSuccess() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let source = try tmp.file("a.png", data: Fixtures.png(seed: 4))
        let item = try await store.importFile(at: source, origin: .drop)
        let dest = tmp.dir("dest")

        let placed = try await store.export(item.id, toDirectory: dest, conflict: .fail, mode: .move)
        #expect(try Fixtures.sha(placed) == Fixtures.sha(source))
        #expect(await store.item(item.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.layout.itemDirectory(item.id).path))
    }

    @Test func conflictFailNeverOverwrites() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let item = try await store.importFile(at: try tmp.file("a.pdf", data: Fixtures.pdf("new")), origin: .drop)
        let dest = tmp.dir("dest")
        let existing = dest.appendingPathComponent("a.pdf")
        try Data("precious unrelated file".utf8).write(to: existing)

        await #expect(throws: ShelfError.destinationExists) {
            try await store.export(item.id, toDirectory: dest, conflict: .fail, mode: .move)
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "precious unrelated file")
        #expect(await store.item(item.id) != nil, "failed move must keep the Shelf copy")
        #expect(childCount(dest) == 1, "no temp files left behind")
    }

    @Test func conflictKeepBothUsesNumberedName() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let item = try await store.importFile(at: try tmp.file("a.pdf", data: Fixtures.pdf("new")), origin: .drop)
        let dest = tmp.dir("dest")
        try Data("old".utf8).write(to: dest.appendingPathComponent("a.pdf"))
        try Data("old2".utf8).write(to: dest.appendingPathComponent("a 2.pdf"))

        let placed = try await store.export(item.id, toDirectory: dest, conflict: .keepBoth, mode: .copy)
        #expect(placed.lastPathComponent == "a 3.pdf")
        #expect(try String(contentsOf: dest.appendingPathComponent("a.pdf"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: dest.appendingPathComponent("a 2.pdf"), encoding: .utf8) == "old2")
    }

    @Test func conflictReplaceReplacesOnlyTheTarget() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let source = try tmp.file("a.pdf", data: Fixtures.pdf("new"))
        let item = try await store.importFile(at: source, origin: .drop)
        let dest = tmp.dir("dest")
        try Data("old".utf8).write(to: dest.appendingPathComponent("a.pdf"))
        try Data("neighbour".utf8).write(to: dest.appendingPathComponent("b.pdf"))

        let placed = try await store.export(item.id, toDirectory: dest, conflict: .replace, mode: .copy)
        #expect(try Fixtures.sha(placed) == Fixtures.sha(source))
        #expect(try String(contentsOf: dest.appendingPathComponent("b.pdf"), encoding: .utf8) == "neighbour")
        #expect(childCount(dest) == 2)
    }

    @Test func failedExportRollsBackAndKeepsItem() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let item = try await store.importFile(at: try tmp.file("a.pdf", data: Fixtures.pdf()), origin: .drop)
        let dest = tmp.dir("readonly-dest")
        chmod(dest.path, 0o555)
        defer { chmod(dest.path, 0o755) }

        await #expect(throws: ShelfError.self) {
            try await store.export(item.id, toDirectory: dest, conflict: .fail, mode: .move)
        }
        #expect(await store.item(item.id)?.status == .ready)
        let url = try #require(await store.contentURL(for: item.id))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(childCount(dest) == 0)
        #expect(await store.isBusy(item.id) == false)
    }

    @Test func exportIntoShelfStorageIsRejected() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let item = try await store.importFile(at: try tmp.file("a.pdf", data: Fixtures.pdf()), origin: .drop)
        await #expect(throws: ShelfError.self) {
            try await store.export(item.id, toDirectory: store.layout.items, conflict: .keepBoth, mode: .copy)
        }
        await #expect(throws: ShelfError.self) {
            try await store.export(item.id, toDirectory: store.layout.root, conflict: .keepBoth, mode: .copy)
        }
    }

    @Test func exportOfMissingContentFailsSafely() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let item = try await store.importFile(at: try tmp.file("a.pdf", data: Fixtures.pdf()), origin: .drop)
        let url = try #require(await store.contentURL(for: item.id))
        try FileManager.default.removeItem(at: url)
        await #expect(throws: ShelfError.sourceMissing) {
            try await store.export(item.id, toDirectory: tmp.dir("dest"), conflict: .fail, mode: .move)
        }
        #expect(await store.item(item.id)?.status == .missing)
    }

    @Test func textItemExportsAsTxtFile() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let item = try await store.importText("Ünïcödé note\nsecond line", origin: .note)
        let placed = try await store.export(item.id, toDirectory: tmp.dir("dest"), conflict: .keepBoth, mode: .copy)
        #expect(placed.pathExtension == "txt")
        #expect(try String(contentsOf: placed, encoding: .utf8) == "Ünïcödé note\nsecond line")
    }

    @Test func folderExportCopiesWholeTree() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let folder = tmp.dir("sources/Album")
        try Fixtures.mp3().write(to: folder.appendingPathComponent("01.mp3"))
        try Fixtures.mp3().write(to: folder.appendingPathComponent("02.mp3"))
        let item = try await store.importFile(at: folder, origin: .drop)
        let placed = try await store.export(item.id, toDirectory: tmp.dir("dest"), conflict: .fail, mode: .move)
        #expect(childCount(placed) == 2)
        #expect(await store.item(item.id) == nil)
    }

    @Test func concurrentExportOfSameItemIsRejected() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let item = try await store.importFile(at: try tmp.file("a.pdf", data: Fixtures.pdf()), origin: .drop)
        try await store.beginTransfer(item.id)   // e.g. a drag session in progress
        await #expect(throws: ShelfError.itemBusy) {
            try await store.export(item.id, toDirectory: tmp.dir("dest"), conflict: .fail, mode: .move)
        }
        await store.endTransfer(item.id)
    }
}
