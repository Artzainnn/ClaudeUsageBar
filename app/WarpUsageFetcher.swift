// PR 12-BE — Warp local sqlite reader (feature-flag off).
//
// Pure-local, sqlite-only. Reads
//   ~/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite
// OR the Group Container variant:
//   ~/Library/Group Containers/2BBY89MBSN.dev.warp/warp.sqlite
// whichever exists first (the Group Container variant is used on
// signed builds installed from the App Store; the Application Support
// variant is used on direct-download builds).
//
// Design choice — schema-guarded reader:
//
// EXPANSION_PLAN.md § Phase 8f explicitly says of Warp's sqlite tables:
// "undocumented columns — inspect live, version-guard the reader" and
// "Do not display 'credits' — Warp's official credit balance lives
// server-side and is not in the local DB."
//
// Warp does officially document `wk-`-prefixed API keys against a
// documented `app.warp.dev` GraphQL endpoint (verified against
// docs.warp.dev/reference/cli/api-keys, July 2026). A live-endpoint
// path is a candidate for a future PR; this one stays local-only per
// the plan.
//
// Because the sqlite schema is genuinely undocumented and has been
// observed to differ between Warp releases (see
// samuelatagana/warp-sqlite-mcp for one snapshot), this reader:
//
//   1. Confirms the DB opens as a SQLite database.
//   2. Introspects `sqlite_master` to look for the expected tables
//      (`ai_queries` or `agent_conversations`).
//   3. Introspects the table's columns via `PRAGMA table_info(...)`.
//   4. Only if a plausible timestamp column exists AND matches one of
//      the known column names does the reader count rows for today.
//   5. Any deviation from the expected shape returns
//      `.schemaUnknown` so the store surfaces an update-app tile
//      rather than a wrong number.
//
// This is intentionally conservative — under-reporting Warp usage is
// safe; over-reporting or displaying a number that doesn't correspond
// to a real quota is not.

import Foundation

// MARK: - Path resolution

public struct WarpEnvironment: Sendable {
    /// Every path we search for `warp.sqlite`, in order. The first
    /// existing file is used.
    public var candidateDbPaths: [String]
    public var fileExists: @Sendable (String) -> Bool

    public init(
        candidateDbPaths: [String],
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.candidateDbPaths = candidateDbPaths
        self.fileExists = fileExists
    }

    public static func current() -> WarpEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return WarpEnvironment(candidateDbPaths: [
            // Direct-download builds.
            "\(home)/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite",
            // App Store / sandboxed builds.
            "\(home)/Library/Group Containers/2BBY89MBSN.dev.warp/warp.sqlite",
            // Preview / beta channel.
            "\(home)/Library/Application Support/dev.warp.Warp-Preview/warp.sqlite"
        ])
    }
}

public enum WarpPathResolver {
    /// Return the first candidate path that exists on disk. Nil if
    /// none.
    public static func resolveDbPath(_ env: WarpEnvironment) -> String? {
        for path in env.candidateDbPaths {
            if env.fileExists(path) { return path }
        }
        return nil
    }
}

// MARK: - Snapshot + read outcome

public struct WarpUsageSnapshot: Sendable, Equatable {
    /// Number of AI queries observed in the today-window (local
    /// midnight → now). Nil when the schema is unknown or a
    /// suitable timestamp column was not found.
    public let requestsToday: Int?
    /// Which table the count came from — surfaced so the diagnostic
    /// tile can name it if a user asks.
    public let sourceTable: String?
    /// Timestamp column the reader ended up using (nil if snapshot
    /// came from a count-all fallback path).
    public let timestampColumn: String?
    /// Total AI queries in the DB — only populated when a plausible
    /// count-all is safe (i.e. the table exists but no plausible
    /// timestamp column was found). Nil otherwise.
    public let requestsAllTime: Int?

    public init(requestsToday: Int?, sourceTable: String?, timestampColumn: String?, requestsAllTime: Int?) {
        self.requestsToday = requestsToday
        self.sourceTable = sourceTable
        self.timestampColumn = timestampColumn
        self.requestsAllTime = requestsAllTime
    }
}

public enum WarpReadOutcome: Sendable, Equatable {
    /// Successful read with a today-window row count.
    case success(WarpUsageSnapshot)
    /// The database opened fine but neither the `ai_queries` nor the
    /// `agent_conversations` table was present — Warp AI may never
    /// have been used, OR the schema drifted beyond what this build
    /// knows about.
    case tablesMissing
    /// The expected table exists but its columns do not match any
    /// known shape — schema-drift; surface an update tile.
    case schemaUnknown
}

// MARK: - Reader

public enum WarpUsageFetcher {
    /// Column names the reader will accept as a per-row timestamp,
    /// in preference order. All observed Warp forks have used one of
    /// these; adding a new one requires only extending this list.
    public static let knownTimestampColumns: [String] = [
        "created_at", "createdAt", "timestamp", "ts", "date", "time"
    ]

    /// Table names the reader will look for, in preference order.
    public static let knownTables: [String] = [
        "ai_queries", "agent_conversations"
    ]

    /// Read the sqlite DB at `path` and return a today-window snapshot.
    /// `now` is injected so the today-window is deterministic in
    /// tests.
    public static func read(from path: String, now: Date = Date()) throws -> WarpReadOutcome {
        let reader = try SQLiteReader(path: path)
        defer { reader.close() }

        // Introspect the schema — every step below either succeeds
        // deterministically (well-known SQL that any modern sqlite
        // executes) or throws through the SQLiteReader errors, which
        // the store's fetch() handler maps to distinct outcomes.
        let existingTables = try reader.query(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ) { row -> String? in
            row.string("name")
        }

        // Find the FIRST known table that actually exists — order
        // matters because `ai_queries` is preferred over
        // `agent_conversations` when both are present (agent
        // conversations include background auto-runs; explicit AI
        // queries are what a user identifies as "usage").
        guard let table = knownTables.first(where: { existingTables.contains($0) }) else {
            return .tablesMissing
        }

        // Introspect the chosen table's columns. `PRAGMA table_info(?)`
        // does not accept placeholders (sqlite's PRAGMA parser is
        // pre-bind), so we interpolate but only after
        // `SQLiteReader.assertIsValidIdentifier` has validated the
        // name — the table name came from sqlite_master's own list
        // above, so it's already strictly SQL-safe, but we validate
        // again for defence in depth.
        try SQLiteReader.assertIsValidIdentifier(table)
        let columns = try reader.query(
            "PRAGMA table_info(\(table))"
        ) { row -> String? in
            row.string("name")
        }

        // Pick the first known timestamp column that exists in the
        // table's schema. Codex R1 P2 finding #3: an unknown
        // timestamp column IS a schema drift — silently returning
        // an all-time count would misrepresent the number as "today".
        // Refuse to fabricate; surface .schemaUnknown so the store
        // shows an update-app tile instead.
        let timestampColumn = knownTimestampColumns.first(where: { columns.contains($0) })
        guard let tsCol = timestampColumn else {
            return .schemaUnknown
        }

        try SQLiteReader.assertIsValidIdentifier(tsCol)
        // Compute today's window bounds. The Warp DB has been
        // observed to store timestamps as (a) unix seconds INTEGER,
        // (b) unix milliseconds INTEGER, or (c) an ISO-8601 TEXT.
        // Auto-detect by peeking at the max value in the column: the
        // MIN of a plausible seconds column since 2019 (when Warp
        // was founded) is above 1.5e9; a milliseconds column is
        // above 1.5e12. Anything above 1e10 is milliseconds.
        let peek = try reader.query(
            "SELECT MAX(\(tsCol)) AS m FROM \(table)"
        ) { row -> (Int64?, String?) in
            (row.int("m"), row.string("m"))
        }.first
        let (todayStart, todayEnd) = Self.todayWindowBounds(now: now)
        let count: Int
        if let m = peek?.0 {
            // Integer column — Codex R1 P2 finding #5: bucket by
            // magnitude, only accept the two shapes Warp has been
            // observed to use. Unknown magnitudes (microseconds,
            // nanoseconds, or hostile huge values) surface as
            // .schemaUnknown so the store shows an update-app tile
            // rather than a zero count.
            let unit = Self.classifyIntegerEpoch(m)
            let (startBind, endBind): (SQLiteBind, SQLiteBind)
            switch unit {
            case .seconds:
                startBind = .int(Int64(todayStart.timeIntervalSince1970))
                endBind = .int(Int64(todayEnd.timeIntervalSince1970))
            case .milliseconds:
                startBind = .int(Int64(todayStart.timeIntervalSince1970 * 1000.0))
                endBind = .int(Int64(todayEnd.timeIntervalSince1970 * 1000.0))
            case .unknown:
                return .schemaUnknown
            }
            count = try reader.query(
                "SELECT COUNT(*) AS c FROM \(table) WHERE \(tsCol) >= ? AND \(tsCol) < ?",
                binds: [startBind, endBind]
            ) { row -> Int? in
                row.int("c").map { Int($0) }
            }.first ?? 0
        } else if let sample = peek?.1, !sample.isEmpty {
            // TEXT column — sqlite historically stores its own
            // `datetime(...)` output as `YYYY-MM-DD HH:MM:SS` (SPACE
            // separator), and modern apps use ISO-8601 with a `T`.
            // Codex R1 P2 finding #4: space sorts LEXICALLY BEFORE
            // `T`, so if we bound by ISO-8601 strings a
            // sqlite-datetime column undercounts. Detect the format
            // from the sample and emit matching bounds.
            switch Self.classifyTextTimestamp(sample) {
            case .iso8601:
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let startStr = iso.string(from: todayStart)
                let endStr = iso.string(from: todayEnd)
                count = try reader.query(
                    "SELECT COUNT(*) AS c FROM \(table) WHERE \(tsCol) >= ? AND \(tsCol) < ?",
                    binds: [.text(startStr), .text(endStr)]
                ) { row -> Int? in
                    row.int("c").map { Int($0) }
                }.first ?? 0
            case .sqliteDatetime:
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone.current
                f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let startStr = f.string(from: todayStart)
                let endStr = f.string(from: todayEnd)
                count = try reader.query(
                    "SELECT COUNT(*) AS c FROM \(table) WHERE \(tsCol) >= ? AND \(tsCol) < ?",
                    binds: [.text(startStr), .text(endStr)]
                ) { row -> Int? in
                    row.int("c").map { Int($0) }
                }.first ?? 0
            case .unknown:
                // Neither ISO-8601 nor sqlite-datetime — schema drift.
                return .schemaUnknown
            }
        } else {
            // Empty table — legitimately zero today.
            count = 0
        }

        return .success(WarpUsageSnapshot(
            requestsToday: count,
            sourceTable: table,
            timestampColumn: tsCol,
            requestsAllTime: nil
        ))
    }

    /// Compute the [midnight, next-midnight) window bounds for `now`
    /// in the user's local time zone. Split out so tests can pin the
    /// result across a DST boundary.
    public static func todayWindowBounds(now: Date) -> (Date, Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    /// Integer-epoch magnitude classification. Codex R1 P2 finding #5.
    public enum EpochUnit: Sendable, Equatable {
        case seconds
        case milliseconds
        /// Microsecond / nanosecond / other magnitudes we do not
        /// handle. The reader surfaces `.schemaUnknown` for these
        /// rather than fabricating a today-window against an epoch
        /// we do not understand.
        case unknown
    }

    /// Classify an integer-epoch max value by magnitude. Ranges:
    ///  - `[1.5e9, 1e10)`: seconds since 1970 (covers 2017 → 2286).
    ///  - `[1.5e12, 1e13)`: milliseconds since 1970 (covers 2017 → 2286).
    ///  - anything else: unknown.
    public static func classifyIntegerEpoch(_ v: Int64) -> EpochUnit {
        if v >= 1_500_000_000 && v < 10_000_000_000 { return .seconds }
        if v >= 1_500_000_000_000 && v < 10_000_000_000_000 { return .milliseconds }
        return .unknown
    }

    /// Classify a TEXT timestamp sample. Codex R1 P2 finding #4.
    public enum TextTimestampFormat: Sendable, Equatable {
        case iso8601        // e.g. "2026-07-13T00:00:00Z" or "2026-07-13T00:00:00.000Z"
        case sqliteDatetime // e.g. "2026-07-13 00:00:00" (sqlite's own datetime() output)
        case unknown
    }

    public static func classifyTextTimestamp(_ sample: String) -> TextTimestampFormat {
        // ISO-8601 uses `T` between date and time.
        if sample.count >= 10 && sample.contains("T") { return .iso8601 }
        // sqlite's built-in datetime() emits `YYYY-MM-DD HH:MM:SS`.
        if sample.count >= 19 {
            let idx10 = sample.index(sample.startIndex, offsetBy: 10)
            if sample[idx10] == " " { return .sqliteDatetime }
        }
        return .unknown
    }
}
