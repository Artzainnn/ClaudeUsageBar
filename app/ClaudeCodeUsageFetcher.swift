// PR 10b-BE — Claude Code local JSONL fetcher (feature-flag off).
//
// First provider in the "local-file readers" family (Milestone 6). Reads
// Claude Code's own on-disk session logs and produces a token-and-cost
// rollup. Nothing leaves the machine.
//
// Data source
// -----------
// Claude Code writes one JSONL file per session under
// `~/.claude/projects/{cwd-slug}/{sessionId}.jsonl`. Each line is a
// standalone JSON record. Records of `type == "assistant"` carry the
// `message.usage` block we care about; user/tool/system records are
// ignored.
//
// Path resolution (in order — first hit wins):
//
//   1. `$CLAUDE_CONFIG_DIR` (Claude Code's official override).
//      When set, treat as the config root and look under `projects/`.
//   2. `$XDG_CONFIG_HOME` (freedesktop convention that some
//      cross-platform tooling honours). Root is `$XDG_CONFIG_HOME/claude`,
//      then `projects/`.
//   3. `~/.claude` (default).
//
// The value of `1` and `2` MUST resolve to a directory that either exists
// or is missing-but-creatable — no shell expansion, no `~` expansion. The
// env-var contract is documented at
// https://docs.claude.com/en/docs/claude-code/settings.
//
// Dedupe (mandatory)
// ------------------
// Long sessions produce duplicate `(message.id, requestId)` records — the
// same assistant response can be replayed when the CLI is resumed, and
// `isSidechain: true` records represent parallel worker replays whose
// usage was already accounted for on the main branch. Not deduping
// approximately DOUBLES the reported spend on any session that runs for
// more than a few turns (see ccusage issue #888 for the reference
// discussion).
//
// Rules:
//   - Primary key: `(message.id, requestId)`. Both non-nil.
//   - Secondary key: `(message.id, nil)` for records where `requestId`
//     was omitted (older CLI versions or `isSidechain: true` replays).
//   - When a record matches EITHER key already seen, drop it.
//   - `message.id` alone (no request id) is still a valid dedupe seed —
//     an id that surfaces once with a request id and again without still
//     dedupes on the second key.
//
// Cost computation
// ----------------
// Prices are loaded from `ClaudeCodePricing.embeddedJSON`, a snapshot of
// LiteLLM's `model_prices_and_context_window.json` filtered to Anthropic-
// direct Claude models. See that file for the snapshot date. Fields:
//
//   input_cost_per_token          — regular input tokens
//   output_cost_per_token         — output tokens
//   cache_creation_input_token_cost           — ephemeral_5m cache-creation
//   cache_creation_input_token_cost_above_1hr — ephemeral_1h cache-creation
//   cache_read_input_token_cost               — cache-read tokens
//
// Some Sonnet-4 family models also expose `_above_200k_tokens` variants
// used once cumulative context on a request exceeds 200 000 tokens. We
// apply the tiered rate only when the record itself exceeds the
// threshold — Anthropic bills per-request against the request's own
// context length, not against a session-cumulative sum.
//
// Unknown model — a `message.model` value not in the pricing table —
// produces a zero-cost line rather than throwing. This lets a brand-new
// Claude release still get counted for TOKENS while cost silently trails
// until the next pricing refresh.
//
// Feature posture
// ---------------
// `features.claudeCode.enabled` defaults false. Nothing registers a
// `ClaudeCodeUsageStore` into the live registry yet (that lands in PR
// 10b-UI). This file compiles and unit-tests but is inert at runtime
// until enabled.

import Foundation

// MARK: - Snapshot pieces

/// One dedupe-and-cost roll-up entry for a single (message.id, requestId)
/// pair. Held per-record so the store can bucket by day, model, or file
/// without having to re-parse.
public struct ClaudeCodeUsageRecord: Equatable, Sendable {
    /// Model identifier as reported by Claude Code (e.g. "claude-opus-4-7").
    public var model: String
    /// Wall-clock timestamp of the record. Nil if the JSONL line omitted
    /// or malformed `timestamp`. Used to bucket by day/MTD.
    public var timestamp: Date?
    /// Anthropic message id (`message.id` — e.g. "msg_018riz53..."). Nil
    /// if the JSONL line omitted it (rare in practice). Retained so
    /// cross-file dedupe uses the true billing key rather than a
    /// content-based heuristic. Codex round-5 finding.
    public var messageId: String?
    /// Claude Code request id (top-level `requestId` — e.g. "req_011..."). Nil
    /// for older CLI versions or sidechain replays. Same rationale as
    /// `messageId`.
    public var requestId: String?
    /// Regular input tokens (excluding cache).
    public var inputTokens: Int
    /// Cache-creation tokens for the ephemeral_5m tier. Priced at
    /// `cache_creation_input_token_cost`.
    public var cacheCreation5mTokens: Int
    /// Cache-creation tokens for the ephemeral_1h tier. Priced at
    /// `cache_creation_input_token_cost_above_1hr`.
    public var cacheCreation1hTokens: Int
    /// Cache-read tokens.
    public var cacheReadTokens: Int
    /// Output tokens.
    public var outputTokens: Int
    /// Web-search server tool invocations. Not billed as tokens; captured
    /// so a future PR can surface them separately.
    public var webSearchRequests: Int
    /// Web-fetch server tool invocations. Same rationale as above.
    public var webFetchRequests: Int
    /// True when the record was flagged `isSidechain: true`. Kept for
    /// diagnostic tiles but excluded from token/cost totals when
    /// deduping.
    public var isSidechain: Bool
    /// Cost in USD computed by `ClaudeCodePricing.cost(for:record:)`.
    /// Zero when the model is not in the pricing table.
    public var costUSD: Double

    public init(
        model: String,
        timestamp: Date?,
        messageId: String? = nil,
        requestId: String? = nil,
        inputTokens: Int,
        cacheCreation5mTokens: Int,
        cacheCreation1hTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        webSearchRequests: Int,
        webFetchRequests: Int,
        isSidechain: Bool,
        costUSD: Double
    ) {
        self.model = model
        self.timestamp = timestamp
        self.messageId = messageId
        self.requestId = requestId
        self.inputTokens = inputTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.webSearchRequests = webSearchRequests
        self.webFetchRequests = webFetchRequests
        self.isSidechain = isSidechain
        self.costUSD = costUSD
    }

    /// Sum of every token category. Used for the "tokens today" tile.
    /// Codex round-1 finding #4: `&+=` wraps silently on overflow — a
    /// pathological Int.max + Int.max = -2 could escape as a negative
    /// token count. `saturatingAdd` (below) clamps to Int.max instead.
    public var totalTokens: Int {
        var s: Int = 0
        s = ClaudeCodeUsageRecord.saturatingAdd(s, inputTokens)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, cacheCreation5mTokens)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, cacheCreation1hTokens)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, cacheReadTokens)
        s = ClaudeCodeUsageRecord.saturatingAdd(s, outputTokens)
        return s
    }

    /// Non-wrapping non-negative addition. Returns `Int.max` on overflow
    /// rather than the wrapped negative value. Both inputs are expected
    /// to be non-negative (parse() clamps every field to `[0, Int.max]`).
    /// A negative input is defensively coerced to 0. Public so tests
    /// exercise the clamp against Int.max + Int.max directly.
    public static func saturatingAdd(_ a: Int, _ b: Int) -> Int {
        let a_ = max(0, a)
        let b_ = max(0, b)
        let (sum, overflow) = a_.addingReportingOverflow(b_)
        return overflow ? Int.max : sum
    }
}

/// Aggregate roll-up produced by `ClaudeCodeUsageFetcher.parse` from a
/// full JSONL corpus. Buckets by day, model, and per-file so the store
/// can render several tiles without re-walking the records.
public struct ClaudeCodeUsageSnapshot: Equatable, Sendable {
    /// All records seen after dedupe, sorted by timestamp ascending.
    public var records: [ClaudeCodeUsageRecord]
    /// Path-relative file counts (absolute paths → record count). Nil in
    /// tests that build a snapshot from records directly.
    public var recordsPerFile: [String: Int]
    /// Number of duplicate records dropped during parse. Surfaced for
    /// diagnostics; a healthy corpus has a small but non-zero count.
    public var dedupedRecordCount: Int
    /// Number of records that could not be JSON-parsed. Non-zero here is
    /// benign — a partial write mid-tick is normal — but a hot climb
    /// suggests a schema break.
    public var malformedRecordCount: Int
    /// Number of records whose `message.model` was not in the pricing
    /// table. Tokens for these are counted; cost is zero. A non-zero
    /// value is the trigger to refresh the pricing snapshot.
    public var unknownModelRecordCount: Int

    public init(
        records: [ClaudeCodeUsageRecord],
        recordsPerFile: [String: Int] = [:],
        dedupedRecordCount: Int = 0,
        malformedRecordCount: Int = 0,
        unknownModelRecordCount: Int = 0
    ) {
        self.records = records
        self.recordsPerFile = recordsPerFile
        self.dedupedRecordCount = dedupedRecordCount
        self.malformedRecordCount = malformedRecordCount
        self.unknownModelRecordCount = unknownModelRecordCount
    }

    /// Sum of tokens over records whose `timestamp` falls within `range`.
    /// Sidechain records are excluded — they were already accounted for
    /// on the main branch. Uses saturating addition (Codex round-1
    /// finding #3): `&+=` on Int64 wraps to a negative value at
    /// `Int64.max + 1` and `Int(clamping:)` on a wrapped negative value
    /// clamps to `0`, not `Int.max` — the tile would show `0 tokens`
    /// after billions of legitimate tokens.
    public func tokens(in range: ClosedRange<Date>) -> Int {
        var s: Int = 0
        for r in records where !r.isSidechain {
            guard let ts = r.timestamp, range.contains(ts) else { continue }
            s = ClaudeCodeUsageRecord.saturatingAdd(s, r.totalTokens)
        }
        return s
    }

    /// Sum of cost over records whose `timestamp` falls within `range`.
    public func cost(in range: ClosedRange<Date>) -> Double {
        var s = 0.0
        for r in records where !r.isSidechain {
            guard let ts = r.timestamp, range.contains(ts) else { continue }
            s += r.costUSD
        }
        return s
    }

    /// Per-model breakdown for the `.cost` MTD range. Returns entries
    /// sorted by descending cost so the tile can show top-N.
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
        for r in records where !r.isSidechain {
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

/// Resolves the JSONL scan root against Claude Code's documented env-var
/// precedence. Static and pure — takes a Process-info snapshot so tests
/// can inject synthetic env-vars without mutating the running process.
public enum ClaudeCodePathResolver {

    /// Environment snapshot passed to `resolveScanRoot`. `homeDirectoryPath`
    /// is Foundation's `NSHomeDirectory()` in production; tests pass a
    /// temp directory.
    public struct Environment: Sendable {
        public var claudeConfigDir: String?
        public var xdgConfigHome: String?
        public var homeDirectoryPath: String
        public init(claudeConfigDir: String?, xdgConfigHome: String?, homeDirectoryPath: String) {
            self.claudeConfigDir = claudeConfigDir
            self.xdgConfigHome = xdgConfigHome
            self.homeDirectoryPath = homeDirectoryPath
        }

        /// Snapshot the current process env-vars and home dir. Not called
        /// from tests — they build an `Environment` explicitly.
        public static func current() -> Environment {
            let env = ProcessInfo.processInfo.environment
            return Environment(
                claudeConfigDir: env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 },
                xdgConfigHome: env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 },
                homeDirectoryPath: NSHomeDirectory()
            )
        }
    }

    /// Resolve the absolute directory that contains the per-project
    /// `*/*.jsonl` trees. Never returns an empty string; returns nil only
    /// if every candidate produced an empty path (all env-vars unset AND
    /// `homeDirectoryPath` was empty, which does not happen on macOS).
    public static func resolveScanRoot(_ env: Environment) -> String? {
        // 1. $CLAUDE_CONFIG_DIR/projects
        if let dir = env.claudeConfigDir, !dir.isEmpty {
            return joinProjects(dir)
        }
        // 2. $XDG_CONFIG_HOME/claude/projects
        if let dir = env.xdgConfigHome, !dir.isEmpty {
            let claudeRoot = (dir as NSString).appendingPathComponent("claude")
            return joinProjects(claudeRoot)
        }
        // 3. $HOME/.claude/projects
        guard !env.homeDirectoryPath.isEmpty else { return nil }
        let claudeRoot = (env.homeDirectoryPath as NSString).appendingPathComponent(".claude")
        return joinProjects(claudeRoot)
    }

    private static func joinProjects(_ base: String) -> String {
        (base as NSString).appendingPathComponent("projects")
    }
}

// MARK: - JSONL parsing

/// Sendable value-type fetcher. All parsing is pure — I/O (directory
/// enumeration, file reads) is optional and can be supplied by the store
/// or by tests via `parse(jsonl:)` on synthetic strings.
public struct ClaudeCodeUsageFetcher: Sendable {

    /// Parse a single `.jsonl` file's contents. `contents` is the raw
    /// text of the file. Returns the records that survived dedupe and
    /// the count of duplicates dropped. Malformed lines are skipped and
    /// counted (a partial write near end-of-file is normal — Claude
    /// Code flushes line-by-line but the last line can be truncated).
    ///
    /// Records with `isSidechain: true` are RETAINED in the output but
    /// flagged; snapshot roll-ups exclude them from token/cost sums but
    /// keep them for diagnostics.
    ///
    /// This function is dedupe-aware WITHIN a single file. Cross-file
    /// dedupe (a message.id that appears in two files) happens in
    /// `parse(files:)` below. Both use the same primary/secondary key
    /// rules.
    public static func parse(
        jsonl contents: String,
        pricing: ClaudeCodePricing = .default,
        seenPrimary: inout Set<PrimaryKey>,
        seenSecondary: inout Set<SecondaryKey>,
        malformedRecordCount: inout Int,
        dedupedRecordCount: inout Int,
        unknownModelRecordCount: inout Int
    ) -> [ClaudeCodeUsageRecord] {
        var out: [ClaudeCodeUsageRecord] = []
        // `components(separatedBy:)` returns `[String]` so `.trimmingCharacters`
        // (a String method) resolves. `split(separator:)` on String returns
        // ArraySlice<Character> in ambiguous overload contexts; components()
        // is unambiguous. Empty lines are filtered explicitly below.
        contents.components(separatedBy: "\n").forEach { rawLine in
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }

            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any] else {
                malformedRecordCount += 1
                return
            }

            // Only `type == "assistant"` records carry usage. Skip
            // everything else silently (they include user prompts, tool
            // results, system pings — a lot of records per session).
            guard let type = dict["type"] as? String, type == "assistant" else { return }
            guard let message = dict["message"] as? [String: Any] else { return }
            guard let usage = message["usage"] as? [String: Any] else { return }

            let messageId = message["id"] as? String
            let requestId = dict["requestId"] as? String
            let isSidechain = (dict["isSidechain"] as? Bool) ?? false

            // Dedupe rules per module header.
            //
            // Codex round-1 finding #1: check secondary FIRST so
            // (msg_1, req_a) then (msg_1, req_b) — the ccusage #888
            // resume case — dedupes to one record.
            //
            // Codex round-2 finding #1: sidechain records MUST NOT
            // seed the secondary set. Otherwise a sidechain replay
            // arriving before the canonical main record wins the
            // "first seen" position, and the main record is dropped —
            // rollups then filter the sidechain out, so tokens/cost
            // both collapse to zero. Sidechain records are still
            // retained in the output for diagnostics; they simply do
            // not participate in dedupe seeding.
            if let mid = messageId, !isSidechain {
                let secondary = SecondaryKey(messageId: mid)
                if seenSecondary.contains(secondary) {
                    dedupedRecordCount += 1
                    return
                }
                if let rid = requestId {
                    let primary = PrimaryKey(messageId: mid, requestId: rid)
                    if seenPrimary.contains(primary) {
                        dedupedRecordCount += 1
                        return
                    }
                    seenPrimary.insert(primary)
                }
                seenSecondary.insert(secondary)
            } else if let mid = messageId, isSidechain {
                // A sidechain record whose main record has already been
                // seen is a true replay — drop it. (Retention only
                // applies to sidechain records that arrive BEFORE the
                // canonical main, which is exotic but possible.)
                let secondary = SecondaryKey(messageId: mid)
                if seenSecondary.contains(secondary) {
                    dedupedRecordCount += 1
                    return
                }
            }
            // Records missing `message.id` entirely can't be deduped; we
            // count them as-is (rare in practice — Claude Code has always
            // written the id).

            let model = (message["model"] as? String) ?? "unknown"
            let timestamp = (dict["timestamp"] as? String).flatMap(parseTimestamp(_:))

            let inputTokens = safeInt(usage["input_tokens"])
            let outputTokens = safeInt(usage["output_tokens"])
            let cacheReadTokens = safeInt(usage["cache_read_input_tokens"])
            // `cache_creation_input_tokens` is the flat total across
            // 5m and 1h tiers; the `cache_creation` sub-object breaks
            // it out. When the sub-object is present we trust it and
            // ignore the flat total (they must match — but if they
            // don't, the sub-object is authoritative). When absent,
            // treat the flat total as if it were entirely 5m — the
            // safer default (5m rate < 1h rate → won't over-charge).
            let cacheFlat = safeInt(usage["cache_creation_input_tokens"])
            let cc = usage["cache_creation"] as? [String: Any]
            let cache1h = cc.map { safeInt($0["ephemeral_1h_input_tokens"]) } ?? 0
            let cache5m = cc.map { safeInt($0["ephemeral_5m_input_tokens"]) } ?? cacheFlat

            let stu = usage["server_tool_use"] as? [String: Any]
            let webSearch = stu.map { safeInt($0["web_search_requests"]) } ?? 0
            let webFetch = stu.map { safeInt($0["web_fetch_requests"]) } ?? 0

            let (costUSD, isUnknownModel) = pricing.cost(
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreation5mTokens: cache5m,
                cacheCreation1hTokens: cache1h,
                cacheReadTokens: cacheReadTokens
            )
            if isUnknownModel {
                unknownModelRecordCount += 1
            }

            out.append(ClaudeCodeUsageRecord(
                model: model,
                timestamp: timestamp,
                messageId: messageId,
                requestId: requestId,
                inputTokens: inputTokens,
                cacheCreation5mTokens: cache5m,
                cacheCreation1hTokens: cache1h,
                cacheReadTokens: cacheReadTokens,
                outputTokens: outputTokens,
                webSearchRequests: webSearch,
                webFetchRequests: webFetch,
                isSidechain: isSidechain,
                costUSD: costUSD
            ))
        }
        return out
    }

    /// Parse a set of JSONL file URLs into a full snapshot.
    ///
    /// Codex round-3 finding #2: cross-file dedupe is TIMESTAMP-ordered,
    /// not input-order. Otherwise, if the same `message.id` appears in
    /// file A (July, lexically earlier) and file B (June, lexically
    /// later), the July replay wins dedupe and the June original is
    /// dropped — MTD bucketing then bills June's tokens to July. The
    /// two-pass structure below parses candidate records without
    /// dedupe, sorts them so earlier timestamps and non-sidechain
    /// records win, then applies dedupe.
    ///
    /// I/O errors on individual files are tolerated: a file that
    /// disappeared mid-scan or is unreadable is silently skipped. The
    /// snapshot's `recordsPerFile` shows which files contributed.
    public static func parse(
        files: [URL],
        pricing: ClaudeCodePricing = .default
    ) -> ClaudeCodeUsageSnapshot {
        // Pass 1: parse candidate records from every file with dedupe
        // sets held per-file (so a duplicate WITHIN one file is caught
        // immediately, but cross-file duplicates are caught in pass 2).
        // Codex round-6 finding #1 (accepted as documented behaviour):
        // within-file dedupe keeps first-seen, not first-by-timestamp.
        // In real logs Claude Code appends chronologically so the two
        // coincide; the finding's out-of-order case only affects the
        // bucketing of the RETAINED record by at most one calendar
        // day — an acceptable tail behaviour vs the complexity of
        // running dedupe over a merged, sorted stream.
        var candidateRecords: [ClaudeCodeUsageRecord] = []
        var perFile: [String: Int] = [:]
        var malformed = 0
        var withinFileDeduped = 0
        var unknownModel = 0

        for url in files {
            guard let lines = readJsonlLines(from: url) else { continue }
            let text = lines.joined(separator: "\n")
            var seenPrimary: Set<PrimaryKey> = []
            var seenSecondary: Set<SecondaryKey> = []
            let recs = parse(
                jsonl: text,
                pricing: pricing,
                seenPrimary: &seenPrimary,
                seenSecondary: &seenSecondary,
                malformedRecordCount: &malformed,
                dedupedRecordCount: &withinFileDeduped,
                unknownModelRecordCount: &unknownModel
            )
            perFile[url.path] = recs.count
            candidateRecords.append(contentsOf: recs)
        }

        // Sort:
        //   1. Records WITHOUT a timestamp sink to the end (they cannot
        //      participate in day/MTD bucketing anyway; keeping them
        //      last means dedupe prefers dated records).
        //   2. Non-sidechain records before sidechain (so the canonical
        //      main record wins on any (msg_id) tie).
        //   3. Timestamp ascending (so the FIRST-in-time record wins
        //      dedupe, which is the correct one to bill).
        candidateRecords.sort { lhs, rhs in
            switch (lhs.timestamp, rhs.timestamp) {
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return false
            case let (l?, r?):
                if l != r { return l < r }
                // Same timestamp — non-sidechain first.
                if lhs.isSidechain != rhs.isSidechain {
                    return !lhs.isSidechain
                }
                return false
            }
        }

        // Pass 2: cross-file dedupe over the sorted candidates using
        // the SAME primary/secondary key rules as within-file dedupe.
        // Codex round-5 finding: because the record now carries the
        // raw messageId + requestId, we can re-apply the true billing
        // key across files rather than the content-based heuristic
        // that the round-3 iteration used. Sort order (earlier
        // timestamp, non-sidechain preferred) ensures the FIRST record
        // for each dedupe key is the one to keep. Also apply the
        // "sidechain must not seed" rule from round-2 finding #1.
        var xSeenPrimary: Set<PrimaryKey> = []
        var xSeenSecondary: Set<SecondaryKey> = []
        var crossFileDeduped = 0
        var allRecords: [ClaudeCodeUsageRecord] = []
        allRecords.reserveCapacity(candidateRecords.count)

        for rec in candidateRecords {
            if let mid = rec.messageId, !rec.isSidechain {
                let secondary = SecondaryKey(messageId: mid)
                if xSeenSecondary.contains(secondary) {
                    crossFileDeduped += 1
                    continue
                }
                if let rid = rec.requestId {
                    let primary = PrimaryKey(messageId: mid, requestId: rid)
                    if xSeenPrimary.contains(primary) {
                        crossFileDeduped += 1
                        continue
                    }
                    xSeenPrimary.insert(primary)
                }
                xSeenSecondary.insert(secondary)
            } else if let mid = rec.messageId, rec.isSidechain {
                let secondary = SecondaryKey(messageId: mid)
                if xSeenSecondary.contains(secondary) {
                    crossFileDeduped += 1
                    continue
                }
                // Sidechain records arriving before any main record
                // are retained but do NOT seed the seen sets, so a
                // later canonical main record still wins.
            }
            allRecords.append(rec)
        }

        // Codex round-4 finding #2: unknown-model count should reflect
        // FINAL (deduped) records, not candidates. Otherwise a duplicate
        // unknown-model record inflates the diagnostic tile and
        // over-suggests a pricing refresh.
        let finalUnknownCount = allRecords.reduce(0) { acc, rec in
            acc + (pricing.hasModel(rec.model) ? 0 : 1)
        }

        return ClaudeCodeUsageSnapshot(
            records: allRecords,
            recordsPerFile: perFile,
            dedupedRecordCount: withinFileDeduped + crossFileDeduped,
            malformedRecordCount: malformed,
            unknownModelRecordCount: finalUnknownCount
        )
    }

    /// Read a JSONL file as an array of decoded lines. Returns nil only
    /// if the file cannot be opened at all — any per-line UTF-8 or I/O
    /// error is tolerated (torn last line, mid-write truncation, invalid
    /// UTF-8 byte). Uses a non-mmap Data read so a multi-GB append-only
    /// session log does not spike memory or race the writer's mtime bump.
    /// Codex round-1 finding #5 + #6.
    ///
    /// A generous per-file size cap (256 MB) protects against a
    /// pathological log that would otherwise pull the whole file into
    /// RAM; larger files are skipped with the caller counting them as
    /// zero-record files. The cap is well above any realistic Claude
    /// Code session (100 MB session ≈ ~200 000 assistant turns).
    static func readJsonlLines(from url: URL) -> [String]? {
        let sizeCap: Int64 = 256 * 1024 * 1024
        // Codex round-6 finding #2: stream via FileHandle so a
        // live-appending file cannot materialise the whole (possibly
        // multi-GB) content into memory. We read chunks up to a
        // hard limit of `sizeCap + 1` bytes; if we ever hit that
        // limit we abort and return nil (the caller counts the file
        // as skipped).
        //
        // Pre-check via stat is kept as a fast path so a >256MB file
        // is rejected without opening a FileHandle at all.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = (attrs?[.size] as? NSNumber)?.int64Value,
           size > sizeCap {
            return nil
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        // 1 MiB chunks. Small enough to bound memory, big enough that
        // even a 200 MB file only needs ~200 chunk reads.
        let chunkSize = 1024 * 1024
        var buffer = Data()
        buffer.reserveCapacity(chunkSize * 2)
        while true {
            let chunk: Data
            do {
                if #available(macOS 10.15.4, *) {
                    guard let read = try handle.read(upToCount: chunkSize) else { break }
                    chunk = read
                } else {
                    chunk = handle.readData(ofLength: chunkSize)
                }
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if Int64(buffer.count) > sizeCap {
                return nil
            }
        }
        // Split on `\n` byte, decode each slice with UTF-8 tolerance.
        // `String(decoding: as: UTF8.self)` replaces invalid bytes with
        // U+FFFD rather than returning nil, so a torn multibyte scalar
        // on the last line produces a malformed JSON line (which the
        // parser counts) instead of discarding the whole file.
        var out: [String] = []
        var start = buffer.startIndex
        for i in buffer.indices where buffer[i] == 0x0A {  // '\n'
            let slice = buffer[start..<i]
            out.append(String(decoding: slice, as: UTF8.self))
            start = buffer.index(after: i)
        }
        if start < buffer.endIndex {
            let slice = buffer[start..<buffer.endIndex]
            out.append(String(decoding: slice, as: UTF8.self))
        }
        return out
    }

    /// Enumerate `.jsonl` files under the scan root, recursively. Returns
    /// [] if the root does not exist. I/O errors on individual entries
    /// are skipped rather than propagated — a locked file mid-tick is
    /// normal.
    public static func discoverFiles(under scanRoot: String) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: scanRoot) else { return [] }
        let rootURL = URL(fileURLWithPath: scanRoot)
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey]),
               vals.isRegularFile == true {
                out.append(url)
            }
        }
        // Sort deterministically (path order) so snapshot ordering is
        // stable — matters for tests and for the cross-file dedupe
        // "first-seen wins" contract.
        out.sort { $0.path < $1.path }
        return out
    }

    // MARK: - Timestamp parsing

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse a Claude Code timestamp — RFC 3339 with or without a
    /// fractional-seconds component. Returns nil for anything else,
    /// which is the same as if the field was omitted (the snapshot
    /// simply won't bucket the record into today/MTD). Public so the
    /// test suite can exercise the parser against synthetic inputs.
    public static func parseTimestamp(_ raw: String) -> Date? {
        if let d = isoFormatter.date(from: raw) { return d }
        return isoFormatterNoFractional.date(from: raw)
    }

    /// Best-effort integer extraction. Accepts Int, Double, and
    /// stringified numerics — some LiteLLM-adjacent tooling emits
    /// stringified fields. Clamps to `[0, Int.max]` — a negative value
    /// is a schema break we surface as zero rather than a negative
    /// cost line. Public so tests can exercise the clamp against
    /// hostile inputs (NaN, infinity, 1e300, negatives).
    public static func safeInt(_ value: Any?) -> Int {
        if let i = value as? Int { return max(0, i) }
        if let d = value as? Double, d.isFinite {
            let rounded = d.rounded()
            if rounded <= 0 { return 0 }
            // Codex round-1 finding #2: `Double(Int.max)` rounds UP to
            // 2^63 (Int.max = 2^63-1 is not representable exactly as
            // Double), so `rounded > Double(Int.max)` misses the exact
            // Int.max boundary and `Int(rounded)` traps. `Int(exactly:)`
            // is the correct guard — it returns nil if the double
            // cannot be represented as an Int without losing magnitude.
            if let n = Int(exactly: rounded) { return n }
            return Int.max
        }
        if let s = value as? String, let i = Int(s) { return max(0, i) }
        return 0
    }

    // MARK: - Dedupe key types

    public struct PrimaryKey: Hashable, Sendable {
        public let messageId: String
        public let requestId: String
        public init(messageId: String, requestId: String) {
            self.messageId = messageId
            self.requestId = requestId
        }
    }
    public struct SecondaryKey: Hashable, Sendable {
        public let messageId: String
        public init(messageId: String) {
            self.messageId = messageId
        }
    }
}
