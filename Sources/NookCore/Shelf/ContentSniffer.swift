import Foundation
import UniformTypeIdentifiers

/// Determines a file's type from its leading bytes rather than trusting its name.
///
/// The Shelf never executes or opens files, so this is used for presentation and to
/// flag a mismatch between what a file claims to be and what it looks like.
public enum ContentSniffer {
    public struct Result: Equatable, Sendable {
        /// Type implied by the filename extension (untrusted).
        public var declared: UTType?
        /// Type detected from file content, when recognizable.
        public var detected: UTType?
        /// True when both are known and the detected type does not conform to the declared one.
        public var isMismatch: Bool {
            guard let declared, let detected else { return false }
            if detected.conforms(to: declared) || declared.conforms(to: detected) { return false }
            // ZIP is a container for many document formats (docx, xlsx, epub, pages…).
            if detected == .zip {
                return [.image, .audiovisualContent, .pdf, .text, .executable].contains { declared.conforms(to: $0) }
            }
            // Different flavours of the same broad kind (e.g. a .jpg that is really a PNG) are not suspicious enough
            // to flag; executables and scripts posing as anything else are.
            for broad in [UTType.image, .audio, .movie] where declared.conforms(to: broad) && detected.conforms(to: broad) {
                return false
            }
            return true
        }
        /// The type we display: content-derived when available, otherwise extension-derived.
        public var effective: UTType {
            detected ?? declared ?? .data
        }
    }

    public static func sniff(fileAt url: URL) -> Result {
        let declared = UTType(filenameExtension: url.pathExtension)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let packageType = declared.flatMap { $0.conforms(to: .package) ? $0 : nil }
            return Result(declared: packageType ?? .folder, detected: packageType ?? .folder)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Result(declared: declared, detected: nil)
        }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 64)) ?? Data()
        return Result(declared: declared, detected: detect(header: header))
    }

    public static func detect(header: Data) -> UTType? {
        let bytes = [UInt8](header)
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset..<offset + prefix.count]) == prefix
        }
        if starts([0x25, 0x50, 0x44, 0x46, 0x2D]) { return .pdf }                        // %PDF-
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if starts([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts([0x47, 0x49, 0x46, 0x38]) { return .gif }                              // GIF8
        if starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], at: 8) { return .webP }
        if starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x41, 0x56, 0x45], at: 8) { return .wav }
        if starts([0x49, 0x44, 0x33]) || starts([0xFF, 0xFB]) || starts([0xFF, 0xF3]) || starts([0xFF, 0xF2]) { return .mp3 }
        if starts([0x66, 0x4C, 0x61, 0x43]) { return UTType("org.xiph.flac") ?? .audio }   // fLaC
        if starts([0x4F, 0x67, 0x67, 0x53]) { return UTType("org.xiph.ogg") ?? .audio }    // OggS
        if starts([0x46, 0x4F, 0x52, 0x4D]) && (starts([0x41, 0x49, 0x46, 0x46], at: 8) || starts([0x41, 0x49, 0x46, 0x43], at: 8)) { return .aiff }
        if starts([0x66, 0x74, 0x79, 0x70], at: 4) {                                      // ISO base media: ftyp
            let brand = bytes.count >= 12 ? String(bytes: bytes[8..<12], encoding: .ascii) ?? "" : ""
            switch brand {
            case "heic", "heix", "mif1", "msf1", "heim", "heis": return .heic
            case "M4A ", "M4B ", "M4P ": return .mpeg4Audio
            case "qt  ": return .quickTimeMovie
            default: return .mpeg4Movie
            }
        }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return .zip }                              // also docx/xlsx/epub containers
        if starts([0xCF, 0xFA, 0xED, 0xFE]) || starts([0xCA, 0xFE, 0xBA, 0xBE]) { return .executable }
        if starts([0x23, 0x21]) { return .shellScript }                                   // #!
        return nil
    }
}
