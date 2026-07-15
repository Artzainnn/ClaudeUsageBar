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
    /// pricing on `ai.google.dev/gemini-api/docs/pricing` (verified
    /// live at PR 24 time via primary-source fetch).
    ///
    /// Gemini 2.5 Pro <=200k input tokens per request:
    ///   input $1.25 / 1M, output $10.00 / 1M, cached $0.125 / 1M.
    /// Gemini 2.5 Pro > 200k input tokens per request:
    ///   input $2.50 / 1M, output $15.00 / 1M, cached $0.25 / 1M.
    /// Gemini 2.5 Flash:
    ///   input $0.30 / 1M, output $2.50 / 1M, cached $0.075 / 1M.
    /// Gemini 1.5 Pro:
    ///   input $1.25 / 1M, output $5.00 / 1M, cached $0.3125 / 1M.
    /// Gemini 1.5 Flash:
    ///   input $0.075 / 1M, output $0.30 / 1M, cached $0.01875 / 1M.
    ///
    /// PR 24 — 2.5 Pro tiered pricing now applied per-record via
    /// `rate(for: model, inputTokens: record.inputTokens)`. Every
    /// record's `inputTokens` corresponds to Google's
    /// `usageMetadata.promptTokenCount`, which is the per-request
    /// prompt count Google itself uses to pick the tier. When
    /// `inputTokens > 200_000` for a 2.5 Pro model, the high-tier
    /// rates apply. Other models are single-tier; the high-tier
    /// table only carries an entry for 2.5 Pro.
    ///
    /// PR 24 3cc correctness fix — the pre-existing `gemini-2.5-pro`
    /// low-tier `cachedPerToken` was $0.31/1M (introduced by PR 15-BE
    /// / PR #79); Google's live page has always listed $0.125/1M.
    /// Corrected here alongside the new high-tier row so both tiers
    /// use Google's actual published rates. Impact for existing
    /// users: cached-token cost estimates on 2.5 Pro records will
    /// drop by ~60% (previously over-billed by ~2.48x).
    public static let table: [String: Rate] = [
        "gemini-2.5-pro":         Rate(inputPerToken: 1.25 / 1_000_000,
                                        outputPerToken: 10.00 / 1_000_000,
                                        cachedPerToken: 0.125 / 1_000_000),
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

    /// PR 24 — high-tier rate table for models with per-request
    /// context-length tiered pricing. Currently only Gemini 2.5 Pro
    /// has such a tier (`> 200_000` input tokens/request).
    ///
    /// High-tier rates verified against Google's live pricing page
    /// `ai.google.dev/gemini-api/docs/pricing` on 2026-07-15:
    /// input $2.50/1M, output $15.00/1M (including thinking tokens),
    /// context caching $0.25/1M. All three roughly 2x the low-tier
    /// figures.
    public static let highTierTable: [String: (threshold: Int, rate: Rate)] = [
        "gemini-2.5-pro": (
            threshold: 200_000,
            rate: Rate(inputPerToken: 2.50 / 1_000_000,
                        outputPerToken: 15.00 / 1_000_000,
                        cachedPerToken: 0.25 / 1_000_000)
        )
    ]

    /// Look up a rate by model id. Handles Gemini's `-latest`,
    /// `-002`, `-preview-*` suffixes by stripping and re-matching.
    /// Returns the low-tier rate for source-compat with existing tests
    /// that don't have a per-record view.
    public static func rate(for model: String) -> Rate? {
        if let exact = table[model] { return exact }
        // Strip common suffixes and try again.
        let lower = model.lowercased()
        for prefix in table.keys.sorted(by: { $0.count > $1.count }) {
            if lower.hasPrefix(prefix) { return table[prefix] }
        }
        return nil
    }

    /// PR 24 — tier-aware rate lookup. Returns the high-tier rate for
    /// models with tiered pricing (2.5 Pro) when `inputTokens` exceeds
    /// the model's threshold; otherwise returns the low-tier rate.
    ///
    /// Suffix-stripping matches `rate(for:)` — a model id like
    /// `gemini-2.5-pro-002` correctly resolves to the 2.5 Pro tiered
    /// entry via longest-prefix match.
    ///
    /// Falls back to low-tier rate for any model with no high-tier
    /// entry — the vast majority of models are single-tier.
    public static func rate(for model: String, inputTokens: Int) -> Rate? {
        // Resolve to the low-tier canonical key first (via longest-
        // prefix match), then check for a high-tier upgrade.
        let canonicalKey = canonicalTableKey(for: model)
        guard let low = canonicalKey.flatMap({ table[$0] }) else { return nil }
        if let key = canonicalKey, let tier = highTierTable[key], inputTokens > tier.threshold {
            return tier.rate
        }
        return low
    }

    /// Return the `table` key that a model id matches under the
    /// longest-prefix rule, or nil if no match.
    private static func canonicalTableKey(for model: String) -> String? {
        if table[model] != nil { return model }
        let lower = model.lowercased()
        for prefix in table.keys.sorted(by: { $0.count > $1.count }) {
            if lower.hasPrefix(prefix) { return prefix }
        }
        return nil
    }

    /// Compute cost from a Rate + record's token counts.
    ///
    /// Google's usageMetadata contract (verified 2026-07-16 via
    /// primary sources — `ai.google.dev/gemini-api/docs/tokens` +
    /// Vertex context-cache overview):
    ///
    /// - `promptTokenCount` (mapped to `record.inputTokens` by
    ///   gemini-cli) is the FULL prompt count and INCLUDES the
    ///   cached portion. `cachedContentTokenCount` (mapped to
    ///   `record.cachedTokens`) is a SUBSET of `promptTokenCount`.
    ///   Non-cached input tokens = inputTokens - cachedTokens.
    /// - `toolUsePromptTokenCount` (mapped to `record.toolTokens`)
    ///   is SEPARATE from `promptTokenCount`, not a subset.
    /// - `thoughtsTokenCount` (mapped to `record.thoughtsTokens`):
    ///   Google's docs say the Gemini API includes thoughts inside
    ///   `candidatesTokenCount` (which is `record.outputTokens`), but
    ///   observed API responses have them as separate additive values.
    ///   Ambiguity noted — this code adds thoughts to output at the
    ///   output rate, which matches Vertex's contract and the observed
    ///   API behaviour but may over-count on the pure Gemini API when
    ///   the docs are authoritative. Follow-up when Google clarifies.
    ///
    /// Billing formula (post PR 28 audit fix):
    ///
    /// - non-cached input = `max(inputTokens - cachedTokens, 0)`
    ///   billed at `input` rate.
    /// - cached input billed at `cached` rate (10% of input rate on
    ///   Gemini's standard tier).
    /// - `output` billed at output rate.
    /// - `thoughts` billed at output rate (see ambiguity note above).
    /// - `tool` billed at input rate (Google's
    ///   `toolUsePromptTokenCount` is prompt-side; billing on the
    ///   input side would otherwise overcharge tool-heavy sessions
    ///   by up to 8x on 2.5 Pro/Flash). 3cc PR 15-BE F1.
    ///
    /// PR 28 audit fix — the pre-existing formula charged `inputTokens`
    /// AT THE FULL RATE AND `cachedTokens` AT THE CACHED RATE, which
    /// double-billed the cached portion (once at input rate, once at
    /// cached rate). This over-billed every Gemini record with cached
    /// tokens > 0 by `cachedTokens * inputRate`. Correction here uses
    /// the non-cached-input-minus-cached formula; matches Google's own
    /// tier documentation and the invoice-reconciliation guidance on
    /// their pricing page.
    public static func cost(for rate: Rate, record: GeminiUsageRecord) -> Double {
        // Subtract cached from input to avoid double-billing the
        // cached portion. Clamp at 0 for the hostile case where the
        // on-disk log has cached > input (should never happen given
        // Google's own contract, but defensive).
        let nonCachedInput = max(record.inputTokens - record.cachedTokens, 0)
        var c = Double(nonCachedInput) * rate.inputPerToken
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
        // PR 24 — use the tier-aware rate lookup. For 2.5 Pro
        // requests where `inputTokens > 200_000`, this returns the
        // high-tier rate; for every other model / smaller request,
        // this returns the same low-tier rate the old `rate(for:
        // model)` returned. Source-compat with the older signature is
        // preserved (the older function still exists and still
        // returns low-tier).
        if let rate = GeminiPricing.rate(for: model, inputTokens: record.inputTokens) {
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
