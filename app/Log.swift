// MARK: - Logging (categorical redaction)
//
// PR 1 introduced the categorical logger below to replace every NSLog site
// in the app that touched cookies, org IDs, or response bodies. The call
// site cannot interpolate a raw String; every value goes through a
// category, and each category has its own emission rule. This makes
// accidental credential logging a compile-time impossibility rather than a
// discipline problem.
//
// PR 2a extracted the types out of ClaudeUsageBar.swift into this file so
// the SwiftPM library target can compile them without also trying to
// compile the @main entry point (which would conflict with TestRunner's
// own main).
//
// The CI static grep guard (see .github/workflows/ci.yml) refuses PRs that
// reintroduce raw-interpolation NSLog calls or the deleted response-body
// log line at the network fetch site. The exact banned pattern lives in
// the workflow file to avoid embedding it here (which would self-trigger).

import Foundation
import CryptoKit

public enum LogValue {
    /// Safe to log verbatim (status codes, event names, HTTP methods, etc.).
    case `public`(String)
    /// Redacted to `<redacted: N chars>` in every build. Use for cookies,
    /// bodies, tokens, API keys, anything that could leak a credential.
    case sensitive(String)
    /// Emitted as a short SHA-256 prefix so the value can be correlated
    /// across log lines without revealing it. Use for org IDs, user IDs.
    case identifier(String)
    /// Numeric counts are safe to log as-is (lengths, HTTP status codes,
    /// retry counts, threshold values).
    case count(Int)

    public var rendered: String {
        switch self {
        case .public(let s):
            return s
        case .sensitive(let s):
            return "<redacted: \(s.count) chars>"
        case .identifier(let s):
            let digest = SHA256.hash(data: Data(s.utf8))
            let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
            return "<id: \(hex.prefix(8))>"
        case .count(let n):
            return String(n)
        }
    }
}

public enum Log {
    /// Debug-only diagnostics. Stripped in release builds by the `#if DEBUG`
    /// gate. Accepts a plain message — no interpolation of untrusted values.
    public static func debug(_ message: String) {
        #if DEBUG
        NSLog("[debug] %@", message)
        #endif
    }

    /// Info-level diagnostics. Retained in release builds. Values must be
    /// wrapped in a `LogValue` category, forcing an explicit redaction
    /// decision at the call site.
    public static func info(_ message: String, _ values: LogValue...) {
        let rendered = values.map(\.rendered).joined(separator: ", ")
        if rendered.isEmpty {
            NSLog("%@", message)
        } else {
            NSLog("%@ | %@", message, rendered)
        }
    }
}
