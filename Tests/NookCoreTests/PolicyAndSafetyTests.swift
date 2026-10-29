import Foundation
import Testing
import UniformTypeIdentifiers
@testable import NookCore

@Suite("Filename safety")
struct FileSafetyTests {
    @Test(arguments: [
        ("../../etc/passwd", "..-..-etc-passwd"),
        ("a/b", "a-b"),
        ("a:b", "a-b"),
        ("  spaced  ", "spaced"),
        ("", "Untitled"),
        (".", "Untitled"),
        ("..", "Untitled"),
        ("line\nbreak\u{0}null", "line break null"),
        (".hidden", ".hidden"),
    ])
    func sanitizes(input: String, expected: String) {
        let out = FileNameSanitizer.sanitize(input)
        #expect(!out.contains("/"))
        #expect(out != "." && out != "..")
        #expect(out == expected)
    }

    @Test func truncatesLongNamesKeepingExtension() {
        let long = String(repeating: "é", count: 300) + ".pdf"
        let out = FileNameSanitizer.sanitize(long)
        #expect(out.utf8.count <= 255)
        #expect(out.hasSuffix(".pdf"))
    }

    @Test func numberedVariants() {
        #expect(FileNameSanitizer.numberedVariant(of: "Report.pdf", number: 2) == "Report 2.pdf")
        #expect(FileNameSanitizer.numberedVariant(of: "Folder", number: 3) == "Folder 3")
        #expect(FileNameSanitizer.numberedVariant(of: "archive.tar.gz", number: 2) == "archive.tar 2.gz")
    }

    @Test func containment() {
        let base = URL(fileURLWithPath: "/tmp/nook-base")
        #expect(PathContainment.isContained(URL(fileURLWithPath: "/tmp/nook-base/a/b"), in: base))
        #expect(!PathContainment.isContained(URL(fileURLWithPath: "/tmp/nook-base/../escape"), in: base))
        #expect(!PathContainment.isContained(URL(fileURLWithPath: "/tmp/nook-base-sibling/x"), in: base))
        #expect(!PathContainment.isContained(base, in: base))
    }

    @Test func renameExclusiveNeverOverwrites() throws {
        let tmp = TempDir()
        let a = try tmp.file("a.txt", data: Data("A".utf8))
        let b = try tmp.file("b.txt", data: Data("B".utf8))
        #expect(throws: POSIXError.self) { try SafeFileOps.renameExclusive(from: a, to: b) }
        #expect(try String(contentsOf: b, encoding: .utf8) == "B")
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    @Test func streamingHashMatchesKnownValue() throws {
        let tmp = TempDir()
        let f = try tmp.file("abc.txt", data: Data("abc".utf8))
        #expect(try SafeFileOps.sha256(of: f) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite("Content sniffing")
struct ContentSnifferTests {
    @Test func detectsCommonFormats() {
        #expect(ContentSniffer.detect(header: Fixtures.pdf()) == .pdf)
        #expect(ContentSniffer.detect(header: Fixtures.png(seed: 1)) == .png)
        #expect(ContentSniffer.detect(header: Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(ContentSniffer.detect(header: Fixtures.mp3()) == .mp3)
        #expect(ContentSniffer.detect(header: Data("plain".utf8)) == nil)
    }

    @Test func zipBasedDocumentIsNotAMismatch() {
        let result = ContentSniffer.Result(declared: UTType(filenameExtension: "docx"), detected: .zip)
        #expect(result.isMismatch == false)
    }

    @Test func executableDisguisedAsImageIsAMismatch() {
        let result = ContentSniffer.Result(declared: .png, detected: .executable)
        #expect(result.isMismatch)
    }
}

@Suite("Cleanup & drag-out policies")
struct PolicyTests {
    func item(_ daysAgo: Double, bytes: Int64, now: Date, status: ShelfItem.Status = .ready) -> ShelfItem {
        ShelfItem(kind: .file, displayName: "x", originalFilename: "x", storedFilename: "x", contentType: "public.data",
                  importedAt: now.addingTimeInterval(-daysAgo * 86_400), byteSize: bytes, status: status, origin: .drop)
    }

    @Test func disabledPolicyNeverSelectsAnything() {
        let now = Date()
        let items = [item(400, bytes: 10, now: now)]
        #expect(CleanupPolicy(enabled: false, maxAgeDays: 1).candidates(in: items, now: now, busy: []).isEmpty)
    }

    @Test func ageBasedSelectionSkipsBusyAndHidden() {
        let now = Date()
        let old = item(40, bytes: 10, now: now)
        let oldBusy = item(50, bytes: 10, now: now)
        let oldHidden = item(60, bytes: 10, now: now, status: .recentlyRemoved)
        let fresh = item(2, bytes: 10, now: now)
        let policy = CleanupPolicy(enabled: true, maxAgeDays: 30)
        let result = policy.candidates(in: [old, oldBusy, oldHidden, fresh], now: now, busy: [oldBusy.id])
        #expect(result.map(\.id) == [old.id])
    }

    @Test func budgetRemovesOldestFirstUntilUnderBudget() {
        let now = Date()
        let a = item(5, bytes: 600, now: now)
        let b = item(4, bytes: 300, now: now)
        let c = item(1, bytes: 300, now: now)
        let policy = CleanupPolicy(enabled: true, maxAgeDays: nil, maxTotalBytes: 700)
        let result = policy.candidates(in: [c, b, a], now: now, busy: [])
        #expect(result.map(\.id) == [a.id])
    }

    @Test func dragOutResolution() {
        #expect(DragOutPolicy.resolve(operationRawValue: 0, endedInsideNook: false) == .keep)          // cancelled / rejected
        #expect(DragOutPolicy.resolve(operationRawValue: 1, endedInsideNook: false) == .accepted)      // copy
        #expect(DragOutPolicy.resolve(operationRawValue: 4, endedInsideNook: false) == .accepted)      // generic
        #expect(DragOutPolicy.resolve(operationRawValue: 2, endedInsideNook: false) == .keep)          // link only
        #expect(DragOutPolicy.resolve(operationRawValue: 1, endedInsideNook: true) == .keep)           // dropped on Nook
    }

    @Test func installLocationUsesRealHomeNotSandboxContainer() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(InstallLocation.isInstalled(URL(fileURLWithPath: "/Users/someone/Applications/Nook.app"), home: home))
        #expect(InstallLocation.isInstalled(URL(fileURLWithPath: "/Applications/Nook.app"), home: home))
        #expect(!InstallLocation.isInstalled(URL(fileURLWithPath: "/Users/someone/Developer/Nook/build/Nook.app"), home: home))
        #expect(!InstallLocation.isInstalled(URL(fileURLWithPath: "/Users/someone/Applications/Nook"), home: home))
        // Regression: in the sandbox, homeDirectoryForCurrentUser is the container, so ~/Applications never matched.
        let container = URL(fileURLWithPath: "/Users/someone/Library/Containers/dev.local.nook/Data")
        #expect(!InstallLocation.isInstalled(URL(fileURLWithPath: "/Users/someone/Applications/Nook.app"), home: container))
        #expect(!InstallLocation.realHomeDirectory.path.contains("/Library/Containers/"))
    }
}
