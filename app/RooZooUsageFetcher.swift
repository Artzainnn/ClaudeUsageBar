// PR 13-BE — Roo Code + Zoo Code local usage fetcher (feature-flag off).
//
// Reads the shared Cline-family per-task record layout. Both Roo and
// Zoo write per-task `history_item.json` rollups AND raw
// `ui_messages.json` message arrays under
// `{globalStorage}/<publisher>/tasks/{taskId}/`.
//
// Reader precedence per task:
//   1. history_item.json (a flat object with `totalCost`, tokensIn,
//      tokensOut, cacheWrites, cacheReads) — cheap and authoritative.
//   2. If history_item.json is absent, empty, or fails parse, fall
//      back to ui_messages.json via ClineUsageFetcher.parse (the
//      same wire shape). Aggregate to a single task record using
//      the sum of tokensIn/tokensOut/… and the LAST record's
//      timestamp as the task timestamp. (3cc R1 F6 — precedence is
//      exclusive per task; never both.)
//
// 3cc R1 F1 / F2: `history_item.json` field name is `totalCost`
// NOT `cost`. A parser that reused Cline's `text.cost` extraction
// would return zero cost for every Roo/Zoo task.
//
// 3cc R3 F11: cap enumerated tasks at 10 000 most-recent by
// directory mtime desc. Beyond that, mark as diagnostic
// (overTaskCapCount) — never silently drop.
//
// 3cc R3 F9: ui_messages.json size cap is 128 MB (higher than
// Cline's 64 MB; Roo/Zoo sessions are known to be longer than
// typical Cline sessions).
//
// 3cc R1 F8: task-id-level dedupe across Roo↔Zoo — if a task with
// the same id exists in both extension namespaces, keep the
// first-seen record (scan-root order determines precedence at the
// caller).
//
// Feature posture — nothing registers a RooUsageStore or
// ZooUsageStore into the live registry yet; that lands in PR 13-UI.

import Foundation

public enum RollupSource: String, Sendable, Equatable {
    case historyItem
    case uiMessagesFallback
}

public struct RooZooTaskRecord: Equatable, Sendable {
    public var taskId: String
    public var model: String
    public var timestamp: Date?
    public var tokensIn: Int
    public var tokensOut: Int
    public var cacheWrites: Int
    public var cacheReads: Int
    public var costUSD: Double
    public var extensionId: RooZooExtension
    public var sourcePath: String
    public var source: RollupSource

    public init(taskId: String, model: String, timestamp: Date?,
                tokensIn: Int, tokensOut: Int, cacheWrites: Int, cacheReads: Int,
                costUSD: Double, extensionId: RooZooExtension,
                sourcePath: String, source: RollupSource) {
        self.taskId = taskId
        self.model = model
        self.timestamp = timestamp
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.cacheWrites = cacheWrites
        self.cacheReads = cacheReads
        self.costUSD = costUSD
        self.extensionId = extensionId
        self.sourcePath = sourcePath
        self.source = source
    }

    public var totalTokens: Int {
        var s = ClaudeCodeUsageRecord.saturatingAdd(0, tokensIn)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, tokensOut)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, cacheWrites)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, cacheReads)
        return s
    }
}

public struct RooZooUsageSnapshot: Equatable, Sendable {
    public var records: [RooZooTaskRecord]
    public var recordsPerRoot: [String: Int]
    public var unreadableFileCount: Int
    public var malformedRecordCount: Int
    public var overCapFileCount: Int
    public var overTaskCapCount: Int

    public init(records: [RooZooTaskRecord],
                recordsPerRoot: [String: Int] = [:],
                unreadableFileCount: Int = 0,
                malformedRecordCount: Int = 0,
                overCapFileCount: Int = 0,
                overTaskCapCount: Int = 0) {
        self.records = records
        self.recordsPerRoot = recordsPerRoot
        self.unreadableFileCount = unreadableFileCount
        self.malformedRecordCount = malformedRecordCount
        self.overCapFileCount = overCapFileCount
        self.overTaskCapCount = overTaskCapCount
    }

    public func tokens(in range: ClosedRange<Date>) -> Int {
        var s = 0
        for r in records {
            guard let ts = r.timestamp, range.contains(ts) else { continue }
            s = ClaudeCodeUsageRecord.saturatingAdd(s, r.totalTokens)
        }
        return s
    }

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

/// One discovered task ready to parse. Kept as a public struct so
/// tests can build fake inputs without the disk enumeration path.
public struct RooZooDiscoveredTask: Equatable, Sendable {
    public var taskId: String
    public var taskDir: String
    public var extensionId: RooZooExtension
    public init(taskId: String, taskDir: String, extensionId: RooZooExtension) {
        self.taskId = taskId
        self.taskDir = taskDir
        self.extensionId = extensionId
    }
}

public struct RooZooUsageFetcher: Sendable {

    /// Cap on the number of task directories the fetcher will
    /// enumerate per fetch tick. Sort by mtime desc; anything beyond
    /// the cap is counted as `overTaskCapCount` for the diagnostic
    /// tile. (3cc R3 F11.)
    public static let taskCap: Int = 10_000

    /// Size cap for the `ui_messages.json` fallback path. Roo/Zoo
    /// sessions are known to be longer than typical Cline sessions.
    /// (3cc R3 F9.)
    public static let uiMessagesSizeCap: Int64 = 128 * 1024 * 1024

    /// Parse a single task's `history_item.json`. Returns nil if the
    /// file is missing, empty, or the top-level JSON is not an object.
    /// Also returns nil if every numeric field is zero — Zoo writes
    /// an empty rollup during some error paths.
    ///
    /// Field name is `totalCost` (NOT `cost`) — 3cc R1 F1.
    public static func parseHistoryItem(
        atPath path: String,
        taskId: String,
        extensionId: RooZooExtension
    ) -> RooZooTaskRecord? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard !data.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return nil
        }
        let tokensIn = ClaudeCodeUsageFetcher.safeInt(dict["tokensIn"])
        let tokensOut = ClaudeCodeUsageFetcher.safeInt(dict["tokensOut"])
        let cacheWrites = ClaudeCodeUsageFetcher.safeInt(dict["cacheWrites"])
        let cacheReads = ClaudeCodeUsageFetcher.safeInt(dict["cacheReads"])
        let cost = safeCostFromHistoryItem(dict["totalCost"])
        if tokensIn == 0 && tokensOut == 0 && cacheWrites == 0
            && cacheReads == 0 && cost == 0 {
            return nil
        }
        let model = extractModel(from: dict)
        let ts = extractTimestampMs(dict["ts"])
        return RooZooTaskRecord(
            taskId: taskId,
            model: model,
            timestamp: ts,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            cacheWrites: cacheWrites,
            cacheReads: cacheReads,
            costUSD: cost,
            extensionId: extensionId,
            sourcePath: path,
            source: .historyItem
        )
    }

    /// Discover per-task subdirectories under each scan root, sorted
    /// by mtime desc across all scan roots. Cap at `cap` total tasks;
    /// return the over-cap count separately. Returns `.tasks` in
    /// mtime-desc order so the caller can iterate newest first.
    public static func discoverTasks(
        under scanRoots: [RooZooPathResolver.ScanRoot],
        cap: Int = taskCap
    ) -> (tasks: [RooZooDiscoveredTask], overCap: Int) {
        let fm = FileManager.default
        var candidates: [(task: RooZooDiscoveredTask, mtime: Date)] = []
        for root in scanRoots {
            let tasksDir = root.tasksDirectoryPath
            guard fm.fileExists(atPath: tasksDir) else { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: tasksDir) else { continue }
            for entry in entries {
                let taskDir = (tasksDir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: taskDir, isDirectory: &isDir), isDir.boolValue else { continue }
                let attrs = (try? fm.attributesOfItem(atPath: taskDir)) ?? [:]
                let mtime = (attrs[.modificationDate] as? Date) ?? Date.distantPast
                let task = RooZooDiscoveredTask(
                    taskId: entry, taskDir: taskDir, extensionId: root.extensionId
                )
                candidates.append((task: task, mtime: mtime))
            }
        }
        candidates.sort { $0.mtime > $1.mtime }
        if candidates.count > cap {
            let overCap = candidates.count - cap
            return (candidates.prefix(cap).map { $0.task }, overCap)
        }
        return (candidates.map { $0.task }, 0)
    }

    /// Parse a set of discovered tasks. Task-id-level dedupe across
    /// the whole list (first-seen wins — Roo scan roots typically
    /// precede Zoo scan roots in the caller's order).
    public static func parseTasks(
        _ tasks: [RooZooDiscoveredTask]
    ) -> RooZooUsageSnapshot {
        var records: [RooZooTaskRecord] = []
        var perRoot: [String: Int] = [:]
        var unreadable = 0
        var malformed = 0
        var overCap = 0
        var seenTaskIds: Set<String> = []

        for task in tasks {
            if seenTaskIds.contains(task.taskId) { continue }

            let historyPath = (task.taskDir as NSString).appendingPathComponent("history_item.json")
            if let rec = parseHistoryItem(atPath: historyPath, taskId: task.taskId, extensionId: task.extensionId) {
                seenTaskIds.insert(task.taskId)
                records.append(rec)
                perRoot[task.taskDir, default: 0] += 1
                continue
            }

            // Fallback: ui_messages.json via Cline parser.
            let uiPath = (task.taskDir as NSString).appendingPathComponent("ui_messages.json")
            guard FileManager.default.fileExists(atPath: uiPath) else {
                // Neither file — probably in-flight task with
                // neither yet written. Skip silently.
                continue
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: uiPath)
            if let size = (attrs?[.size] as? NSNumber)?.int64Value,
               size > uiMessagesSizeCap {
                overCap += 1
                continue
            }
            guard let text = ClineUsageFetcher.readClineUiMessagesText(from: URL(fileURLWithPath: uiPath)) else {
                unreadable += 1
                continue
            }
            var localMalformed = 0
            guard let clineRecs = ClineUsageFetcher.parse(
                uiMessages: text,
                sourceFile: uiPath,
                malformedRecordCount: &localMalformed
            ) else {
                unreadable += 1
                continue
            }
            malformed += localMalformed
            // Aggregate the Cline records into a single task-level
            // record so the snapshot bucketing works.
            var tokensIn = 0, tokensOut = 0, cacheWrites = 0, cacheReads = 0
            var cost = 0.0
            var lastTs: Date? = nil
            var model = "unknown"
            for r in clineRecs {
                tokensIn = ClaudeCodeUsageRecord.saturatingAdd(tokensIn, r.tokensIn)
                tokensOut = ClaudeCodeUsageRecord.saturatingAdd(tokensOut, r.tokensOut)
                cacheWrites = ClaudeCodeUsageRecord.saturatingAdd(cacheWrites, r.cacheWrites)
                cacheReads = ClaudeCodeUsageRecord.saturatingAdd(cacheReads, r.cacheReads)
                cost += r.costUSD
                if let ts = r.timestamp { lastTs = ts }
                if r.model != "unknown" { model = r.model }
            }
            if tokensIn == 0 && tokensOut == 0 && cacheWrites == 0
                && cacheReads == 0 && cost == 0 {
                continue
            }
            seenTaskIds.insert(task.taskId)
            records.append(RooZooTaskRecord(
                taskId: task.taskId,
                model: model,
                timestamp: lastTs,
                tokensIn: tokensIn,
                tokensOut: tokensOut,
                cacheWrites: cacheWrites,
                cacheReads: cacheReads,
                costUSD: cost,
                extensionId: task.extensionId,
                sourcePath: uiPath,
                source: .uiMessagesFallback
            ))
            perRoot[task.taskDir, default: 0] += 1
        }
        records.sort { lhs, rhs in
            switch (lhs.timestamp, rhs.timestamp) {
            case let (l?, r?): return l < r
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return false
            }
        }
        return RooZooUsageSnapshot(
            records: records,
            recordsPerRoot: perRoot,
            unreadableFileCount: unreadable,
            malformedRecordCount: malformed,
            overCapFileCount: overCap,
            overTaskCapCount: 0
        )
    }

    // MARK: - Field extraction helpers

    static func safeCostFromHistoryItem(_ raw: Any?) -> Double {
        // Bool guard first — same reasoning as ClaudeCodeUsageFetcher.safeInt.
        if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            return 0.0
        }
        var value: Double
        if let d = raw as? Double { value = d }
        else if let i = raw as? Int { value = Double(i) }
        else if let s = raw as? String, let parsed = Double(s) { value = parsed }
        else { return 0.0 }
        guard value.isFinite else { return 0.0 }
        if value <= 0 { return 0.0 }
        return min(value, 1_000_000.0)
    }

    static func extractModel(from dict: [String: Any]) -> String {
        if let m = dict["model"] as? String, !m.isEmpty { return m }
        return "unknown"
    }

    /// Roo/Zoo `history_item.json` `ts` is JS `Date.now()` — ms
    /// since epoch. Clamp to `[year2000, year2100)`.
    static func extractTimestampMs(_ raw: Any?) -> Date? {
        let msSince1970: Double
        if let d = raw as? Double { msSince1970 = d }
        else if let i = raw as? Int { msSince1970 = Double(i) }
        else if let s = raw as? String, let parsed = Double(s) { msSince1970 = parsed }
        else { return nil }
        guard msSince1970.isFinite else { return nil }
        let seconds = msSince1970 / 1000.0
        let year2000: Double = 946_684_800
        let year2100: Double = 4_102_444_800
        guard seconds >= year2000 && seconds < year2100 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
