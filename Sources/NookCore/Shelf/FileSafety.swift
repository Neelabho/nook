import CryptoKit
import Darwin
import Foundation

/// Filename hygiene for untrusted names coming from drags, pastes and promises.
public enum FileNameSanitizer {
    /// Maximum filename length in UTF-8 bytes (APFS/HFS+ limit is 255).
    public static let maxBytes = 255

    /// Returns a single, safe path component derived from `name`.
    ///
    /// - Strips directory separators so the result can never escape its parent.
    /// - Removes control characters and NUL.
    /// - Rejects `.` and `..`.
    /// - Truncates to 255 UTF-8 bytes while keeping the extension.
    public static func sanitize(_ name: String, fallback: String = "Untitled") -> String {
        var cleaned = String(name.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "/", ":": return "-"
            default:
                if CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0 { return " " }
                return Character(scalar)
            }
        })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { cleaned = fallback }
        return truncate(cleaned)
    }

    static func truncate(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        let budget = max(1, maxBytes - suffix.utf8.count)
        var truncated = ""
        for character in base {
            if truncated.utf8.count + String(character).utf8.count > budget { break }
            truncated.append(character)
        }
        if truncated.isEmpty { truncated = "Untitled" }
        return truncated + (suffix.utf8.count < maxBytes ? suffix : "")
    }

    /// "Report.pdf" -> "Report 2.pdf", "Report 3.pdf", ... (Finder-style "Keep Both").
    public static func numberedVariant(of name: String, number: Int) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
        return truncate(candidate)
    }
}

public enum PathContainment {
    /// True when `child` resolves to a location strictly inside `parent`.
    public static func isContained(_ child: URL, in parent: URL) -> Bool {
        let c = child.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let p = parent.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard c.count > p.count else { return false }
        return Array(c.prefix(p.count)) == p
    }
}

public enum SafeFileOps {
    /// Renames `source` to `destination`, failing with EEXIST instead of overwriting.
    /// Both paths must be on the same volume. This is the commit primitive for the Shelf.
    public static func renameExclusive(from source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return -1 }
                return renamex_np(src, dst, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Streaming SHA-256 so large files never need to be loaded into memory.
    public static func sha256(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Total byte size and regular-file count of a file or directory tree (symlinks are not followed).
    public static func footprint(of url: URL) throws -> (bytes: Int64, files: Int) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey]
        let values = try url.resourceValues(forKeys: keys)
        if values.isDirectory != true {
            return (Int64(values.fileSize ?? 0), 1)
        }
        var bytes: Int64 = 0
        var files = 0
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return (0, 0)
        }
        for case let child as URL in enumerator {
            let v = try child.resourceValues(forKeys: keys)
            if v.isRegularFile == true {
                bytes += Int64(v.fileSize ?? 0)
                files += 1
            }
        }
        return (bytes, files)
    }

    public static func volumeIdentifier(for url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    public static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let va = volumeIdentifier(for: a), let vb = volumeIdentifier(for: b) else { return false }
        return va.isEqual(vb)
    }
}
