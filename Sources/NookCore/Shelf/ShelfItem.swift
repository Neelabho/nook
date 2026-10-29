import Foundation

/// Persistent metadata for one Shelf entry.
///
/// Each committed item lives in `items/<id>/` and carries a sidecar `item.json` with this
/// record, so the index file can always be rebuilt from disk.
public struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, folder, text }

    public enum Status: String, Codable, Sendable {
        /// Stored and available.
        case ready
        /// Restored from disk during reconciliation (its index entry had been lost).
        case recovered
        /// The index knows about it but its stored content is gone.
        case missing
        /// Hidden after a confirmed drag-out; content retained until the retention period ends.
        case recentlyRemoved
    }

    public var id: UUID
    public var kind: Kind
    public var displayName: String
    /// The name the item had when it arrived (untrusted; display only).
    public var originalFilename: String?
    /// Sanitized name of the content inside the item's directory.
    public var storedFilename: String
    /// Content-derived UTType identifier (falls back to extension-derived).
    public var contentType: String
    /// Extension-derived UTType identifier.
    public var declaredContentType: String?
    public var typeMismatch: Bool
    public var importedAt: Date
    public var byteSize: Int64?
    public var fileCount: Int?
    public var sha256: String?
    public var status: Status
    public var removedAt: Date?
    /// For text items: a short preview. The full text is stored on disk as UTF-8.
    public var textPreview: String?
    public var origin: Origin

    public enum Origin: String, Codable, Sendable {
        case drop, filePicker, paste, note, assistant, promise, recovered
    }

    public init(
        id: UUID = UUID(),
        kind: Kind,
        displayName: String,
        originalFilename: String?,
        storedFilename: String,
        contentType: String,
        declaredContentType: String? = nil,
        typeMismatch: Bool = false,
        importedAt: Date = Date(),
        byteSize: Int64? = nil,
        fileCount: Int? = nil,
        sha256: String? = nil,
        status: Status = .ready,
        removedAt: Date? = nil,
        textPreview: String? = nil,
        origin: Origin
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.contentType = contentType
        self.declaredContentType = declaredContentType
        self.typeMismatch = typeMismatch
        self.importedAt = importedAt
        self.byteSize = byteSize
        self.fileCount = fileCount
        self.sha256 = sha256
        self.status = status
        self.removedAt = removedAt
        self.textPreview = textPreview
        self.origin = origin
    }

    /// Path of the stored content relative to the Shelf root.
    public var relativeStoragePath: String { "items/\(id.uuidString)/\(storedFilename)" }

    public var isVisible: Bool { status != .recentlyRemoved }

    public static func makePreview(_ text: String, limit: Int = 400) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

public enum ShelfError: Error, Equatable, Sendable, LocalizedError {
    case sourceMissing
    case permissionDenied
    case unsupportedItem(String)
    case insufficientSpace(needed: Int64, available: Int64)
    case verificationFailed
    case writeFailed(String)
    case duplicate(existing: UUID)
    case itemNotFound
    case itemBusy
    case destinationExists
    case destinationInvalid(String)
    case cancelled
    case textTooLarge
    case storageUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing: return "The original item is no longer available."
        case .permissionDenied: return "Nook doesn't have permission to read this item."
        case .unsupportedItem(let why): return "This item can't be added to the Shelf (\(why))."
        case .insufficientSpace(let needed, let available):
            guard needed > 0 else { return "The disk is full. Free up some space and try again. The original is untouched." }
            let f = ByteCountFormatter()
            return "Not enough disk space (needs \(f.string(fromByteCount: needed)), \(f.string(fromByteCount: available)) free)."
        case .verificationFailed: return "The copy could not be verified, so it was discarded. The original is untouched."
        case .writeFailed(let why): return "Writing failed: \(why)"
        case .duplicate: return "This item is already on the Shelf."
        case .itemNotFound: return "That Shelf item no longer exists."
        case .itemBusy: return "That item is being transferred. Try again in a moment."
        case .destinationExists: return "An item with that name already exists at the destination."
        case .destinationInvalid(let why): return "The destination can't be used (\(why))."
        case .cancelled: return "The operation was cancelled."
        case .textTooLarge: return "That text is too large for a Shelf note."
        case .storageUnavailable(let why): return "Shelf storage is unavailable: \(why)"
        }
    }

    static func from(_ error: Error) -> ShelfError {
        if let shelf = error as? ShelfError { return shelf }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .sourceMissing
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .permissionDenied
            case NSFileWriteOutOfSpaceError: return .insufficientSpace(needed: 0, available: 0)
            case NSFileWriteFileExistsError: return .destinationExists
            default: break
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                return from(underlying)
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case ENOENT: return .sourceMissing
            case EACCES, EPERM: return .permissionDenied
            case ENOSPC, EDQUOT: return .insufficientSpace(needed: 0, available: 0)
            case EEXIST: return .destinationExists
            default: break
            }
        }
        return .writeFailed(ns.localizedDescription)
    }
}
