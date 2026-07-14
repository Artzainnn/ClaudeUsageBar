// PR 9-BE — GitHub Copilot UsageProvider conformer (dark code, flag off).
//
// Seventh non-Anthropic provider. Reads GitHub's public REST billing
// endpoint for the authenticated user's Copilot AI Credit spend via a
// fine-grained PAT with the `Plan (Read)` permission. See CopilotUsageFetcher
// for the full deferred-scope notes.
//
// Feature posture: features.copilot.enabled defaults false. Nothing registers
// a store into the live registry yet (the tile + Settings paste sheet land
// in PR 9-UI).
//
// Credential posture: the PAT is a spending credential (can view billing).
// Stored in KeychainStore, never logged. Only HTTP status codes go through
// Log.info(.count).

import Foundation
import SwiftUI
import Combine

@MainActor
public final class CopilotUsageStore: UsageProvider, PasteKeyProvider {

    public let id: String = "copilot"
    public let displayName: String = "GitHub Copilot"
    public let featureFlagKey: String = "features.copilot.enabled"

    // PasteKeyProvider — the user pastes a fine-grained PAT prefixed
    // `github_pat_`. The `Plan (Read)` permission is a per-user account
    // permission (not an org permission), so the PAT resource owner MUST
    // be the user's own account.
    public let keyPlaceholder: String = "github_pat_… (fine-grained token, Plan: Read)"

    // MARK: Observable state

    @Published public private(set) var snapshot: CopilotUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?

    private let credentials: CredentialStore
    private let transport: CopilotUsageTransport
    private let defaults: UserDefaults

    /// Monotonically-increasing generation counter. Every credential-changing
    /// event (`saveKey`, `clear`) bumps it; every `fetch()` snapshots the
    /// current value into its completion closure and only applies the
    /// result if the counter is still that value. This defeats two Codex
    /// review #1/#2 races:
    ///   - fetch launched with PAT A completes AFTER the user saved PAT B →
    ///     the stale result would otherwise land in `snapshot`.
    ///   - fetch launched, then `clear()` was called → the stale result
    ///     would otherwise repopulate state that clear had just wiped.
    private var fetchGeneration: UInt64 = 0

    public init(
        credentials: CredentialStore = KeychainStore(),
        transport: CopilotUsageTransport = URLSessionCopilotTransport(),
        defaults: UserDefaults = .standard
    ) {
        self.credentials = credentials
        self.transport = transport
        self.defaults = defaults
    }

    // MARK: - Credential management

    /// True when a PAT is stored. `.unavailable` (locked keychain) counts
    /// as configured so a locked screen does not drop the provider to
    /// onboarding (parity with the PR #60 hardening pattern; and the
    /// chk1-audit Bug #2 fix in Perplexity).
    public var hasKey: Bool {
        switch credentials.readResult(CopilotUsageFetcher.patKeychainKey) {
        case .found(let data): return !data.isEmpty
        case .unavailable:     return true
        case .missing:         return false
        }
    }

    /// Save a pasted PAT. Empty input clears it and the cached login. We
    /// clear the login too because a new PAT may belong to a different
    /// GitHub user. Also bumps the fetch generation so any in-flight
    /// fetch launched with the previous PAT will be discarded when its
    /// completion fires.
    public func saveKey(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            credentials.delete(CopilotUsageFetcher.patKeychainKey)
            credentials.delete(CopilotUsageFetcher.loginKeychainKey)
        } else {
            credentials.write(CopilotUsageFetcher.patKeychainKey, Data(trimmed.utf8))
            // Do NOT preserve a stale login here — the new PAT may belong
            // to a different account. The next fetch discovers it via /user.
            credentials.delete(CopilotUsageFetcher.loginKeychainKey)
        }
        fetchGeneration &+= 1
        objectWillChange.send()
    }

    // MARK: - UsageProvider: feature flag

    public var isEnabled: Bool { defaults.bool(forKey: featureFlagKey) }
    public var isConfigured: Bool { hasKey }
    public var lastUpdated: Date? { lastUpdatedAt }
    public var errorMessage: String? { lastError }

    // MARK: - UsageProvider: tiles

    public var tiles: [UsageTile] {
        guard isEnabled else { return [] }

        if !isConfigured {
            return [UsageTile(
                id: "copilot-needs-key",
                title: "GitHub Copilot",
                kind: .needsAccess(
                    path: "api.github.com",
                    guidance: "Paste a fine-grained GitHub PAT with 'Plan: Read' (Account permissions) in Settings. Resource owner must be your own account."
                )
            )]
        }

        guard let snap = snapshot else { return [] }

        // Org-billed / no-activity signal: 200 with usageItems == [] means
        // the user has no personal spend to report (either their Copilot
        // seat is managed through an org/enterprise, or they simply had
        // zero AI Credit usage in the period). Surface a specific tile so
        // an empty section is not mistaken for a fetch failure.
        if snap.isEmptyOrgBilled {
            return [UsageTile(
                id: "copilot-empty",
                title: "GitHub Copilot",
                kind: .text(
                    status: "No personal usage",
                    subtitle: "If your Copilot seat is managed by an organisation or enterprise, personal usage is not reported on this endpoint."
                )
            )]
        }

        var out: [UsageTile] = []

        // Headline MTD spend tile. netAmount is a USD Double; the balance
        // tile takes minor units (cents). Crash-safe against a hostile
        // 1e300 amount via the same Int(exactly:) clamp used in Perplexity.
        let usdMTD = snap.netAmountMTDUSD
        let cents: Int = {
            let clamped = max(0.0, usdMTD * 100.0)
            guard clamped.isFinite else { return 0 }
            return Int(exactly: clamped.rounded()) ?? Int.max
        }()
        out.append(UsageTile(
            id: "copilot-mtd",
            title: "Copilot spend (MTD)",
            kind: .balance(
                remainingMinorUnits: cents,
                currency: "USD",
                plan: periodLabel(snap),
                resetsAt: nil        // no month-end date on the wire
            )
        ))

        // Per-SKU breakdown as `.text` tiles. Cap at the top three so the
        // popover does not stretch on accounts with many SKUs.
        for item in snap.itemsBySkuDescending.prefix(3) where item.netAmount > 0 {
            let dollarString = String(format: "USD %.2f", item.netAmount)
            let subtitle: String = {
                var parts: [String] = []
                if let model = item.model, !model.isEmpty { parts.append(model) }
                let qty = item.netQuantity
                // Codex round-1 finding #3: `Int(qty)` traps on non-finite
                // or oversize Doubles (`Int(1e300)` is a trap, not a
                // truncation). Guard with `Int(exactly:)` on the rounded
                // integer path and fall back to a %.2f render for anything
                // that would not round-trip cleanly.
                let qtyString: String = {
                    if qty.isFinite && qty == qty.rounded(),
                       let asInt = Int(exactly: qty.rounded()) {
                        return String(asInt)
                    }
                    return String(format: "%.2f", qty)
                }()
                let unit = item.unitType.isEmpty ? "units" : item.unitType
                parts.append("\(qtyString) \(unit)")
                return parts.joined(separator: " · ")
            }()
            out.append(UsageTile(
                id: "copilot-sku-\(item.sku.lowercased().replacingOccurrences(of: " ", with: "-"))",
                title: item.sku,
                kind: .text(status: dollarString, subtitle: subtitle)
            ))
        }

        return out
    }

    /// Human label for the reporting period, e.g. "July 2026" or "2026".
    private func periodLabel(_ snap: CopilotUsageSnapshot) -> String {
        // Codex round-1 finding #7: hostile `month: 13` would let
        // `Calendar.date(from:)` roll over to January of the next year,
        // labelling the wrong billing period. Validate 1…12 before use.
        if let month = snap.month, (1 ... 12).contains(month) {
            let fmt = DateFormatter()
            fmt.dateFormat = "LLLL yyyy"
            var comps = DateComponents()
            comps.year = snap.year
            comps.month = month
            comps.day = 1
            if let date = Calendar(identifier: .gregorian).date(from: comps) {
                return fmt.string(from: date)
            }
        }
        return String(snap.year)
    }

    // MARK: - Result application (testable seam)

    public func apply(_ result: CopilotUsageResult, now: Date = Date()) {
        switch result {
        case .success(let snap):
            self.snapshot = snap
            self.lastUpdatedAt = now
            self.lastError = nil
        case .unauthorized:
            // 401 site-wide (or 403 with x-ratelimit-remaining > 0): the PAT
            // is invalid, expired, or lacks the Plan permission. Drop the
            // stale snapshot to match the Perplexity chk1 fix pattern.
            self.snapshot = nil
            self.lastError = "GitHub token invalid or missing Plan permission. Re-generate a fine-grained PAT with Plan: Read."
        case .rateLimited(let retryAfterSeconds):
            if let sec = retryAfterSeconds, sec > 0 {
                self.lastError = "GitHub rate-limited (retry in \(sec)s)."
            } else {
                self.lastError = "GitHub rate-limited. Try again shortly."
            }
        case .httpError(let code):
            if (500 ..< 600).contains(code) {
                self.lastError = "GitHub server error (HTTP \(code)). Retry later."
            } else {
                self.lastError = "HTTP \(code)"
            }
        case .networkError:
            self.lastError = "Network error"
        }
    }

    // MARK: - UsageProvider: actions

    public func fetch() {
        guard isEnabled else { return }
        // Use readResult() so a locked keychain (.unavailable) is
        // distinguished from a truly-missing PAT — same audit-hardened
        // pattern the chk1-fix branch established for Perplexity.
        let patData: Data
        switch credentials.readResult(CopilotUsageFetcher.patKeychainKey) {
        case .found(let value) where !value.isEmpty:
            patData = value
        case .found, .missing:
            snapshot = nil
            lastError = nil
            return
        case .unavailable:
            snapshot = nil
            lastError = "Keychain locked or unavailable. Unlock your Mac to refresh Copilot usage."
            return
        }
        guard let pat = String(data: patData, encoding: .utf8) else {
            snapshot = nil
            lastError = "Could not decode the stored GitHub token. Re-paste it in Settings."
            return
        }
        // Cached login (if any) from a prior fetch, so we can skip the
        // /user round-trip. read() rather than readResult() is fine here —
        // absence just triggers a fresh discovery.
        let cachedLogin = credentials.read(CopilotUsageFetcher.loginKeychainKey)
            .flatMap { String(data: $0, encoding: .utf8) }

        // Codex round-2 finding #1: EVERY fetch bumps the generation, not
        // just credential changes. That way two overlapping fetches (e.g.
        // auto-refresh timer + user's Refresh button) never share the same
        // launchedAt, so the earlier one is always superseded by the later.
        fetchGeneration &+= 1
        let launchedAt = fetchGeneration

        transport.fetchAll(token: pat, cachedLogin: cachedLogin) { [weak self] result, discoveredLogin in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Codex round-1 findings #1 + #2: discard if the credential
                // that launched this fetch has since been rotated or cleared.
                guard self.fetchGeneration == launchedAt else { return }
                // Codex round-1 finding #5 (broadened per round-2 #2): if
                // the fetch was launched with a CACHED login and it failed
                // in any way that suggests the login is wrong (404, 401
                // — the user's login may have been renamed such that the
                // cached username is now someone else's, or 403 that isn't
                // a rate limit), drop the cache. Next fetch re-discovers
                // via /user. rateLimited is left alone — no reason to
                // suspect the cached login there.
                if cachedLogin != nil {
                    switch result {
                    case .httpError(404), .unauthorized:
                        self.credentials.delete(CopilotUsageFetcher.loginKeychainKey)
                    default:
                        break
                    }
                }
                // Persist a freshly-discovered login so future fetches skip
                // the /user hop. Only write when the login actually changed
                // (i.e. the transport resolved one and it differs from cache).
                if let login = discoveredLogin, cachedLogin != login {
                    self.credentials.write(CopilotUsageFetcher.loginKeychainKey, Data(login.utf8))
                }
                self.apply(result)
            }
        }
    }

    public func clear() {
        credentials.delete(CopilotUsageFetcher.patKeychainKey)
        credentials.delete(CopilotUsageFetcher.loginKeychainKey)
        // Bump BEFORE clearing state — an in-flight fetch's completion
        // will see the new generation and skip its apply() step.
        fetchGeneration &+= 1
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
    }
}

// MARK: - Transport abstraction

public enum CopilotUsageResult: Sendable {
    case success(CopilotUsageSnapshot)
    case unauthorized
    /// 429, or 403 with `x-ratelimit-remaining: 0`. Optional retry hint
    /// from `Retry-After` (seconds) or `x-ratelimit-reset` (delta).
    case rateLimited(retryAfterSeconds: Int?)
    case httpError(Int)
    case networkError
}

/// Seam over the login-discovery-plus-billing chain. Completion MAY be
/// delivered on any queue; the store hops to the main actor via
/// `Task { @MainActor }`. `discoveredLogin` is nil when the transport
/// reused a cached login (no /user hop), and populated when a fresh
/// discovery occurred (so the store can persist it).
public protocol CopilotUsageTransport: Sendable {
    func fetchAll(
        token: String,
        cachedLogin: String?,
        completion: @escaping @Sendable (CopilotUsageResult, String?) -> Void
    )
}

/// Production transport. Chains: `GET /user` (skipped when `cachedLogin`
/// is present) → `GET /users/{login}/settings/billing/ai_credit/usage`.
/// Uses a private URLSession with ephemeral configuration and bounded
/// timeouts — same chk1-audit pattern the Perplexity transport landed.
public struct URLSessionCopilotTransport: CopilotUsageTransport {

    private let userURL = URL(string: "https://api.github.com/user")!
    private let apiBase = "https://api.github.com"

    /// Chrome-shaped User-Agent is unnecessary for api.github.com (no
    /// Cloudflare browser fingerprinting here) but a non-empty User-Agent
    /// IS required — GitHub rejects headerless requests with 403.
    /// Version-tagged so a Sentry-style investigation can reproduce.
    private let userAgent = "ClaudeUsageBar/1.7 (github.com/Artzainnn/ClaudeUsageBar)"

    /// Private URLSession isolated from URLSession.shared (chk1-fix pattern
    /// carried over from Perplexity). `.ephemeral` = in-memory cookie jar
    /// (irrelevant here — GitHub sets no auth cookies — but keeps the
    /// isolation guarantee), no disk cache, bounded timeouts.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    public init() {}

    public func fetchAll(
        token: String,
        cachedLogin: String?,
        completion: @escaping @Sendable (CopilotUsageResult, String?) -> Void
    ) {
        let deliver: @Sendable (CopilotUsageResult, String?) -> Void = { result, login in
            DispatchQueue.main.async { completion(result, login) }
        }

        // Reject a token that carries control chars before it reaches an
        // Authorization header. Same defence-in-depth as Perplexity.
        guard let safeToken = RequestSafety.headerValue(token) else {
            deliver(.unauthorized, nil)
            return
        }
        let authHeader = "Bearer \(safeToken)"

        // If we have a cached login, skip /user and hit billing directly.
        if let login = cachedLogin, !login.isEmpty {
            fetchUsage(login: login, authHeader: authHeader) { result in
                deliver(result, nil)   // no new login discovered
            }
            return
        }

        // Otherwise discover the login via /user first.
        get(userURL, authHeader: authHeader) { data, status, headers in
            guard let status = status else {
                deliver(.networkError, nil); return
            }
            if status == 401 {
                deliver(.unauthorized, nil); return
            }
            if status == 403 {
                if Self.isRateLimitResponse(headers) {
                    deliver(.rateLimited(retryAfterSeconds: Self.retryAfterSeconds(from: headers)), nil)
                } else {
                    deliver(.unauthorized, nil)
                }
                return
            }
            if status == 429 {
                deliver(.rateLimited(retryAfterSeconds: Self.retryAfterSeconds(from: headers)), nil)
                return
            }
            guard status == 200, let data = data,
                  let login = try? CopilotUsageFetcher.parseAuthenticatedUserLogin(data) else {
                deliver(status == 200 ? .networkError : .httpError(status), nil); return
            }
            self.fetchUsage(login: login, authHeader: authHeader) { result in
                deliver(result, login)
            }
        }
    }

    /// True when the response is a rate-limit response. Two flavours:
    ///   - Primary: `x-ratelimit-remaining: 0`.
    ///   - Secondary (abuse) rate limit: 403 with `Retry-After` present
    ///     regardless of remaining. Codex round-2 finding #3: a naive
    ///     "remaining == 0" check misclassified secondary rate limits as
    ///     auth failures. `public` for unit-testability (same rationale as
    ///     the Perplexity accumulator — app-only module, no external
    ///     consumers).
    public static func isRateLimitResponse(_ headers: [String: String]?) -> Bool {
        guard let headers = headers else { return false }
        if let raw = headers["x-ratelimit-remaining"], let remaining = Int(raw), remaining == 0 {
            return true
        }
        if headers["retry-after"] != nil {
            return true
        }
        return false
    }

    /// Extract a seconds-hint from a rate-limit response. GitHub's contract:
    /// `Retry-After` (seconds OR HTTP-date) is preferred; if absent,
    /// `x-ratelimit-reset` (UTC epoch seconds) gives an absolute reset time
    /// from which we compute a delta. Returns nil when nothing is usable.
    /// `public` for unit-testability.
    public static func retryAfterSeconds(from headers: [String: String]?) -> Int? {
        guard let headers = headers else { return nil }
        if let raw = headers["retry-after"] {
            if let s = Int(raw), s > 0 { return s }
            // Codex round-2 finding #4: Retry-After may be an HTTP-date
            // per RFC 9110. Parse it against RFC 1123 format.
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "GMT")
            fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = fmt.date(from: raw) {
                let delta = Int(date.timeIntervalSince(Date()))
                return delta > 0 ? delta : nil
            }
        }
        if let raw = headers["x-ratelimit-reset"], let epoch = Int(raw) {
            let delta = epoch - Int(Date().timeIntervalSince1970)
            return delta > 0 ? delta : nil
        }
        return nil
    }

    /// Hit the AI-Credit billing endpoint for the given login.
    private func fetchUsage(
        login: String,
        authHeader: String,
        done: @escaping @Sendable (CopilotUsageResult) -> Void
    ) {
        // Path segment safety: the login is a semi-trusted string (comes
        // from either a Keychain-cached value or GitHub's /user response).
        // Encode as a single path segment so a hostile value cannot alter
        // the path.
        guard let encodedLogin = RequestSafety.pathSegment(login) else {
            done(.unauthorized); return
        }
        let urlString = "\(apiBase)/users/\(encodedLogin)/settings/billing/ai_credit/usage"
        guard let url = URL(string: urlString) else {
            done(.networkError); return
        }
        get(url, authHeader: authHeader) { data, status, headers in
            guard let status = status else { done(.networkError); return }
            if status == 401 {
                done(.unauthorized); return
            }
            if status == 403 {
                if Self.isRateLimitResponse(headers) {
                    done(.rateLimited(retryAfterSeconds: Self.retryAfterSeconds(from: headers)))
                } else {
                    done(.unauthorized)
                }
                return
            }
            if status == 429 {
                done(.rateLimited(retryAfterSeconds: Self.retryAfterSeconds(from: headers)))
                return
            }
            guard status == 200, let data = data,
                  let snap = try? CopilotUsageFetcher.parseUsage(data) else {
                done(.httpError(status)); return
            }
            done(.success(snap))
        }
    }

    private func get(
        _ url: URL,
        authHeader: String,
        done: @escaping @Sendable (Data?, Int?, [String: String]?) -> Void
    ) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(CopilotUsageFetcher.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            if error != nil { done(nil, nil, nil); return }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode
            Log.info("GitHub Copilot billing API response", .count(status ?? -1))
            // Lower-case header keys for reliable lookup — HTTPURLResponse
            // headers are case-insensitive per the docs but Foundation
            // preserves the wire casing.
            var headers: [String: String] = [:]
            if let allHeaders = http?.allHeaderFields {
                for (k, v) in allHeaders {
                    if let ks = k as? String, let vs = v as? String {
                        headers[ks.lowercased()] = vs
                    }
                }
            }
            done(data, status, headers)
        }.resume()
    }
}
