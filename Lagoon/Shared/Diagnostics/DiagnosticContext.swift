import Foundation
import LagoonEngine
#if canImport(UIKit)
import UIKit
#endif

/// Build, OS, device class and channel. Nothing here identifies an install
/// or a person.
nonisolated struct DiagnosticContext: Equatable, Sendable {
    let bundleIdentifier: String
    let appVersion: String
    let build: String
    let osName: String
    let osVersion: String
    let deviceModel: String
    let isSimulator: Bool
    /// `debug`, `testflight`, or `appstore`.
    let environment: String
    let engineVersion: String

    /// Sentry's release identity: `bundle@version+build`.
    var release: String { "\(bundleIdentifier)@\(appVersion)+\(build)" }

    /// Main actor because the iPad check reads `UIDevice`.
    @MainActor
    static func current(engineVersion: String) -> DiagnosticContext {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var osVersion = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 {
            osVersion += ".\(version.patchVersion)"
        }
        return DiagnosticContext(
            bundleIdentifier: bundle.bundleIdentifier ?? "ee.helop.lagoon",
            appVersion: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            osName: Self.osName,
            osVersion: osVersion,
            deviceModel: Self.deviceModel,
            isSimulator: Self.isSimulator,
            environment: Self.environment(for: bundle),
            engineVersion: engineVersion
        )
    }

    @MainActor
    private static var osName: String {
        #if os(tvOS)
        return "tvOS"
        #elseif os(iOS)
        #if canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom == .pad { return "iPadOS" }
        #endif
        return "iOS"
        #else
        return "unknown"
        #endif
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// `AppleTV14,1`; the simulator reports its model via the environment,
    /// not `hw.machine`.
    private static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           DiagnosticSchema.isToken(simulated) {
            return simulated
        }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 1 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        let model = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return DiagnosticSchema.isToken(model) ? model : "unknown"
    }

    private static func environment(for bundle: Bundle) -> String {
        #if DEBUG
        return "debug"
        #else
        if bundle.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return "testflight"
        }
        return "appstore"
        #endif
    }
}

/// Release builds report unless turned off in Settings. Debug builds stay
/// quiet unless run with `-diagnostics.reportingEnabled YES`, to spare the
/// quota.
nonisolated enum DiagnosticsPreference {
    static let reportingEnabledKey = "diagnostics.reportingEnabled"

    static var defaultReportingEnabled: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    static var isReportingEnabled: Bool {
        isReportingEnabled(storedValue: UserDefaults.standard.object(forKey: reportingEnabledKey))
    }

    /// The toggle stores a Bool, a launch argument a string. Both count;
    /// anything else means "not set".
    static func isReportingEnabled(storedValue: Any?) -> Bool {
        switch storedValue {
        case let flag as Bool:
            return flag
        case let number as NSNumber:
            return number.boolValue
        case let text as String:
            return (text as NSString).boolValue
        default:
            return defaultReportingEnabled
        }
    }
}
