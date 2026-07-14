// PR 13-BE — Continue local dev-data JSONL fetcher (feature-flag off).
//
// Reads Continue's own on-disk `tokensGenerated.jsonl` at
// `~/.continue/dev_data/0.2.0/tokensGenerated.jsonl`. Nothing leaves the
// machine. Tokens-only (Continue's schema has NO cost field and NO cache
// tokens; adding cost would require a cross-provider LiteLLM pricing
// snapshot, which is out of scope for this PR).
//
// Continue writes 10 sibling event streams under the same folder
// (autocomplete, chatFeedback, chatInteraction, editInteraction,
// editOutcome, nextEditOutcome, nextEditWithHistory, toolUsage, plus a
// legacy quickEdit under 0.1.0). We consume ONLY tokensGenerated, which
// is the single canonical source of token counts across every LLM call
// in Continue.
//
// Schema per line (verbatim from continuedev/continue's
// `packages/config-yaml/src/schemas/data/tokensGenerated/v0.2.0.ts`):
//
//   { timestamp, userId, userAgent, selectedProfileId, eventName,
//     schema, model, provider, promptTokens, generatedTokens }
//
// `timestamp` is ISO-8601 (`new Date().toISOString()`), NOT ms-since-
// epoch. Feed it through `ClaudeCodeUsageFetcher.parseTimestamp` — Cline's
// own `extractTimestamp` would treat the string as `Double(s)`, return
// nil, and every Continue record's timestamp would be dropped from the
// today / MTD buckets. (3cc R1 F10 / R3 F3.)
//
// Local logging is unconditionally ON in Continue (`core/data/log.ts:88`
// comment: `// Local logs (always on for all levels)`). No user-side
// enable step; if Continue has been used, the file exists.
//
// Feature posture — `features.continue.enabled` defaults false.
// Nothing registers a ContinueUsageStore into the live registry yet
// (that lands in the store commit later in this PR).

import Foundation

// MARK: - Snapshot pieces

public struct ContinueUsageRecord: Equatable, Sendable {
    public var model: String
    public var provider: String
    public var timestamp: Date?
    public var promptTokens: Int
    public var generatedTokens: Int
    public var sourceFile: String

    public init(model: String, provider: String, timestamp: Date?,
                promptTokens: Int, generatedTokens: Int, sourceFile: String) {
        self.model = model
        self.provider = provider
        self.timestamp = timestamp
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.sourceFile = sourceFile
    }

    /// Sum of prompt + generated tokens. Uses saturating addition so a
    /// hostile 1e300 in the wire data cannot wrap to a negative count.
    public var totalTokens: Int {
        ClaudeCodeUsageRecord.saturatingAdd(promptTokens, generatedTokens)
    }
}

public struct ContinueUsageSnapshot: Equatable, Sendable {
    public var records: [ContinueUsageRecord]
    public var recordsPerFile: [String: Int]
    public var malformedRecordCount: Int
    public var unreadableFileCount: Int
    /// Files that existed but exceeded the 256 MB cap. Distinguished
    /// from `unreadableFileCount` so the tile can surface a specific
    /// diagnostic ("N log files exceeded the 256 MB cap"). 3cc R3 F9.
    public var overCapFileCount: Int

    public init(records: [ContinueUsageRecord],
                recordsPerFile: [String: Int] = [:],
                malformedRecordCount: Int = 0,
                unreadableFileCount: Int = 0,
                overCapFileCount: Int = 0) {
        self.records = records
        self.recordsPerFile = recordsPerFile
        self.malformedRecordCount = malformedRecordCount
        self.unreadableFileCount = unreadableFileCount
        self.overCapFileCount = overCapFileCount
    }

    /// Sum of tokens over records whose `timestamp` falls within `range`.
    /// Uses saturating addition to avoid Int overflow on a corrupt log.
    public func tokens(in range: ClosedRange<Date>) -> Int {
        var s = 0
        for r in records {
            guard let ts = r.timestamp, range.contains(ts) else { continue }
            s = ClaudeCodeUsageRecord.saturatingAdd(s, r.totalTokens)
        }
        return s
    }

    public struct ModelBreakdown: Equatable, Sendable {
        public var model: String
        public var tokens: Int
        public init(model: String, tokens: Int) {
            self.model = model
            self.tokens = tokens
        }
    }

    /// Per-model token breakdown for `range`, sorted descending. Used
    /// for the `continue-by-model` tile.
    public func breakdownByModel(in range: ClosedRange<Date>) -> [ModelBreakdown] {
        var byModel: [String: Int] = [:]
        for r in records {
            guard let ts = r.timestamp, range.contains(ts) else { continue }
            byModel[r.model] = ClaudeCodeUsageRecord.saturatingAdd(
                byModel[r.model] ?? 0, r.totalTokens)
        }
        return byModel.map { ModelBreakdown(model: $0.key, tokens: $0.value) }
                      .sorted { $0.tokens > $1.tokens }
    }

    public struct ProviderBreakdown: Equatable, Sendable {
        public var provider: String
        public var tokens: Int
        public init(provider: String, tokens: Int) {
            self.provider = provider
            self.tokens = tokens
        }
    }

    /// Per-provider token breakdown for `range`, sorted descending. Used
    /// for the `continue-by-provider` tile.
    public func breakdownByProvider(in range: ClosedRange<Date>) -> [ProviderBreakdown] {
        var byProv: [String: Int] = [:]
        for r in records {
            guard let ts = r.timestamp, range.contains(ts) else { continue }
            byProv[r.provider] = ClaudeCodeUsageRecord.saturatingAdd(
                byProv[r.provider] ?? 0, r.totalTokens)
        }
        return byProv.map { ProviderBreakdown(provider: $0.key, tokens: $0.value) }
                     .sorted { $0.tokens > $1.tokens }
    }
}

// MARK: - Path resolution

public enum ContinuePathResolver {
    public struct Environment: Sendable {
        public var homeDirectoryPath: String
        public init(homeDirectoryPath: String) {
            self.homeDirectoryPath = homeDirectoryPath
        }
        public static func current() -> Environment {
            Environment(homeDirectoryPath: NSHomeDirectory())
        }
    }

    public struct ScanRoot: Equatable, Sendable {
        public var id: String
        public var jsonlPath: String
        public init(id: String, jsonlPath: String) {
            self.id = id
            self.jsonlPath = jsonlPath
        }
    }

    /// Single-root resolution. Only `0.2.0/tokensGenerated.jsonl` is
    /// scanned. Legacy `0.1.0/` folder is not read — schema for that
    /// version is not verified, and the population of users still on
    /// pre-2024 Continue is negligible. If a user has both folders,
    /// the 0.1.0 activity is silently missing. Acceptable — the tile
    /// value on any current user overwhelmingly derives from 0.2.0.
    /// (3cc R2 F5.)
    public static func resolveScanRoots(_ env: Environment) -> [ScanRoot] {
        guard !env.homeDirectoryPath.isEmpty else { return [] }
        let path = (env.homeDirectoryPath as NSString)
            .appendingPathComponent(".continue/dev_data/0.2.0/tokensGenerated.jsonl")
        return [ScanRoot(id: "Continue", jsonlPath: path)]
    }
}

// MARK: - Fetcher

public struct ContinueUsageFetcher: Sendable {

    /// 256 MB cap on the JSONL file. Matches ClaudeCode. A Continue
    /// power-user log grows by ~1 KB per request; at 1000 requests/day
    /// that's 365 MB/year — realistic to hit within 2 years.
    /// (3cc R3 F9 — beyond cap, `overCapFileCount` is incremented and
    /// the file is skipped with a distinct diagnostic. A tail-read
    /// strategy is out of scope for v1; if a user reports hitting the
    /// cap, a future PR will add tail-read.)
    public static let jsonlSizeCap: Int64 = 256 * 1024 * 1024

    /// Parse one JSONL line into a `ContinueUsageRecord`.
    ///
    /// Returns nil for:
    ///   - Empty or whitespace-only lines (no malformed increment).
    ///   - Records with a non-"tokensGenerated" eventName (no malformed
    ///     increment — defensive against a future refactor that mixes
    ///     streams in the same file).
    ///   - Records where both promptTokens and generatedTokens are zero
    ///     (no contribution to any tile).
    ///
    /// Returns nil and increments `malformedCount` for:
    ///   - JSON parse failure.
    ///   - Top-level value not a JSON object.
    ///
    /// Numeric fields go through `ClaudeCodeUsageFetcher.safeInt`
    /// which now includes the `is Bool` guard (PR 13-BE 3cc R3 F8).
    /// Timestamps go through `parseTimestamp` which now clamps to
    /// `[year2000, year2100)`.
    public static func parseLine(
        _ line: String,
        sourceFile: String,
        malformedCount: inout Int
    ) -> ContinueUsageRecord? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            malformedCount += 1
            return nil
        }
        // Defensive: only accept records whose eventName is
        // "tokensGenerated". A future refactor that mixes streams in
        // the same file would otherwise leak autocomplete-only
        // records into the token counter tile.
        if let ev = dict["eventName"] as? String, ev != "tokensGenerated" {
            return nil
        }
        let model = (dict["model"] as? String) ?? "unknown"
        let provider = (dict["provider"] as? String) ?? "unknown"
        let promptTokens = ClaudeCodeUsageFetcher.safeInt(dict["promptTokens"])
        let generatedTokens = ClaudeCodeUsageFetcher.safeInt(dict["generatedTokens"])
        if promptTokens == 0 && generatedTokens == 0 { return nil }

        var ts: Date? = nil
        if let rawTs = dict["timestamp"] as? String {
            ts = ClaudeCodeUsageFetcher.parseTimestamp(rawTs)
        }

        return ContinueUsageRecord(
            model: model,
            provider: provider,
            timestamp: ts,
            promptTokens: promptTokens,
            generatedTokens: generatedTokens,
            sourceFile: sourceFile
        )
    }

    /// Parse a set of Continue JSONL files into a full snapshot.
    ///
    /// Uses `ClaudeCodeUsageFetcher.readJsonlLines` under the hood
    /// (per-line UTF-8 tolerance, streaming FileHandle, 256 MB cap).
    /// A file that exceeds cap is counted as `overCapFileCount` (not
    /// `unreadableFileCount`) so the store's diagnostic tile can
    /// surface it distinctly. Individual malformed lines are counted
    /// as `malformedRecordCount` without discarding the file.
    public static func parse(files: [URL]) -> ContinueUsageSnapshot {
        var allRecords: [ContinueUsageRecord] = []
        var perFile: [String: Int] = [:]
        var malformed = 0
        var unreadable = 0
        var overCap = 0

        for url in files {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let size = (attrs?[.size] as? NSNumber)?.int64Value,
               size > jsonlSizeCap {
                overCap += 1
                continue
            }
            guard let lines = ClaudeCodeUsageFetcher.readJsonlLines(from: url) else {
                unreadable += 1
                continue
            }
            var perFileCount = 0
            for line in lines {
                guard let rec = parseLine(line, sourceFile: url.path,
                                          malformedCount: &malformed) else {
                    continue
                }
                allRecords.append(rec)
                perFileCount += 1
            }
            perFile[url.path] = perFileCount
        }

        allRecords.sort { lhs, rhs in
            switch (lhs.timestamp, rhs.timestamp) {
            case let (l?, r?): return l < r
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return false
            }
        }

        return ContinueUsageSnapshot(
            records: allRecords,
            recordsPerFile: perFile,
            malformedRecordCount: malformed,
            unreadableFileCount: unreadable,
            overCapFileCount: overCap
        )
    }

    /// Given a list of scan roots, return the URLs of every file that
    /// currently exists. A missing file is not an error; the store
    /// classifies via TCC probe (either `.pathMissing` for a fresh
    /// install, or `.denied` if TCC blocks the read).
    public static func discoverFiles(under scanRoots: [ContinuePathResolver.ScanRoot]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for root in scanRoots {
            if fm.fileExists(atPath: root.jsonlPath) {
                out.append(URL(fileURLWithPath: root.jsonlPath))
            }
        }
        return out
    }
}
