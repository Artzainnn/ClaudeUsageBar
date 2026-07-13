// PR 10c-BE — Cline UsageProvider store (feature-flag off).
//
// Second local-file reader. Watches every candidate globalStorage path
// (VS Code stable, Insiders, VSCodium, Cursor, Windsurf, plus the Cline
// CLI variants under `~/.cline/data` / `$CLINE_DATA_DIR` / `$CLINE_DIR/data`)
// and produces a token+cost rollup on demand. Nothing leaves the machine.
//
// Concurrency model mirrors ClaudeCodeUsageStore: parse work runs on a
// serial background queue; results apply on the main actor via
// `Task { @MainActor [weak self] in ... }`; `fetchGeneration` invalidates
// any in-flight completion so a TCC transition, disable, or `clear()`
// cannot repopulate stale state.
//
// Feature posture: `features.cline.enabled` defaults false. Nothing
// registers a ClineUsageStore into `AppDelegate.providers` yet — that
// lands in PR 10c-UI along with `ProviderCopy.help(for: "cline")`.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class ClineUsageStore: @preconcurrency UsageProvider {

    public let id: String = "cline"
    public let displayName: String = "Cline"
    public let featureFlagKey: String = "features.cline.enabled"

    // MARK: - Observable state

    @Published public private(set) var snapshot: ClineUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?
    /// Aggregated TCC state across all candidate scan roots. `.granted`
    /// if at least one root is readable; `.pathMissing` if no root
    /// exists; `.denied` if every existing root is unreadable (rare —
    /// Cline lives under `~/Library/Application Support` which is NOT
    /// TCC-protected on 12.0+, so this is generally reachable without
    /// Full Disk Access, unlike Warp's Group Container path).
    @Published public private(set) var tccState: TCCState = .granted
    /// Number of scan roots that exist but were probed `.denied` on the
    /// last fetch. Codex round-1 finding #1: if this is non-zero AND
    /// `tccState == .granted`, the rollup is PARTIAL — some Cline
    /// data is on disk but we could not read it. Surfaced as a
    /// diagnostic tile so the user is not misled by an incomplete
    /// number.
    @Published public private(set) var deniedRootCount: Int = 0

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let resolveScanRoots: @Sendable () -> [ClinePathResolver.ScanRoot]
    private let tccProbe: @Sendable (String) -> TCCState
    private let discoverFiles: @Sendable ([ClinePathResolver.ScanRoot]) -> [URL]
    private let parseFiles: @Sendable ([URL]) -> ClineUsageSnapshot
    private let workQueue: DispatchQueue
    private let clock: @Sendable () -> Date

    /// Monotonic counter — bumped on every fetch() start, clear(), and
    /// disable-flag toggle so a completion arriving from a stale earlier
    /// fetch cannot overwrite fresher state. Only touched on main actor.
    private var fetchGeneration: UInt64 = 0
    /// Hash of the granted-root-set from the last fetch that applied a
    /// snapshot. Codex round-2 finding #4: when the set changes
    /// (e.g. user revokes Cursor access), the OLD snapshot may still
    /// include usage from a now-inaccessible root. Detected by
    /// comparing the current granted-root-set against this stored
    /// hash; a change clears the snapshot so the tile does not show
    /// stale numbers while the new parse runs.
    private var lastAppliedGrantedRootsKey: String?

    public init(
        defaults: UserDefaults = .standard,
        resolveScanRoots: @escaping @Sendable () -> [ClinePathResolver.ScanRoot] = {
            ClinePathResolver.resolveScanRoots(.current())
        },
        tccProbe: @escaping @Sendable (String) -> TCCState = { TCCProbe.probe(path: $0) },
        discoverFiles: @escaping @Sendable ([ClinePathResolver.ScanRoot]) -> [URL] = {
            ClineUsageFetcher.discoverFiles(under: $0)
        },
        parseFiles: @escaping @Sendable ([URL]) -> ClineUsageSnapshot = {
            ClineUsageFetcher.parse(files: $0)
        },
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.claude.usagebar.cline.parse",
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

    public var isEnabled: Bool {
        defaults.bool(forKey: featureFlagKey)
    }

    /// "Configured" means the flag is on — there is no credential to
    /// paste. The onboarding tile handles the case where Cline is not
    /// installed on this Mac.
    public var isConfigured: Bool { isEnabled }

    public var lastUpdated: Date? { lastUpdatedAt }

    public var errorMessage: String? { lastError }

    // MARK: - UsageProvider: tiles

    public var tiles: [UsageTile] {
        guard isEnabled else { return [] }

        switch tccState {
        case .denied:
            let copy = LocalProviderAccessGuide.copy(for: .denied, appName: displayName)
            // Codex round-2 + round-3 + round-4 findings: name every
            // supported location — editor family AND CLI — in the
            // WRAPPING guidance line, not the monospace `path` line
            // (which UsageTileView renders `.lineLimit(1)` with
            // middle-truncation and hides most of the string in a
            // 360px popover).
            let clineGuidance = copy.guidance
                + " Cline data lives under: `<host>/User/globalStorage/saoudrizwan.claude-dev/tasks/` for VS Code, VS Code Insiders, VSCodium, Cursor, or Windsurf; or `$CLINE_DATA_DIR/tasks/`, `$CLINE_DIR/data/tasks/`, or `~/.cline/data/tasks/` for the Cline CLI."
            return [UsageTile(
                id: "cline-needs-access",
                title: copy.title,
                kind: .needsAccess(
                    path: "~/Library/Application Support/…/saoudrizwan.claude-dev/tasks",
                    guidance: clineGuidance
                )
            )]
        case .pathMissing:
            // Codex round-3 finding: "not installed" was misleading
            // for an editor user who has Cline installed but has not
            // yet started a task, so `tasks/` is missing. Reframe as
            // "no sessions" with two remediation paths.
            return [UsageTile(
                id: "cline-not-installed",
                title: displayName,
                kind: .text(
                    status: "No Cline sessions found",
                    subtitle: "If Cline is installed in VS Code, VS Code Insiders, VSCodium, Cursor, or Windsurf, start a Cline task and click Refresh. If you use the Cline CLI, run it at least once."
                )
            )]
        case .granted:
            break
        }

        // Codex round-2 finding #3: surface the partial-access tile
        // BEFORE the snapshot guard so a slow parse does not hide the
        // access problem from the user.
        var priorityTiles: [UsageTile] = []
        if deniedRootCount > 0 {
            priorityTiles.append(UsageTile(
                id: "cline-partial-access",
                title: "Partial access",
                kind: .text(
                    status: "\(deniedRootCount) Cline install\(deniedRootCount == 1 ? "" : "s") could not be read.",
                    subtitle: "Grant Full Disk Access in System Settings to include their usage."
                )
            ))
        }

        guard let snap = snapshot else {
            return priorityTiles + [UsageTile(
                id: "cline-loading",
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
            id: "cline-tokens-today",
            title: "Tokens today",
            kind: .counter(
                used: tokensToday,
                limit: nil,
                resetsAt: ClaudeCodeUsageStore.startOfNextDay(after: now)
            )
        ))
        out.append(UsageTile(
            id: "cline-cost-today",
            title: "Cost today",
            kind: .text(status: ClaudeCodeUsageStore.formatUSD(costToday), subtitle: nil)
        ))
        out.append(UsageTile(
            id: "cline-cost-mtd",
            title: "Cost month-to-date",
            kind: .text(status: ClaudeCodeUsageStore.formatUSD(costMTD), subtitle: nil)
        ))
        if !byModel.isEmpty {
            let top = byModel.prefix(3)
            let lines = top.map { entry in
                "\(entry.model) — \(ClaudeCodeUsageStore.formatUSD(entry.costUSD)) (\(ClaudeCodeUsageStore.formatTokens(entry.tokens)))"
            }
            out.append(UsageTile(
                id: "cline-by-model",
                title: "Top models this month",
                kind: .text(
                    status: lines.first ?? "",
                    subtitle: lines.dropFirst().joined(separator: "\n")
                )
            ))
        }

        // 3cc round-1 finding #2: surface file-level parse failures.
        // Without this, a corrupt / over-cap / permission-denied
        // ui_messages.json is silently skipped and the tile shows the
        // remaining totals as complete — the user has no way to know
        // some sessions are missing. Both counts are diagnostics, not
        // errors, so the tile is informational, not alarming.
        let unreadable = snap.unreadableFileCount
        let malformed = snap.malformedRecordCount
        if unreadable > 0 || malformed > 0 {
            var lines: [String] = []
            if unreadable > 0 {
                lines.append("\(unreadable) session file\(unreadable == 1 ? "" : "s") could not be read (corrupt, over 64 MB, or unreadable).")
            }
            if malformed > 0 {
                lines.append("\(malformed) usage record\(malformed == 1 ? "" : "s") could not be parsed (a partial write may be in flight).")
            }
            out.append(UsageTile(
                id: "cline-diagnostics",
                title: "Some sessions skipped",
                kind: .text(
                    status: lines.first ?? "",
                    subtitle: lines.dropFirst().joined(separator: "\n")
                )
            ))
        }

        // Codex round-1 finding #1 partial-access tile is now emitted
        // as a priority tile above (round-2 finding #3), so it stays
        // visible during a slow parse too.

        return priorityTiles + out
    }

    // MARK: - UsageProvider: actions

    public func fetch() {
        // Codex round-5 finding #1: bump generation even when disabled
        // so a rapid disable → fetch()-while-disabled → re-enable →
        // fetch() sequence cannot let a pre-disable in-flight fetch's
        // completion apply. The isEnabled guard on the completion
        // still exists, but generation-bump gives defence-in-depth
        // against a future refactor that removes it.
        fetchGeneration &+= 1
        guard isEnabled else {
            snapshot = nil
            lastAppliedGrantedRootsKey = nil
            return
        }
        let launchGeneration = fetchGeneration

        let scanRoots = resolveScanRoots()

        // Codex round-1 finding #1: track granted vs denied roots
        // SEPARATELY. Only pass GRANTED roots to discoverFiles so a
        // denied root is never silently skipped mid-parse. If EVERY
        // existing root is denied, surface `.denied` so the user is
        // prompted to grant Full Disk Access. If any root is granted
        // (regardless of a sibling denial), we can still deliver
        // usage from the readable roots, but we surface the partial-
        // access warning via `deniedRootsCount` on the snapshot for a
        // future diagnostic tile (kept as store state below).
        // chk1 Bug #2: `pathMissing` roots are counted by the "if no
        // granted and no denied" branch below via the `.pathMissing`
        // aggregate state, so we do not need a separate counter here.
        var grantedRoots: [ClinePathResolver.ScanRoot] = []
        var deniedRoots: [ClinePathResolver.ScanRoot] = []
        for root in scanRoots {
            switch tccProbe(root.tasksDirectoryPath) {
            case .granted:      grantedRoots.append(root)
            case .denied:       deniedRoots.append(root)
            case .pathMissing:  break
            }
        }
        let aggregated: TCCState
        if !grantedRoots.isEmpty {
            aggregated = .granted
        } else if !deniedRoots.isEmpty {
            // No granted roots at all — surface denial so the user
            // grants access.
            aggregated = .denied
        } else {
            aggregated = .pathMissing
        }
        self.tccState = aggregated
        self.deniedRootCount = deniedRoots.count

        if aggregated != .granted {
            self.snapshot = nil
            self.lastAppliedGrantedRootsKey = nil
            self.lastError = nil
            return
        }

        // Codex round-2 finding #4: if the granted-root-set changed
        // since the last applied snapshot, drop the OLD snapshot so
        // the tile does not show stale numbers (which may include
        // usage from a now-denied root) while the new parse runs.
        let grantedKey = grantedRoots.map(\.tasksDirectoryPath).sorted().joined(separator: "\n")
        if grantedKey != lastAppliedGrantedRootsKey {
            self.snapshot = nil
        }

        // Only scan roots that were probed .granted — never re-scan a
        // denied root (which would silently drop its data).
        let rootsCopy = grantedRoots
        let discover = self.discoverFiles
        let parse = self.parseFiles

        // Sendable capture of the granted-root-set key so the apply
        // hop can record which set produced the snapshot (Codex
        // round-2 finding #4).
        let grantedKeyCopy = grantedKey
        // Capture dependencies for the re-probe below (3cc round-1
        // finding #1).
        let tccProbeCopy = self.tccProbe
        workQueue.async { [weak self] in
            let urls = discover(rootsCopy)
            let snap = parse(urls)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Claude Code round-3 finding #3: guard on isEnabled
                // too, so a fetch that completes after the user
                // disables the provider cannot repopulate.
                guard self.isEnabled else { return }
                guard launchGeneration == self.fetchGeneration else { return }
                // 3cc round-1 finding #1: TCC may have been revoked
                // between fetch-start and now. discoverFiles(⋯) on a
                // now-unreadable root returns [] silently, so we would
                // otherwise write an empty snapshot as if the user had
                // no usage. Re-probe every root that was granted at
                // fetch-start; if any turned .denied, discard this
                // parse result, surface .denied, and rely on the next
                // fetch tick to reconcile.
                var stillAllGranted = true
                var newDeniedCount = 0
                for root in rootsCopy {
                    switch tccProbeCopy(root.tasksDirectoryPath) {
                    case .granted:      break
                    case .denied:       stillAllGranted = false; newDeniedCount += 1
                    case .pathMissing:  break  // was granted; now missing — treat
                                               // as "no data" not "access revoked"
                    }
                }
                if !stillAllGranted {
                    self.tccState = .denied
                    self.deniedRootCount = self.deniedRootCount + newDeniedCount
                    self.snapshot = nil
                    self.lastAppliedGrantedRootsKey = nil
                    return
                }
                self.snapshot = snap
                self.lastAppliedGrantedRootsKey = grantedKeyCopy
                // Codex round-5 finding #2: use the injected clock so
                // deterministic tests get deterministic lastUpdatedAt.
                self.lastUpdatedAt = self.clock()
                self.lastError = nil
                Log.info("Cline ui_messages parsed", .count(snap.records.count))
            }
        }
    }

    public func clear() {
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
        lastAppliedGrantedRootsKey = nil
        fetchGeneration &+= 1
    }
}
