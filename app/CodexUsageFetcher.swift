// PR 3-BE — Codex usage fetcher.
//
// Mirrors AnthropicUsageFetcher (PR 2b): a Sendable value type with no
// observable state, no delegates, no side effects. It exposes a pure
// static parser that turns the raw bytes of a
// `GET https://chatgpt.com/backend-api/wham/usage` response into a
// CodexUsageSnapshot, and a credential reader that ingests
// `~/.codex/auth.json` (respecting `CODEX_HOME`).
//
// The two-layer split (Fetcher value type + Store observable class) is the
// same as Anthropic: this fetcher is what the TestRunner fixtures hit, and
// CodexUsageStore (PR 3-BE, separate file) is what SwiftUI observes.
//
// Feature posture: this file is dark code in PR 3-BE. Nothing constructs a
// CodexUsageStore into the live provider registry yet; the popover wiring
// and Settings toggle land in PR 3-UI. Shipping the backend first, behind a
// default-off feature flag, keeps the release non-breaking.
//
// Response shape: established by a live read-only probe of the real
// endpoint (structure only, no credential retained) plus the Codex CLI's
// own deserialization structs. The authoritative fields are:
//
//   rate_limit.allowed                      Bool
//   rate_limit.limit_reached                Bool
//   rate_limit.primary_window.used_percent  Int      (0…100)
//   rate_limit.primary_window.reset_after_seconds  Int  (relative)
//   rate_limit.primary_window.reset_at      Int      (Unix epoch seconds)
//   rate_limit.secondary_window.*           (same shape as primary)
//   additional_rate_limits                  [Window]? (null or array)
//   credits.has_credits / unlimited / balance (String) / overage_limit_reached
//   plan_type                               String
//
// Note the reset timing is Unix-epoch integers, NOT ISO-8601 strings — this
// differs from the Anthropic endpoint. `used_percent` is an integer here.

import Foundation

// MARK: - Snapshot

/// One usage-limit window parsed from the Codex usage response. The primary
/// (5-hour) and secondary (weekly) windows share this shape, as do the
/// nested windows inside each `additional_rate_limits[]` element.
///
/// Field names and types are the `RateLimitWindowSnapshot` model from
/// openai/codex (`rate_limit_window_snapshot.rs`): every field is an i32 on
/// the wire.
public struct CodexRateWindow: Equatable, Sendable {
    /// 0…100 integer utilisation for the window.
    public var usedPercent: Int
    /// Length of the window in seconds (18000 = 5h, 604800 = 7d).
    public var limitWindowSeconds: Int?
    /// Seconds until the window resets, relative to the response time.
    public var resetAfterSeconds: Int?
    /// Absolute reset time as a Unix epoch (seconds). The endpoint returns
    /// this as an integer, not an ISO-8601 string, and not milliseconds.
    public var resetAt: Date?

    public init(
        usedPercent: Int = 0,
        limitWindowSeconds: Int? = nil,
        resetAfterSeconds: Int? = nil,
        resetAt: Date? = nil
    ) {
        self.usedPercent = usedPercent
        self.limitWindowSeconds = limitWindowSeconds
        self.resetAfterSeconds = resetAfterSeconds
        self.resetAt = resetAt
    }
}

/// One element of `additional_rate_limits[]` — a model-specific limit lane
/// (e.g. "GPT-5.3-Codex-Spark"). This is the `AdditionalRateLimitDetails`
/// model from openai/codex (`additional_rate_limit_details.rs`).
///
/// The usage is NOT flat on the element: it is nested one level deeper under
/// `rate_limit.primary_window` / `rate_limit.secondary_window`, both of which
/// are individually nullable. Reading `used_percent` off the element root is
/// the single most common integration mistake against this endpoint, so the
/// nesting is preserved here deliberately.
public struct CodexAdditionalLimit: Equatable, Sendable {
    /// Human-readable limit name, e.g. "GPT-5.3-Codex-Spark".
    public var limitName: String?
    /// Metered-feature slug used to identify the lane server-side.
    public var meteredFeature: String?
    /// The 5-hour window for this lane, if present.
    public var primaryWindow: CodexRateWindow?
    /// The weekly window for this lane, if present.
    public var secondaryWindow: CodexRateWindow?

    public init(
        limitName: String? = nil,
        meteredFeature: String? = nil,
        primaryWindow: CodexRateWindow? = nil,
        secondaryWindow: CodexRateWindow? = nil
    ) {
        self.limitName = limitName
        self.meteredFeature = meteredFeature
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
    }
}

/// Credit balance block. Present on accounts that carry pay-as-you-go
/// credits; `balance` is returned as a String by the endpoint.
public struct CodexCredits: Equatable, Sendable {
    public var hasCredits: Bool
    public var unlimited: Bool
    public var overageLimitReached: Bool
    /// Raw balance string exactly as returned (e.g. "0", "12.50"). Kept as a
    /// String because the endpoint returns it as a String and the tile
    /// renders it verbatim; we do not reinterpret currency here.
    public var balance: String?

    public init(
        hasCredits: Bool = false,
        unlimited: Bool = false,
        overageLimitReached: Bool = false,
        balance: String? = nil
    ) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.overageLimitReached = overageLimitReached
        self.balance = balance
    }
}

/// A parsed snapshot of the `wham/usage` response. Every field is optional
/// or defaulted in the same spirit as AnthropicUsageSnapshot — a fresh
/// account with no additional windows has an empty `additionalWindows`, and
/// an account with no credit block has `credits == nil`.
public struct CodexUsageSnapshot: Equatable, Sendable {
    /// Whether the account is currently allowed to make requests.
    public var allowed: Bool
    /// Whether any window has hit its limit.
    public var limitReached: Bool

    /// The 5-hour (primary) window. Always present in a well-formed
    /// response; nil only if `rate_limit` is entirely absent.
    public var primaryWindow: CodexRateWindow?
    /// The weekly (secondary) window.
    public var secondaryWindow: CodexRateWindow?
    /// Zero or more model-specific limit lanes (per-model or promotional
    /// caps, e.g. Spark). `additional_rate_limits` is `null` on most
    /// accounts, which parses to an empty array.
    public var additionalLimits: [CodexAdditionalLimit]

    /// Pay-as-you-go credit block, if the account carries one.
    public var credits: CodexCredits?

    /// Account plan identifier ("plus", "team", "free", …). Surfaced for the
    /// help panel copy, not for a tile.
    public var planType: String?

    public init(
        allowed: Bool = true,
        limitReached: Bool = false,
        primaryWindow: CodexRateWindow? = nil,
        secondaryWindow: CodexRateWindow? = nil,
        additionalLimits: [CodexAdditionalLimit] = [],
        credits: CodexCredits? = nil,
        planType: String? = nil
    ) {
        self.allowed = allowed
        self.limitReached = limitReached
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
        self.additionalLimits = additionalLimits
        self.credits = credits
        self.planType = planType
    }
}

// MARK: - Credentials

/// Credentials read from `~/.codex/auth.json`. Only the two fields the usage
/// request needs are surfaced; the id_token and refresh_token are never read
/// out of the file by this app (PR 3-BE does not refresh — see the plan's
/// Phase 1 note deferring writeback to Phase 1b).
public struct CodexCredentials: Equatable, Sendable {
    public let accessToken: String
    public let accountId: String

    public init(accessToken: String, accountId: String) {
        self.accessToken = accessToken
        self.accountId = accountId
    }
}

public enum CodexUsageParseError: Error, Equatable {
    case invalidJSON
    case unexpectedShape(String)
}

public enum CodexAuthError: Error, Equatable {
    /// `auth.json` does not exist. UI should prompt `codex auth login`.
    case authFileMissing
    /// `auth.json` exists but could not be parsed as JSON.
    case authFileMalformed
    /// `auth.json` parsed but is missing access_token or account_id (e.g. an
    /// API-key-only login with `auth_mode == "apikey"` and null tokens).
    case authFileIncomplete
}

// MARK: - Fetcher

/// Pure parser and credential reader for the Codex usage endpoint. Value
/// type with no observable state; all callers receive a snapshot (or a
/// thrown error) and apply it themselves on the main actor.
public struct CodexUsageFetcher: Sendable {

    public init() {}

    // MARK: Credential ingestion

    /// Resolve the Codex home directory, honouring `CODEX_HOME` when set and
    /// non-empty, else `~/.codex`.
    public static func codexHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["CODEX_HOME"],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // FileManager.homeDirectoryForCurrentUser is the real user home even
        // inside a sandbox container's mapped path; matches the CLI, which
        // uses the OS home rather than $HOME string interpolation.
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    /// Full path to `auth.json` under the resolved Codex home.
    public static func authFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        codexHome(environment: environment).appendingPathComponent("auth.json", isDirectory: false)
    }

    /// Read and parse `auth.json`, extracting the access token and account
    /// id needed for the usage request. Throws a typed CodexAuthError so the
    /// Store can map each case to a distinct UI state.
    ///
    /// This is separated from file IO so tests can exercise the parse
    /// directly against synthetic bytes without touching the filesystem.
    public static func parseAuth(_ data: Data) throws -> CodexCredentials {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthError.authFileMalformed
        }
        guard let tokens = json["tokens"] as? [String: Any] else {
            throw CodexAuthError.authFileIncomplete
        }
        guard
            let access = tokens["access_token"] as? String, !access.isEmpty,
            let account = tokens["account_id"] as? String, !account.isEmpty
        else {
            throw CodexAuthError.authFileIncomplete
        }
        return CodexCredentials(accessToken: access, accountId: account)
    }

    /// Read credentials from disk. Returns `.authFileMissing` when the file
    /// does not exist so the Store can render the "run codex auth login"
    /// onboarding card rather than an error.
    public static func readCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CodexCredentials {
        let url = authFileURL(environment: environment)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexAuthError.authFileMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Existence check passed but the read failed (permissions, race
            // with a concurrent `codex auth login` rewrite). Treat as
            // malformed rather than missing — the file is there.
            throw CodexAuthError.authFileMalformed
        }
        return try parseAuth(data)
    }

    // MARK: Pure parsing (this is what the fixtures hit)

    /// Parse one window object into a CodexRateWindow. Tolerant of absent
    /// fields: an object with only `used_percent` still parses.
    private static func parseWindow(_ obj: [String: Any]) -> CodexRateWindow {
        var w = CodexRateWindow()
        // used_percent is an Int in the live response; accept a Double too so
        // a future server-side change to fractional percentages does not
        // silently drop the value.
        if let p = obj["used_percent"] as? Int {
            w.usedPercent = p
        } else if let p = obj["used_percent"] as? Double {
            w.usedPercent = Int(p)
        }
        if let s = obj["limit_window_seconds"] as? Int {
            w.limitWindowSeconds = s
        } else if let s = obj["limit_window_seconds"] as? Double {
            w.limitWindowSeconds = Int(s)
        }
        if let s = obj["reset_after_seconds"] as? Int {
            w.resetAfterSeconds = s
        } else if let s = obj["reset_after_seconds"] as? Double {
            w.resetAfterSeconds = Int(s)
        }
        // reset_at is a Unix epoch integer (seconds). JSONSerialization may
        // surface a large integer as Int or, on 32-bit-ish paths, Double —
        // handle both.
        if let epoch = obj["reset_at"] as? Int {
            w.resetAt = Date(timeIntervalSince1970: TimeInterval(epoch))
        } else if let epoch = obj["reset_at"] as? Double {
            w.resetAt = Date(timeIntervalSince1970: epoch)
        }
        return w
    }

    /// Parse the JSON body of a `wham/usage` response into a snapshot.
    /// Preserves every field the tiles consume. Throws `invalidJSON` only
    /// when the top level is not a JSON object — a well-formed but sparse
    /// response (missing credits, null additional_rate_limits) parses to a
    /// snapshot with defaulted/absent fields, matching how AnthropicUsage
    /// Fetcher tolerates Free-plan minimal bodies.
    public static func parse(_ data: Data) throws -> CodexUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexUsageParseError.invalidJSON
        }

        var snap = CodexUsageSnapshot()

        snap.planType = json["plan_type"] as? String

        if let rl = json["rate_limit"] as? [String: Any] {
            if let allowed = rl["allowed"] as? Bool { snap.allowed = allowed }
            if let reached = rl["limit_reached"] as? Bool { snap.limitReached = reached }

            if let primary = rl["primary_window"] as? [String: Any] {
                snap.primaryWindow = parseWindow(primary)
            }
            if let secondary = rl["secondary_window"] as? [String: Any] {
                snap.secondaryWindow = parseWindow(secondary)
            }
        }

        // additional_rate_limits is null on most accounts. When present it is
        // an array of AdditionalRateLimitDetails: each element carries
        // limit_name + metered_feature, and its usage is nested under
        // `rate_limit.primary_window` / `rate_limit.secondary_window` — NOT
        // flat on the element. Anything that is not an array (including
        // explicit null) yields an empty list.
        if let additional = json["additional_rate_limits"] as? [[String: Any]] {
            snap.additionalLimits = additional.map { entry in
                var limit = CodexAdditionalLimit(
                    limitName: entry["limit_name"] as? String,
                    meteredFeature: entry["metered_feature"] as? String
                )
                if let nested = entry["rate_limit"] as? [String: Any] {
                    if let primary = nested["primary_window"] as? [String: Any] {
                        limit.primaryWindow = parseWindow(primary)
                    }
                    if let secondary = nested["secondary_window"] as? [String: Any] {
                        limit.secondaryWindow = parseWindow(secondary)
                    }
                }
                return limit
            }
        }

        if let c = json["credits"] as? [String: Any] {
            var credits = CodexCredits()
            if let has = c["has_credits"] as? Bool { credits.hasCredits = has }
            if let unlimited = c["unlimited"] as? Bool { credits.unlimited = unlimited }
            if let overage = c["overage_limit_reached"] as? Bool { credits.overageLimitReached = overage }
            // balance is a String in the live response; accept a number too
            // and stringify it defensively.
            if let b = c["balance"] as? String {
                credits.balance = b
            } else if let b = c["balance"] as? Int {
                credits.balance = String(b)
            } else if let b = c["balance"] as? Double {
                credits.balance = String(b)
            }
            snap.credits = credits
        }

        return snap
    }
}
