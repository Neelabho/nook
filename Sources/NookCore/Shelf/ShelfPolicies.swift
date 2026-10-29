import Foundation

/// Optional storage cleanup. Disabled by default; never applied without the user confirming
/// the exact list of candidates.
public struct CleanupPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var maxAgeDays: Int?
    public var maxTotalBytes: Int64?

    public init(enabled: Bool = false, maxAgeDays: Int? = 30, maxTotalBytes: Int64? = nil) {
        self.enabled = enabled
        self.maxAgeDays = maxAgeDays
        self.maxTotalBytes = maxTotalBytes
    }

    /// Items the policy would remove, oldest first. Busy items and hidden (recently removed) items
    /// are never candidates; the latter have their own retention period.
    public func candidates(in items: [ShelfItem], now: Date, busy: Set<UUID>) -> [ShelfItem] {
        guard enabled else { return [] }
        let eligible = items
            .filter { $0.isVisible && !busy.contains($0.id) }
            .sorted { $0.importedAt < $1.importedAt }
        var selected: [UUID] = []
        if let days = maxAgeDays, days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            selected = eligible.filter { $0.importedAt < cutoff }.map(\.id)
        }
        if let budget = maxTotalBytes, budget >= 0 {
            var total = items.filter(\.isVisible).reduce(Int64(0)) { $0 + ($1.byteSize ?? 0) }
            total -= eligible.filter { selected.contains($0.id) }.reduce(Int64(0)) { $0 + ($1.byteSize ?? 0) }
            for item in eligible where total > budget && !selected.contains(item.id) {
                selected.append(item.id)
                total -= item.byteSize ?? 0
            }
        }
        return eligible.filter { selected.contains($0.id) }
    }
}

/// How a drag-out result is interpreted. AppKit reports the operation the destination
/// performed; `[]` means cancelled or rejected.
public enum DragOutResolution: Equatable, Sendable {
    /// Cancelled, rejected, or unknown: the item stays exactly as it was.
    case keep
    /// The destination reported accepting the data; apply the user's after-drag preference.
    case accepted
}

public enum AfterDragOutBehavior: String, Codable, Sendable, CaseIterable {
    /// Leave the item on the Shelf.
    case keep
    /// Hide it from the Shelf but retain the stored file for the retention period (undoable).
    case hideRecoverably
}

public enum DragOutPolicy {
    /// - Parameter operationRawValue: `NSDragOperation.rawValue` reported by `draggingSession(_:endedAt:operation:)`.
    /// - Parameter endedInsideNook: drops back onto Nook itself never count as a transfer.
    public static func resolve(operationRawValue: UInt, endedInsideNook: Bool) -> DragOutResolution {
        if endedInsideNook { return .keep }
        // NSDragOperation: copy = 1, link = 2, generic = 4, private = 8, move = 16, delete = 32.
        let copy: UInt = 1, generic: UInt = 4, move: UInt = 16
        let accepted = operationRawValue & (copy | generic | move)
        return accepted != 0 ? .accepted : .keep
    }
}
