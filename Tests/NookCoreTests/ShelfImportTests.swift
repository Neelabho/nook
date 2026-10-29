import Foundation
import Testing
@testable import NookCore

@Suite("Shelf import")
struct ShelfImportTests {
    @Test func importsPDFAndLeavesSourceUntouched() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let source = try tmp.file("Report.pdf", data: Fixtures.pdf())
        let before = try Fixtures.sha(source)
        let attrsBefore = try FileManager.default.attributesOfItem(atPath: source.path)

        let item = try await store.importFile(at: source, origin: .drop)

        #expect(item.kind == .file)
        #expect(item.contentType == "com.adobe.pdf")
        #expect(item.storedFilename == "Report.pdf")
        #expect(item.originalFilename == "Report.pdf")
        #expect(item.sha256 == before)
        #expect(item.byteSize == Int64(Fixtures.pdf().count))
        // Source still exists, unchanged.
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Fixtures.sha(source) == before)
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect(attrsBefore[.modificationDate] as? Date == attrsAfter[.modificationDate] as? Date)
        // Stored copy matches.
        let stored = try #require(await store.contentURL(for: item.id))
        #expect(try Fixtures.sha(stored) == before)
        // Sidecar exists; staging is empty.
        #expect(FileManager.default.fileExists(atPath: store.layout.sidecar(item.id).path))
        #expect(childCount(store.layout.staging) == 0)
    }

    @Test func importsSeveralImagesConcurrently() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        var sources: [URL] = []
        for i in 1...6 { sources.append(try tmp.file("photo-\(i).png", data: Fixtures.png(seed: UInt8(i)))) }

        let items = try await withThrowingTaskGroup(of: ShelfItem.self) { group in
            for s in sources { group.addTask { try await store.importFile(at: s, origin: .drop) } }
            var out: [ShelfItem] = []
            for try await item in group { out.append(item) }
            return out
        }
        #expect(items.count == 6)
        #expect(Set(items.map(\.id)).count == 6)
        #expect(items.allSatisfy { $0.contentType == "public.png" })
        #expect(await store.visibleItems().count == 6)
        for item in items {
            let url = try #require(await store.contentURL(for: item.id))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(childCount(store.layout.staging) == 0)
    }

    @Test func importsAudioAndDetectsTypeFromContent() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let source = try tmp.file("song.mp3", data: Fixtures.mp3())
        let item = try await store.importFile(at: source, origin: .drop)
        #expect(item.contentType == "public.mp3")
        #expect(item.typeMismatch == false)
    }

    @Test func flagsContentThatDoesNotMatchItsExtension() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let source = try tmp.file("invoice.pdf", data: Fixtures.png(seed: 3))
        let item = try await store.importFile(at: source, origin: .drop)
        #expect(item.typeMismatch)
        #expect(item.contentType == "public.png")
        #expect(item.declaredContentType == "com.adobe.pdf")
    }

    @Test func importsLargeFileWithVerification() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let source = tmp.dir("sources").appendingPathComponent("big.bin")
        try Fixtures.writeLargeFile(at: source, megabytes: 96)
        let before = try Fixtures.sha(source)
        let item = try await store.importFile(at: source, origin: .drop)
        #expect(item.byteSize == Int64(96 * 1024 * 1024))
        #expect(item.sha256 == before)
        let stored = try #require(await store.contentURL(for: item.id))
        #expect(try Fixtures.sha(stored) == before)
    }

    @Test func identicalNamesWithDifferentContentAreBothKept() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let a = try tmp.file("notes.pdf", in: "a", data: Fixtures.pdf("A"))
        let b = try tmp.file("notes.pdf", in: "b", data: Fixtures.pdf("B"))
        let first = try await store.importFile(at: a, origin: .drop)
        let second = try await store.importFile(at: b, origin: .drop)
        #expect(first.id != second.id)
        #expect(first.storedFilename == second.storedFilename)
        let u1 = try #require(await store.contentURL(for: first.id))
        let u2 = try #require(await store.contentURL(for: second.id))
        #expect(u1 != u2)
        #expect(try Fixtures.sha(u1) == Fixtures.sha(a))
        #expect(try Fixtures.sha(u2) == Fixtures.sha(b))
    }

    @Test func identicalFileIsSkippedOrKeptPerPolicy() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let a = try tmp.file("same.pdf", data: Fixtures.pdf())
        let first = try await store.importFile(at: a, origin: .drop)
        await #expect(throws: ShelfError.duplicate(existing: first.id)) {
            try await store.importFile(at: a, origin: .drop, duplicatePolicy: .skipIdentical)
        }
        #expect(childCount(store.layout.staging) == 0)
        let again = try await store.importFile(at: a, origin: .drop, duplicatePolicy: .keepBoth)
        #expect(again.id != first.id)
        #expect(await store.visibleItems().count == 2)
    }

    @Test func importsUnicodeText() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let text = "Grüße aus Zürich 🇨🇭\nこんにちは世界 — “quotes” & emoji 🎧\nلغة عربية"
        let item = try await store.importText(text, origin: .paste)
        #expect(item.kind == .text)
        #expect(item.displayName == "Grüße aus Zürich 🇨🇭")
        #expect(try await store.readText(item.id) == text)
        #expect(item.textPreview?.contains("こんにちは") == true)
        let url = try #require(await store.contentURL(for: item.id))
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test func rejectsEmptyAndOversizedText() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        await #expect(throws: ShelfError.self) { try await store.importText("   \n ", origin: .paste) }
        let huge = String(repeating: "a", count: ShelfStore.maxTextBytes + 1)
        await #expect(throws: ShelfError.textTooLarge) { try await store.importText(huge, origin: .paste) }
    }

    @Test func handlesUnusualCharactersInFilenames() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let weird = "Résumé – draft (final) [v2] 🎉 ;$(rm -rf) `x` 'q' \"d\".pdf"
        let source = try tmp.file(weird, data: Fixtures.pdf())
        let item = try await store.importFile(at: source, origin: .drop)
        #expect(item.storedFilename == weird)
        let stored = try #require(await store.contentURL(for: item.id))
        #expect(PathContainment.isContained(stored, in: store.layout.items))
        #expect(FileManager.default.fileExists(atPath: stored.path))
    }

    @Test func importsReadOnlyFileAndLeavesItReadOnly() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let source = try tmp.file("locked.pdf", data: Fixtures.pdf())
        chmod(source.path, 0o444)
        let item = try await store.importFile(at: source, origin: .drop)
        #expect(item.status == .ready)
        let perms = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? Int
        #expect(perms == 0o444)
        // The Shelf must be able to delete its own copy later even though the source was read-only.
        try await store.remove(item.id)
        #expect(await store.visibleItems().isEmpty)
    }

    @Test func missingSourceFailsCleanly() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let ghost = tmp.dir("sources").appendingPathComponent("gone.pdf")
        await #expect(throws: ShelfError.sourceMissing) { try await store.importFile(at: ghost, origin: .drop) }
        #expect(await store.visibleItems().isEmpty)
        #expect(childCount(store.layout.staging) == 0)
        #expect(childCount(store.layout.items) == 0)
    }

    @Test func unreadableSourceReportsPermissionError() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let source = try tmp.file("secret.pdf", data: Fixtures.pdf())
        chmod(source.path, 0o000)
        defer { chmod(source.path, 0o644) }
        await #expect(throws: ShelfError.permissionDenied) { try await store.importFile(at: source, origin: .drop) }
        #expect(childCount(store.layout.staging) == 0)
        #expect(childCount(store.layout.items) == 0)
    }

    @Test func diskFullDuringCopyRollsBack() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp, fileOps: DiskFullFileOperations())
        let source = try tmp.file("big.pdf", data: Fixtures.pdf(String(repeating: "x", count: 10_000)))
        let before = try Fixtures.sha(source)
        await #expect(throws: ShelfError.insufficientSpace(needed: 0, available: 0)) {
            try await store.importFile(at: source, origin: .drop)
        }
        #expect(childCount(store.layout.staging) == 0)
        #expect(childCount(store.layout.items) == 0)
        #expect(try Fixtures.sha(source) == before)
    }

    @Test func insufficientFreeSpaceIsDetectedBeforeCopying() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp, fileOps: LowSpaceFileOperations(available: 10))
        let source = try tmp.file("doc.pdf", data: Fixtures.pdf())
        await #expect(throws: ShelfError.self) { try await store.importFile(at: source, origin: .drop) }
        #expect(childCount(store.layout.staging) == 0)
    }

    @Test func corruptedCopyIsRejectedByVerification() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp, fileOps: CorruptingFileOperations())
        let source = try tmp.file("doc.pdf", data: Fixtures.pdf())
        await #expect(throws: ShelfError.verificationFailed) { try await store.importFile(at: source, origin: .drop) }
        #expect(childCount(store.layout.staging) == 0)
        #expect(childCount(store.layout.items) == 0)
    }

    @Test func importsFolders() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let folder = tmp.dir("sources/Project")
        try Fixtures.pdf().write(to: folder.appendingPathComponent("a.pdf"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Fixtures.png(seed: 1).write(to: folder.appendingPathComponent("sub/b.png"))
        let item = try await store.importFile(at: folder, origin: .drop)
        #expect(item.kind == .folder)
        #expect(item.fileCount == 2)
        let stored = try #require(await store.contentURL(for: item.id))
        #expect(FileManager.default.fileExists(atPath: stored.appendingPathComponent("sub/b.png").path))
    }

    @Test func refusesToReimportItsOwnStoredFiles() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let item = try await store.importFile(at: try tmp.file("a.pdf", data: Fixtures.pdf()), origin: .drop)
        let stored = try #require(await store.contentURL(for: item.id))
        await #expect(throws: ShelfError.self) { try await store.importFile(at: stored, origin: .drop) }
        #expect(await store.visibleItems().count == 1)
    }

    @Test func cancelledImportLeavesNoTrace() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let source = tmp.dir("sources").appendingPathComponent("big.bin")
        try Fixtures.writeLargeFile(at: source, megabytes: 64)
        let task = Task { try await store.importFile(at: source, origin: .drop) }
        task.cancel()
        _ = await task.result
        // Whether the cancel landed before or after commit, there's never a partial item.
        #expect(childCount(store.layout.staging) == 0)
        let visible = await store.visibleItems()
        for item in visible {
            let url = try #require(await store.contentURL(for: item.id))
            #expect(try Fixtures.sha(url) == Fixtures.sha(source))
        }
    }
}
