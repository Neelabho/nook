import Foundation

/// On-disk layout of the Shelf. Everything lives under one application-managed root,
/// separate from binaries, caches and logs.
///
/// ```
/// <root>/
///   shelf-index.json      ordered index (cache; rebuildable from sidecars)
///   items/<uuid>/         one committed item per directory
///       item.json         sidecar metadata
///       <stored name>     the content (file, folder or UTF-8 text)
///   staging/<txn>/        in-flight imports; never visible; wiped on launch
///   trash/<uuid>/         items being deleted; wiped on launch
///   incoming/<txn>/       files delivered by drag promises, waiting to be imported
/// ```
public struct ShelfLayout: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public var index: URL { root.appendingPathComponent("shelf-index.json") }
    public var items: URL { root.appendingPathComponent("items", isDirectory: true) }
    public var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }
    public var trash: URL { root.appendingPathComponent("trash", isDirectory: true) }
    public var incoming: URL { root.appendingPathComponent("incoming", isDirectory: true) }

    public func itemDirectory(_ id: UUID) -> URL { items.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func sidecar(_ id: UUID) -> URL { itemDirectory(id).appendingPathComponent(ShelfLayout.sidecarName) }
    public func content(of item: ShelfItem) -> URL {
        itemDirectory(item.id).appendingPathComponent(item.storedFilename, isDirectory: item.kind == .folder)
    }

    public static let sidecarName = "item.json"

    public static func defaultRoot(productName: String = "Nook") throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent(productName, isDirectory: true).appendingPathComponent("Shelf", isDirectory: true)
    }
}

/// File operations the Shelf depends on, injectable so tests can simulate
/// disk-full, permission and interruption failures.
public protocol ShelfFileOperations: Sendable {
    func copyItem(at source: URL, to destination: URL) throws
    func availableCapacity(near url: URL) -> Int64?
}

public struct SystemFileOperations: ShelfFileOperations {
    public init() {}
    public func copyItem(at source: URL, to destination: URL) throws {
        // FileManager uses copyfile(3) with APFS clone support: streaming, never loads the file into memory.
        try FileManager.default.copyItem(at: source, to: destination)
    }
    public func availableCapacity(near url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}

struct ShelfIndexFile: Codable {
    var version: Int
    var items: [ShelfItem]
}

enum JSONCoding {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) { return date }
            if let date = try? Date(s, strategy: .iso8601) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized date")
        }
        return d
    }
}

/// What `open()` found and repaired. Surfaced in Diagnostics and, when non-trivial, in the Shelf UI.
public struct ReconciliationReport: Equatable, Sendable {
    public var discardedIncompleteImports = 0
    public var purgedPendingDeletions = 0
    public var recoveredItems = 0
    public var missingItems = 0
    public var unrecognizedEntries = 0
    public var indexWasCorrupt = false
    public var importedPendingPromises = 0

    public init() {}

    public var needsAttention: Bool {
        recoveredItems > 0 || missingItems > 0 || indexWasCorrupt || unrecognizedEntries > 0
    }

    public var summary: String {
        var parts: [String] = []
        if indexWasCorrupt { parts.append("the Shelf index was damaged and was rebuilt from item records") }
        if recoveredItems > 0 { parts.append("\(recoveredItems) item(s) were recovered") }
        if missingItems > 0 { parts.append("\(missingItems) item(s) are missing their stored content") }
        if unrecognizedEntries > 0 { parts.append("\(unrecognizedEntries) unrecognized entr(ies) were left untouched") }
        if discardedIncompleteImports > 0 { parts.append("\(discardedIncompleteImports) incomplete import(s) were cleaned up (originals were never modified)") }
        if importedPendingPromises > 0 { parts.append("\(importedPendingPromises) received file(s) were added") }
        return parts.isEmpty ? "Shelf storage is consistent." : parts.joined(separator: "; ").capitalizedFirst + "."
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
