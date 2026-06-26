import Foundation

/// Minimal logging that avoids leaking sensitive data into the unified system
/// log. Verbose diagnostics are OFF by default and never include secrets
/// (tokens, cookies) or user content (status text). Set `AUTOAFK_DEBUG=1` in
/// the environment to enable verbose, name-level diagnostics for support.
enum Log {
    static let verbose = ProcessInfo.processInfo.environment["AUTOAFK_DEBUG"] == "1"

    /// Detailed, possibly identifying diagnostics (workspace names, counts).
    /// Suppressed unless AUTOAFK_DEBUG=1.
    static func debug(_ message: @autoclosure () -> String) {
        if verbose { NSLog("[AutoAFK] \(message())") }
    }

    /// Low-volume, non-sensitive status/error messages. Always logged.
    static func info(_ message: String) {
        NSLog("[AutoAFK] \(message)")
    }
}
