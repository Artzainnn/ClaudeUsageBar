// PR 19 — merged Roo + Zoo UsageProvider store.
//
// Before PR 19, `RooUsageStore` and `ZooUsageStore` were two ~360-
// line stores that differed by exactly 9 substantive characters
// (extension id enum case, display-name string, feature-flag key,
// workQueue label, and log-line prefix — all derivable from a
// single `RooZooExtension` value). The duplication was intentional
// during Milestone 6 (PR 13-BE) so the two providers could remain
// independent should they diverge; Roo's GitHub repo is archived
// (May 2026) and Zoo Code is the active fork, so divergence is now
// implausible.
//
// PR 19 merges them into a single parameterised
// `RooZooUsageStore` class. Two instances are constructed at
// registration time — `RooZooUsageStore(ext: .roo)` and
// `RooZooUsageStore(ext: .zoo)` — so users still toggle each
// provider independently via distinct feature flags.
//
// Concurrency: same pattern as ClineUsageStore.fetch():
// - generation counter invalidates stale completions.
// - resolveScanRoots + TCC probe loop run OFF the main actor
//   (3cc R3 F1 pattern from PR 13-BE).
// - re-probe on completion (3cc R3 F5).
// - non-granted branch clears lastUpdatedAt (3cc round-2 F2).
//
// Public type kept as `RooUsageStore` for source-compatibility of
// the AppDelegate registration site; ZooUsageStore is deleted.

import Foundation
import SwiftUI
import Combine

/// Type-alias so `Roo` and `Zoo` remain distinct compile-time
/// identifiers at the registration site, while sharing one
/// implementation. `AppDelegate.applicationDidFinishLaunching`
/// still writes `providers.append(ProviderBox(RooUsageStore()))`
/// and `providers.append(ProviderBox(ZooUsageStore()))`; both
/// forward to the merged class below.
public typealias RooUsageStore = RooZooUsageStore
public typealias ZooUsageStore = RooZooUsageStore

@MainActor
public final class RooZooUsageStore: UsageProvider {

    public let ext: RooZooExtension

    public var id: String {
        switch ext {
        case .roo: return "roo"
        case .zoo: return "zoo"
        }
    }
    public var displayName: String { ext.displayShortName }
    public var featureFlagKey: String { "features.\(id).enabled" }

    @Published public private(set) var snapshot: RooZooUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var tccState: TCCState = .granted
    @Published public private(set) var deniedRootCount: Int = 0
    @Published public private(set) var overTaskCapCount: Int = 0

    private let defaults: UserDefaults
    private let resolveScanRoots: @Sendable () -> [RooZooPathResolver.ScanRoot]
    private let tccProbe: @Sendable (String) -> TCCState
    private let discoverTasks: @Sendable ([RooZooPathResolver.ScanRoot]) -> (tasks: [RooZooDiscoveredTask], overCap: Int)
    private let parseTasks: @Sendable ([RooZooDiscoveredTask]) -> RooZooUsageSnapshot
    private let workQueue: DispatchQueue
    private let clock: @Sendable () -> Date

    private var fetchGeneration: UInt64 = 0
    private var lastAppliedGrantedRootsKey: String?

    public init(
        ext: RooZooExtension = .roo,
        defaults: UserDefaults = .standard,
        resolveScanRoots: (@Sendable () -> [RooZooPathResolver.ScanRoot])? = nil,
        tccProbe: @escaping @Sendable (String) -> TCCState = { TCCProbe.probe(path: $0) },
        discoverTasks: @escaping @Sendable ([RooZooPathResolver.ScanRoot]) -> (tasks: [RooZooDiscoveredTask], overCap: Int) = {
            RooZooUsageFetcher.discoverTasks(under: $0)
        },
        parseTasks: @escaping @Sendable ([RooZooDiscoveredTask]) -> RooZooUsageSnapshot = {
            RooZooUsageFetcher.parseTasks($0)
        },
        workQueue: DispatchQueue? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ext = ext
        self.defaults = defaults
        // Default resolveScanRoots binds the extension value so we
        // don't need one closure per case in the type-alias.
        self.resolveScanRoots = resolveScanRoots ?? {
            RooZooPathResolver.resolveScanRoots(.current(), for: ext)
        }
        self.tccProbe = tccProbe
        self.discoverTasks = discoverTasks
        self.parseTasks = parseTasks
        // Distinct workQueue label per extension for
        // Instruments-friendly stack traces.
        self.workQueue = workQueue ?? DispatchQueue(
            label: "com.claude.usagebar.\(ext.rawValue).parse",
            qos: .utility
        )
        self.clock = clock
    }

    public var isEnabled: Bool { defaults.bool(forKey: featureFlagKey) }
    public var isConfigured: Bool { isEnabled }
    public var lastUpdated: Date? { lastUpdatedAt }
    public var errorMessage: String? { lastError }

    public var tiles: [UsageTile] {
        guard isEnabled else { return [] }
        return RooZooTileBuilder.build(
            providerId: id,
            displayName: displayName,
            snapshot: snapshot,
            tccState: tccState,
            deniedRootCount: deniedRootCount,
            overTaskCapCount: overTaskCapCount,
            now: clock()
        )
    }

    public func fetch() {
        fetchGeneration &+= 1
        guard isEnabled else {
            snapshot = nil
            lastAppliedGrantedRootsKey = nil
            deniedRootCount = 0
            overTaskCapCount = 0
            return
        }
        let launchGeneration = fetchGeneration
        let resolve = self.resolveScanRoots
        let probe = self.tccProbe
        let discover = self.discoverTasks
        let parse = self.parseTasks
        let priorAppliedKey = self.lastAppliedGrantedRootsKey
        // Capture the extension's display short name for the log
        // line so the two instances produce distinguishable log
        // output.
        let logLabel = "\(ext.displayShortName) tasks parsed"

        workQueue.async { [weak self] in
            let scanRoots = resolve()
            var grantedRoots: [RooZooPathResolver.ScanRoot] = []
            var deniedRoots: [RooZooPathResolver.ScanRoot] = []
            for root in scanRoots {
                switch probe(root.tasksDirectoryPath) {
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
            let deniedCount = deniedRoots.count
            let grantedKey = grantedRoots.map(\.tasksDirectoryPath).sorted().joined(separator: "\n")

            if aggregated != .granted {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    guard self.isEnabled else { return }
                    guard launchGeneration == self.fetchGeneration else { return }
                    self.tccState = aggregated
                    self.deniedRootCount = deniedCount
                    self.snapshot = nil
                    self.lastAppliedGrantedRootsKey = nil
                    self.lastError = nil
                    self.overTaskCapCount = 0
                    self.lastUpdatedAt = nil
                }
                return
            }

            let (tasks, overCap) = discover(grantedRoots)
            let snap = parse(tasks)

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isEnabled else { return }
                guard launchGeneration == self.fetchGeneration else { return }
                self.tccState = .granted
                self.deniedRootCount = deniedCount
                if grantedKey != priorAppliedKey {
                    self.snapshot = nil
                }
                var stillAllGranted = true
                var newDeniedCount = 0
                for root in grantedRoots {
                    switch probe(root.tasksDirectoryPath) {
                    case .granted:     break
                    case .denied:      stillAllGranted = false; newDeniedCount += 1
                    case .pathMissing: break
                    }
                }
                if !stillAllGranted {
                    self.tccState = .denied
                    self.deniedRootCount = deniedCount + newDeniedCount
                    self.snapshot = nil
                    self.lastAppliedGrantedRootsKey = nil
                    self.overTaskCapCount = 0
                    self.lastUpdatedAt = nil
                    return
                }
                self.snapshot = snap
                self.overTaskCapCount = overCap
                self.lastAppliedGrantedRootsKey = grantedKey
                self.lastUpdatedAt = self.clock()
                self.lastError = nil
                Log.info(logLabel, .count(snap.records.count))
            }
        }
    }

    public func clear() {
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
        lastAppliedGrantedRootsKey = nil
        deniedRootCount = 0
        overTaskCapCount = 0
        fetchGeneration &+= 1
    }
}

// MARK: - Shared tile builder

/// Common tile-rendering logic between the two Roo/Zoo instances.
/// The `providerId` prefix scopes tile IDs (`roo-tokens-today` /
/// `zoo-tokens-today`).
public enum RooZooTileBuilder {

    public static func build(
        providerId: String,
        displayName: String,
        snapshot: RooZooUsageSnapshot?,
        tccState: TCCState,
        deniedRootCount: Int,
        overTaskCapCount: Int,
        now: Date
    ) -> [UsageTile] {
        switch tccState {
        case .denied:
            let copy = LocalProviderAccessGuide.copy(for: .denied, appName: displayName)
            let guidance = copy.guidance
                + " \(displayName) data lives under: `<host>/User/globalStorage/<publisher>/tasks/` for VS Code, VS Code Insiders, VSCodium, Cursor, Cursor Nightly, or Windsurf. A user-configured `customStoragePath` in the host's settings.json is also honoured."
            return [UsageTile(
                id: "\(providerId)-needs-access",
                title: copy.title,
                kind: .needsAccess(
                    path: "~/Library/Application Support/…/<publisher>/tasks",
                    guidance: guidance
                )
            )]
        case .pathMissing:
            return [UsageTile(
                id: "\(providerId)-not-installed",
                title: displayName,
                kind: .text(
                    status: "No \(displayName) sessions found",
                    subtitle: "If \(displayName) is installed in VS Code, VS Code Insiders, VSCodium, Cursor, Cursor Nightly, or Windsurf, start a task and click Refresh."
                )
            )]
        case .granted:
            break
        }

        var priorityTiles: [UsageTile] = []
        if deniedRootCount > 0 {
            priorityTiles.append(UsageTile(
                id: "\(providerId)-partial-access",
                title: "Partial access",
                kind: .text(
                    status: "\(deniedRootCount) \(displayName) install\(deniedRootCount == 1 ? "" : "s") could not be read.",
                    subtitle: "Grant Full Disk Access in System Settings to include their usage."
                )
            ))
        }
        if overTaskCapCount > 0 {
            priorityTiles.append(UsageTile(
                id: "\(providerId)-cap",
                title: "Session cap hit",
                kind: .text(
                    status: "Only 10 000 most-recent sessions counted.",
                    subtitle: "\(overTaskCapCount) additional session\(overTaskCapCount == 1 ? "" : "s") skipped."
                )
            ))
        }

        guard let snap = snapshot else {
            return priorityTiles + [UsageTile(
                id: "\(providerId)-loading",
                title: displayName,
                kind: .text(status: "Loading…", subtitle: nil)
            )]
        }

        let todayRange = ClaudeCodeUsageStore.todayRange(around: now)
        let mtdRange = ClaudeCodeUsageStore.monthToDateRange(around: now)

        let tokensToday = snap.tokens(in: todayRange)
        let costToday = snap.cost(in: todayRange)
        let costMTD = snap.cost(in: mtdRange)
        let byModel = snap.breakdownByModel(in: mtdRange)

        var out: [UsageTile] = []

        out.append(UsageTile(
            id: "\(providerId)-tokens-today",
            title: "Tokens today",
            kind: .counter(
                used: tokensToday,
                limit: nil,
                resetsAt: ClaudeCodeUsageStore.startOfNextDay(after: now)
            )
        ))
        out.append(UsageTile(
            id: "\(providerId)-cost-today",
            title: "Cost today",
            kind: .text(status: ClaudeCodeUsageStore.formatUSD(costToday), subtitle: nil)
        ))
        out.append(UsageTile(
            id: "\(providerId)-cost-mtd",
            title: "Cost month-to-date",
            kind: .text(status: ClaudeCodeUsageStore.formatUSD(costMTD), subtitle: nil)
        ))

        if !byModel.isEmpty {
            let top = byModel.prefix(3)
            let lines = top.map { entry in
                "\(entry.model) — \(ClaudeCodeUsageStore.formatUSD(entry.costUSD)) (\(ClaudeCodeUsageStore.formatTokens(entry.tokens)))"
            }
            out.append(UsageTile(
                id: "\(providerId)-by-model",
                title: "Top models this month",
                kind: .text(
                    status: lines.first ?? "",
                    subtitle: lines.dropFirst().joined(separator: "\n")
                )
            ))
        }

        let unreadable = snap.unreadableFileCount
        let malformed = snap.malformedRecordCount
        let overCap = snap.overCapFileCount
        if unreadable > 0 || malformed > 0 || overCap > 0 {
            var lines: [String] = []
            if unreadable > 0 {
                lines.append("\(unreadable) session file\(unreadable == 1 ? "" : "s") could not be read.")
            }
            if overCap > 0 {
                lines.append("\(overCap) session file\(overCap == 1 ? "" : "s") exceeded the 128 MB cap.")
            }
            if malformed > 0 {
                lines.append("\(malformed) usage record\(malformed == 1 ? "" : "s") could not be parsed (a partial write may be in flight).")
            }
            out.append(UsageTile(
                id: "\(providerId)-diagnostics",
                title: "Some sessions skipped",
                kind: .text(
                    status: lines.first ?? "",
                    subtitle: lines.dropFirst().joined(separator: "\n")
                )
            ))
        }

        return priorityTiles + out
    }
}
