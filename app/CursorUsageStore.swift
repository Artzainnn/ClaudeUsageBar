// PR 11-BE — Cursor UsageProvider store (feature-flag off).
//
// Cursor hybrid provider: reads Cursor's own state.vscdb for the
// WorkOS session token, then fetches usage from cursor.com. Refresh
// flow via api2.cursor.sh is invoked ONLY on 401 — never proactively,
// so a valid session stays valid.
//
// State machine (per fetch tick):
//
//   1. Read credentials from state.vscdb.
//      Missing / SQLITE_CANTOPEN → .needsAccess or .pathMissing.
//   2. GET /api/usage-summary with the accessToken cookie.
//      2xx → parseUsageSummary → 3. Aggregation.
//      401 → REFRESH sub-flow (once).
//      Other → error tile.
//   3. POST /get-aggregated-usage-events for the current billing cycle
//      (from step 2's response). 2xx → merge; other → summary-only.
//   4. REFRESH: POST /oauth/token. Success → update state.vscdb by the
//      OS-native path? NO — Cursor itself writes back to state.vscdb;
//      a third-party writing there would race Cursor's own writes.
//      Instead we keep the new accessToken IN-MEMORY only for this
//      session; a subsequent Cursor launch will write a fresh one to
//      the DB and we'll pick it up naturally. shouldLogout → surface
//      "sign in again in Cursor".
//
// Feature posture: `features.cursor.enabled` defaults false. Nothing
// registers a CursorUsageStore into `AppDelegate.providers` yet —
// that lands in PR 11-UI along with `ProviderCopy.help(for: "cursor")`.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class CursorUsageStore: @preconcurrency UsageProvider {

    public let id: String = "cursor"
    public let displayName: String = "Cursor"
    public let featureFlagKey: String = "features.cursor.enabled"

    // MARK: - Observable state

    @Published public private(set) var snapshot: CursorSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var tccState: TCCState = .granted
    /// True when the refresh token is also invalid and the user must
    /// re-authenticate in Cursor itself. The tile becomes an
    /// informational card until Cursor writes a new token to
    /// state.vscdb (the next Cursor launch after a successful login).
    @Published public private(set) var sessionExpired: Bool = false

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let resolvePath: @Sendable () -> String?
    private let tccProbe: @Sendable (String) -> TCCState
    private let readCredentials: @Sendable (String) throws -> CursorCredentials?
    private let transport: CursorTransport
    private let workQueue: DispatchQueue
    private let clock: @Sendable () -> Date

    private var fetchGeneration: UInt64 = 0

    /// In-memory override for the accessToken after a successful
    /// refresh — Cursor itself writes back to state.vscdb; a
    /// third-party writing there would race Cursor's own writes.
    ///
    /// Codex round-1 finding #5: we must remember the DB accessToken
    /// value that was current WHEN the refresh happened. If the DB
    /// later produces a DIFFERENT accessToken (a real re-login, a
    /// second account, Cursor's own refresh finally committing), the
    /// in-memory override is stale and must be dropped so the DB
    /// value takes precedence.
    private var refreshedAccessToken: String?
    private var refreshedFromDbToken: String?
    /// The DB accessToken value seen when `sessionExpired` was set to
    /// true. Codex round-1 finding #6: on the next fetch, if the DB
    /// value differs, the user has re-signed-in and we clear the
    /// sticky flag. Prevents a 429/500/network error from leaving the
    /// user stuck on "Sign in again" after they already did.
    private var sessionExpiredForDbToken: String?

    public init(
        defaults: UserDefaults = .standard,
        resolvePath: @escaping @Sendable () -> String? = {
            CursorPathResolver.stateDbPath(.current())
        },
        tccProbe: @escaping @Sendable (String) -> TCCState = { TCCProbe.probe(path: $0) },
        readCredentials: @escaping @Sendable (String) throws -> CursorCredentials? = {
            try CursorCredentialReader.read(from: $0)
        },
        transport: CursorTransport = URLSessionCursorTransport(),
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.claude.usagebar.cursor.parse",
            qos: .utility
        ),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.resolvePath = resolvePath
        self.tccProbe = tccProbe
        self.readCredentials = readCredentials
        self.transport = transport
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

        if sessionExpired {
            return [UsageTile(
                id: "cursor-session-expired",
                title: displayName,
                kind: .text(
                    status: "Sign in again in Cursor",
                    subtitle: "Your Cursor session expired. Open Cursor, sign in, then click Refresh here."
                )
            )]
        }

        switch tccState {
        case .denied:
            let copy = LocalProviderAccessGuide.copy(for: .denied, appName: displayName)
            return [UsageTile(
                id: "cursor-needs-access",
                title: copy.title,
                kind: .needsAccess(
                    path: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
                    guidance: copy.guidance
                )
            )]
        case .pathMissing:
            return [UsageTile(
                id: "cursor-not-installed",
                title: displayName,
                kind: .text(
                    status: "No Cursor install found",
                    subtitle: "Install Cursor and sign in once. If Cursor is not on this Mac, disable this provider in Settings."
                )
            )]
        case .granted:
            break
        }

        guard let snap = snapshot else {
            return [UsageTile(
                id: "cursor-loading",
                title: displayName,
                kind: .text(status: "Loading…", subtitle: nil)
            )]
        }

        var out: [UsageTile] = []

        // Plan tile — membershipType is Cursor's own string ("pro",
        // "free", "enterprise", …). Displayed capitalised.
        out.append(UsageTile(
            id: "cursor-plan",
            title: "Cursor plan",
            kind: .text(
                status: Self.friendlyPlanLabel(snap.membershipType),
                subtitle: snap.isUnlimited ? "Unlimited" : nil
            )
        ))

        // MTD usage tile. planLimitCents=0 renders as a fraction of 0 →
        // hide the bar; use a counter with the used cents as major
        // units. When limit>0, render a bar.
        if snap.planLimitCents > 0 {
            let fraction = min(1.0, max(0.0, Double(snap.planUsedCents) / Double(snap.planLimitCents)))
            out.append(UsageTile(
                id: "cursor-usage-mtd",
                title: "Plan usage",
                kind: .bar(
                    fraction: fraction,
                    resetsAt: snap.billingCycleEnd,
                    badge: Self.formatDollarsFromCents(snap.planUsedCents)
                )
            ))
        } else if snap.planUsedCents > 0 {
            out.append(UsageTile(
                id: "cursor-usage-mtd",
                title: "Plan usage",
                kind: .text(
                    status: Self.formatDollarsFromCents(snap.planUsedCents),
                    subtitle: snap.billingCycleEnd.map { "Resets \(Self.humanBillingReset($0))" }
                )
            ))
        }

        // On-demand tile — only when the plan actually has an on-demand
        // component and it has non-zero usage.
        if snap.onDemandEnabled && snap.onDemandUsedCents > 0 {
            let subtitle: String?
            if let limit = snap.onDemandLimitCents, limit > 0 {
                let remaining = snap.onDemandRemainingCents ?? 0
                subtitle = "\(Self.formatDollarsFromCents(remaining)) remaining of \(Self.formatDollarsFromCents(limit))"
            } else {
                subtitle = nil
            }
            out.append(UsageTile(
                id: "cursor-on-demand",
                title: "On-demand",
                kind: .text(
                    status: Self.formatDollarsFromCents(snap.onDemandUsedCents),
                    subtitle: subtitle
                )
            ))
        }

        // Per-model tile — top-3 by totalCents descending.
        let byModel = snap.perModel.sorted { ($0.totalCents ?? 0) > ($1.totalCents ?? 0) }
        if !byModel.isEmpty {
            let top = byModel.prefix(3)
            let lines = top.map { entry -> String in
                let cost = entry.totalCents.map { Self.formatDollarsFromCents($0) } ?? "—"
                // Codex round-2 finding #1: saturating add — a
                // hostile aggregation with Int64.max in one field
                // would wrap `&+` to Int64.min and then trip
                // `abs(Int.min)` in the formatter.
                let totalTokens = Self.saturatingAddInt64(
                    Self.saturatingAddInt64(entry.inputTokens, entry.outputTokens),
                    Self.saturatingAddInt64(entry.cacheWriteTokens, entry.cacheReadTokens)
                )
                return "\(entry.modelIntent) — \(cost) (\(Self.formatTokens(totalTokens)))"
            }
            out.append(UsageTile(
                id: "cursor-per-model",
                title: "Top models this cycle",
                kind: .text(
                    status: lines.first ?? "",
                    subtitle: lines.dropFirst().joined(separator: "\n")
                )
            ))
        }
        return out
    }

    // MARK: - Fetch state machine

    public func fetch() {
        fetchGeneration &+= 1
        guard isEnabled else {
            snapshot = nil
            sessionExpired = false
            refreshedAccessToken = nil
            refreshedFromDbToken = nil
            return
        }
        let launchGeneration = fetchGeneration

        guard let path = resolvePath() else {
            lastError = "Could not resolve Cursor data path."
            return
        }
        let probed = tccProbe(path)
        self.tccState = probed
        if probed != .granted {
            self.snapshot = nil
            self.lastError = nil
            self.sessionExpired = false
            return
        }

        let readCreds = self.readCredentials
        let inMemoryRefreshed = self.refreshedAccessToken
        let refreshedFromDbToken = self.refreshedFromDbToken
        workQueue.async { [weak self] in
            let credOutcome: CredentialReadOutcome
            do {
                if let creds = try readCreds(path) {
                    // Codex round-1 finding #5: overlay the in-memory
                    // refreshed accessToken ONLY when the DB
                    // accessToken is still the same one we refreshed
                    // from. If the DB now holds a different value,
                    // Cursor has since written a fresh token (a
                    // re-login, or an account swap) and we must
                    // prefer the DB value.
                    let effectiveToken: String
                    let usedRefreshed = (inMemoryRefreshed != nil
                        && refreshedFromDbToken == creds.accessToken)
                    if usedRefreshed, let refreshed = inMemoryRefreshed {
                        effectiveToken = refreshed
                    } else {
                        effectiveToken = creds.accessToken
                    }
                    let effective = CursorCredentials(
                        accessToken: effectiveToken,
                        refreshToken: creds.refreshToken,
                        stripeMembershipType: creds.stripeMembershipType
                    )
                    credOutcome = .success(effective, usedRefreshed: usedRefreshed, dbAccessToken: creds.accessToken)
                } else {
                    credOutcome = .missing
                }
            } catch SQLiteReaderError.notFound {
                credOutcome = .pathMissing
            } catch SQLiteReaderError.openFailed {
                credOutcome = .denied
            } catch SQLiteReaderError.notADatabase, SQLiteReaderError.encrypted {
                credOutcome = .otherError("Cursor state.vscdb is not readable.")
            } catch SQLiteReaderError.schemaMismatch {
                credOutcome = .otherError("Cursor state.vscdb schema changed.")
            } catch SQLiteReaderError.busy {
                credOutcome = .transientBusy
            } catch {
                credOutcome = .otherError("\(error)")
            }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isEnabled else { return }
                guard launchGeneration == self.fetchGeneration else { return }
                self.applyCredentialOutcome(credOutcome, launchGeneration: launchGeneration)
            }
        }
    }

    public func clear() {
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
        sessionExpired = false
        sessionExpiredForDbToken = nil
        refreshedAccessToken = nil
        refreshedFromDbToken = nil
        fetchGeneration &+= 1
    }

    // MARK: - Credential-outcome application (main actor)

    private enum CredentialReadOutcome: Sendable {
        // usedRefreshed=true means the effective accessToken is our
        // in-memory refresh, not the DB value; dbAccessToken carries the
        // DB value regardless so a re-login can invalidate the override.
        case success(CursorCredentials, usedRefreshed: Bool, dbAccessToken: String)
        case missing                 // DB opened, but keys absent
        case pathMissing
        case denied
        case transientBusy
        case otherError(String)
    }

    private func applyCredentialOutcome(_ outcome: CredentialReadOutcome, launchGeneration: UInt64) {
        switch outcome {
        case .success(let creds, let usedRefreshed, let dbAccessToken):
            // Codex round-1 finding #5: if the DB accessToken has
            // changed since our last refresh, drop the in-memory
            // override so the fresh DB value takes precedence.
            if !usedRefreshed && refreshedAccessToken != nil {
                refreshedAccessToken = nil
                refreshedFromDbToken = nil
            }
            // Codex round-1 finding #6: clear the sticky
            // sessionExpired flag if the DB token has changed since
            // it was set (user has re-signed-in). Prevents a
            // 429/500/network error on a fresh sign-in from leaving
            // the user staring at "Sign in again" when they already
            // did.
            if sessionExpired && sessionExpiredForDbToken != dbAccessToken {
                sessionExpired = false
                sessionExpiredForDbToken = nil
            }
            // Codex round-2 finding #2: if sessionExpired is still
            // true after the DB-token-change check above, the user
            // has NOT re-signed-in. Skip the HTTP roundtrip
            // entirely — otherwise every 60-second timer tick sends
            // a known-expired refresh token to Cursor. Sign-in is
            // detected on the next fetch when the DB accessToken
            // finally changes.
            if sessionExpired {
                return
            }
            // Kick off the summary fetch. Aggregation is chained on
            // success. 401 triggers refresh.
            transport.fetchUsageSummary(cookieToken: creds.accessToken) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    guard self.isEnabled else { return }
                    guard launchGeneration == self.fetchGeneration else { return }
                    self.applySummaryResult(result, creds: creds, launchGeneration: launchGeneration, isRetry: false, dbAccessToken: dbAccessToken)
                }
            }
        case .missing:
            snapshot = nil
            lastError = "Cursor has no saved session — sign in to Cursor first."
        case .pathMissing:
            tccState = .pathMissing
            snapshot = nil
            lastError = nil
        case .denied:
            tccState = .denied
            snapshot = nil
            lastError = nil
        case .transientBusy:
            lastError = "Cursor is holding the database — retry on next tick."
        case .otherError(let msg):
            lastError = msg
        }
    }

    // MARK: - Summary result

    private func applySummaryResult(
        _ result: CursorTransportResult,
        creds: CursorCredentials,
        launchGeneration: UInt64,
        isRetry: Bool,
        dbAccessToken: String
    ) {
        switch result {
        case .success(let data):
            guard let summary = CursorResponseParser.parseUsageSummary(data) else {
                lastError = "Cursor usage-summary response did not decode."
                return
            }
            // Chain aggregation with the billing-cycle window from the
            // summary. If the summary omitted cycle bounds, fall back
            // to the last 30 days.
            let now = clock()
            let startMs = Int64((summary.billingCycleStart ?? now.addingTimeInterval(-30 * 86_400)).timeIntervalSince1970 * 1000.0)
            let endMs = Int64((summary.billingCycleEnd ?? now).timeIntervalSince1970 * 1000.0)
            transport.fetchAggregations(cookieToken: creds.accessToken, startDateMs: startMs, endDateMs: endMs) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    guard self.isEnabled else { return }
                    guard launchGeneration == self.fetchGeneration else { return }
                    self.applyAggregationResult(result, summary: summary, launchGeneration: launchGeneration)
                }
            }
        case .unauthorized:
            if isRetry {
                // Second consecutive 401 after a successful refresh
                // means the refreshed token is also being rejected —
                // give up and surface session-expired.
                sessionExpired = true
                sessionExpiredForDbToken = dbAccessToken
                snapshot = nil
                lastError = nil
                return
            }
            // Trigger refresh flow.
            transport.refreshAccessToken(refreshToken: creds.refreshToken) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    guard self.isEnabled else { return }
                    guard launchGeneration == self.fetchGeneration else { return }
                    self.applyRefreshResult(result, creds: creds, launchGeneration: launchGeneration, dbAccessToken: dbAccessToken)
                }
            }
        case .rateLimited(let retryAfter):
            // Slow polling — do not clear the existing snapshot; next
            // tick will retry.
            let sec = retryAfter.map { " (retry after \($0)s)" } ?? ""
            lastError = "Cursor rate-limited — waiting for next tick\(sec)."
        case .httpError(let code):
            lastError = "Cursor API error: HTTP \(code)"
        case .networkError:
            lastError = "Network error — Cursor could not be reached."
        case .sessionExpired:
            sessionExpired = true
            sessionExpiredForDbToken = dbAccessToken
            snapshot = nil
            lastError = nil
        }
    }

    // MARK: - Aggregation result

    private func applyAggregationResult(
        _ result: CursorTransportResult,
        summary: CursorSnapshot,
        launchGeneration: UInt64
    ) {
        var merged = summary
        if case .success(let data) = result {
            merged.perModel = CursorResponseParser.parseAggregations(data)
        }
        // Aggregation failure is non-fatal — we still render the
        // summary. Only overwrite snapshot with the merged value.
        self.snapshot = merged
        self.lastUpdatedAt = clock()
        self.lastError = nil
        self.sessionExpired = false
        Log.info("Cursor snapshot parsed", .count(merged.perModel.count))
    }

    // MARK: - Refresh result

    private func applyRefreshResult(
        _ result: CursorTransportResult,
        creds: CursorCredentials,
        launchGeneration: UInt64,
        dbAccessToken: String
    ) {
        switch result {
        case .success(let data):
            switch CursorResponseParser.parseRefresh(data) {
            case .success(let newAccessToken, _):
                self.refreshedAccessToken = newAccessToken
                // Remember which DB accessToken we refreshed from —
                // Codex round-1 finding #5. A future fetch whose DB
                // token differs drops the override.
                self.refreshedFromDbToken = dbAccessToken
                // Retry the summary fetch with the new cookie. isRetry
                // = true so a second 401 goes straight to
                // session-expired.
                let effective = CursorCredentials(
                    accessToken: newAccessToken,
                    refreshToken: creds.refreshToken,
                    stripeMembershipType: creds.stripeMembershipType
                )
                transport.fetchUsageSummary(cookieToken: newAccessToken) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        guard self.isEnabled else { return }
                        guard launchGeneration == self.fetchGeneration else { return }
                        self.applySummaryResult(result, creds: effective, launchGeneration: launchGeneration, isRetry: true, dbAccessToken: dbAccessToken)
                    }
                }
            case .sessionExpired:
                self.sessionExpired = true
                self.sessionExpiredForDbToken = dbAccessToken
                self.snapshot = nil
                self.lastError = nil
                self.refreshedAccessToken = nil
                self.refreshedFromDbToken = nil
            case .malformed:
                self.lastError = "Cursor refresh response did not decode."
            }
        case .unauthorized, .sessionExpired:
            self.sessionExpired = true
            self.sessionExpiredForDbToken = dbAccessToken
            self.snapshot = nil
            self.lastError = nil
            self.refreshedAccessToken = nil
            self.refreshedFromDbToken = nil
        case .rateLimited(let retryAfter):
            let sec = retryAfter.map { " (retry after \($0)s)" } ?? ""
            self.lastError = "Cursor refresh rate-limited\(sec)."
        case .httpError(let code):
            self.lastError = "Cursor refresh error: HTTP \(code)"
        case .networkError:
            self.lastError = "Network error during refresh."
        }
    }

    // MARK: - Formatting helpers

    /// Cursor's `membershipType` values seen in the wild:
    /// "free", "pro", "pro-plus", "business", "enterprise", "team".
    /// Display capitalised with any hyphens turned into spaces.
    public nonisolated static func friendlyPlanLabel(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "-", with: " ")
        return cleaned.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Format a cent value as "$X.XX". Reuses the ClaudeCode formatter
    /// via Double conversion so tests are consistent across providers.
    public nonisolated static func formatDollarsFromCents(_ cents: Int) -> String {
        return ClaudeCodeUsageStore.formatUSD(Double(cents) / 100.0)
    }

    public nonisolated static func formatTokens(_ count: Int64) -> String {
        if count < 0 { return ClaudeCodeUsageStore.formatTokens(0) }
        if count > Int64(Int.max) { return ClaudeCodeUsageStore.formatTokens(Int.max) }
        return ClaudeCodeUsageStore.formatTokens(Int(count))
    }

    /// Non-wrapping non-negative Int64 addition. Codex round-2
    /// finding #1: aggregation token counts (input+output+cache*)
    /// summed with `&+` could wrap to Int64.min on hostile inputs,
    /// producing a negative count that then crashes formatTokens via
    /// `abs(Int.min)`. Saturating math clamps the total to Int64.max.
    public nonisolated static func saturatingAddInt64(_ a: Int64, _ b: Int64) -> Int64 {
        let a_ = max(0, a)
        let b_ = max(0, b)
        let (sum, overflow) = a_.addingReportingOverflow(b_)
        return overflow ? Int64.max : sum
    }

    /// Short label for a billing-cycle reset — the Cursor tile's badge.
    public nonisolated static func humanBillingReset(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return "on \(f.string(from: date))"
    }
}
