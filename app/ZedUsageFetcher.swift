// PR 5-BE — Zed usage fetcher + reader for Zed's own Keychain credential.
//
// Zed differs from every prior provider: it holds no credential of its own.
// It reads the access token Zed itself already stored in the login Keychain
// (an internet-password item for server "zed.dev"), then calls Zed's client
// API for the current user's plan and edit-prediction usage.
//
// The first Keychain read triggers a macOS SecurityAgent prompt ("ClaudeUsage
// Bar wants to use the zed.dev password"); the user must allow it once. We
// never write to Zed's Keychain item.
//
// Auth is unusual: the Authorization header value is "{user_id} {access_token}"
// — the user id and token separated by a SPACE, NOT the "Bearer" scheme.
//
// Data source: GET https://cloud.zed.dev/client/users/me
//
// Response shape (the plan object the tiles consume) is built against Zed's
// open-source client structs. Fields the parser reads:
//   plan.plan_v3                              String enum (zed_free, zed_pro, …)
//   plan.usage.edit_predictions.used / .limit Int
//   plan.subscription_period.ended_at         reset time
//   plan.has_overdue_invoices                 Bool
//   plan.is_account_too_young                 Bool
// Every field is treated as optional and tolerated when absent — this is an
// undocumented internal API and the shape can drift.

import Foundation
import Security

// MARK: - Snapshot

/// Edit-prediction usage from `plan.usage.edit_predictions`.
public struct ZedEditPredictionUsage: Equatable, Sendable {
    public var used: Int
    /// Nil means unlimited (Pro plans have no edit-prediction cap).
    public var limit: Int?

    public init(used: Int = 0, limit: Int? = nil) {
        self.used = used
        self.limit = limit
    }
}

/// A parsed snapshot of the Zed `users/me` plan block.
public struct ZedUsageSnapshot: Equatable, Sendable {
    /// Raw plan identifier, e.g. "zed_free", "zed_pro". Rendered via a
    /// friendly label in the tile.
    public var planV3: String?
    public var editPredictions: ZedEditPredictionUsage?
    /// End of the current subscription/usage period — the edit-prediction
    /// reset time.
    public var periodEndsAt: Date?
    public var hasOverdueInvoices: Bool
    public var isAccountTooYoung: Bool

    public init(
        planV3: String? = nil,
        editPredictions: ZedEditPredictionUsage? = nil,
        periodEndsAt: Date? = nil,
        hasOverdueInvoices: Bool = false,
        isAccountTooYoung: Bool = false
    ) {
        self.planV3 = planV3
        self.editPredictions = editPredictions
        self.periodEndsAt = periodEndsAt
        self.hasOverdueInvoices = hasOverdueInvoices
        self.isAccountTooYoung = isAccountTooYoung
    }
}

/// Credentials read from Zed's own Keychain item.
public struct ZedCredentials: Equatable, Sendable {
    public let userId: String
    public let accessToken: String

    public init(userId: String, accessToken: String) {
        self.userId = userId
        self.accessToken = accessToken
    }

    /// The Authorization header value Zed's client uses: user id and token
    /// separated by a single space (not the Bearer scheme). Returns nil if
    /// either component contains a control character (CR/LF/etc.) that could
    /// split or inject an HTTP header — the values come from Zed's Keychain
    /// item, which we do not control, so they are validated before use.
    public var authorizationHeaderValue: String? {
        guard let uid = RequestSafety.headerValue(userId),
              let tok = RequestSafety.headerValue(accessToken) else {
            return nil
        }
        return "\(uid) \(tok)"
    }
}

public enum ZedUsageParseError: Error, Equatable {
    case invalidJSON
    case unexpectedShape(String)
}

public enum ZedAuthError: Error, Equatable {
    /// No zed.dev item in the Keychain (Zed not logged in, or the user
    /// denied the SecurityAgent prompt).
    case keychainItemMissing
    /// The item exists but lacks a usable account (user id) or token.
    case keychainItemIncomplete
}

// MARK: - Fetcher

public struct ZedUsageFetcher: Sendable {

    public init() {}

    // MARK: Keychain read (Zed's own internet-password item)

    /// Read Zed's access token from the login Keychain. Zed stores it as an
    /// internet-password item for server "zed.dev"; the item's account is the
    /// user id and its data is the access token. We match by server only
    /// (the user id is not known in advance) and read both attributes back.
    ///
    /// The `server` is injectable so tests do not touch the real Keychain.
    public static func readCredentials(server: String = "zed.dev") throws -> ZedCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw ZedAuthError.keychainItemMissing
        }
        guard let dict = item as? [String: Any],
              let account = dict[kSecAttrAccount as String] as? String, !account.isEmpty,
              let data = dict[kSecValueData as String] as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else {
            throw ZedAuthError.keychainItemIncomplete
        }
        return ZedCredentials(userId: account, accessToken: token)
    }

    // MARK: Pure parsing (this is what the fixtures hit)

    /// Parse the JSON body of `users/me`. The plan block may be nested under
    /// a top-level "plan" key, or the whole response may itself be the plan
    /// block depending on Zed's version — accept both by preferring a "plan"
    /// object when present and falling back to the top level.
    public static func parse(_ data: Data) throws -> ZedUsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZedUsageParseError.invalidJSON
        }

        // Prefer an explicit "plan" object; otherwise treat the root as the
        // plan block (tolerant of both documented layouts).
        let plan = (root["plan"] as? [String: Any]) ?? root

        var snap = ZedUsageSnapshot()
        snap.planV3 = plan["plan_v3"] as? String
        snap.hasOverdueInvoices = (plan["has_overdue_invoices"] as? Bool) ?? false
        snap.isAccountTooYoung = (plan["is_account_too_young"] as? Bool) ?? false

        if let usage = plan["usage"] as? [String: Any],
           let edit = usage["edit_predictions"] as? [String: Any] {
            var ep = ZedEditPredictionUsage()
            if let used = edit["used"] as? Int {
                ep.used = used
            } else if let used = safeInt(edit["used"]) {
                ep.used = used
            }
            // limit is Zed's UsageLimit enum, whose wire encoding is
            // non-obvious: Limited(N) serializes as the OBJECT {"limited": N},
            // and Unlimited serializes as the bare STRING "unlimited". A plain
            // integer is NOT what this endpoint returns. Map both: an object
            // with "limited" -> that number; "unlimited" (or absent) -> nil
            // (unlimited). Accept a bare number too, defensively.
            ep.limit = Self.parseUsageLimit(edit["limit"])
            snap.editPredictions = ep
        }

        if let period = plan["subscription_period"] as? [String: Any] {
            snap.periodEndsAt = parseDate(period["ended_at"])
        }

        return snap
    }

    /// Parse Zed's `UsageLimit` from `usage.edit_predictions.limit`. The wire
    /// encoding is a serde externally-tagged enum:
    ///   Limited(i32) -> {"limited": N}   (an OBJECT)
    ///   Unlimited    -> "unlimited"       (a bare STRING)
    /// Returns the numeric cap for Limited, or nil for Unlimited / absent /
    /// unrecognised. Also accepts a bare number defensively.
    public static func parseUsageLimit(_ value: Any?) -> Int? {
        if let obj = value as? [String: Any] {
            if let n = obj["limited"] as? Int { return n }
            if let n = safeInt(obj["limited"]) { return n }
            return nil
        }
        if let s = value as? String {
            // "unlimited" -> nil. A numeric string (header-style) -> its value.
            if s == "unlimited" { return nil }
            return Int(s)
        }
        if let n = value as? Int { return n }
        return safeInt(value)
    }

    /// Convert a value that may be a Double to Int WITHOUT trapping. Int(d)
    /// crashes on a non-finite or out-of-range Double, which a hostile API
    /// could send (e.g. 1e300 as valid JSON); Int(exactly:) returns nil.
    static func safeInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double {
            guard d.isFinite else { return nil }
            return Int(exactly: d.rounded())
        }
        return nil
    }

    /// Parse a reset timestamp that may be an ISO-8601 string or a Unix epoch
    /// integer, tolerating both since the wire format is not guaranteed.
    private static func parseDate(_ value: Any?) -> Date? {
        if let s = value as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let epoch = value as? Int { return Date(timeIntervalSince1970: TimeInterval(epoch)) }
        // A non-finite epoch Double would produce an invalid Date; guard it.
        if let epoch = value as? Double, epoch.isFinite {
            return Date(timeIntervalSince1970: epoch)
        }
        return nil
    }
}
