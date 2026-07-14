// PR 15-BE — Gemini Developer local JSONL fetcher (feature-flag off).
//
// Reads Gemini CLI's own on-disk session logs and produces a
// token-and-cost rollup. Nothing leaves the machine.
//
// Data source
// -----------
// Gemini CLI writes one JSONL file per session under:
//
//   ~/.gemini/tmp/<projectHash>/chats/session-<ts>-<sessionIdShort>.jsonl
//
// (Path constant `GEMINI_DIR = ".gemini"` from
// `google-gemini/gemini-cli` `packages/core/src/utils/paths.ts`;
// `getProjectTempDir()` in `storage.ts` resolves to
// `~/.gemini/tmp/<projectHash>/`; per-session file at
// `chats/session-<timestamp>-<idShort>.jsonl` per `gemini.tsx`.)
//
// Path resolution (in order):
//   1. `$GEMINI_CLI_HOME` (official env-var override).
//   2. `~/.gemini` (default).
//
// Each line is one of three record types:
//   - `MessageRecord` — carries `id`, `type` (`"user" | "gemini" | ...`),
//     `timestamp` (ISO-8601), and — for `type == "gemini"` — a
//     `tokens: TokensSummary` block plus optional `model` string.
//   - `RewindRecord` — `{"$rewindTo": "<messageId>"}`.
//   - `MetadataUpdateRecord` — `{"$set": {...}}`.
//
// TokensSummary shape (per `chatRecordingTypes.ts`):
//   input, output, cached, total, thoughts?, tool?
// The on-disk name is `input` (= promptTokenCount),
// `output` (= candidatesTokenCount), `cached` (= cachedContentTokenCount),
// `total` (= totalTokenCount).
//
// We consume ONLY `MessageRecord` with `type == "gemini"` and a
// non-nil `tokens` block. User messages and metadata / rewind records
// are ignored (they carry no usage).
//
// Cost is derived from Gemini's public per-token pricing at build
// time (Gemini 2.5 Pro, 2.5 Flash, 1.5 Pro, 1.5 Flash — the models
// most CLI users hit). Unknown models produce a zero-cost line rather
// than throwing.
//
// Feature posture — `features.gemini.enabled` defaults false.
// Nothing registers a GeminiUsageStore into the live registry yet.

import Foundation

// MARK: - Snapshot pieces

public struct GeminiUsageRecord: Equatable, Sendable {
    public var model: String
    public var timestamp: Date?
    public var messageId: String?
    /// promptTokenCount (input tokens).
    public var inputTokens: Int
    /// candidatesTokenCount (output tokens).
    public var outputTokens: Int
    /// cachedContentTokenCount (may be zero).
    public var cachedTokens: Int
    /// thoughtsTokenCount (Gemini 2.5's reasoning-thought tokens, if
    /// present in the log). Zero when absent.
    public var thoughtsTokens: Int
    /// toolUsePromptTokenCount — additional tokens attributed to
    /// tool-use prompts. Zero when absent.
    public var toolTokens: Int
    /// Cost in USD derived from a bundled per-model rate table.
    /// Zero for unknown models — the "Pricing update available"
    /// diagnostic tile surfaces when a non-zero unknown-model count
    /// appears in the snapshot.
    public var costUSD: Double
    /// Absolute path of the source JSONL file. Used for per-file
    /// diagnostics.
    public var sourceFile: String

    public init(
        model: String,
        timestamp: Date?,
        messageId: String? = nil,
        inputTokens: Int,
        outputTokens: Int,
        cachedTokens: Int,
        thoughtsTokens: Int,
        toolTokens: Int,
        costUSD: Double,
        sourceFile: String
    ) {
        self.model = model
        self.timestamp = timestamp
        self.messageId = messageId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.thoughtsTokens = thoughtsTokens
        self.toolTokens = toolTokens
        self.costUSD = costUSD
        self.sourceFile = sourceFile
    }

    /// Sum of every token category. Uses saturating addition (via
    /// `ClaudeCodeUsageRecord.saturatingAdd`) to avoid Int overflow
    /// on a hostile 1e300 in the wire data.
    public var totalTokens: Int {
        var s = ClaudeCodeUsageRecord.saturatingAdd(0, inputTokens)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, outputTokens)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, cachedTokens)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, thoughtsTokens)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, toolTokens)
        return s
    }
}

public struct GeminiUsageSnapshot: Equatable, Sendable {
    public var records: [GeminiUsageRecord]
    public var recordsPerFile: [String: Int]
    public var malformedRecordCount: Int
    public var unreadableFileCount: Int
    public var overCapFileCount: Int
    public var unknownModelRecordCount: Int

    public init(
        records: [GeminiUsageRecord],
        recordsPerFile: [String: Int] = [:],
        malformedRecordCount: Int = 0,
        unreadableFileCount: Int = 0,
        overCapFileCount: Int = 0,
        unknownModelRecordCount: Int = 0
    ) {
        self.records = records
        self.recordsPerFile = recordsPerFile
        self.malformedRecordCount = malformedRecordCount
        self.unreadableFileCount = unreadableFileCount
        self.overCapFileCount = overCapFileCount
        self.unknownModelRecordCount = unknownModelRecordCount
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

// MARK: - Path resolution

public enum GeminiPathResolver {
    public struct Environment: Sendable {
        public var geminiCliHome: String?
        public var homeDirectoryPath: String
        public init(geminiCliHome: String?, homeDirectoryPath: String) {
            self.geminiCliHome = geminiCliHome
            self.homeDirectoryPath = homeDirectoryPath
        }
        public static func current() -> Environment {
            let env = ProcessInfo.processInfo.environment
            let cliHome = env["GEMINI_CLI_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            return Environment(geminiCliHome: cliHome, homeDirectoryPath: NSHomeDirectory())
        }
    }

    public struct ScanRoot: Equatable, Sendable {
        public var id: String
        public var tmpDirectoryPath: String
        public init(id: String, tmpDirectoryPath: String) {
            self.id = id
            self.tmpDirectoryPath = tmpDirectoryPath
        }
    }

    /// Return the single Gemini `tmp/` root that contains project
    /// subdirectories. First-hit-wins: `$GEMINI_CLI_HOME/tmp` if set,
    /// then `~/.gemini/tmp`.
    public static func resolveScanRoots(_ env: Environment) -> [ScanRoot] {
        if let cliHome = env.geminiCliHome, !cliHome.isEmpty {
            let path = (cliHome as NSString).appendingPathComponent("tmp")
            return [ScanRoot(id: "Gemini CLI ($GEMINI_CLI_HOME)", tmpDirectoryPath: path)]
        }
        guard !env.homeDirectoryPath.isEmpty else { return [] }
        let path = (env.homeDirectoryPath as NSString).appendingPathComponent(".gemini/tmp")
        return [ScanRoot(id: "Gemini CLI", tmpDirectoryPath: path)]
    }
}

// MARK: - Pricing table

/// Gemini per-model per-token pricing. USD per token (unlike the
/// per-million-token quoted price on Google's public pages — we
/// pre-divide by 1e6). Only Gemini CLI models are listed. Unknown
/// models return nil, in which case the snapshot's
/// `unknownModelRecordCount` increments and the record contributes
/// tokens but zero cost.
///
/// Snapshot date: 2026-07 (Google Cloud pricing page). Fields:
///   `input` per input token, `output` per output token,
///   `cached` per cached input token.
public enum GeminiPricing {
    public struct Rate: Equatable, Sendable {
        public var inputPerToken: Double
        public var outputPerToken: Double
        public var cachedPerToken: Double
        public init(inputPerToken: Double, outputPerToken: Double, cachedPerToken: Double) {
            self.inputPerToken = inputPerToken
            self.outputPerToken = outputPerToken
            self.cachedPerToken = cachedPerToken
        }
    }

    /// Snapshot date 2026-07-15 — Gemini public per-million-token
    /// pricing on `ai.google.dev/pricing`. Divided by 1e6 to yield
    /// per-token rates.
    ///
    /// Gemini 2.5 Pro <=200k context:
    ///   input $1.25 / 1M, output $10.00 / 1M, cached $0.31 / 1M.
    /// Gemini 2.5 Flash:
    ///   input $0.30 / 1M, output $2.50 / 1M, cached $0.075 / 1M.
    /// Gemini 1.5 Pro:
    ///   input $1.25 / 1M, output $5.00 / 1M, cached $0.3125 / 1M.
    /// Gemini 1.5 Flash:
    ///   input $0.075 / 1M, output $0.30 / 1M, cached $0.01875 / 1M.
    ///
    /// Tiered pricing (2.5 Pro > 200k) is NOT applied per-request
    /// — Gemini bills per-request against the request's own context
    /// length, but the on-disk log does not carry cumulative context
    /// length as a first-class field. Cost estimates use the
    /// low-tier rate; a "Pricing update available" tile surfaces
    /// when this app is behind Google's official rates.
    public static let table: [String: Rate] = [
        "gemini-2.5-pro":         Rate(inputPerToken: 1.25 / 1_000_000,
                                        outputPerToken: 10.00 / 1_000_000,
                                        cachedPerToken: 0.31 / 1_000_000),
        "gemini-2.5-flash":       Rate(inputPerToken: 0.30 / 1_000_000,
                                        outputPerToken: 2.50 / 1_000_000,
                                        cachedPerToken: 0.075 / 1_000_000),
        // 3cc PR 15-BE F3 — Gemini 2.0 Flash rows added. Prefix-longest-
        // first sort ensures `gemini-2.0-flash-lite` matches BEFORE
        // `gemini-2.0-flash` (26 chars vs 20 chars — length DESC).
        "gemini-2.0-flash-lite":  Rate(inputPerToken: 0.075 / 1_000_000,
                                        outputPerToken: 0.30 / 1_000_000,
                                        cachedPerToken: 0.01875 / 1_000_000),
        "gemini-2.0-flash":       Rate(inputPerToken: 0.10 / 1_000_000,
                                        outputPerToken: 0.40 / 1_000_000,
                                        cachedPerToken: 0.025 / 1_000_000),
        "gemini-1.5-pro":         Rate(inputPerToken: 1.25 / 1_000_000,
                                        outputPerToken: 5.00 / 1_000_000,
                                        cachedPerToken: 0.3125 / 1_000_000),
        "gemini-1.5-flash":       Rate(inputPerToken: 0.075 / 1_000_000,
                                        outputPerToken: 0.30 / 1_000_000,
                                        cachedPerToken: 0.01875 / 1_000_000),
    ]

    /// Look up a rate by model id. Handles Gemini's `-latest`,
    /// `-002`, `-preview-*` suffixes by stripping and re-matching.
    public static func rate(for model: String) -> Rate? {
        if let exact = table[model] { return exact }
        // Strip common suffixes and try again.
        let lower = model.lowercased()
        for prefix in table.keys.sorted(by: { $0.count > $1.count }) {
            if lower.hasPrefix(prefix) { return table[prefix] }
        }
        return nil
    }

    /// Compute cost from a Rate + record's token counts.
    ///
    /// - `input` billed at input rate.
    /// - `output` billed at output rate.
    /// - `cached` billed at cached rate.
    /// - `thoughts` billed at output rate (Gemini 2.5's reasoning
    ///   tokens are output-side).
    /// - `tool` billed at input rate (Google's
    ///   `toolUsePromptTokenCount` is prompt-side; billing on the
    ///   input side would otherwise overcharge tool-heavy sessions
    ///   by up to 8x on 2.5 Pro/Flash). 3cc PR 15-BE F1.
    public static func cost(for rate: Rate, record: GeminiUsageRecord) -> Double {
        var c = Double(record.inputTokens) * rate.inputPerToken
        c += Double(record.outputTokens) * rate.outputPerToken
        c += Double(record.cachedTokens) * rate.cachedPerToken
        c += Double(record.thoughtsTokens) * rate.outputPerToken
        c += Double(record.toolTokens) * rate.inputPerToken
        return c
    }
}

// MARK: - Fetcher

public struct GeminiUsageFetcher: Sendable {

    /// 256 MB cap on any single session JSONL. Matches ClaudeCode.
    public static let jsonlSizeCap: Int64 = 256 * 1024 * 1024

    /// Parse one JSONL line. Returns nil (no malformed increment) for
    /// non-gemini message types, non-message records (`$rewindTo`,
    /// `$set`), and messages without a `tokens` block. Returns nil
    /// AND increments `malformedCount` for JSON parse failures.
    public static func parseLine(
        _ line: String,
        sourceFile: String,
        malformedCount: inout Int,
        unknownModelCount: inout Int
    ) -> GeminiUsageRecord? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            malformedCount += 1
            return nil
        }
        // Non-message records (rewind / metadata) don't carry usage.
        if dict["$rewindTo"] != nil || dict["$set"] != nil { return nil }
        // Only gemini-typed message records carry usage.
        guard let type = dict["type"] as? String, type == "gemini" else { return nil }
        // Extract tokens.
        guard let tokens = dict["tokens"] as? [String: Any] else { return nil }
        let inputTokens = ClaudeCodeUsageFetcher.safeInt(tokens["input"])
        let outputTokens = ClaudeCodeUsageFetcher.safeInt(tokens["output"])
        let cachedTokens = ClaudeCodeUsageFetcher.safeInt(tokens["cached"])
        let thoughtsTokens = ClaudeCodeUsageFetcher.safeInt(tokens["thoughts"])
        let toolTokens = ClaudeCodeUsageFetcher.safeInt(tokens["tool"])
        if inputTokens == 0 && outputTokens == 0 && cachedTokens == 0
            && thoughtsTokens == 0 && toolTokens == 0 { return nil }

        let model = (dict["model"] as? String) ?? "unknown"
        let messageId = dict["id"] as? String

        var ts: Date? = nil
        if let raw = dict["timestamp"] as? String {
            ts = ClaudeCodeUsageFetcher.parseTimestamp(raw)
        }

        var record = GeminiUsageRecord(
            model: model,
            timestamp: ts,
            messageId: messageId,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedTokens: cachedTokens,
            thoughtsTokens: thoughtsTokens,
            toolTokens: toolTokens,
            costUSD: 0.0,
            sourceFile: sourceFile
        )
        if let rate = GeminiPricing.rate(for: model) {
            record.costUSD = GeminiPricing.cost(for: rate, record: record)
        } else if model != "unknown" {
            unknownModelCount += 1
        }
        return record
    }

    /// Parse a set of Gemini JSONL files into a full snapshot. Uses
    /// `ClaudeCodeUsageFetcher.readJsonlLines` (256 MB cap, streaming
    /// FileHandle, per-line UTF-8 tolerance).
    public static func parse(files: [URL]) -> GeminiUsageSnapshot {
        var allRecords: [GeminiUsageRecord] = []
        var perFile: [String: Int] = [:]
        var malformed = 0
        var unreadable = 0
        var overCap = 0
        var unknownModel = 0

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
                guard let rec = parseLine(
                    line,
                    sourceFile: url.path,
                    malformedCount: &malformed,
                    unknownModelCount: &unknownModel
                ) else { continue }
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

        return GeminiUsageSnapshot(
            records: allRecords,
            recordsPerFile: perFile,
            malformedRecordCount: malformed,
            unreadableFileCount: unreadable,
            overCapFileCount: overCap,
            unknownModelRecordCount: unknownModel
        )
    }

    /// Enumerate every `session-*.jsonl` under every project's
    /// `chats/` subdirectory beneath the given `tmp/` scan roots.
    public static func discoverFiles(under scanRoots: [GeminiPathResolver.ScanRoot]) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for root in scanRoots {
            let tmpDir = root.tmpDirectoryPath
            guard fm.fileExists(atPath: tmpDir) else { continue }
            guard let projects = try? fm.contentsOfDirectory(atPath: tmpDir) else { continue }
            for project in projects {
                let chatsDir = (tmpDir as NSString)
                    .appendingPathComponent(project)
                    + "/chats"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: chatsDir, isDirectory: &isDir), isDir.boolValue else { continue }
                guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }
                for f in files where f.hasPrefix("session-") && f.hasSuffix(".jsonl") {
                    let full = (chatsDir as NSString).appendingPathComponent(f)
                    out.append(URL(fileURLWithPath: full))
                }
            }
        }
        out.sort { $0.path < $1.path }
        return out
    }
}
