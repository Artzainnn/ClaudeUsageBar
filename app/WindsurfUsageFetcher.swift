// PR 11-BE — Windsurf local usage fetcher (feature-flagged off).
//
// Third local-file provider (Milestone 6). Reads Windsurf's own
// state.vscdb (a SQLite database) for the cached plan-usage record
// Windsurf's Cascade chat writes there. Nothing leaves the machine.
//
// Data source
// -----------
// `~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb`
// is a standard VS Code-style key/value SQLite DB. The
// `ItemTable(key, value)` schema holds a `windsurf.settings.cachedPlanInfo`
// row whose `value` is a JSON string.
//
// Two shapes observed in the wild (Windsurf's plan-info payload has
// evolved twice; both live installs today can produce either shape):
//
//   OLDER: `quotaUsage.{dailyRemainingPercent, weeklyRemainingPercent,
//                       dailyResetAtUnix,       weeklyResetAtUnix}`
//   NEWER: `usage.{usedMessages,       remainingMessages,
//                   usedFlexCredits,   flexCredits,
//                   usedFlowActions}`
//   Both: `planName`, `startTimestamp`, `endTimestamp` (all optional).
//
// The parser reads BOTH and produces a tile-ready `WindsurfPlanUsage`
// with best-effort projection: `quotaUsage.*` maps to explicit daily/
// weekly windows with reset times; `usage.*` maps to a single "credits"
// window using `usedMessages` / `messages` (or `usedFlexCredits` /
// `flexCredits` when present).
//
// Live-endpoint (`windsurf.com/_backend/exa.seat_management_pb...`) is
// intentionally deferred — it uses Connect-RPC protobuf and Chromium
// leveldb cookies (requires Full Disk Access), which materially
// increases attack surface and maintenance load for a nice-to-have.
// Local-only ships first; live path can land in a follow-on PR.
//
// Feature posture
// ---------------
// `features.windsurf.enabled` defaults false. Nothing registers a
// `WindsurfUsageStore` into the live registry yet (that lands in PR
// 11-UI). This file compiles and unit-tests but is inert at runtime
// until enabled.

import Foundation

// MARK: - Snapshot pieces

/// A single quota window Windsurf exposes. Windsurf's cached plan info
/// mixes two representations: percent-remaining with reset times
/// (older shape) and used/remaining message counts (newer shape). Both
/// project to this record via `WindsurfUsageParser`.
public struct WindsurfPlanUsageWindow: Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable {
        case daily
        case weekly
        case credits          // catch-all for `usage.usedMessages` /
                              // `usedFlexCredits` shape.
    }
    public var kind: Kind
    /// Fraction of the window consumed in the range `[0, 1]`. Derived from
    /// `100 - remainingPercent` (older) or `used / total` (newer).
    public var fractionUsed: Double
    /// Wall-clock reset time for this window, when the source data has it.
    /// Nil when Windsurf did not persist a reset stamp.
    public var resetsAt: Date?
    /// Human label for the window ("Daily", "Weekly", "Credits"). Kept
    /// separately from `Kind` because a future Windsurf plan tier may
    /// expose a differently-named window we still want to render.
    public var displayLabel: String

    public init(kind: Kind, fractionUsed: Double, resetsAt: Date?, displayLabel: String) {
        self.kind = kind
        self.fractionUsed = fractionUsed
        self.resetsAt = resetsAt
        self.displayLabel = displayLabel
    }
}

/// Aggregate parse result. `planName` is exposed for a diagnostic /
/// header line in the popover; the windows drive the actual tiles.
public struct WindsurfPlanUsage: Equatable, Sendable {
    /// e.g. "Pro", "Free", "Enterprise". Nil when the JSON did not carry a
    /// planName (older Windsurf builds).
    public var planName: String?
    /// Windows extracted from the payload. Empty when the JSON was well-
    /// formed but had no usage numbers — the caller renders a diagnostic.
    public var windows: [WindsurfPlanUsageWindow]

    public init(planName: String? = nil, windows: [WindsurfPlanUsageWindow] = []) {
        self.planName = planName
        self.windows = windows
    }
}

// MARK: - Path resolution

public enum WindsurfPathResolver {

    public struct Environment: Sendable {
        public var homeDirectoryPath: String
        public var applicationSupportPath: String
        public init(homeDirectoryPath: String, applicationSupportPath: String) {
            self.homeDirectoryPath = homeDirectoryPath
            self.applicationSupportPath = applicationSupportPath
        }

        public static func current() -> Environment {
            let home = NSHomeDirectory()
            return Environment(
                homeDirectoryPath: home,
                applicationSupportPath: (home as NSString).appendingPathComponent("Library/Application Support")
            )
        }
    }

    /// Absolute path to `state.vscdb`. Nil when we have no
    /// `applicationSupportPath` to build against (an empty environment
    /// snapshot — never in practice on macOS).
    public static func stateDbPath(_ env: Environment) -> String? {
        guard !env.applicationSupportPath.isEmpty else { return nil }
        return "\(env.applicationSupportPath)/Windsurf/User/globalStorage/state.vscdb"
    }
}

// MARK: - JSON parsing

public enum WindsurfUsageParser {

    /// Parse a `windsurf.settings.cachedPlanInfo` value string into a
    /// tile-ready plan-usage record. Returns nil when the string does
    /// not decode as a JSON object; returns an empty-windows record when
    /// the object is well-formed but has no quota fields.
    public static func parse(cachedPlanInfoJSON raw: String) -> WindsurfPlanUsage? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return nil
        }
        let planName = dict["planName"] as? String
        var windows: [WindsurfPlanUsageWindow] = []

        // Older shape — `quotaUsage.{daily,weekly}RemainingPercent`.
        if let quota = dict["quotaUsage"] as? [String: Any] {
            if let dailyRemaining = numeric(quota["dailyRemainingPercent"]) {
                let used = max(0.0, min(1.0, (100.0 - dailyRemaining) / 100.0))
                windows.append(WindsurfPlanUsageWindow(
                    kind: .daily,
                    fractionUsed: used,
                    resetsAt: unixTimestampFlexibleSecondsOrMs(quota["dailyResetAtUnix"]),
                    displayLabel: "Daily"
                ))
            }
            if let weeklyRemaining = numeric(quota["weeklyRemainingPercent"]) {
                let used = max(0.0, min(1.0, (100.0 - weeklyRemaining) / 100.0))
                windows.append(WindsurfPlanUsageWindow(
                    kind: .weekly,
                    fractionUsed: used,
                    resetsAt: unixTimestampFlexibleSecondsOrMs(quota["weeklyResetAtUnix"]),
                    displayLabel: "Weekly"
                ))
            }
        }

        // Newer shape — `usage.{used,remaining}Messages` /
        // `usage.{usedFlexCredits, flexCredits}`. Only surfaced when the
        // older shape produced no windows so the tile does not double-
        // count.
        if windows.isEmpty, let usage = dict["usage"] as? [String: Any] {
            // Prefer flex credits when Windsurf exposes them (Pro plan).
            if let used = numeric(usage["usedFlexCredits"]),
               let total = numeric(usage["flexCredits"]),
               total > 0 {
                windows.append(WindsurfPlanUsageWindow(
                    kind: .credits,
                    fractionUsed: max(0.0, min(1.0, used / total)),
                    resetsAt: unixTimestampFlexibleSecondsOrMs(dict["endTimestamp"]),
                    displayLabel: "Flex credits"
                ))
            } else if let used = numeric(usage["usedMessages"]),
                      let remaining = numeric(usage["remainingMessages"]) {
                let total = used + remaining
                if total > 0 {
                    windows.append(WindsurfPlanUsageWindow(
                        kind: .credits,
                        fractionUsed: max(0.0, min(1.0, used / total)),
                        resetsAt: unixTimestampFlexibleSecondsOrMs(dict["endTimestamp"]),
                        displayLabel: "Messages"
                    ))
                }
            } else if let used = numeric(usage["usedMessages"]),
                      let total = numeric(usage["messages"]),
                      total > 0 {
                // Third form observed in some plans: `usage.messages` is
                // the total, `usedMessages` the consumed count. Kept as
                // a distinct branch so a schema break narrows the
                // failure mode.
                windows.append(WindsurfPlanUsageWindow(
                    kind: .credits,
                    fractionUsed: max(0.0, min(1.0, used / total)),
                    resetsAt: unixTimestampFlexibleSecondsOrMs(dict["endTimestamp"]),
                    displayLabel: "Messages"
                ))
            }
        }

        return WindsurfPlanUsage(planName: planName, windows: windows)
    }

    // MARK: - Field helpers

    /// Best-effort numeric extraction. Windsurf stores every quota field
    /// as JSON Number, but a schema drift or hand-edit could produce a
    /// stringified number. Returns nil for `null`, missing, NaN, or
    /// infinity.
    ///
    /// Codex round-1 finding #2: JSON booleans MUST be rejected — an
    /// `NSNumber` bridged from a JSON bool has `.doubleValue == 0` or
    /// `1`, which would silently map `dailyRemainingPercent: false` to
    /// 0% remaining (i.e. 100% used) instead of "no data".
    public static func numeric(_ raw: Any?) -> Double? {
        if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            return nil
        }
        if let d = raw as? Double, d.isFinite { return d }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let s = raw as? String, let parsed = Double(s), parsed.isFinite { return parsed }
        return nil
    }

    /// Interpret a Unix timestamp that may be seconds OR milliseconds
    /// (Windsurf's schema is inconsistent across releases — the older
    /// `quotaUsage.*ResetAtUnix` used seconds, but some newer builds emit
    /// milliseconds). Heuristic: > 1e11 → treat as ms (would be year
    /// 5138 as seconds); ≤ 1e11 → seconds. Rejects values outside
    /// [2000-01-01, 2100-01-01] the same way Cline's parser does.
    public static func unixTimestampFlexibleSecondsOrMs(_ raw: Any?) -> Date? {
        guard let n = numeric(raw) else { return nil }
        let seconds: Double = n > 1_000_000_000_00 /* 1e11 */ ? n / 1000.0 : n
        let year2000: Double = 946_684_800
        let year2100: Double = 4_102_444_800
        guard seconds >= year2000 && seconds < year2100 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Fetcher

/// Sendable value-type. All I/O is optional via injection.
public struct WindsurfUsageFetcher: Sendable {

    /// Read the `windsurf.settings.cachedPlanInfo` row from a Windsurf
    /// state.vscdb and return the parsed usage record.
    ///
    /// Throws every error `SQLiteReader.init` can emit — `.notFound` and
    /// `.openFailed` (TCC-denied) drive the store's onboarding tile;
    /// `.notADatabase` / `.encrypted` / `.schemaMismatch` are hard
    /// failures the store surfaces as an error tile.
    ///
    /// Returns nil ONLY when the file opened cleanly and the
    /// cachedPlanInfo row is absent (fresh install; user has not
    /// signed in yet).
    ///
    /// Codex round-1 finding #1: a row that exists but is malformed
    /// (JSON parse fails, or the JSON is not a top-level object) must
    /// NOT be indistinguishable from a missing row — otherwise the
    /// store stays on "Loading…" forever. Signalled via the new
    /// `.malformedPayload` case below; the store maps it to a
    /// schema-mismatch tile.
    public static func read(from stateDbPath: String) throws -> WindsurfReadOutcome {
        let reader = try SQLiteReader(path: stateDbPath)
        defer { reader.close() }
        // Codex round-3 finding #1: differentiate row-absent from
        // row-present-with-non-text-value. The decode closure returns
        // an inner Optional<String> so a NULL / blob / integer value
        // still counts as a row-present hit and maps to
        // .malformedPayload instead of collapsing to .rowMissing.
        let rows = try reader.query(
            "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
            binds: [.text("windsurf.settings.cachedPlanInfo")]
        ) { row -> String? in
            // Sentinel: return a marker for "present-but-not-text" by
            // reading the value column as a blob first. If it's a
            // string, decode it; if it's non-nil but not text, return
            // an empty string (distinct from the "no row" case where
            // the closure is not called at all).
            if row.isNull("value") { return "" }
            if let text = row.string("value") { return text }
            // Row present with non-text value (blob / integer /
            // double). Treat as malformed.
            return ""
        }
        guard let value = rows.first ?? nil else { return .rowMissing }
        if value.isEmpty { return .malformedPayload }
        guard let parsed = WindsurfUsageParser.parse(cachedPlanInfoJSON: value) else {
            return .malformedPayload
        }
        return .success(parsed)
    }
}

/// Outcome of a Windsurf state.vscdb read. Differentiates a
/// legitimately-missing cachedPlanInfo row (`.rowMissing` — fresh
/// install) from a row that exists but contains junk (`.malformedPayload`
/// — schema drift). Codex round-1 finding #1.
public enum WindsurfReadOutcome: Equatable, Sendable {
    case success(WindsurfPlanUsage)
    case rowMissing
    case malformedPayload
}
