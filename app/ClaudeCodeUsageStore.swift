// PR 10b-BE — Claude Code UsageProvider store (feature-flag off).
//
// First "local file reader" provider. Watches the JSONL scan root that
// Claude Code writes under `~/.claude/projects/**/*.jsonl` (or the
// $CLAUDE_CONFIG_DIR / $XDG_CONFIG_HOME override), re-parses on
// filesystem change, and emits four popover tiles:
//
//   cc-tokens-today  — Counter: today's tokens across all models
//   cc-cost-today    — Text:    today's cost in USD, formatted "$X.XX"
//   cc-cost-mtd      — Text:    month-to-date cost in USD
//   cc-by-model      — Text:    top-3 models by MTD cost with per-model
//                                cost and token counts
//
// The TCC/FDA story is different from PR 5's Zed store: Claude Code
// files are inside the user's home under ~/.claude, which is NOT
// TCC-protected. A dedicated user could still deny read via chmod, but
// the normal case is "granted or path missing (never installed)". We
// probe TCC once per fetch and render `.needsAccess` for `.denied` and
// nothing for `.pathMissing` (an unused-Claude-Code Mac has nothing
// worth showing).
//
// Concurrency model
// -----------------
// The heavy work — enumerating files, opening them, parsing JSONL — is
// dispatched off the main actor via a background queue. Result is
// applied on the main actor via `Task { @MainActor [weak self] in ... }`
// to match the Hardening pass (PR #60) rule of NEVER using
// `MainActor.assumeIsolated` from a background completion.
//
// Feature posture
// ---------------
// `features.claudeCode.enabled` defaults false. Nothing registers a
// `ClaudeCodeUsageStore` into `AppDelegate.providers` yet — that lands
// in PR 10b-UI along with `ProviderCopy.help(for: "claudeCode")`.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class ClaudeCodeUsageStore: @preconcurrency UsageProvider {

    public let id: String = "claudeCode"
    public let displayName: String = "Claude Code"
    public let featureFlagKey: String = "features.claudeCode.enabled"

    // MARK: - Observable state

    @Published public private(set) var snapshot: ClaudeCodeUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var tccState: TCCState = .granted

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let pricing: ClaudeCodePricing
    /// Path resolver returns the JSONL scan root. Injected so tests can
    /// point to a temp directory.
    private let resolveScanRoot: @Sendable () -> String?
    /// TCC probe. Injected so tests can force `.denied` / `.pathMissing`.
    private let tccProbe: @Sendable (String) -> TCCState
    /// File enumerator. Injected so tests can supply a fixed list.
    private let discoverFiles: @Sendable (String) -> [URL]
    /// Parser. Injected so tests can bypass real I/O and drive a
    /// synthetic in-memory JSONL corpus.
    private let parseFiles: @Sendable ([URL], ClaudeCodePricing) -> ClaudeCodeUsageSnapshot
    /// Queue used to run I/O off-main. Serial so a burst of filesystem
    /// events coalesces into one parse pass rather than N parallel
    /// re-scans of overlapping files. Serial also protects the fetch
    /// generation counter without an atomic.
    private let workQueue: DispatchQueue
    /// Clock used for bucket boundaries — injected so tests can pin
    /// "today" against a deterministic date.
    private let clock: @Sendable () -> Date

    // Monotonic counter — bumped on every `clear()` and every fresh
    // fetch so a completion arriving from a stale earlier fetch does
    // not overwrite fresher state. Mirrors the pattern used by
    // CopilotUsageStore (chk1 round-1 finding). Only touched on the
    // main actor.
    private var fetchGeneration: UInt64 = 0

    public init(
        defaults: UserDefaults = .standard,
        pricing: ClaudeCodePricing = .default,
        resolveScanRoot: @escaping @Sendable () -> String? = {
            ClaudeCodePathResolver.resolveScanRoot(.current())
        },
        tccProbe: @escaping @Sendable (String) -> TCCState = { TCCProbe.probe(path: $0) },
        discoverFiles: @escaping @Sendable (String) -> [URL] = { ClaudeCodeUsageFetcher.discoverFiles(under: $0) },
        parseFiles: @escaping @Sendable ([URL], ClaudeCodePricing) -> ClaudeCodeUsageSnapshot = { urls, p in
            ClaudeCodeUsageFetcher.parse(files: urls, pricing: p)
        },
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.claude.usagebar.claudecode.parse",
            qos: .utility
        ),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.pricing = pricing
        self.resolveScanRoot = resolveScanRoot
        self.tccProbe = tccProbe
        self.discoverFiles = discoverFiles
        self.parseFiles = parseFiles
        self.workQueue = workQueue
        self.clock = clock
    }

    // MARK: - UsageProvider: metadata

    public var isEnabled: Bool {
        defaults.bool(forKey: featureFlagKey)
    }

    /// The Claude Code reader is always "configured" once the flag is on
    /// — there is no credential to enter. The path may not exist yet
    /// (Claude Code never installed), which the tile surfaces as an
    /// informational status; the store still considers itself configured.
    public var isConfigured: Bool {
        isEnabled
    }

    public var lastUpdated: Date? { lastUpdatedAt }

    public var errorMessage: String? { lastError }

    // MARK: - UsageProvider: tiles

    public var tiles: [UsageTile] {
        guard isEnabled else { return [] }

        // TCC gating — deny path renders one card that points the user
        // at Full Disk Access. Path-missing renders nothing so an
        // unused-Claude-Code Mac stays quiet.
        switch tccState {
        case .denied:
            let copy = LocalProviderAccessGuide.copy(for: .denied, appName: displayName)
            return [UsageTile(
                id: "cc-needs-access",
                title: copy.title,
                kind: .needsAccess(path: "~/.claude/projects", guidance: copy.guidance)
            )]
        case .pathMissing:
            // Nothing to show — the app is not on this Mac. Return a
            // single explanatory text tile so an enabled-but-empty
            // state is not confusing (the popover would otherwise show
            // "Claude Code" section header with zero content).
            return [UsageTile(
                id: "cc-not-installed",
                title: displayName,
                kind: .text(status: "No sessions found", subtitle: "Launch Claude Code and click Refresh.")
            )]
        case .granted:
            break
        }

        guard let snap = snapshot else {
            // Enabled, granted, no snapshot yet — first fetch pending.
            return [UsageTile(
                id: "cc-loading",
                title: displayName,
                kind: .text(status: "Loading…", subtitle: nil)
            )]
        }

        let now = clock()
        let todayRange = Self.todayRange(around: now)
        let mtdRange = Self.monthToDateRange(around: now)

        let tokensToday = snap.tokens(in: todayRange)
        let costToday = snap.cost(in: todayRange)
        let costMTD = snap.cost(in: mtdRange)
        let byModel = snap.breakdownByModel(in: mtdRange)

        var out: [UsageTile] = []

        out.append(UsageTile(
            id: "cc-tokens-today",
            title: "Tokens today",
            kind: .counter(used: tokensToday, limit: nil, resetsAt: Self.startOfNextDay(after: now))
        ))
        out.append(UsageTile(
            id: "cc-cost-today",
            title: "Cost today",
            kind: .text(status: Self.formatUSD(costToday), subtitle: nil)
        ))
        out.append(UsageTile(
            id: "cc-cost-mtd",
            title: "Cost month-to-date",
            kind: .text(status: Self.formatUSD(costMTD), subtitle: nil)
        ))
        if !byModel.isEmpty {
            let top = byModel.prefix(3)
            let lines = top.map { entry in
                "\(entry.model) — \(Self.formatUSD(entry.costUSD)) (\(Self.formatTokens(entry.tokens)))"
            }
            out.append(UsageTile(
                id: "cc-by-model",
                title: "Top models this month",
                kind: .text(status: lines.first ?? "", subtitle: lines.dropFirst().joined(separator: "\n"))
            ))
        }

        // Diagnostic tile — surfaces only when the pricing table missed
        // at least one record on THIS snapshot. Keeps the popover quiet
        // on healthy sessions.
        if snap.unknownModelRecordCount > 0 {
            out.append(UsageTile(
                id: "cc-pricing-stale",
                title: "Pricing update available",
                kind: .text(
                    status: "\(snap.unknownModelRecordCount) records used a model not in the bundled price list.",
                    subtitle: "Cost figures may under-count until the app ships an updated snapshot."
                )
            ))
        }

        return out
    }

    // MARK: - UsageProvider: actions

    public func fetch() {
        guard isEnabled else { return }

        // Codex round-2 finding #6: bump the fetch generation BEFORE
        // any early-return path so an in-flight fetch cannot complete
        // and repopulate stale data after access was denied. Without
        // this, fetch A running on the queue can finish and apply its
        // result after fetch B saw `.denied` and cleared state.
        fetchGeneration &+= 1
        let launchGeneration = fetchGeneration

        let scanRoot = resolveScanRoot()
        guard let root = scanRoot else {
            lastError = "Could not resolve Claude Code data directory."
            return
        }

        // Probe TCC on every fetch. The user might grant/revoke Full
        // Disk Access at any time; we want to reflect that quickly.
        let probed = tccProbe(root)
        self.tccState = probed
        if probed != .granted {
            // Nothing to fetch — the tile message is enough. The
            // generation bump above invalidates any prior in-flight
            // fetch so a late completion cannot revive the snapshot
            // after the user denied access.
            self.snapshot = nil
            self.lastError = nil
            return
        }

        // Capture dependencies for the background queue. `self` is
        // captured weakly on the main-actor apply hop only; the
        // dispatched closure holds only value-type copies.
        let root_ = root
        let discover = self.discoverFiles
        let parse = self.parseFiles
        let pricing_ = self.pricing

        workQueue.async { [weak self] in
            let urls = discover(root_)
            let snap = parse(urls, pricing_)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Codex round-3 finding #3: guard on isEnabled too.
                // Without this, a fetch started while enabled can
                // complete after the user disabled the provider and
                // repopulate stale state — which then flashes back if
                // they re-enable.
                guard self.isEnabled else { return }
                guard launchGeneration == self.fetchGeneration else { return }
                self.snapshot = snap
                self.lastUpdatedAt = Date()
                self.lastError = nil
                Log.info("Claude Code JSONL parsed", .count(snap.records.count))
            }
        }
    }

    public func clear() {
        // No credential to delete — local JSONL is Claude Code's file,
        // not ours. Clearing drops in-memory state only, and invalidates
        // any in-flight fetch via the generation bump.
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
        fetchGeneration &+= 1
    }

    // MARK: - Formatting helpers
    //
    // Marked `nonisolated` — these are pure static functions with no
    // access to instance state. Without this, calling them from a test
    // context (or any non-MainActor code path) requires an actor hop or
    // await, which is unnecessary since they cannot observe or mutate
    // main-actor state.

    /// Format a USD amount with two decimal places. Amounts under $0.01
    /// render as "<$0.01" — a raw "$0.00" line for a session that just
    /// spent $0.003 would be misleading. Uses `String(format:)` with a
    /// fixed locale (dot decimal separator, no thousands separators for
    /// small dollar amounts) — `NumberFormatter.currency` with `en_US_POSIX`
    /// injects a stray space between `$` and the digits which reads
    /// wrongly in the popover.
    public nonisolated static func formatUSD(_ amount: Double) -> String {
        guard amount.isFinite else { return "$0.00" }
        if amount > 0 && amount < 0.005 { return "<$0.01" }
        // 3cc round-3 finding #3: guard Int((huge * 100.0).rounded())
        // against a trap. `Int(exactly:)` returns nil when the Double
        // is outside Int range; clamp to Int.max / .min in that case.
        let scaled = (amount * 100.0).rounded()
        let cents: Int
        if let n = Int(exactly: scaled) {
            cents = n
        } else if scaled > 0 {
            cents = Int.max
        } else {
            cents = Int.min + 1     // reserve Int.min so abs() cannot trap
        }
        let sign = cents < 0 ? "-" : ""
        let abs_ = abs(cents)
        let dollars = abs_ / 100
        let remainder = abs_ % 100
        return "\(sign)$\(formatWithCommas(dollars)).\(String(format: "%02d", remainder))"
    }

    /// Format a token count with comma thousand separators
    /// (e.g. "1,234,567 tokens"). Zero renders as "0 tokens".
    public nonisolated static func formatTokens(_ count: Int) -> String {
        return "\(formatWithCommas(count)) tokens"
    }

    /// Insert comma thousand separators into a non-negative integer.
    /// Used by both `formatUSD` (dollars portion) and `formatTokens`.
    /// Kept private and pure so both tests exercise it through their
    /// public callers. Negative inputs are formatted absolute; the
    /// caller re-prepends the sign.
    private nonisolated static func formatWithCommas(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out += "," }
            out += String(ch)
        }
        return String(out.reversed())
    }

    /// Range covering [start-of-day, end-of-day] in the user's current
    /// calendar. Used to bucket today's records.
    ///
    /// Codex round-2 finding #8: DST-safe — calendar arithmetic for
    /// nextDay handles 23h and 25h days.
    ///
    /// Codex round-3 finding #1: end is `nextDay - 1 nanosecond`, not
    /// `nextDay - 1 second`. A fractional-seconds Claude Code timestamp
    /// like `23:59:59.500` would be excluded from a ClosedRange ending
    /// at `23:59:59.000`. Using `nextDown` on the Foundation Date's
    /// underlying TimeInterval gives the largest representable Date
    /// strictly less than `nextDay`, so every subsecond record in the
    /// last second of the day is included.
    public nonisolated static func todayRange(around now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let start = calendar.startOfDay(for: now)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        // largest representable Date < nextDay
        let endOfDay = Date(timeIntervalSinceReferenceDate: nextDay.timeIntervalSinceReferenceDate.nextDown)
        return start...endOfDay
    }

    /// The next midnight — used as the "resets at" hint on the tokens tile.
    public nonisolated static func startOfNextDay(after now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? now
    }

    /// Range covering [start-of-month, now] in the user's current
    /// calendar. Used to bucket month-to-date records.
    public nonisolated static func monthToDateRange(around now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let comps = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: comps) ?? now
        return start...now
    }
}
