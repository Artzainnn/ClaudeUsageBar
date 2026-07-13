// PR 12-BE — JetBrains AI Assistant UsageProvider store (feature-flag off).
//
// Fourth local-file provider. Enumerates every JetBrains IDE (and
// Android Studio) that has an AIAssistantQuotaManager2.xml under
// ~/Library/Application Support/JetBrains (or Google), picks the
// most-recently-written one, and renders quota + refill tiles.
//
// DMCA constraint: this store, its fetcher, and every code path they
// touch NEVER contact api.jetbrains.ai or grazie.aws.intellij.net.
// Verified by the CI static-grep guard (see Non-breaking guarantee in
// the PR body).
//
// Feature posture: `features.jetbrains.enabled` defaults false. PR 12-UI
// registers a JetBrainsUsageStore into `AppDelegate.providers` alongside
// the Windsurf / Cursor / Warp providers, and adds
// `ProviderCopy.help(for: "jetbrains")` + `ProviderCopy.disclosure(for: "jetbrains")`.
// The store remains inert until the feature flag is flipped on.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class JetBrainsUsageStore: @preconcurrency UsageProvider {

    public let id: String = "jetbrains"
    public let displayName: String = "JetBrains AI"
    public let featureFlagKey: String = "features.jetbrains.enabled"

    // MARK: - Observable state

    @Published public private(set) var snapshot: JetBrainsQuotaSnapshot?
    /// Which IDE the current snapshot belongs to. Shown in the plan
    /// tile so a user with multiple JetBrains IDEs sees which one they
    /// are looking at.
    @Published public private(set) var activeInstall: JetBrainsIDEInstall?
    /// Every IDE that has a candidate quota file — used by the popover
    /// to show "N of M IDEs read" when the user has more than one.
    @Published public private(set) var detectedInstalls: [JetBrainsIDEInstall] = []
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var tccState: TCCState = .granted
    /// True after a fetch parsed the XML but found no
    /// `<component name="AIAssistantQuotaManager2">` block — the file
    /// exists (usually because AI Assistant was installed once) but no
    /// quota has been recorded yet.
    @Published public private(set) var componentMissing: Bool = false
    /// True after a fetch found the component but its JSON payload
    /// refused to parse — surfaces an "update ClaudeUsageBar" prompt
    /// because JetBrains's persisted-state format has evolved before.
    @Published public private(set) var schemaMismatch: Bool = false

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let env: JetBrainsEnvironment
    private let tccProbe: @Sendable (String) -> TCCState
    private let readXML: @Sendable (String) throws -> JetBrainsReadOutcome
    private let workQueue: DispatchQueue
    private let clock: @Sendable () -> Date

    private var fetchGeneration: UInt64 = 0

    public init(
        defaults: UserDefaults = .standard,
        environment: JetBrainsEnvironment = .current(),
        tccProbe: @escaping @Sendable (String) -> TCCState = { TCCProbe.probe(path: $0) },
        readXML: @escaping @Sendable (String) throws -> JetBrainsReadOutcome = {
            try JetBrainsUsageFetcher.read(from: $0)
        },
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.claude.usagebar.jetbrains.parse",
            qos: .utility
        ),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.env = environment
        self.tccProbe = tccProbe
        self.readXML = readXML
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
                id: "jetbrains-schema-mismatch",
                title: displayName,
                kind: .text(
                    status: "JetBrains quota format changed",
                    subtitle: "The quota format on disk changed and this ClaudeUsageBar build cannot read it safely. Update ClaudeUsageBar to include the new format."
                )
            )]
        }

        switch tccState {
        case .denied:
            let copy = LocalProviderAccessGuide.copy(for: .denied, appName: displayName)
            return [UsageTile(
                id: "jetbrains-needs-access",
                title: copy.title,
                kind: .needsAccess(
                    path: "~/Library/Application Support/JetBrains (+ ~/Library/Application Support/Google for Android Studio)",
                    guidance: copy.guidance
                )
            )]
        case .pathMissing:
            return [UsageTile(
                id: "jetbrains-not-installed",
                title: displayName,
                kind: .text(
                    status: "No JetBrains AI Assistant data found",
                    subtitle: "Install a JetBrains IDE (or Android Studio), enable AI Assistant, and send at least one query. If you do not use JetBrains AI Assistant, disable this provider in Settings."
                )
            )]
        case .granted:
            break
        }

        if componentMissing {
            return [UsageTile(
                id: "jetbrains-signin-needed",
                title: displayName,
                kind: .text(
                    status: "AI Assistant never used on this Mac",
                    subtitle: "This IDE's quota file exists but has no AI Assistant record yet. Enable AI Assistant in your IDE and send one query, then click Refresh."
                )
            )]
        }

        guard let snap = snapshot else {
            return [UsageTile(
                id: "jetbrains-loading",
                title: displayName,
                kind: .text(status: "Loading…", subtitle: nil)
            )]
        }

        var out: [UsageTile] = []

        // Plan / IDE tile — shows the active IDE + its quota-type
        // string. Only present when we successfully identified the
        // install; test-injected fetches can leave activeInstall nil.
        if let install = activeInstall {
            let subtitle: String? = detectedInstalls.count > 1
                ? "\(detectedInstalls.count) JetBrains IDEs detected"
                : nil
            out.append(UsageTile(
                id: "jetbrains-plan",
                title: displayName,
                kind: .text(
                    status: "\(install.ide.displayName) \(install.version)",
                    subtitle: subtitle
                )
            ))
        }

        // Quota tile — bar when maximum > 0, text when the state is
        // "Unlimited" / unknown.
        if snap.maximum > 0 {
            let fraction = snap.usedFraction
            let badge = "\(Self.formatUnits(max(0.0, snap.maximum - snap.available))) / \(Self.formatUnits(snap.maximum))"
            out.append(UsageTile(
                id: "jetbrains-quota",
                title: "AI Assistant quota",
                kind: .bar(
                    fraction: fraction,
                    resetsAt: snap.refillNext,
                    badge: badge
                )
            ))
        } else {
            // No numeric ceiling — either JetBrains has classified
            // this account as unlimited or the JSON omitted the
            // maximum for a legitimate state (e.g. mid-refill).
            out.append(UsageTile(
                id: "jetbrains-quota",
                title: "AI Assistant quota",
                kind: .text(
                    status: snap.quotaType ?? "Unknown quota",
                    subtitle: nil
                )
            ))
        }

        // Refill tile — only when we have a distinct refill window and
        // a next-refill timestamp to render.
        if let next = snap.refillNext {
            let subtitle: String? = {
                if let amount = snap.refillAmount, let duration = snap.refillDuration {
                    return "\(Self.formatUnits(amount)) every \(Self.formatDuration(duration))"
                }
                return snap.refillDuration.map { "Every \(Self.formatDuration($0))" }
            }()
            out.append(UsageTile(
                id: "jetbrains-refill",
                title: "Next refill",
                kind: .text(
                    status: Self.formatDateShort(next),
                    subtitle: subtitle
                )
            ))
        }

        return out
    }

    public func fetch() {
        fetchGeneration &+= 1
        guard isEnabled else {
            // chk1 audit Bug #1: the disable branch must clear EVERY
            // stale published field — otherwise `lastError`,
            // `lastUpdatedAt`, or `tccState` from the last enabled
            // session persist and the popover shows a red banner or
            // a "Last updated: 3 hours ago" caption against an
            // empty tile set. Reset to the disabled baseline.
            resetToDisabledBaseline()
            return
        }
        let launchGeneration = fetchGeneration

        // Discovery runs on the background parse queue. chk1 audit
        // Risk #4: previously discovery ran on the main actor, doing
        // up to 30 fileExists() + 2 contentsOfDirectory() syscalls on
        // every fetch tick. Moving it into workQueue keeps the popover
        // responsive on a slow/spun-down disk.
        let env = self.env
        let tccProbeFn = self.tccProbe
        let jetbrainsVendorPath = env.jetbrainsVendorPath
        let googleVendorPath = env.googleVendorPath
        let read = self.readXML
        workQueue.async { [weak self] in
            let installs = JetBrainsPathResolver.discover(env)
            let chosen = JetBrainsPathResolver.mostRecentlyModified(installs, env: env)
            // No-install fallback needs both TCC probes so we can
            // tell "denied" from "truly not installed".
            let noInstallTccState: TCCState = {
                guard chosen == nil else { return .granted }
                let jb = tccProbeFn(jetbrainsVendorPath)
                let goog = tccProbeFn(googleVendorPath)
                if jb == .denied || goog == .denied { return .denied }
                return .pathMissing
            }()
            let probedForChosen: TCCState? = chosen.map { tccProbeFn($0.quotaFilePath) }
            // Apply the discovery + TCC probe result on the main
            // actor. If TCC is granted, proceed with the parse; if
            // not, return early with a fully-clean state (chk1
            // audit Bug #2 + #3).
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isEnabled else { return }
                guard launchGeneration == self.fetchGeneration else { return }
                self.detectedInstalls = installs
                guard let chosen = chosen else {
                    // No detected IDE.
                    self.tccState = noInstallTccState
                    self.applyNonGrantedReset()
                    return
                }
                let probed = probedForChosen ?? .granted
                self.tccState = probed
                if probed != .granted {
                    self.applyNonGrantedReset()
                    return
                }
                // Kick off the actual XML read on workQueue.
                self.enqueueRead(path: chosen.quotaFilePath, install: chosen, launchGeneration: launchGeneration, read: read)
            }
        }
    }

    /// Reset every published field to the "disabled" baseline —
    /// used by both the disable branch of `fetch()` and by
    /// `clear()`. chk1 audit Bug #1/#2/#3: keep the two sites in
    /// lockstep so state hygiene can't drift between them.
    private func resetToDisabledBaseline() {
        snapshot = nil
        activeInstall = nil
        detectedInstalls = []
        lastUpdatedAt = nil
        lastError = nil
        tccState = .granted
        componentMissing = false
        schemaMismatch = false
    }

    /// Reset published state after a TCC deny / pathMissing outcome
    /// while KEEPING the just-set `tccState` intact. chk1 audit
    /// Bugs #2, #3: previously `detectedInstalls` and `lastUpdatedAt`
    /// were retained on these branches, leaving stale UI captions
    /// alongside the needs-access tile.
    private func applyNonGrantedReset() {
        snapshot = nil
        activeInstall = nil
        detectedInstalls = []
        lastUpdatedAt = nil
        lastError = nil
        componentMissing = false
        schemaMismatch = false
    }

    /// Second phase of `fetch()`: run the XML parse on `workQueue`
    /// and hop the result back to the main actor for state apply.
    /// Extracted so the discovery-off-main-actor refactor keeps
    /// the completion path readable.
    private func enqueueRead(
        path: String,
        install: JetBrainsIDEInstall,
        launchGeneration: UInt64,
        read: @escaping @Sendable (String) throws -> JetBrainsReadOutcome
    ) {
        workQueue.async { [weak self] in
            let outcome: WorkOutcome
            do {
                // chk1 audit Bug #4: rename the read-result local
                // so it does NOT shadow the `read` closure parameter
                // — the old `let read = try read(path)` was legal
                // but the reused name was a code smell.
                let readOutcome = try read(path)
                switch readOutcome {
                case .success(let snap):
                    outcome = .success(snap)
                case .componentMissing:
                    outcome = .componentMissing
                case .malformedPayload:
                    outcome = .schemaMismatch
                }
            } catch {
                outcome = .otherError("\(error)")
            }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isEnabled else { return }
                guard launchGeneration == self.fetchGeneration else { return }
                self.applyOutcome(outcome, install: install)
            }
        }
    }

    public func clear() {
        resetToDisabledBaseline()
        fetchGeneration &+= 1
    }

    private enum WorkOutcome: Sendable {
        case success(JetBrainsQuotaSnapshot)
        case componentMissing
        case schemaMismatch
        case otherError(String)
    }

    private func applyOutcome(_ outcome: WorkOutcome, install: JetBrainsIDEInstall) {
        switch outcome {
        case .success(let snap):
            self.snapshot = snap
            self.activeInstall = install
            self.componentMissing = false
            self.schemaMismatch = false
            self.lastUpdatedAt = clock()
            self.lastError = nil
            // Codex R2 P2: clamp before Int() — a hostile finite
            // maximum like 1e300 would trap in the Int initialiser.
            // Use Int(exactly:) with the finite guard so a hostile
            // persisted-state cannot crash the log call.
            let loggedMax: Int
            if snap.maximum.isFinite, let clamped = Int(exactly: snap.maximum.rounded()) {
                loggedMax = clamped
            } else {
                loggedMax = Int.max
            }
            Log.info("JetBrains quota parsed", .count(loggedMax))
        case .componentMissing:
            self.snapshot = nil
            self.activeInstall = install
            self.componentMissing = true
            self.schemaMismatch = false
            self.lastUpdatedAt = clock()
            self.lastError = nil
        case .schemaMismatch:
            self.schemaMismatch = true
            self.snapshot = nil
            self.activeInstall = install
            self.componentMissing = false
            self.lastError = nil
        case .otherError(let msg):
            self.lastError = "JetBrains read failed: \(msg)"
        }
    }

    // MARK: - Formatting helpers

    /// Format a token / unit count. Matches the ClaudeCodeUsageStore
    /// style so numbers look consistent across providers. Clamps to
    /// Int for the shared formatter.
    ///
    /// Codex R3 P2: `Double(Int.max)` rounds UP to `2^63` (a value one
    /// past Int.max), so a naive `Int(min(raw, Double(Int.max)))`
    /// STILL traps on `1e300`. Use `Int(exactly: raw.rounded())`
    /// with a saturating fallback so hostile finite doubles land on
    /// Int.max cleanly.
    public nonisolated static func formatUnits(_ raw: Double) -> String {
        guard raw.isFinite else { return "0" }
        let nonNeg = max(0.0, raw)
        // Try exact Int; if that overflows (e.g. 1e300), saturate to
        // Int.max. Int(exactly:) returns nil rather than trapping.
        let asInt: Int
        if let exact = Int(exactly: nonNeg.rounded()) {
            asInt = exact
        } else {
            asInt = Int.max
        }
        return ClaudeCodeUsageStore.formatTokens(asInt)
    }

    /// Turn an ISO-8601 duration like "PT720H" or "P30D" into a short
    /// human string ("30 days", "12 hours", "1 day, 12 hours").
    /// Anything unrecognised falls through as-is.
    ///
    /// chk1 audit Bug #6: previously mixed forms like `P1DT12H`
    /// rendered as `"1 day"` — the trailing 12 hours were silently
    /// dropped. This version concatenates every nonzero component
    /// so mixed durations retain their precision.
    public nonisolated static func formatDuration(_ raw: String) -> String {
        // Strip the leading "P" (period) marker.
        var s = raw
        if s.hasPrefix("P") { s.removeFirst() }
        // Split date and time components on "T".
        var days = 0
        var hours = 0
        var minutes = 0
        let parts = s.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        let datePart = parts.first.map(String.init) ?? ""
        let timePart = parts.count > 1 ? String(parts[1]) : ""
        // Consume "<n>D" from datePart. Anything else (weeks, months)
        // ignored — JetBrains has only been observed to emit hours.
        if let dIdx = datePart.firstIndex(of: "D") {
            let n = Int(String(datePart[..<dIdx])) ?? 0
            days = n
        }
        // Time part components: "<n>H", "<n>M".
        var buf = ""
        for ch in timePart {
            if ch.isNumber { buf.append(ch); continue }
            let n = Int(buf) ?? 0
            buf.removeAll(keepingCapacity: true)
            switch ch {
            case "H": hours = n
            case "M": minutes = n
            default: break
            }
        }
        // Special case: `PT<24n>H` with no D component — render as
        // a whole-day count if the hours divide evenly. Matches
        // JetBrains's dashboard which shows "30 days" for PT720H.
        if days == 0 && hours >= 24 && hours % 24 == 0 && minutes == 0 {
            let d = hours / 24
            return "\(d) day\(d == 1 ? "" : "s")"
        }
        // General mixed form — join every nonzero component with
        // commas. If ALL three are zero the input is unrecognised
        // and we fall through to `raw`.
        var pieces: [String] = []
        if days > 0 { pieces.append("\(days) day\(days == 1 ? "" : "s")") }
        if hours > 0 { pieces.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { pieces.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if pieces.isEmpty { return raw }
        return pieces.joined(separator: ", ")
    }

    /// Short absolute date label ("d MMM UTC"). Codex R1 P3 finding:
    /// JetBrains publishes refill instants as UTC (e.g.
    /// `2026-08-01T00:00:00Z`). Formatting in the user's local time
    /// zone would render `31 Jul` in Americas timezones for what
    /// JetBrains's own dashboard shows as `1 Aug`. Render in UTC and
    /// suffix with the label so the user is not confused.
    public nonisolated static func formatDateShort(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        f.timeZone = TimeZone(identifier: "UTC") ?? .current
        return "\(f.string(from: date)) UTC"
    }
}
