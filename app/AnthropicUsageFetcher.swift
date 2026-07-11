// PR 2b — Anthropic usage fetcher.
//
// Extracted from UsageManager. Sendable value type. No observable state,
// no delegates, no side effects. Takes raw response bytes, returns a
// parsed AnthropicUsageSnapshot. All HTTP concerns are handled by
// AnthropicUsageFetcher.fetch(cookie:); the caller decides how to apply
// the snapshot on the main actor.
//
// This split keeps the fetcher testable without depending on UI, timers,
// AppKit, or the delegate. The unit tests in Tests/TestRunner feed known
// JSON bytes and lock in the exact parsed output.

import Foundation

/// A parsed snapshot of the claude.ai `/api/organizations/{org}/usage`
/// response. Every field is optional in the same shape the endpoint
/// itself returns — a Free-plan account has no `seven_day_sonnet`,
/// a non-Fable account has no Fable entry in `limits[]`.
public struct AnthropicUsageSnapshot: Equatable, Sendable {
    public var sessionUsage: Int
    public var sessionResetsAt: Date?

    public var weeklyUsage: Int
    public var weeklyResetsAt: Date?

    public var hasWeeklySonnet: Bool
    public var weeklySonnetUsage: Int
    public var weeklySonnetResetsAt: Date?

    public var hasWeeklyFable: Bool
    public var weeklyFableUsage: Int
    public var weeklyFableResetsAt: Date?

    public init(
        sessionUsage: Int = 0,
        sessionResetsAt: Date? = nil,
        weeklyUsage: Int = 0,
        weeklyResetsAt: Date? = nil,
        hasWeeklySonnet: Bool = false,
        weeklySonnetUsage: Int = 0,
        weeklySonnetResetsAt: Date? = nil,
        hasWeeklyFable: Bool = false,
        weeklyFableUsage: Int = 0,
        weeklyFableResetsAt: Date? = nil
    ) {
        self.sessionUsage = sessionUsage
        self.sessionResetsAt = sessionResetsAt
        self.weeklyUsage = weeklyUsage
        self.weeklyResetsAt = weeklyResetsAt
        self.hasWeeklySonnet = hasWeeklySonnet
        self.weeklySonnetUsage = weeklySonnetUsage
        self.weeklySonnetResetsAt = weeklySonnetResetsAt
        self.hasWeeklyFable = hasWeeklyFable
        self.weeklyFableUsage = weeklyFableUsage
        self.weeklyFableResetsAt = weeklyFableResetsAt
    }
}

public enum AnthropicUsageParseError: Error, Equatable {
    case invalidJSON
    case unexpectedShape(String)
}

/// Pure parser and HTTP client for claude.ai's usage endpoint. Value type
/// with no observable state — all callers receive a snapshot and apply it
/// themselves.
public struct AnthropicUsageFetcher: Sendable {

    public init() {}

    // MARK: - Pure parsing (this is what the tests hit)

    /// Parse the JSON body of a `/api/organizations/{org}/usage` response.
    /// Preserves the historical behaviour of UsageManager.parseUsageData
    /// exactly — every branch (missing five_hour, Sonnet absent, Fable in
    /// limits[], Fable percent as Int vs Double) is a fixture in the test
    /// suite so future refactors cannot silently regress.
    public static func parse(_ data: Data) throws -> AnthropicUsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicUsageParseError.invalidJSON
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var snap = AnthropicUsageSnapshot()

        if let fiveHour = json["five_hour"] as? [String: Any] {
            if let util = fiveHour["utilization"] as? Double {
                snap.sessionUsage = Int(util)
            }
            if let s = fiveHour["resets_at"] as? String {
                snap.sessionResetsAt = iso.date(from: s)
            }
        }

        if let sevenDay = json["seven_day"] as? [String: Any] {
            if let util = sevenDay["utilization"] as? Double {
                snap.weeklyUsage = Int(util)
            }
            if let s = sevenDay["resets_at"] as? String {
                snap.weeklyResetsAt = iso.date(from: s)
            }
        }

        if let sonnet = json["seven_day_sonnet"] as? [String: Any] {
            snap.hasWeeklySonnet = true
            if let util = sonnet["utilization"] as? Double {
                snap.weeklySonnetUsage = Int(util)
            }
            if let s = sonnet["resets_at"] as? String {
                snap.weeklySonnetResetsAt = iso.date(from: s)
            }
        }

        // Fable lives inside limits[] where scope.model.display_name == "Fable".
        // Not surfaced by UI until usage >= 1% — that decision is in the view
        // layer, not here. `percent` may decode as Int or Double.
        if let limits = json["limits"] as? [[String: Any]] {
            if let fable = limits.first(where: { entry in
                let scope = entry["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                return (model?["display_name"] as? String) == "Fable"
            }) {
                snap.hasWeeklyFable = true
                if let p = fable["percent"] as? Int {
                    snap.weeklyFableUsage = p
                } else if let p = fable["percent"] as? Double {
                    snap.weeklyFableUsage = Int(p)
                }
                if let s = fable["resets_at"] as? String {
                    snap.weeklyFableResetsAt = iso.date(from: s)
                }
            }
        }

        return snap
    }

    // MARK: - Org-id discovery

    /// Extract the org id from the `lastActiveOrg=...` cookie value, if
    /// present. Returns nil when the cookie does not carry it.
    public static func orgId(fromCookieString raw: String) -> String? {
        for part in raw.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("lastActiveOrg=") {
                return String(trimmed.dropFirst("lastActiveOrg=".count))
            }
        }
        return nil
    }
}
