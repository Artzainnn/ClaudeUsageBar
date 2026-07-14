// PR 15-BE — Gemini Developer UsageProvider store (feature-flag off).
//
// Mirrors ClineUsageStore.fetch() with generation counter, weak-self
// work queue, and re-probe on completion (3cc R3 F5). Fetch runs off
// main actor.
//
// Feature posture — `features.gemini.enabled` defaults false. Nothing
// registers a GeminiUsageStore into `AppDelegate.providers` yet;
// that lands in PR 15-UI.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class GeminiUsageStore: @preconcurrency UsageProvider {

    public let id: String = "gemini"
    public let displayName: String = "Gemini CLI"
    public let featureFlagKey: String = "features.gemini.enabled"

    @Published public private(set) var snapshot: GeminiUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var tccState: TCCState = .granted

    private let defaults: UserDefaults
    private let resolveScanRoots: @Sendable () -> [GeminiPathResolver.ScanRoot]
    private let tccProbe: @Sendable (String) -> TCCState
    private let discoverFiles: @Sendable ([GeminiPathResolver.ScanRoot]) -> [URL]
    private let parseFiles: @Sendable ([URL]) -> GeminiUsageSnapshot
    private let workQueue: DispatchQueue
    private let clock: @Sendable () -> Date

    private var fetchGeneration: UInt64 = 0

    public init(
        defaults: UserDefaults = .standard,
        resolveScanRoots: @escaping @Sendable () -> [GeminiPathResolver.ScanRoot] = {
            GeminiPathResolver.resolveScanRoots(.current())
        },
        tccProbe: @escaping @Sendable (String) -> TCCState = { TCCProbe.probe(path: $0) },
        discoverFiles: @escaping @Sendable ([GeminiPathResolver.ScanRoot]) -> [URL] = {
            GeminiUsageFetcher.discoverFiles(under: $0)
        },
        parseFiles: @escaping @Sendable ([URL]) -> GeminiUsageSnapshot = {
            GeminiUsageFetcher.parse(files: $0)
        },
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.claude.usagebar.gemini.parse",
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

    public var isEnabled: Bool { defaults.bool(forKey: featureFlagKey) }
    public var isConfigured: Bool { isEnabled }
    public var lastUpdated: Date? { lastUpdatedAt }
    public var errorMessage: String? { lastError }

    public var tiles: [UsageTile] {
        guard isEnabled else { return [] }

        switch tccState {
        case .denied:
            let copy = LocalProviderAccessGuide.copy(for: .denied, appName: displayName)
            let guidance = copy.guidance + " Gemini CLI writes session logs under `~/.gemini/tmp/<projectHash>/chats/`; enabling Full Disk Access lets ClaudeUsageBar read them."
            return [UsageTile(
                id: "gemini-needs-access",
                title: copy.title,
                kind: .needsAccess(
                    path: "~/.gemini/tmp/…/chats/session-*.jsonl",
                    guidance: guidance
                )
            )]
        case .pathMissing:
            return [UsageTile(
                id: "gemini-not-installed",
                title: displayName,
                kind: .text(
                    status: "No Gemini CLI sessions found",
                    subtitle: "Install and use the `gemini` CLI at least once — session logs land under `~/.gemini/tmp/<projectHash>/chats/`. Click Refresh."
                )
            )]
        case .granted:
            break
        }

        guard let snap = snapshot else {
            return [UsageTile(
                id: "gemini-loading",
                title: displayName,
                kind: .text(status: "Loading…", subtitle: nil)
            )]
        }

        let now = clock()
        let todayRange = ClaudeCodeUsageStore.todayRange(around: now)
        let mtdRange = ClaudeCodeUsageStore.monthToDateRange(around: now)

        let tokensToday = snap.tokens(in: todayRange)
        let costToday = snap.cost(in: todayRange)
        let costMTD = snap.cost(in: mtdRange)
        let byModel = snap.breakdownByModel(in: mtdRange)

        var out: [UsageTile] = []
        out.append(UsageTile(
            id: "gemini-tokens-today",
            title: "Tokens today",
            kind: .counter(
                used: tokensToday,
                limit: nil,
                resetsAt: ClaudeCodeUsageStore.startOfNextDay(after: now)
            )
        ))
        out.append(UsageTile(
            id: "gemini-cost-today",
            title: "Cost today",
            kind: .text(status: ClaudeCodeUsageStore.formatUSD(costToday), subtitle: nil)
        ))
        out.append(UsageTile(
            id: "gemini-cost-mtd",
            title: "Cost month-to-date",
            kind: .text(status: ClaudeCodeUsageStore.formatUSD(costMTD), subtitle: nil)
        ))
        if !byModel.isEmpty {
            let top = byModel.prefix(3)
            let lines = top.map { entry in
                "\(entry.model) — \(ClaudeCodeUsageStore.formatUSD(entry.costUSD)) (\(ClaudeCodeUsageStore.formatTokens(entry.tokens)))"
            }
            out.append(UsageTile(
                id: "gemini-by-model",
                title: "Top models this month",
                kind: .text(
                    status: lines.first ?? "",
                    subtitle: lines.dropFirst().joined(separator: "\n")
                )
            ))
        }

        // Unknown-model diagnostic — surfaces when Google ships a new
        // Gemini model that isn't in our bundled pricing snapshot.
        if snap.unknownModelRecordCount > 0 {
            out.append(UsageTile(
                id: "gemini-pricing-stale",
                title: "Pricing update available",
                kind: .text(
                    status: "\(snap.unknownModelRecordCount) record\(snap.unknownModelRecordCount == 1 ? "" : "s") used a model this app doesn't know about.",
                    subtitle: "Tokens are counted; cost shows $0 for those records until this app is updated."
                )
            ))
        }

        // File-level diagnostics.
        let unreadable = snap.unreadableFileCount
        let malformed = snap.malformedRecordCount
        let overCap = snap.overCapFileCount
        if unreadable > 0 || malformed > 0 || overCap > 0 {
            var lines: [String] = []
            if unreadable > 0 {
                lines.append("\(unreadable) session file\(unreadable == 1 ? "" : "s") could not be read.")
            }
            if overCap > 0 {
                lines.append("\(overCap) session file\(overCap == 1 ? "" : "s") exceeded the 256 MB cap.")
            }
            if malformed > 0 {
                lines.append("\(malformed) record\(malformed == 1 ? "" : "s") could not be parsed.")
            }
            out.append(UsageTile(
                id: "gemini-diagnostics",
                title: "Some records skipped",
                kind: .text(
                    status: lines.first ?? "",
                    subtitle: lines.dropFirst().joined(separator: "\n")
                )
            ))
        }
        return out
    }

    public func fetch() {
        fetchGeneration &+= 1
        guard isEnabled else {
            snapshot = nil
            return
        }
        let launchGeneration = fetchGeneration
        let resolve = self.resolveScanRoots
        let probe = self.tccProbe
        let discover = self.discoverFiles
        let parse = self.parseFiles

        workQueue.async { [weak self] in
            let scanRoots = resolve()
            var grantedRoots: [GeminiPathResolver.ScanRoot] = []
            var deniedRoots: [GeminiPathResolver.ScanRoot] = []
            for root in scanRoots {
                switch probe(root.tmpDirectoryPath) {
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
                    self.lastUpdatedAt = nil
                }
                return
            }
            let urls = discover(grantedRoots)
            let snap = parse(urls)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isEnabled else { return }
                guard launchGeneration == self.fetchGeneration else { return }
                var stillGranted = true
                for root in grantedRoots {
                    switch probe(root.tmpDirectoryPath) {
                    case .granted: break
                    case .denied:  stillGranted = false
                    case .pathMissing: break
                    }
                }
                if !stillGranted {
                    self.tccState = .denied
                    self.snapshot = nil
                    self.lastUpdatedAt = nil
                    return
                }
                self.tccState = .granted
                self.snapshot = snap
                self.lastUpdatedAt = self.clock()
                self.lastError = nil
                Log.info("Gemini JSONL parsed", .count(snap.records.count))
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
