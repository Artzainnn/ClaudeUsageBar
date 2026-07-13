// PR 10c-BE — Cline local usage fetcher (feature-flagged off).
//
// Second local-file provider (Milestone 6). Reads the Cline VS Code
// extension's own on-disk usage records — `ui_messages.json` under the
// per-task directory — and produces a token-and-cost rollup. Nothing
// leaves the machine.
//
// Data source
// -----------
// Cline persists one JSON file per session at:
//
//   {globalStorage}/saoudrizwan.claude-dev/tasks/{taskId}/ui_messages.json
//
// where `{globalStorage}` is one of the following (searched in order):
//
//   1. `$CLINE_DATA_DIR` (Cline CLI/SDK override — v4+). Layout is
//      `{CLINE_DATA_DIR}/tasks/{taskId}/ui_messages.json`. No extension
//      id under this override (the CLI is a first-class citizen of
//      Cline).
//   2. `$CLINE_DIR/data` (Cline CLI/SDK convention).
//   3. `~/.cline/data` (Cline CLI/SDK default when neither env-var is
//      set).
//   4. `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev`
//      (VS Code stable).
//   5. `~/Library/Application Support/Code - Insiders/User/globalStorage/saoudrizwan.claude-dev`.
//   6. `~/Library/Application Support/VSCodium/User/globalStorage/saoudrizwan.claude-dev`.
//   7. `~/Library/Application Support/Cursor/User/globalStorage/saoudrizwan.claude-dev`.
//   8. `~/Library/Application Support/Windsurf/User/globalStorage/saoudrizwan.claude-dev`.
//
// Every path is treated as an INDEPENDENT scan root — a user with Cline
// installed under BOTH VS Code stable and Insiders sees combined usage.
// Deduplication is unnecessary because each host writes its own set of
// task ids under its own scan root (task ids are UUIDs; a collision
// across hosts would require re-using the same globalStorage folder).
//
// File format
// -----------
// `ui_messages.json` is a JSON ARRAY of `ClineMessage` objects — NOT
// line-delimited JSON. Every element is a message with fields:
//
//   { "ts": 1_700_000_000_000,
//     "type": "say" | "ask",
//     "say": "api_req_started" | "deleted_api_reqs" | "subagent_usage" | …,
//     "text": "{\"tokensIn\":10,\"tokensOut\":20,\"cost\":0.001,…}",
//     "modelInfo": {"modelId": "claude-opus-4-7", "providerId": "…", "mode": "…"}
//   }
//
// Only records of `type=="say"` AND `say` in the three usage-carrying
// variants above contribute to the rollup, per Cline's own
// `getApiMetrics` implementation
// (github.com/cline/cline apps/vscode/src/shared/getApiMetrics.ts).
//
// The `text` field is a JSON-ENCODED STRING (double-encoded) that
// parses to `{tokensIn, tokensOut, cacheWrites, cacheReads, cost}`.
// Every field is optional and every field is a JSON Number. Cost is
// already computed by the extension in USD — no pricing table needed
// (unlike Claude Code, which requires our LiteLLM snapshot).
//
// Model attribution — `message.modelInfo?.modelId` is the raw model
// name (e.g. "claude-opus-4-7", "gpt-5", "gemini-2.5-pro"). Absent on
// older Cline versions; the rollup falls back to "unknown".
//
// Partial writes — Cline uses atomic-rename-via-tmp for `ui_messages.json`
// (issue #7101 fix). A concurrent read during a rename either sees the
// old file OR the new file; a torn write never surfaces. We still
// tolerate a JSON parse failure (returns nil, file skipped) so an older
// Cline version without the atomic-rename fix does not crash the tile.
//
// Feature posture
// ---------------
// `features.cline.enabled` defaults false. Nothing registers a
// `ClineUsageStore` into the live registry yet (that lands in PR
// 10c-UI). This file compiles and unit-tests but is inert at runtime
// until enabled.

import Foundation

// MARK: - Snapshot pieces

/// One usage record extracted from a `say=="api_req_started" |
/// "deleted_api_reqs" | "subagent_usage"` message in `ui_messages.json`.
public struct ClineUsageRecord: Equatable, Sendable {
    /// Model identifier as reported by Cline's `modelInfo.modelId`. Falls
    /// back to "unknown" when the message predates the modelInfo field
    /// (Cline versions before ~v3.5).
    public var model: String
    /// Wall-clock timestamp of the record from `message.ts` (ms since
    /// epoch, converted to `Date`). Nil if the field was missing or
    /// out-of-range (before 2000-01-01 or after 2100-01-01 — a schema
    /// break we don't want to leak into the bucketing).
    public var timestamp: Date?
    /// The three usage-carrying say kinds. Kept so the rollup can
    /// diagnose an unexpected mix of message kinds without re-parsing.
    public var sayKind: SayKind
    /// tokensIn (regular input tokens excluding cache).
    public var tokensIn: Int
    /// tokensOut (output tokens).
    public var tokensOut: Int
    /// cacheWrites (cache-creation tokens).
    public var cacheWrites: Int
    /// cacheReads (cache-read tokens).
    public var cacheReads: Int
    /// Cost in USD as computed by the Cline extension. Cline already
    /// applies the correct per-model rate (LiteLLM-derived); we take
    /// its number verbatim.
    public var costUSD: Double
    /// Absolute path of the source file. Used for diagnostics + the
    /// per-file breakdown in the snapshot.
    public var sourceFile: String

    public enum SayKind: String, Sendable, Equatable {
        case apiReqStarted = "api_req_started"
        case deletedApiReqs = "deleted_api_reqs"
        case subagentUsage = "subagent_usage"
    }

    public init(
        model: String,
        timestamp: Date?,
        sayKind: SayKind,
        tokensIn: Int,
        tokensOut: Int,
        cacheWrites: Int,
        cacheReads: Int,
        costUSD: Double,
        sourceFile: String
    ) {
        self.model = model
        self.timestamp = timestamp
        self.sayKind = sayKind
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.cacheWrites = cacheWrites
        self.cacheReads = cacheReads
        self.costUSD = costUSD
        self.sourceFile = sourceFile
    }

    /// Sum of every token category. Uses `ClaudeCodeUsageRecord.saturatingAdd`
    /// so a hostile 1e300 in the wire data cannot wrap to a negative
    /// count.
    public var totalTokens: Int {
        var s = ClaudeCodeUsageRecord.saturatingAdd(0, tokensIn)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, tokensOut)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, cacheWrites)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, cacheReads)
        return s
    }
}

/// Aggregate roll-up produced by `ClineUsageFetcher.parse(files:)`.
public struct ClineUsageSnapshot: Equatable, Sendable {
    /// All records after malformed-line filtering, sorted by timestamp
    /// ascending (records without a timestamp sink to the end).
    public var records: [ClineUsageRecord]
    /// Path-relative file counts (absolute path → contributing record
    /// count).
    public var recordsPerFile: [String: Int]
    /// Number of usage-carrying messages that failed to JSON-decode
    /// their `text` field. Benign on a live file (Cline sometimes
    /// updates message.text as the request progresses; a partial write
    /// mid-stream may leave the text in an intermediate state). A
    /// climbing count suggests a schema break.
    public var malformedRecordCount: Int
    /// Number of files that could not be parsed at all (JSON at the
    /// top level failed).
    public var unreadableFileCount: Int

    public init(
        records: [ClineUsageRecord],
        recordsPerFile: [String: Int] = [:],
        malformedRecordCount: Int = 0,
        unreadableFileCount: Int = 0
    ) {
        self.records = records
        self.recordsPerFile = recordsPerFile
        self.malformedRecordCount = malformedRecordCount
        self.unreadableFileCount = unreadableFileCount
    }

    /// Sum of tokens over records whose `timestamp` falls within `range`.
    /// Uses saturating addition per the Claude Code precedent so an
    /// Int-overflow cannot wrap negative.
    public func tokens(in range: ClosedRange<Date>) -> Int {
        var s = 0
        for r in records {
            guard let ts = r.timestamp, range.contains(ts) else { continue }
            s = ClaudeCodeUsageRecord.saturatingAdd(s, r.totalTokens)
        }
        return s
    }

    /// Sum of cost over records whose `timestamp` falls within `range`.
    public func cost(in range: ClosedRange<Date>) -> Double {
        var s = 0.0
        for r in records {
            guard let ts = r.timestamp, range.contains(ts) else { continue }
            s += r.costUSD
        }
        return s
    }

    public struct ModelBreakdown: Equatable, Sendable {
        public var model: String
        public var costUSD: Double
        public var tokens: Int
        public init(model: String, costUSD: Double, tokens: Int) {
            self.model = model
            self.costUSD = costUSD
            self.tokens = tokens
        }
    }
    public func breakdownByModel(in range: ClosedRange<Date>) -> [ModelBreakdown] {
        var byModel: [String: (cost: Double, tokens: Int)] = [:]
        for r in records {
            guard let ts = r.timestamp, range.contains(ts) else { continue }
            var entry = byModel[r.model] ?? (0.0, 0)
            entry.cost += r.costUSD
            entry.tokens = ClaudeCodeUsageRecord.saturatingAdd(entry.tokens, r.totalTokens)
            byModel[r.model] = entry
        }
        return byModel
            .map { ModelBreakdown(model: $0.key, costUSD: $0.value.cost, tokens: $0.value.tokens) }
            .sorted { $0.costUSD > $1.costUSD }
    }
}

// MARK: - Path resolution

public enum ClinePathResolver {

    /// Environment snapshot passed to `resolveScanRoots`. Tests build
    /// this explicitly with fake env-vars and home; production uses
    /// `Environment.current()`.
    public struct Environment: Sendable {
        public var clineDataDir: String?
        public var clineDir: String?
        public var homeDirectoryPath: String
        /// Optional override for `~/Library/Application Support` — tests
        /// point this at a temp directory to fabricate the VS Code /
        /// Cursor / Windsurf layouts without touching the real user home.
        public var applicationSupportPath: String
        public init(
            clineDataDir: String?,
            clineDir: String?,
            homeDirectoryPath: String,
            applicationSupportPath: String
        ) {
            self.clineDataDir = clineDataDir
            self.clineDir = clineDir
            self.homeDirectoryPath = homeDirectoryPath
            self.applicationSupportPath = applicationSupportPath
        }

        public static func current() -> Environment {
            let env = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            return Environment(
                clineDataDir: env["CLINE_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 },
                clineDir: env["CLINE_DIR"].flatMap { $0.isEmpty ? nil : $0 },
                homeDirectoryPath: home,
                applicationSupportPath: (home as NSString).appendingPathComponent("Library/Application Support")
            )
        }
    }

    /// A single candidate scan root, with a stable id used for
    /// diagnostics ("VS Code stable", "Cline CLI", "Cursor"). The id is
    /// user-facing on the per-file diagnostic tile.
    public struct ScanRoot: Equatable, Sendable {
        public var id: String
        public var tasksDirectoryPath: String
        public init(id: String, tasksDirectoryPath: String) {
            self.id = id
            self.tasksDirectoryPath = tasksDirectoryPath
        }
    }

    /// Return every plausible scan root — the caller decides which of
    /// them actually exist and are readable. Duplicates are removed
    /// (e.g. `$CLINE_DIR/data` and `~/.cline/data` collapse to one if
    /// `$CLINE_DIR` resolves to `$HOME/.cline`).
    ///
    /// Codex round-1 finding #2: dedupe uses (1) filesystem identity
    /// (`URLResourceKey.fileResourceIdentifierKey`) when the path
    /// exists, so a case-insensitive HFS+/APFS mount does not fool us
    /// with `$CLINE_DIR=/users/…` vs the default `/Users/…`, and (2)
    /// case-folded standardized-path fallback for paths that do not
    /// yet exist (a fresh install with no tasks dir written yet).
    public static func resolveScanRoots(_ env: Environment) -> [ScanRoot] {
        var out: [ScanRoot] = []
        // Filesystem identity keys — collected when a path (or its
        // parent) exists. Two paths with the same identity are the
        // same on-disk directory regardless of case or symlink.
        var seenIdentity: Set<String> = []
        // Case-folded path fallback used ONLY when identity lookup
        // failed for the given path. Codex round-2 finding #1: on a
        // case-SENSITIVE APFS volume, two directories with names
        // differing only in case are DISTINCT, so the case-fold key
        // must not collapse them. We therefore run the case-fold
        // fallback only when we have no identity to compare (i.e.
        // neither path nor parent exists yet — a fresh install
        // scenario, where the user is not yet configured on this
        // Mac).
        var seenPathKey: Set<String> = []
        func add(_ id: String, _ rawBase: String) {
            let tasks = (rawBase as NSString).appendingPathComponent("tasks")
            let normalized = (tasks as NSString).standardizingPath
            if let identity = fileIdentity(of: normalized) {
                if !seenIdentity.insert(identity).inserted { return }
                // Path exists — trust identity dedupe alone. Do NOT
                // also apply the case-fold fallback (round-2 #1).
                out.append(ScanRoot(id: id, tasksDirectoryPath: normalized))
                return
            }
            // No identity available: fall back to case-folded path key.
            let caseFolded = normalized.lowercased()
            if !seenPathKey.insert(caseFolded).inserted { return }
            out.append(ScanRoot(id: id, tasksDirectoryPath: normalized))
        }
        /// Return a stable identity string for `path`, based on
        /// `stat()` device + inode when the path (or its parent) is
        /// reachable. Codex round-2 finding #2: `stat` is direct and
        /// avoids the URLResourceValues casting fragility on
        /// non-APFS filesystems (network mounts, exotic loopback).
        /// Returns nil when we cannot stat the path OR its parent.
        func fileIdentity(of path: String) -> String? {
            // Codex round-3 finding: use `stat()` (follows symlinks),
            // not `lstat()`. Otherwise `~/.cline/data/tasks` and its
            // symlink target (e.g. via `$CLINE_DATA_DIR`) look like
            // distinct inodes and both survive dedupe, causing the
            // same ui_messages.json files to be counted twice.
            var st = stat()
            let candidates: [String]
            if stat(path, &st) == 0 {
                candidates = [path]
            } else {
                let parent = (path as NSString).deletingLastPathComponent
                candidates = [parent]
            }
            for candidate in candidates {
                var s = stat()
                guard stat(candidate, &s) == 0 else { continue }
                let dev = UInt64(s.st_dev)
                let ino = UInt64(s.st_ino)
                if candidate == path {
                    return "\(dev):\(ino)"
                }
                // Parent hit: append the tail so two *sibling*
                // non-existing children under the same parent do NOT
                // dedupe together (they will resolve to distinct
                // (parent-dev:parent-ino:tail) strings).
                let tail = (path as NSString).lastPathComponent
                return "\(dev):\(ino):\(tail)"
            }
            return nil
        }
        if let dir = env.clineDataDir, !dir.isEmpty {
            add("Cline CLI ($CLINE_DATA_DIR)", dir)
        }
        if let dir = env.clineDir, !dir.isEmpty {
            add("Cline CLI ($CLINE_DIR)", (dir as NSString).appendingPathComponent("data"))
        }
        if !env.homeDirectoryPath.isEmpty {
            add("Cline CLI (~/.cline)", (env.homeDirectoryPath as NSString).appendingPathComponent(".cline/data"))
        }
        // VS Code family — each host has its own globalStorage.
        let hosts: [(String, String)] = [
            ("VS Code", "Code"),
            ("VS Code Insiders", "Code - Insiders"),
            ("VSCodium", "VSCodium"),
            ("Cursor", "Cursor"),
            ("Windsurf", "Windsurf"),
        ]
        for (label, folder) in hosts {
            if !env.applicationSupportPath.isEmpty {
                let base = "\(env.applicationSupportPath)/\(folder)/User/globalStorage/saoudrizwan.claude-dev"
                add(label, base)
            }
        }
        return out
    }
}

// MARK: - JSON parsing

/// Sendable value-type fetcher. All parsing is pure.
public struct ClineUsageFetcher: Sendable {

    /// Parse a single `ui_messages.json` file's contents. `contents` is
    /// the raw text of the file. Returns the records that parsed
    /// successfully; malformed usage-carrying messages count in the
    /// `malformedRecordCount` output. A non-JSON top-level content
    /// yields nil (the caller counts it as an unreadable file).
    public static func parse(
        uiMessages contents: String,
        sourceFile: String,
        malformedRecordCount: inout Int
    ) -> [ClineUsageRecord]? {
        // chk1 Bug #1: cast to `[Any]` at the top level, then per-element
        // `as? [String: Any]` guard. Casting straight to `[[String: Any]]`
        // is all-or-nothing — a single `null` / string / number in the
        // array collapses the entire file to unreadable. A schema drift
        // or a hand-edited log would otherwise silently drop hundreds of
        // valid records.
        guard let data = contents.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let anyArr = obj as? [Any] else {
            return nil
        }
        var out: [ClineUsageRecord] = []
        for element in anyArr {
            guard let msg = element as? [String: Any] else { continue }
            // Only `type == "say"` records carry usage.
            guard let type = msg["type"] as? String, type == "say" else { continue }
            guard let sayRaw = msg["say"] as? String,
                  let sayKind = ClineUsageRecord.SayKind(rawValue: sayRaw) else { continue }
            // The three usage-carrying kinds all encode their data in
            // the `text` field as a JSON string.
            guard let text = msg["text"] as? String else { continue }
            guard let payload = text.data(using: .utf8),
                  let payloadObj = try? JSONSerialization.jsonObject(with: payload),
                  let payloadDict = payloadObj as? [String: Any] else {
                malformedRecordCount += 1
                continue
            }
            let tokensIn = ClaudeCodeUsageFetcher.safeInt(payloadDict["tokensIn"])
            let tokensOut = ClaudeCodeUsageFetcher.safeInt(payloadDict["tokensOut"])
            let cacheWrites = ClaudeCodeUsageFetcher.safeInt(payloadDict["cacheWrites"])
            let cacheReads = ClaudeCodeUsageFetcher.safeInt(payloadDict["cacheReads"])
            let cost = safeCost(payloadDict["cost"])

            // Skip empty rows — a message.text that decoded successfully
            // but had every numeric field zero/absent is Cline's own
            // "no charge" marker (typical of a request that failed
            // before any tokens were emitted). Counting it as a record
            // would inflate the per-file diagnostic without changing
            // the rollup, so we drop it.
            if tokensIn == 0 && tokensOut == 0 && cacheWrites == 0
                && cacheReads == 0 && cost == 0 {
                continue
            }

            let timestamp = extractTimestamp(msg["ts"])
            let model = extractModel(msg)

            out.append(ClineUsageRecord(
                model: model,
                timestamp: timestamp,
                sayKind: sayKind,
                tokensIn: tokensIn,
                tokensOut: tokensOut,
                cacheWrites: cacheWrites,
                cacheReads: cacheReads,
                costUSD: cost,
                sourceFile: sourceFile
            ))
        }
        return out
    }

    /// Parse a set of `ui_messages.json` files into a full snapshot.
    /// I/O errors on individual files are counted, not thrown.
    public static func parse(files: [URL]) -> ClineUsageSnapshot {
        var allRecords: [ClineUsageRecord] = []
        var perFile: [String: Int] = [:]
        var malformed = 0
        var unreadable = 0

        for url in files {
            // Codex round-1 finding #3: read the file bytes directly
            // (bounded by a 64 MB Cline-specific cap) rather than
            // routing through the JSONL line-splitter — Cline's
            // ui_messages.json is a single JSON array, not
            // line-delimited, so splitting-then-rejoining is wasted
            // memory. 64 MB is well above any realistic Cline session
            // (~50 000 assistant turns) and matches ccusage's own cap.
            guard let text = readClineUiMessagesText(from: url) else {
                unreadable += 1
                continue
            }
            let recs = parse(
                uiMessages: text,
                sourceFile: url.path,
                malformedRecordCount: &malformed
            )
            guard let recs = recs else {
                unreadable += 1
                continue
            }
            perFile[url.path] = recs.count
            allRecords.append(contentsOf: recs)
        }

        allRecords.sort { lhs, rhs in
            switch (lhs.timestamp, rhs.timestamp) {
            case let (l?, r?): return l < r
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return false
            }
        }
        return ClineUsageSnapshot(
            records: allRecords,
            recordsPerFile: perFile,
            malformedRecordCount: malformed,
            unreadableFileCount: unreadable
        )
    }

    /// Enumerate every `ui_messages.json` under every scan root's
    /// `tasks/{taskId}/` subtree. A missing scan root or missing tasks
    /// directory yields no files (not an error). Individual unreadable
    /// entries are skipped.
    public static func discoverFiles(under scanRoots: [ClinePathResolver.ScanRoot]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for root in scanRoots {
            let tasksDir = root.tasksDirectoryPath
            guard fm.fileExists(atPath: tasksDir) else { continue }
            guard let contents = try? fm.contentsOfDirectory(atPath: tasksDir) else { continue }
            for entry in contents {
                let taskDir = (tasksDir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: taskDir, isDirectory: &isDir), isDir.boolValue else { continue }
                let candidate = (taskDir as NSString).appendingPathComponent("ui_messages.json")
                if fm.fileExists(atPath: candidate) {
                    out.append(URL(fileURLWithPath: candidate))
                }
            }
        }
        out.sort { $0.path < $1.path }
        return out
    }

    /// Read a Cline `ui_messages.json` file into a decoded string.
    /// Streams via FileHandle in 1 MiB chunks, aborting once the
    /// cumulative buffer exceeds a 64 MB cap (well above any real
    /// Cline session; matches ccusage's own cap for the same file).
    /// UTF-8 decoding is tolerant — invalid bytes become U+FFFD, so a
    /// torn write near end-of-file surfaces as invalid JSON rather
    /// than a nil return that discards the whole file. Returns nil
    /// only when the file cannot be opened.
    static func readClineUiMessagesText(from url: URL) -> String? {
        let sizeCap: Int64 = 64 * 1024 * 1024
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = (attrs?[.size] as? NSNumber)?.int64Value, size > sizeCap {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunkSize = 1024 * 1024
        var buffer = Data()
        buffer.reserveCapacity(chunkSize * 2)
        while true {
            // chk1 Bug #3: the fallback `readData(ofLength:)` branch was
            // gated on `#available(macOS 10.15.4, *)` but the app targets
            // macOS 12.0 (see `app/build.sh` — `-target arm64-apple-macos12.0`),
            // so the branch was unreachable dead code AND its
            // `readData(ofLength:)` raises Objective-C NSException on error
            // (uncatchable in Swift), unlike the throwing
            // `read(upToCount:)`. Deleted entirely.
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: chunkSize) else { break }
                chunk = read
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if Int64(buffer.count) > sizeCap { return nil }
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    // MARK: - Field helpers

    /// Cline stores `ts` as milliseconds since epoch (JavaScript
    /// `Date.now()` output). Clamp to a sane range so a schema break
    /// cannot inject a distant-past or distant-future record into the
    /// today/MTD bucketing. Public so tests exercise the range clamp
    /// against hostile inputs (NaN, infinity, 1e18, negatives).
    public static func extractTimestamp(_ raw: Any?) -> Date? {
        let msSince1970: Double
        if let d = raw as? Double { msSince1970 = d }
        else if let i = raw as? Int { msSince1970 = Double(i) }
        else if let s = raw as? String, let parsed = Double(s) { msSince1970 = parsed }
        else { return nil }
        guard msSince1970.isFinite else { return nil }
        let seconds = msSince1970 / 1000.0
        // Reject anything before 2000-01-01 or after 2100-01-01 —
        // outside this range the value is unlikely to be a real Cline
        // timestamp (typical values are in the 1.7e12 ms range).
        let year2000: Double = 946_684_800   // 2000-01-01T00:00:00Z
        let year2100: Double = 4_102_444_800 // 2100-01-01T00:00:00Z
        guard seconds >= year2000 && seconds < year2100 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Extract `modelInfo.modelId` when present. Falls back to
    /// "unknown" so a Cline version predating modelInfo (~<v3.5) still
    /// contributes to token/cost rollups. Public so tests exercise the
    /// fallback path.
    public static func extractModel(_ msg: [String: Any]) -> String {
        guard let modelInfo = msg["modelInfo"] as? [String: Any] else { return "unknown" }
        if let id = modelInfo["modelId"] as? String, !id.isEmpty { return id }
        return "unknown"
    }

    /// Cost is a JSON Number in USD. Reject NaN / infinity / negative
    /// (a hostile or corrupt log). Clamp very large finite values to a
    /// $1_000_000 cap so a single bad record cannot silently dominate
    /// every rollup. Public so tests can exercise every rejection
    /// branch.
    public static func safeCost(_ raw: Any?) -> Double {
        var value: Double
        if let d = raw as? Double { value = d }
        else if let i = raw as? Int { value = Double(i) }
        else if let s = raw as? String, let parsed = Double(s) { value = parsed }
        else { return 0.0 }
        guard value.isFinite else { return 0.0 }
        if value <= 0 { return 0.0 }
        return min(value, 1_000_000.0)
    }
}
