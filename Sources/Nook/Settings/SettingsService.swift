import Foundation
import NookCore
import Observation
import SwiftUI
import os

let nookLog = Logger(subsystem: "dev.local.nook", category: "app")

/// Abbreviates the user's real home folder as "~". (Inside the sandbox `NSHomeDirectory()` is the
/// container, so it can't be used for display.)
func displayPath(_ url: URL?) -> String {
    guard let path = url?.path else { return "Unavailable" }
    guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return path }
    let home = String(cString: dir)
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// Owns `NookSettings`; persists to UserDefaults as one validated JSON blob.
@MainActor
@Observable
final class SettingsService {
    private(set) var settings: NookSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var listeners: [(NookSettings, NookSettings) -> Void] = []
    static let key = "settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = NookSettings.decode(defaults.data(forKey: Self.key))
    }

    func update(_ change: (inout NookSettings) -> Void) {
        var next = settings
        change(&next)
        next = next.validated()
        guard next != settings else { return }
        let previous = settings
        settings = next
        if let data = next.encoded() { defaults.set(data, forKey: Self.key) }
        for listener in listeners { listener(previous, next) }
    }

    func onChange(_ listener: @escaping (NookSettings, NookSettings) -> Void) {
        listeners.append(listener)
    }

    func binding<T>(_ keyPath: WritableKeyPath<NookSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    var effectiveReduceMotion: Bool {
        settings.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// App-wide diagnostics: a bounded in-memory event log plus point-in-time facts.
@MainActor
@Observable
final class DiagnosticsService {
    @ObservationIgnored let log = DiagnosticsLog()
    var lastReconciliation: ReconciliationReport?
    var displaySummary = "Not measured yet"
    var launchDuration: TimeInterval?

    func record(_ category: String, _ message: String) {
        log.record(category, message)
        nookLog.debug("\(category, privacy: .public): \(Redactor.text(message), privacy: .private)")
    }

    /// Resident memory footprint of this process (what Activity Monitor shows as "Memory").
    static func memoryFootprint() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : nil
    }

    /// Total CPU time consumed by this process so far.
    static func cpuTime() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return secs(usage.ru_utime) + secs(usage.ru_stime)
    }
}
