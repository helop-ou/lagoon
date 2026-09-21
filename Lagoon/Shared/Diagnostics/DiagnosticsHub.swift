import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// Where incidents go once the hub has assembled them. The app decides what
/// stands behind it; the engine and the clients never know.
nonisolated protocol DiagnosticSink: Sendable {
    func submit(_ incident: DiagnosticIncident)
    /// A chance to send what is queued, for foreground transitions.
    func flush()
}

/// The vendor-neutral core of diagnostic reporting: a rolling history any
/// thread can append to, and a `report` that turns a moment into an incident
/// carrying that history. Cheap on purpose. `record` is a lock and an array
/// append; `report` adds a schema pass and a snapshot copy, then hands off to
/// the sink, which does its serialization and I/O on its own queue.
nonisolated final class DiagnosticsHub: Sendable {
    private struct State {
        var history: DiagnosticHistory
        var suppressor: IncidentSuppressor
        var sink: DiagnosticSink?
        /// Fields every incident inherits while they are set: the playback
        /// attempt's identity and facts, so a stall the engine reports
        /// carries the same codec and delivery tags as a failure the
        /// controller reports. An incident's own fields win on conflict.
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

    /// Sets the fields every later incident inherits; pass an empty
    /// dictionary to clear them.
    func setAmbientFields(_ fields: [String: DiagnosticValue]) {
        let validated = DiagnosticSchema.validated(fields).accepted
        state.withLock { $0.ambientFields = validated }
    }

    /// Whether the tester has reporting on. Callers that do periodic work
    /// only for the history (the playback sampler) check this so "off"
    /// costs nothing at all.
    var isReportingEnabled: Bool { reportingEnabled() }

    func record(_ code: DiagnosticEventCode, _ fields: [String: DiagnosticValue] = [:]) {
        guard reportingEnabled() else { return }
        let event = DiagnosticEvent(code: code, uptime: uptime(), fields: fields)
        state.withLock { $0.history.append(event) }
    }

    /// Assembles and submits an incident. Returns whether it was handed to
    /// the sink, which is false when reporting is off or the suppressor
    /// folded it into a later report.
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

    /// Milliseconds since `code` was last recorded, or nil when it is not
    /// in the buffer. Lets a report say "this failure came 800 ms after a
    /// track switch" without the reporter and the switcher knowing each
    /// other.
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

/// The process-wide hub. The app configures its sink at launch; everything
/// else only records and reports.
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

/// Process-level context the history is better for having: memory
/// pressure, thermal state, and foreground transitions. Recorded, never
/// reported; an incident that follows a memory warning carries it.
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
