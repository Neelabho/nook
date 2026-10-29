import Foundation
@testable import NookCore

/// A unique temporary directory, removed on deinit. Tests never touch real user data or the
/// production Shelf: every store is rooted inside one of these.
final class TempDir: @unchecked Sendable {
    let url: URL

    init(_ label: String = "NookTests") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // Restore permissions changed by tests so cleanup succeeds.
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let child as URL in e { chmod(child.path, 0o755) }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func dir(_ name: String) -> URL {
        let d = url.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @discardableResult
    func file(_ name: String, in subdir: String = "sources", data: Data) throws -> URL {
        let f = dir(subdir).appendingPathComponent(name)
        try data.write(to: f)
        return f
    }
}

enum Fixtures {
    static func pdf(_ marker: String = "hello") -> Data {
        Data("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\n% \(marker)\n%%EOF\n".utf8)
    }

    static func png(seed: UInt8) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        d.append(contentsOf: (0..<2048).map { UInt8(truncatingIfNeeded: Int($0) &* Int(seed) &+ 7) })
        return d
    }

    static func mp3() -> Data {
        var d = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00])
        d.append(Data(repeating: 0xAB, count: 4096))
        return d
    }

    /// Writes `megabytes` of deterministic data in chunks (never holding it all in memory).
    static func writeLargeFile(at url: URL, megabytes: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var chunk = Data(count: 1 << 20)
        for i in 0..<megabytes {
            chunk.withUnsafeMutableBytes { buf in
                for j in stride(from: 0, to: buf.count, by: 4096) { buf[j] = UInt8(truncatingIfNeeded: i &+ j) }
            }
            try handle.write(contentsOf: chunk)
        }
    }

    static func sha(_ url: URL) throws -> String { try SafeFileOps.sha256(of: url) }
}

/// Simulates a copy that runs out of space halfway, leaving a partial file behind.
struct DiskFullFileOperations: ShelfFileOperations {
    func copyItem(at source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        try data.prefix(data.count / 2).write(to: destination)
        throw POSIXError(.ENOSPC)
    }
    func availableCapacity(near url: URL) -> Int64? { nil }
}

struct LowSpaceFileOperations: ShelfFileOperations {
    var available: Int64
    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }
    func availableCapacity(near url: URL) -> Int64? { available }
}

/// Copies successfully but corrupts one byte, to prove verification rejects bad copies.
struct CorruptingFileOperations: ShelfFileOperations {
    func copyItem(at source: URL, to destination: URL) throws {
        var data = try Data(contentsOf: source)
        if !data.isEmpty { data[data.count - 1] ^= 0xFF }
        try data.write(to: destination)
    }
    func availableCapacity(near url: URL) -> Int64? { nil }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) { value = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(days: Double) { lock.lock(); value = value.addingTimeInterval(days * 86_400); lock.unlock() }
}

func makeStore(_ tmp: TempDir, fileOps: ShelfFileOperations = SystemFileOperations(), clock: Clock? = nil) async throws -> ShelfStore {
    let c = clock ?? Clock()
    let store = ShelfStore(layout: ShelfLayout(root: tmp.dir("shelf")), fileOps: fileOps, spaceMargin: 0, now: { c.now })
    try await store.open()
    return store
}

func childCount(_ url: URL) -> Int {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).count
}
