import Foundation
import Testing
@testable import NookCore

@Suite("Shelf at scale")
struct ShelfScaleTests {
    @Test func manyItemsImportReopenAndReconcileQuickly() async throws {
        let tmp = TempDir()
        let store = try await makeStore(tmp)
        let count = 500
        let sources = tmp.dir("many")
        for i in 0..<count {
            try Data("item \(i) ".utf8 + Data(repeating: UInt8(i % 251), count: 2048)).write(to: sources.appendingPathComponent("file-\(i).bin"))
        }
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask { _ = try await store.importFile(at: sources.appendingPathComponent("file-\(i).bin"), origin: .drop) }
                if i % 16 == 15 { try await group.waitForAll() }    // bounded parallelism
            }
            try await group.waitForAll()
        }
        let importTime = ContinuousClock.now - start
        #expect(await store.visibleItems().count == count)

        let reopenStart = ContinuousClock.now
        let reopened = ShelfStore(layout: store.layout, spaceMargin: 0)
        let report = try await reopened.open()
        let reopenTime = ContinuousClock.now - reopenStart
        #expect(!report.needsAttention)
        #expect(await reopened.visibleItems().count == count)

        // Worst case: index lost, everything rebuilt from sidecars.
        try FileManager.default.removeItem(at: store.layout.index)
        let rebuildStart = ContinuousClock.now
        let rebuilt = ShelfStore(layout: store.layout, spaceMargin: 0)
        let rebuildReport = try await rebuilt.open()
        let rebuildTime = ContinuousClock.now - rebuildStart
        #expect(rebuildReport.recoveredItems == count)

        let indexSize = (try? FileManager.default.attributesOfItem(atPath: store.layout.index.path)[.size] as? Int) ?? 0
        print("[scale] \(count) imports: \(importTime); reopen: \(reopenTime); rebuild from sidecars: \(rebuildTime); index \(indexSize / 1024) KB")
        #expect(reopenTime < .seconds(2))
    }
}
