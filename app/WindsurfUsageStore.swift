// PR 11-BE — Windsurf UsageProvider store (feature-flag off).
//
// Third local-file reader. Reads Windsurf's own state.vscdb for the
// `windsurf.settings.cachedPlanInfo` blob and renders per-window
// quota tiles. Nothing leaves the machine.
//
// Concurrency model mirrors ClaudeCodeUsageStore / ClineUsageStore:
// SQLite read + JSON parse run on a serial background queue; results
// apply on the main actor via `Task { @MainActor [weak self] in ... }`;
// `fetchGeneration` invalidates in-flight completions on clear(),
// disable, or TCC transition.
//
// Feature posture: `features.windsurf.enabled` defaults false. Nothing
// registers a WindsurfUsageStore into `AppDelegate.providers` yet —
// that lands in PR 11-UI along with `ProviderCopy.help(for: "windsurf")`.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class WindsurfUsageStore: @preconcurrency UsageProvider {

    public let id: String = "windsurf"
    public let displayName: String = "Windsurf"
    public let featureFlagKey: String = "features.windsurf.enabled"

    // MARK: - Observable state

    @Published public private(set) var usage: WindsurfPlanUsage?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var tccState: TCCState = .granted
    /// True when the SQLite reader reported `.schemaMismatch` — the tile
    /// tells the user to update the app rather than showing stale numbers
    /// against a schema they no longer recognise. Modelled per the plan's
    /// "ship a schema-version sentinel; refuse to render on mismatch"
    /// directive (applied to Windsurf out of prudence; Windsurf's plan
    /// info has evolved twice already).
    @Published public private(set) var schemaMismatch: Bool = false
    /// True after a fetch completed successfully but Windsurf had no
    /// `cachedPlanInfo` row (fresh install, user has not signed in).
    /// Codex round-3 finding #2: differentiated from the initial
    /// "loading" state so the user gets an actionable "sign in"
    /// tile rather than "Loading…" forever.
    @Published public private(set) var rowMissing: Bool = false

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let resolvePath: @Sendable () -> String?
    private let tccProbe: @Sendable (String) -> TCCState
    /// Reader hook — parses the file bytes on the background queue and
    /// returns a discriminated outcome: success, row-missing, or
    /// malformed-payload. Codex round-1 finding #1: differentiate
    /// missing vs corrupt so the tile can render distinct states.
    private let readUsage: @Sendable (String) throws -> WindsurfReadOutcome
    private let workQueue: DispatchQueue
    private let clock: @Sendable () -> Date

    private var fetchGeneration: UInt64 = 0

    public init(
        defaults: UserDefaults = .standard,
        resolvePath: @escaping @Sendable () -> String? = {
            WindsurfPathResolver.stateDbPath(.current())
        },
        tccProbe: @escaping @Sendable (String) -> TCCState = { TCCProbe.probe(path: $0) },
        readUsage: @escaping @Sendable (String) throws -> WindsurfReadOutcome = {
            try WindsurfUsageFetcher.read(from: $0)
        },
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.claude.usagebar.windsurf.parse",
            qos: .utility
        ),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.resolvePath = resolvePath
        self.tccProbe = tccProbe
        self.readUsage = readUsage
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

        if schemaMismatch {
            return [UsageTile(
                id: "windsurf-schema-mismatch",
                title: displayName,
                kind: .text(
                    status: "Windsurf plan-info format changed",
                    subtitle: "The plan-info format on disk changed and this ClaudeUsageBar build cannot read it safely. Update ClaudeUsageBar to include the new format."
                )
            )]
        }

        switch tccState {
        case .denied:
            let copy = LocalProviderAccessGuide.copy(for: .denied, appName: displayName)
            return [UsageTile(
                id: "windsurf-needs-access",
                title: copy.title,
                kind: .needsAccess(
                    path: "~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb",
                    guidance: copy.guidance
                )
            )]
        case .pathMissing:
            return [UsageTile(
                id: "windsurf-not-installed",
                title: displayName,
                kind: .text(
                    status: "No Windsurf install found",
                    subtitle: "If Windsurf is installed, sign in and open a Cascade chat once. If Windsurf is not on this Mac, disable this provider in Settings."
                )
            )]
        case .granted:
            break
        }

        // Codex round-3 finding #2: distinguish "loading, no fetch
        // completed yet" from "fetch completed, row absent" (fresh
        // install with no sign-in). The former is transient; the
        // latter is a durable state and needs an actionable tile.
        if usage == nil && rowMissing {
            return [UsageTile(
                id: "windsurf-signin-needed",
                title: displayName,
                kind: .text(
                    status: "No Windsurf session",
                    subtitle: "Sign in to Windsurf and open a Cascade chat once, then click Refresh."
                )
            )]
        }
        guard let usage = usage else {
            return [UsageTile(
                id: "windsurf-loading",
                title: displayName,
                kind: .text(status: "Loading…", subtitle: nil)
            )]
        }

        if usage.windows.isEmpty {
            return [UsageTile(
                id: "windsurf-no-quota",
                title: displayName,
                kind: .text(
                    status: "No quota data found",
                    subtitle: "Windsurf's plan info exists but has no quota fields. Sign in to Windsurf and open a Cascade chat, then click Refresh."
                )
            )]
        }

        var out: [UsageTile] = []
        // Plan name tile — informational only. Only shown when the plan
        // has a name; keeps the popover quiet on older Windsurf builds
        // that omit `planName`.
        if let name = usage.planName, !name.isEmpty {
            out.append(UsageTile(
                id: "windsurf-plan",
                title: displayName,
                kind: .text(status: name, subtitle: nil)
            ))
        }
        // One bar tile per window.
        for w in usage.windows {
            out.append(UsageTile(
                id: "windsurf-\(w.kind.rawValue)",
                title: w.displayLabel,
                kind: .bar(
                    fraction: w.fractionUsed,
                    resetsAt: w.resetsAt,
                    badge: nil
                )
            ))
        }
        return out
    }

    public func fetch() {
        fetchGeneration &+= 1
        guard isEnabled else {
            usage = nil
            schemaMismatch = false
            rowMissing = false
            return
        }
        let launchGeneration = fetchGeneration

        guard let path = resolvePath() else {
            lastError = "Could not resolve Windsurf data path."
            return
        }

        let probed = tccProbe(path)
        self.tccState = probed
        if probed != .granted {
            self.usage = nil
            self.lastError = nil
            self.schemaMismatch = false
            self.rowMissing = false
            return
        }

        let read = self.readUsage
        workQueue.async { [weak self] in
            let outcome: FetchOutcome
            do {
                let readOutcome = try read(path)
                switch readOutcome {
                case .success(let usage):
                    outcome = .success(usage)
                case .rowMissing:
                    outcome = .rowMissing
                case .malformedPayload:
                    // Codex round-1 finding #1: a payload that exists
                    // but does not parse is a schema-mismatch signal,
                    // NOT "no data yet". Surfaces the update-app tile.
                    outcome = .schemaMismatch
                }
            } catch SQLiteReaderError.notFound {
                outcome = .pathMissing
            } catch SQLiteReaderError.openFailed {
                outcome = .denied
            } catch SQLiteReaderError.notADatabase, SQLiteReaderError.encrypted {
                outcome = .schemaMismatch
            } catch SQLiteReaderError.schemaMismatch {
                outcome = .schemaMismatch
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
        usage = nil
        lastUpdatedAt = nil
        lastError = nil
        schemaMismatch = false
        rowMissing = false
        fetchGeneration &+= 1
    }

    // MARK: - Outcome application

    /// Internal outcome enum kept private so the store's public surface
    /// only exposes @Published state. Every SQLiteReaderError variant
    /// projects to exactly one outcome; the apply hop writes the
    /// matching state and lets `tiles` compute the render.
    private enum FetchOutcome: Sendable {
        case success(WindsurfPlanUsage?)
        case rowMissing
        case pathMissing
        case denied
        case schemaMismatch
        case transientBusy
        case otherError(String)
    }

    private func applyOutcome(_ outcome: FetchOutcome) {
        switch outcome {
        case .success(let usage):
            self.usage = usage
            self.lastUpdatedAt = clock()
            self.lastError = nil
            self.schemaMismatch = false
            self.rowMissing = false
            Log.info("Windsurf plan-info parsed", .count(usage?.windows.count ?? 0))
        case .rowMissing:
            // Fresh install / not signed in. Distinct from "still
            // loading" so the tile can show an actionable prompt.
            self.usage = nil
            self.rowMissing = true
            self.lastUpdatedAt = clock()
            self.lastError = nil
            self.schemaMismatch = false
        case .pathMissing:
            self.tccState = .pathMissing
            self.usage = nil
            self.rowMissing = false
            self.lastError = nil
            self.schemaMismatch = false
        case .denied:
            self.tccState = .denied
            self.usage = nil
            self.rowMissing = false
            self.lastError = nil
            self.schemaMismatch = false
        case .schemaMismatch:
            self.schemaMismatch = true
            self.usage = nil
            self.rowMissing = false
            self.lastError = nil
        case .transientBusy:
            // Editor holding the lock. Do not clear existing usage; next
            // tick will retry.
            self.lastError = "Windsurf editor is holding the database — retry on next tick."
        case .otherError(let msg):
            self.lastError = "Windsurf read failed: \(msg)"
            self.schemaMismatch = false
        }
    }
}
