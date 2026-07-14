// PR 13-BE — Continue UsageProvider store (feature-flag off).
//
// Concurrency model mirrors ClineUsageStore: parse work runs on a
// serial background queue; results apply on the main actor via
// `Task { @MainActor [weak self] in ... }`; `fetchGeneration`
// invalidates any in-flight completion so a TCC transition, disable,
// or `clear()` cannot repopulate stale state.
//
// The re-probe-on-completion pattern (3cc R3 F5) is inherited from
// ClineUsageStore.fetch(). ClaudeCodeUsageStore.fetch() lacks it —
// do NOT mirror ClaudeCodeUsageStore verbatim.
//
// Feature posture — `features.continue.enabled` defaults false.
// Nothing registers a ContinueUsageStore into `AppDelegate.providers`
// yet; that lands in PR 13-UI along with `ProviderCopy.help(for:
// "continue")`.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class ContinueUsageStore: @preconcurrency UsageProvider {

    public let id: String = "continue"
    public let displayName: String = "Continue"
    public let featureFlagKey: String = "features.continue.enabled"

    // MARK: - Observable state

    @Published public private(set) var snapshot: ContinueUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var tccState: TCCState = .granted

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let resolveScanRoots: @Sendable () -> [ContinuePathResolver.ScanRoot]
    private let tccProbe: @Sendable (String) -> TCCState
    private let discoverFiles: @Sendable ([ContinuePathResolver.ScanRoot]) -> [URL]
    private let parseFiles: @Sendable ([URL]) -> ContinueUsageSnapshot
    private let workQueue: DispatchQueue
    private let clock: @Sendable () -> Date

    /// Monotonic counter — bumped on every fetch() start (even when
    /// disabled), clear(), and disable-flag transition so a completion
    /// arriving from a stale earlier fetch cannot overwrite fresher
    /// state. Only touched on main actor.
    private var fetchGeneration: UInt64 = 0

    public init(
        defaults: UserDefaults = .standard,
        resolveScanRoots: @escaping @Sendable () -> [ContinuePathResolver.ScanRoot] = {
            ContinuePathResolver.resolveScanRoots(.current())
        },
        tccProbe: @escaping @Sendable (String) -> TCCState = { TCCProbe.probe(path: $0) },
        discoverFiles: @escaping @Sendable ([ContinuePathResolver.ScanRoot]) -> [URL] = {
            ContinueUsageFetcher.discoverFiles(under: $0)
        },
        parseFiles: @escaping @Sendable ([URL]) -> ContinueUsageSnapshot = {
            ContinueUsageFetcher.parse(files: $0)
        },
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.claude.usagebar.continue.parse",
            qos: .utility
        ),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.resolveScanRoots = resolveScanRoots
        self.tccProbe = tccProbe
        self.discoverFiles = discoverFiles
        self.parseFiles = parseFiles
        self.workQueue = workQueue
        self.clock = clock
    }

    // MARK: - UsageProvider: metadata

    public var isEnabled: Bool { defaults.bool(forKey: featureFlagKey) }

    /// "Configured" means the flag is on — Continue needs no
    /// credential. The onboarding tile handles the case where
    /// Continue is not installed.
    public var isConfigured: Bool { isEnabled }

    public var lastUpdated: Date? { lastUpdatedAt }
    public var errorMessage: String? { lastError }

    // MARK: - UsageProvider: tiles

    public var tiles: [UsageTile] {
        guard isEnabled else { return [] }

        switch tccState {
        case .denied:
            let copy = LocalProviderAccessGuide.copy(for: .denied, appName: displayName)
            let guidance = copy.guidance
                + " Continue writes its own anonymised dev-data JSONL under `~/.continue/dev_data/0.2.0/`; enabling Full Disk Access lets ClaudeUsageBar read it."
            return [UsageTile(
                id: "continue-needs-access",
                title: copy.title,
                kind: .needsAccess(
                    path: "~/.continue/dev_data/0.2.0/tokensGenerated.jsonl",
                    guidance: guidance
                )
            )]
        case .pathMissing:
            return [UsageTile(
                id: "continue-not-installed",
                title: displayName,
                kind: .text(
                    status: "No Continue log found",
                    subtitle: "If Continue is installed, use it once to create the log at `~/.continue/dev_data/0.2.0/tokensGenerated.jsonl`, then click Refresh."
                )
            )]
        case .granted:
            break
        }

        guard let snap = snapshot else {
            return [UsageTile(
                id: "continue-loading",
                title: displayName,
                kind: .text(status: "Loading…", subtitle: nil)
            )]
        }

        let now = clock()
        let todayRange = ClaudeCodeUsageStore.todayRange(around: now)
        let mtdRange = ClaudeCodeUsageStore.monthToDateRange(around: now)

        let tokensToday = snap.tokens(in: todayRange)
        let tokensMTD = snap.tokens(in: mtdRange)
        let byModel = snap.breakdownByModel(in: mtdRange)
        let byProvider = snap.breakdownByProvider(in: mtdRange)

        var out: [UsageTile] = []

        out.append(UsageTile(
            id: "continue-tokens-today",
            title: "Tokens today",
            kind: .counter(
                used: tokensToday,
                limit: nil,
                resetsAt: ClaudeCodeUsageStore.startOfNextDay(after: now)
            )
        ))

        out.append(UsageTile(
            id: "continue-tokens-mtd",
            title: "Tokens month-to-date",
            kind: .text(
                status: ClaudeCodeUsageStore.formatTokens(tokensMTD),
                subtitle: nil
            )
        ))

        if !byModel.isEmpty {
            let top = byModel.prefix(3)
            let lines = top.map { entry in
                "\(entry.model) — \(ClaudeCodeUsageStore.formatTokens(entry.tokens))"
            }
            out.append(UsageTile(
                id: "continue-by-model",
                title: "Top models this month",
                kind: .text(
                    status: lines.first ?? "",
                    subtitle: lines.dropFirst().joined(separator: "\n")
                )
            ))
        }

        if !byProvider.isEmpty {
            let top = byProvider.prefix(3)
            let lines = top.map { entry in
                "\(entry.provider) — \(ClaudeCodeUsageStore.formatTokens(entry.tokens))"
            }
            out.append(UsageTile(
                id: "continue-by-provider",
                title: "Top providers this month",
                kind: .text(
                    status: lines.first ?? "",
                    subtitle: lines.dropFirst().joined(separator: "\n")
                )
            ))
        }

        // Diagnostic tile — surfaces file-level issues that would
        // otherwise be silent under-counting. See ClineUsageStore
        // "Some sessions skipped" for the pattern.
        let unreadable = snap.unreadableFileCount
        let malformed = snap.malformedRecordCount
        let overCap = snap.overCapFileCount
        if unreadable > 0 || malformed > 0 || overCap > 0 {
            var lines: [String] = []
            if unreadable > 0 {
                lines.append("\(unreadable) log file\(unreadable == 1 ? "" : "s") could not be read.")
            }
            if overCap > 0 {
                lines.append("\(overCap) log file\(overCap == 1 ? "" : "s") exceeded the 256 MB cap.")
            }
            if malformed > 0 {
                lines.append("\(malformed) log line\(malformed == 1 ? "" : "s") could not be parsed (a partial write may be in flight).")
            }
            out.append(UsageTile(
                id: "continue-diagnostics",
                title: "Some records skipped",
                kind: .text(
                    status: lines.first ?? "",
                    subtitle: lines.dropFirst().joined(separator: "\n")
                )
            ))
        }

        return out
    }

    // MARK: - UsageProvider: actions

    public func fetch() {
        // Bump generation even when disabled so a rapid disable →
        // fetch()-while-disabled → re-enable → fetch() sequence cannot
        // let a pre-disable in-flight fetch's completion apply
        // (Cline Codex round-5 finding #1).
        fetchGeneration &+= 1
        guard isEnabled else {
            snapshot = nil
            return
        }
        let launchGeneration = fetchGeneration
        // 3cc R3 F1 fix: `resolveScanRoots()` and the TCC probe both
        // do synchronous file I/O (Continue's scan-root path check is
        // cheap because it's just one file, but the pattern-matches
        // Roo/Zoo for consistency and defence against a future
        // resolver that adds discovery logic).
        let resolve = self.resolveScanRoots
        let probe = self.tccProbe
        let discover = self.discoverFiles
        let parse = self.parseFiles

        workQueue.async { [weak self] in
            let scanRoots = resolve()
            var grantedRoots: [ContinuePathResolver.ScanRoot] = []
            var deniedRoots: [ContinuePathResolver.ScanRoot] = []
            for root in scanRoots {
                switch probe(root.jsonlPath) {
                case .granted:     grantedRoots.append(root)
                case .denied:      deniedRoots.append(root)
                case .pathMissing: break
                }
            }
            let aggregated: TCCState
            if !grantedRoots.isEmpty {
                aggregated = .granted
            } else if !deniedRoots.isEmpty {
                aggregated = .denied
            } else {
                aggregated = .pathMissing
            }

            if aggregated != .granted {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    guard self.isEnabled else { return }
                    guard launchGeneration == self.fetchGeneration else { return }
                    self.tccState = aggregated
                    self.snapshot = nil
                    self.lastError = nil
                }
                return
            }

            let urls = discover(grantedRoots)
            let snap = parse(urls)

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isEnabled else { return }
                guard launchGeneration == self.fetchGeneration else { return }
                // 3cc R3 F5: re-probe every root on completion. If any
                // turned .denied between fetch-start and now, discard
                // this parse result. Without this, revoking TCC
                // mid-parse writes an empty snapshot as if the user
                // had no usage.
                var stillGranted = true
                for root in grantedRoots {
                    switch probe(root.jsonlPath) {
                    case .granted:     break
                    case .denied:      stillGranted = false
                    case .pathMissing: break // was granted; now missing — treat as no data
                    }
                }
                if !stillGranted {
                    self.tccState = .denied
                    self.snapshot = nil
                    return
                }
                self.tccState = .granted
                self.snapshot = snap
                self.lastUpdatedAt = self.clock()
                self.lastError = nil
                Log.info("Continue JSONL parsed", .count(snap.records.count))
            }
        }
    }

    public func clear() {
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
        fetchGeneration &+= 1
    }
}
