import Foundation
import LagoonEngine
import os
#if canImport(UIKit)
import UIKit
#endif

/// Where incidents go. Only the app knows what stands behind it.
nonisolated protocol DiagnosticSink: Sendable {
    func submit(_ incident: DiagnosticIncident)
    /// A chance to send what is queued, for foreground transitions.
    func flush()
}

/// Vendor-neutral reporting: a rolling history any thread can append to,
/// and `report`, which attaches it to an incident. Cheap on purpose: the
/// sink does serialization and I/O on its own queue.
nonisolated final class DiagnosticsHub: Sendable {
    private struct State {
        var history: DiagnosticHistory
        var suppressor: IncidentSuppressor
        var sink: DiagnosticSink?
        /// Fields every incident inherits, such as the playback attempt's
        /// facts. An incident's own fields win.
        var ambientFields: [String: DiagnosticValue] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>
    private let uptime: @Sendable () -> TimeInterval
    private let now: @Sendable () -> Date
    private let reportingEnabled: @Sendable () -> Bool

    init(
        history: DiagnosticHistory = DiagnosticHistory(),
        limits: IncidentSuppressor.Limits = .standard,
        sink: DiagnosticSink? = nil,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        now: @escaping @Sendable () -> Date = { Date() },
        reportingEnabled: @escaping @Sendable () -> Bool = { DiagnosticsPreference.isReportingEnabled }
    ) {
        state = OSAllocatedUnfairLock(initialState: State(
            history: history,
            suppressor: IncidentSuppressor(limits: limits),
            sink: sink
        ))
        self.uptime = uptime
        self.now = now
        self.reportingEnabled = reportingEnabled
    }

    /// App wiring. Nil leaves the history running with nowhere to report.
    func configure(sink: DiagnosticSink?) {
        state.withLock { $0.sink = sink }
    }

    /// Pass an empty dictionary to clear.
    func setAmbientFields(_ fields: [String: DiagnosticValue]) {
        let validated = DiagnosticSchema.validated(fields).accepted
        state.withLock { $0.ambientFields = validated }
    }

    /// Periodic history-only work checks this so "off" costs nothing.
    var isReportingEnabled: Bool { reportingEnabled() }

    func record(_ code: DiagnosticEventCode, _ fields: [String: DiagnosticValue] = [:]) {
        guard reportingEnabled() else { return }
        let event = DiagnosticEvent(code: code, uptime: uptime(), fields: fields)
        state.withLock { $0.history.append(event) }
    }

    /// Returns false when reporting is off or the report was suppressed.
    @discardableResult
    func report(
        _ code: DiagnosticIncidentCode,
        level: DiagnosticLevel,
        variant: [String] = [],
        fields: [String: DiagnosticValue] = [:]
    ) -> Bool {
        guard reportingEnabled() else { return false }
        let at = uptime()
        let fingerprint = [code.rawValue] + variant.filter(DiagnosticSchema.isToken)
        let prepared: (sink: DiagnosticSink, incident: DiagnosticIncident)? = state.withLock { state in
            guard let sink = state.sink else { return nil }
            guard case .report(let occurrences) = state.suppressor.decide(fingerprint: fingerprint, now: at) else {
                return nil
            }
            let incident = DiagnosticIncident(
                code: code,
                level: level,
                variant: variant,
                fields: state.ambientFields.merging(fields) { _, own in own },
                history: state.history.snapshot(at: at),
                occurrences: occurrences,
                timestamp: now(),
                uptime: at
            )
            return (sink, incident)
        }
        guard let prepared else { return false }
        prepared.sink.submit(prepared.incident)
        return true
    }

    func flush() {
        state.withLock { $0.sink }?.flush()
    }

    /// Milliseconds since `code` was last recorded, or nil if not buffered.
    func millisecondsSince(_ code: DiagnosticEventCode) -> Double? {
        let at = uptime()
        guard let last = state.withLock({ $0.history.lastUptime(of: code) }) else { return nil }
        return max(at - last, 0) * 1_000
    }

    /// The history as it stands, for tests and the debug HUD.
    func snapshot() -> [DiagnosticEvent] {
        let at = uptime()
        return state.withLock { $0.history.snapshot(at: at) }
    }
}

/// The process-wide hub. The app sets its sink at launch.
nonisolated enum Diagnostics {
    static let shared = DiagnosticsHub()

    static func record(_ code: DiagnosticEventCode, _ fields: [String: DiagnosticValue] = [:]) {
        shared.record(code, fields)
    }

    @discardableResult
    static func report(
        _ code: DiagnosticIncidentCode,
        level: DiagnosticLevel,
        variant: [String] = [],
        fields: [String: DiagnosticValue] = [:]
    ) -> Bool {
        shared.report(code, level: level, variant: variant, fields: fields)
    }
}

/// Memory, thermal and foreground events: recorded into the history, never
/// reported on their own.
nonisolated final class DiagnosticsProcessObserver: Sendable {
    private let tokens: OSAllocatedUnfairLock<[NSObjectProtocol]>

    init(hub: DiagnosticsHub) {
        let center = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []
        tokens.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            hub.record(.appThermal, ["thermal": .string(Self.thermalName(ProcessInfo.processInfo.thermalState))])
        })
        #if canImport(UIKit)
        tokens.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            let memory = MemorySnapshot.current()
            hub.record(.appMemoryWarning, [
                "memoryMB": .double(memory.footprintMB.rounded(toPlaces: 1)),
                "availableMB": .double(memory.availableMB.rounded(toPlaces: 1)),
            ])
        })
        tokens.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            hub.record(.appForeground)
            hub.flush()
        })
        tokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            hub.record(.appBackground)
        })
        #endif
        self.tokens = OSAllocatedUnfairLock(initialState: tokens)
    }

    deinit {
        let center = NotificationCenter.default
        for token in tokens.withLock({ $0 }) {
            center.removeObserver(token)
        }
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "nominal"
        }
    }
}
