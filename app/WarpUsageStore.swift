// PR 12-BE — Warp UsageProvider store (feature-flag off).
//
// Fifth local-file provider. Reads Warp's own state sqlite for a
// today-window AI-query count and (when the schema shape is unknown)
// surfaces a diagnostic tile per EXPANSION_PLAN.md § Phase 8f's
// "version-guard the reader" directive.
//
// Feature posture: `features.warp.enabled` defaults false. Nothing
// registers a WarpUsageStore into `AppDelegate.providers` yet — that
// lands in PR 12-UI along with `ProviderCopy.help(for: "warp")`.
//
// Live-endpoint deferred: Warp officially documents `wk-`-prefixed
// API keys against `app.warp.dev`'s GraphQL endpoint; that path is a
// candidate for a future PR but adds credential-holding surface area
// this local-only PR does not need to take on.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class WarpUsageStore: @preconcurrency UsageProvider {

    public let id: String = "warp"
    public let displayName: String = "Warp"
    public let featureFlagKey: String = "features.warp.enabled"

    // MARK: - Observable state

    @Published public private(set) var snapshot: WarpUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var tccState: TCCState = .granted
    /// True when the sqlite opened but neither of the known tables
    /// (`ai_queries` / `agent_conversations`) is present — either
    /// Warp AI has never been used on this Mac, or the schema drifted
    /// to a name we do not recognise.
    @Published public private(set) var tablesMissing: Bool = false
    /// True when the table was present but its column shape did not
    /// match any known form. Surfaces an "update ClaudeUsageBar" tile
    /// so the reader does not fabricate a number against an unknown
    /// schema.
    @Published public private(set) var schemaUnknown: Bool = false

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let env: WarpEnvironment
    private let tccProbe: @Sendable (String) -> TCCState
    private let readSnapshot: @Sendable (String, Date) throws -> WarpReadOutcome
    private let workQueue: DispatchQueue
    private let clock: @Sendable () -> Date

    private var fetchGeneration: UInt64 = 0

    public init(
        defaults: UserDefaults = .standard,
        environment: WarpEnvironment = .current(),
        tccProbe: @escaping @Sendable (String) -> TCCState = { TCCProbe.probe(path: $0) },
        readSnapshot: @escaping @Sendable (String, Date) throws -> WarpReadOutcome = {
            try WarpUsageFetcher.read(from: $0, now: $1)
        },
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.claude.usagebar.warp.parse",
            qos: .utility
        ),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.env = environment
        self.tccProbe = tccProbe
        self.readSnapshot = readSnapshot
        self.workQueue = workQueue
        self.clock = clock
    }

    // MARK: - UsageProvider

    public var isEnabled: Bool { defaults.bool(forKey: featureFlagKey) }
    public var isConfigured: Bool { isEnabled }
    public var lastUpdated: Date? { lastUpdatedAt }
    public var errorMessage: String? { lastError }

    public var tiles: [UsageTile] {
        guard isEnabled else { return [] }

        if schemaUnknown {
            return [UsageTile(
                id: "warp-schema-unknown",
                title: displayName,
                kind: .text(
                    status: "Warp database format changed",
                    subtitle: "The Warp database has a table this ClaudeUsageBar build does not recognise. Update ClaudeUsageBar to include the new format."
                )
            )]
        }

        switch tccState {
        case .denied:
            let copy = LocalProviderAccessGuide.copy(for: .denied, appName: displayName)
            return [UsageTile(
                id: "warp-needs-access",
                title: copy.title,
                kind: .needsAccess(
                    path: "~/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite",
                    guidance: copy.guidance
                )
            )]
        case .pathMissing:
            return [UsageTile(
                id: "warp-not-installed",
                title: displayName,
                kind: .text(
                    status: "No Warp install found",
                    subtitle: "Install Warp and send at least one AI query. If Warp is not on this Mac, disable this provider in Settings."
                )
            )]
        case .granted:
            break
        }

        if tablesMissing {
            return [UsageTile(
                id: "warp-signin-needed",
                title: displayName,
                kind: .text(
                    status: "No Warp AI usage recorded",
                    subtitle: "Warp is installed but has not recorded any AI queries. Send one query in Warp, then click Refresh."
                )
            )]
        }

        guard let snap = snapshot else {
            return [UsageTile(
                id: "warp-loading",
                title: displayName,
                kind: .text(status: "Loading…", subtitle: nil)
            )]
        }

        var out: [UsageTile] = []

        if let today = snap.requestsToday {
            let sourceNote: String? = snap.sourceTable.map { "from \($0)" }
            out.append(UsageTile(
                id: "warp-requests-today",
                title: "AI requests today",
                kind: .counter(
                    used: max(0, today),
                    limit: nil,
                    resetsAt: nil
                )
            ))
            if let sourceNote = sourceNote {
                out.append(UsageTile(
                    id: "warp-source",
                    title: displayName,
                    kind: .text(
                        status: sourceNote,
                        subtitle: "Local Warp database — nothing leaves your Mac."
                    )
                ))
            }
        } else if let total = snap.requestsAllTime {
            // Fallback path — table exists but no known timestamp
            // column. Show the all-time count with an explicit
            // "no today-window available" label so the user is not
            // misled into thinking this is today's number.
            out.append(UsageTile(
                id: "warp-requests-alltime",
                title: "AI requests (all time)",
                kind: .counter(
                    used: max(0, total),
                    limit: nil,
                    resetsAt: nil
                )
            ))
            out.append(UsageTile(
                id: "warp-partial-schema",
                title: displayName,
                kind: .text(
                    status: "Today-window unavailable",
                    subtitle: "Warp's database has no timestamp column that this ClaudeUsageBar build knows about. Update ClaudeUsageBar for per-day counts."
                )
            ))
        }

        return out
    }

    public func fetch() {
        fetchGeneration &+= 1
        guard isEnabled else {
            // chk1 audit Bug #7: the disable branch must clear
            // every stale published field. Previously
            // `lastError`, `lastUpdatedAt`, and `tccState`
            // persisted from the last enabled session.
            resetToDisabledBaseline()
            return
        }
        let launchGeneration = fetchGeneration

        guard let path = WarpPathResolver.resolveDbPath(env) else {
            // No candidate exists via fileExists — but fileExists
            // returns false for BOTH "genuinely missing" and "TCC
            // denied at the parent". Codex R1 P1: probe EVERY
            // candidate path's parent directory (via TCCProbe which
            // cross-checks the containing directory) so a Group
            // Container that we can't see through TCC surfaces
            // .denied, not .pathMissing.
            var seenDenied = false
            for candidate in env.candidateDbPaths {
                let state = tccProbe(candidate)
                if state == .denied {
                    seenDenied = true
                    break
                }
            }
            self.tccState = seenDenied ? .denied : .pathMissing
            // chk1 audit Bug #9: also clear lastUpdatedAt so a
            // stale "Last updated 3h ago" caption does not sit
            // beside a needs-access / not-installed tile.
            self.applyNonGrantedReset()
            return
        }
        let probed = tccProbe(path)
        self.tccState = probed
        if probed != .granted {
            // chk1 audit Bug #8: also clear lastUpdatedAt on
            // TCC-denied. Same rationale as Bug #9 above.
            self.applyNonGrantedReset()
            return
        }

        let read = self.readSnapshot
        let now = clock()
        workQueue.async { [weak self] in
            let outcome: WorkOutcome
            do {
                let readOutcome = try read(path, now)
                switch readOutcome {
                case .success(let snap):
                    outcome = .success(snap)
                case .tablesMissing:
                    outcome = .tablesMissing
                case .schemaUnknown:
                    outcome = .schemaUnknown
                }
            } catch SQLiteReaderError.notFound {
                outcome = .pathMissing
            } catch SQLiteReaderError.openFailed {
                outcome = .denied
            } catch SQLiteReaderError.notADatabase, SQLiteReaderError.encrypted {
                outcome = .schemaUnknown
            } catch SQLiteReaderError.busy {
                outcome = .transientBusy
            } catch {
                outcome = .otherError("\(error)")
            }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isEnabled else { return }
                guard launchGeneration == self.fetchGeneration else { return }
                self.applyOutcome(outcome)
            }
        }
    }

    public func clear() {
        resetToDisabledBaseline()
        fetchGeneration &+= 1
    }

    /// Reset every published field to the "disabled" baseline —
    /// used by both the disable branch of `fetch()` and by
    /// `clear()`. chk1 audit Bug #7: keep the two sites in
    /// lockstep so state hygiene can't drift between them.
    private func resetToDisabledBaseline() {
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
        tccState = .granted
        tablesMissing = false
        schemaUnknown = false
    }

    /// Reset published state after a TCC deny / pathMissing outcome
    /// while KEEPING the just-set `tccState` intact. chk1 audit
    /// Bugs #8, #9: previously `lastUpdatedAt` was retained on
    /// these branches, leaving a stale "Last updated" caption.
    private func applyNonGrantedReset() {
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
        tablesMissing = false
        schemaUnknown = false
    }

    private enum WorkOutcome: Sendable {
        case success(WarpUsageSnapshot)
        case tablesMissing
        case schemaUnknown
        case pathMissing
        case denied
        case transientBusy
        case otherError(String)
    }

    private func applyOutcome(_ outcome: WorkOutcome) {
        switch outcome {
        case .success(let snap):
            self.snapshot = snap
            self.tablesMissing = false
            self.schemaUnknown = false
            self.lastUpdatedAt = clock()
            self.lastError = nil
            Log.info("Warp usage parsed", .count(snap.requestsToday ?? snap.requestsAllTime ?? 0))
        case .tablesMissing:
            self.snapshot = nil
            self.tablesMissing = true
            self.schemaUnknown = false
            self.lastUpdatedAt = clock()
            self.lastError = nil
        case .schemaUnknown:
            self.snapshot = nil
            self.tablesMissing = false
            self.schemaUnknown = true
            self.lastError = nil
        case .pathMissing:
            // Codex R3 P2 on chk1 audit Bug #9: a read-time
            // .notFound transition (file disappeared between the
            // probe and the sqlite open) previously left
            // lastUpdatedAt intact — the same stale-timestamp
            // regression Bug #9 fixed for the pre-read branch,
            // resurfacing here. Route through the shared reset.
            self.tccState = .pathMissing
            self.applyNonGrantedReset()
        case .denied:
            // Codex R3 P2 on chk1 audit Bug #8: same class of
            // regression — a read-time .openFailed transition
            // (TCC denial revealed by sqlite_open_v2 after the
            // parent-dir probe passed) previously left
            // lastUpdatedAt intact.
            self.tccState = .denied
            self.applyNonGrantedReset()
        case .transientBusy:
            self.lastError = "Warp is holding the database — retry on next tick."
        case .otherError(let msg):
            self.lastError = "Warp read failed: \(msg)"
        }
    }
}
