// PR 8-BE — Perplexity Pro/Max UsageProvider conformer (dark code, flag off).
//
// Sixth non-Anthropic provider; first cookie-authenticated one. The user's
// perplexity.ai session cookie is stored in the Keychain (PasteKeyProvider
// UX shipped in PR 8-UI). Three endpoints are polled every 60 seconds by
// the shared AppDelegate timer when enabled: credits, rate-limit/all,
// user/settings. Bodies are never logged; only HTTP status codes go
// through Log.info(.count).
//
// Feature posture: features.perplexity.enabled defaults false. Nothing
// registers a store into the live registry yet — the tile + Settings sheet
// land in PR 8-UI.
//
// Polling etiquette: perplexity.ai's own internal endpoints ask consumers
// to cache 60s+ to avoid a shadow-ban on the session cookie. The shared
// AppDelegate timer fires providers at 60s; that meets the etiquette
// without a per-provider override.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class PerplexityUsageStore: @preconcurrency UsageProvider, PasteKeyProvider {

    public let id: String = "perplexity"
    public let displayName: String = "Perplexity"
    public let featureFlagKey: String = "features.perplexity.enabled"

    // PasteKeyProvider — the input can be a bare token, a name=value pair,
    // or a full cookie header string (browser DevTools "Copy value" or
    // "Copy string"). Extraction runs at fetch time.
    public let keyPlaceholder: String = "__Secure-next-auth.session-token=… (or paste the cookie value)"
    /// Override the default noun so the generic ProviderToggleRow renders
    /// "Cookie saved in Keychain" rather than "Key saved in Keychain",
    /// matching what the user actually pasted.
    public var secretKindNoun: String { "Cookie" }

    // MARK: Observable state

    @Published public private(set) var snapshot: PerplexityUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?

    private let credentials: CredentialStore
    private let transport: PerplexityUsageTransport
    private let defaults: UserDefaults

    public init(
        credentials: CredentialStore = KeychainStore(),
        transport: PerplexityUsageTransport = URLSessionPerplexityTransport(),
        defaults: UserDefaults = .standard
    ) {
        self.credentials = credentials
        self.transport = transport
        self.defaults = defaults
    }

    // MARK: - Credential management

    /// True when a session cookie is stored, treating a locked keychain as
    /// "still configured" so a locked screen does not drop the provider back
    /// to onboarding (parity with DeepSeek / xAI / OpenAI).
    public var hasKey: Bool {
        switch credentials.readResult(PerplexityUsageFetcher.cookieKeychainKey) {
        case .found(let data): return !data.isEmpty
        case .unavailable:     return true
        case .missing:         return false
        }
    }

    /// Store the pasted cookie verbatim (whitespace-trimmed only). We do NOT
    /// pre-parse: keeping the raw input lets the user amend a stray prefix
    /// without re-pasting the whole thing, and extraction runs at fetch
    /// time.
    public func saveKey(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            credentials.delete(PerplexityUsageFetcher.cookieKeychainKey)
        } else {
            credentials.write(PerplexityUsageFetcher.cookieKeychainKey, Data(trimmed.utf8))
        }
        objectWillChange.send()
    }

    // MARK: - UsageProvider: feature flag

    public var isEnabled: Bool {
        defaults.bool(forKey: featureFlagKey)
    }

    public var isConfigured: Bool {
        hasKey
    }

    public var lastUpdated: Date? { lastUpdatedAt }
    public var errorMessage: String? { lastError }

    // MARK: - UsageProvider: tiles

    public var tiles: [UsageTile] {
        guard isEnabled else { return [] }

        if !isConfigured {
            return [UsageTile(
                id: "perplexity-needs-key",
                title: "Perplexity",
                kind: .needsAccess(
                    path: "perplexity.ai",
                    guidance: "Paste your Perplexity session cookie in Settings. Sign in on perplexity.ai, then copy the value of the __Secure-next-auth.session-token cookie."
                )
            )]
        }

        guard let snap = snapshot else { return [] }

        var out: [UsageTile] = []

        // Plan tile from user/settings. Only rendered when we can name a
        // plan tier — the tile is omitted when the settings endpoint was
        // Cloudflare-challenged or only reported a billing source.
        if let settings = snap.settings, let tier = normalisedTier(settings.subscriptionTier) {
            let statusLine = settings.subscriptionStatus.map { "\(tier) (\($0))" } ?? tier
            out.append(UsageTile(
                id: "perplexity-plan",
                title: "Perplexity plan",
                kind: .text(status: statusLine, subtitle: nil)
            ))
        }

        // Credits balance tile. balance_cents is a live USD-cents number;
        // the balance tile takes minor units directly. Renewal date drives
        // the resetsAt hint.
        if let credits = snap.credits {
            // Crash-safety: balance_cents is a Double parsed from an
            // untrusted server. `Int(Double)` traps on non-finite / oversize
            // values (1e300 is a valid JSON number). Clamp with
            // Int(exactly:) on the rounded Double, then max(0, …).
            let cents: Int = {
                let clamped = max(0.0, credits.balanceCents)
                guard clamped.isFinite else { return 0 }
                return Int(exactly: clamped.rounded()) ?? Int.max
            }()
            let renewsAt: Date? = credits.renewalEpoch > 0
                ? Date(timeIntervalSince1970: credits.renewalEpoch)
                : nil
            // Plan hint on the balance tile comes from the recurring grant
            // total. Perplexity's own plans put Pro's monthly credit
            // allotment in the ~$5 range and Max's in the ~$100+ range; use
            // 10 000 cents ($100) as the Pro/Max boundary so a $50 (5 000c)
            // recurring grant is still labelled Pro. Verified against
            // published Pro/Max plan comparisons (CodexBar comment) —
            // NB: the initial draft used 5 000 which flipped Pro users to
            // "Max" one order of magnitude too early.
            // Defensive lowercase compare: Perplexity has been observed
            // returning "recurring" verbatim, but a future casing change
            // ("Recurring") would silently drop the recurring total and
            // blank out the plan hint. Match case-insensitively so a
            // schema tweak does not cause a silent regression.
            let recurring = credits.grants
                .filter { $0.type.lowercased() == "recurring" }
                .reduce(0.0) { $0 + max(0, $1.amountCents) }
            let planHint: String? = recurring <= 0
                ? nil
                : (recurring < 10000 ? "Pro" : "Max")
            out.append(UsageTile(
                id: "perplexity-credits",
                title: "Perplexity credits",
                kind: .balance(
                    remainingMinorUnits: cents,
                    currency: "USD",
                    plan: planHint,
                    resetsAt: renewsAt
                )
            ))
        }

        // Per-mode counters from /rest/rate-limit/all. Only remaining values
        // are on the wire — no totals — so we cannot render a proper
        // used/limit counter without inferring a plan cap client-side. That
        // inference is brittle (Perplexity ships plan changes without
        // notice), so surface the raw number as a `.text` tile ("42 left")
        // rather than a `.counter` whose "limit" would be the same as
        // "remaining" and read as unused. Only emit tiles for modes that
        // report a positive number so a free-tier account isn't papered
        // with four grey zeros.
        if let limits = snap.rateLimits {
            let modes: [(String, String, Int)] = [
                ("perplexity-pro", "Pro Search", limits.remainingPro),
                ("perplexity-research", "Deep Research", limits.remainingResearch),
                ("perplexity-labs", "Labs", limits.remainingLabs),
                ("perplexity-agentic", "Agentic Research", limits.remainingAgenticResearch),
            ]
            for (id, title, remaining) in modes where remaining > 0 {
                out.append(UsageTile(
                    id: id,
                    title: title,
                    kind: .text(status: "\(remaining) left", subtitle: nil)
                ))
            }
        }

        return out
    }

    /// Normalise a raw subscription-tier string into a human label. Preserves
    /// unknown values verbatim so a new tier introduced server-side is not
    /// silently swallowed. Returns nil when no tier is reported — the caller
    /// omits the plan tile in that case rather than mislabelling it with a
    /// billing-provider name (chk1 Bug #3: `subscription_source` values like
    /// "stripe" / "revenuecat" are billing providers, NOT plans).
    private func normalisedTier(_ rawTier: String?) -> String? {
        guard let tier = rawTier?.trimmingCharacters(in: .whitespaces),
              !tier.isEmpty,
              tier.lowercased() != "none" else {
            return nil
        }
        switch tier.lowercased() {
        case "free": return "Free"
        case "pro":  return "Pro"
        case "max":  return "Max"
        default:     return tier   // preserve an unknown tier verbatim
        }
    }

    // MARK: - Result application (testable seam)

    /// Apply a transport result. Extracted so the TestRunner can drive every
    /// branch synchronously.
    public func apply(_ result: PerplexityUsageResult, now: Date = Date()) {
        switch result {
        case .success(let snap):
            self.snapshot = snap
            self.lastUpdatedAt = now
            self.lastError = nil
        case .unauthorized:
            // 401/403 — cookie expired, or Cloudflare bounced us. Both need
            // the same user action (re-copy the cookie from a signed-in
            // browser); the differentiation is hidden behind one message.
            // Also drop the stale snapshot so the tile does not keep
            // showing an obsolete balance / counters while the credential
            // is known-bad (Codex adversarial review #6).
            self.snapshot = nil
            self.lastError = "Perplexity session cookie expired or blocked. Sign in on perplexity.ai and paste a fresh cookie."
        case .httpError(let code):
            // 429 is Perplexity's rate-limit / soft-shadow-ban signal;
            // 5xx is a real server problem the user cannot fix. Give each
            // a distinct message so the user knows whether to slow down or
            // wait for Perplexity to recover.
            if code == 429 {
                self.lastError = "Perplexity is rate-limiting this session. Slow polling or wait a few minutes."
            } else if (500 ..< 600).contains(code) {
                self.lastError = "Perplexity server error (HTTP \(code)). Retry later."
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
        // Use readResult() rather than read() so a locked keychain
        // (.unavailable) is distinguished from a truly-missing item. Round-2
        // review addressed the malformed-cookie case; this closes the same
        // silent-no-op gap for the locked-keychain scenario — isConfigured
        // still returns true when the item exists but is unreadable, so
        // without an explicit branch here the UI would report the provider
        // as configured while fetch quietly did nothing (chk1 Bug #2).
        let data: Data
        switch credentials.readResult(PerplexityUsageFetcher.cookieKeychainKey) {
        case .found(let value) where !value.isEmpty:
            data = value
        case .found, .missing:
            // No credential stored (or empty item — treat as missing).
            // Onboarding card renders via isConfigured=false.
            snapshot = nil
            lastError = nil
            return
        case .unavailable:
            // Keychain present but temporarily unreadable (locked screen,
            // access denied). Surface an actionable message so the tile
            // does not silently blank while the user's Mac is locked.
            snapshot = nil
            lastError = "Keychain locked or unavailable. Unlock your Mac to refresh Perplexity usage."
            return
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            snapshot = nil
            lastError = "Could not decode the stored Perplexity cookie. Re-paste it in Settings."
            return
        }
        guard let cookie = PerplexityCookie.extract(from: raw) else {
            // The stored blob exists but is not a usable cookie. Surface an
            // actionable error rather than silently no-op'ing forever —
            // isConfigured is still true (hasKey checks presence, not
            // parseability), so without this message the user sees an
            // empty section indefinitely.
            snapshot = nil
            lastError = "Could not parse the stored Perplexity cookie. Re-paste it in Settings."
            return
        }

        transport.fetchAll(cookieName: cookie.name, cookieValue: cookie.token) { [weak self] result in
            // Task { @MainActor } is safe on any delivery queue (cannot trap
            // like assumeIsolated if a transport calls back off-main).
            Task { @MainActor [weak self] in self?.apply(result) }
        }
    }

    public func clear() {
        // Clearing Perplexity DOES delete the cookie — the user pasted it
        // here. Same pattern as DeepSeek's Clear Key.
        credentials.delete(PerplexityUsageFetcher.cookieKeychainKey)
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
    }
}

// MARK: - Transport abstraction

public enum PerplexityUsageResult: Sendable {
    case success(PerplexityUsageSnapshot)
    case unauthorized
    case httpError(Int)
    case networkError
}

/// Seam over the multi-endpoint fetch. The completion MAY be delivered on
/// any queue; the store hops to the main actor via a `Task { @MainActor }`
/// before touching @Published state (see the Hardening pass in PR #60 for
/// why `assumeIsolated` is banned).
public protocol PerplexityUsageTransport: Sendable {
    func fetchAll(
        cookieName: String,
        cookieValue: String,
        completion: @escaping @Sendable (PerplexityUsageResult) -> Void
    )
}

/// Production transport. Issues three GETs in parallel with the pasted
/// cookie, browser-shaped headers, and no body. Bodies are never logged;
/// only status codes go through Log.info(.count).
public struct URLSessionPerplexityTransport: PerplexityUsageTransport {

    private let creditsURL = URL(string: "https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default")!
    private let rateLimitsURL = URL(string: "https://www.perplexity.ai/rest/rate-limit/all")!
    private let settingsURL = URL(string: "https://www.perplexity.ai/rest/user/settings?version=2.18&source=default")!

    /// Browser-shaped User-Agent. Cloudflare bot detection fingerprints on
    /// TLS + IP; a plain URLSession UA is enough for residential Mac users
    /// but the header still needs to smell like a browser to avoid the
    /// challenge-page filter. This UA is not spoofing a specific browser —
    /// it is the shape Perplexity's own web bundle sends.
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    /// Private URLSession, isolated from `URLSession.shared` (chk1 Risk #1
    /// + #2). Two problems the shared session has for a cookie-authenticated
    /// provider:
    ///   1. The default `HTTPCookieStorage` is disk-backed under
    ///      ~/Library/Cookies/. Perplexity sets several cookies on every
    ///      response (`__cf_bm`, `cf_clearance`, session tokens); with the
    ///      shared session those would silently persist across app launches
    ///      in a store the user cannot see, and would leak onto every other
    ///      request the app makes to perplexity.ai (including Anthropic's
    ///      tracker if that ever traversed the domain).
    ///   2. `URLSessionConfiguration.default.timeoutIntervalForResource` is
    ///      604 800 seconds (7 days). A stalled Perplexity response would
    ///      park its callback for a week.
    /// This session uses `.ephemeral` configuration — Apple's documented
    /// pattern for a URLSession with in-memory-only cookie storage isolated
    /// from `URLSession.shared`. `.ephemeral` gives us a per-session cookie
    /// jar that:
    ///   - Cloudflare's per-poll `__cf_bm` challenge cookies still work
    ///     inside a single fetchAll() cycle (chk1-fix Codex round 4: nulling
    ///     the store entirely could break Cloudflare challenge flows).
    ///   - Nothing persists to disk (unlike the shared session's default
    ///     store under ~/Library/Cookies/).
    ///   - Nothing leaks into the shared jar or any other provider.
    /// Timeouts are matched to the 60s poll cadence.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    public init() {}

    public func fetchAll(
        cookieName: String,
        cookieValue: String,
        completion: @escaping @Sendable (PerplexityUsageResult) -> Void
    ) {
        let deliver: @Sendable (PerplexityUsageResult) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }

        // Cookie assembly. Both name and value pass through
        // RequestSafety.headerValue to reject control chars (CR/LF/NUL) that
        // could split the header. Additionally, `;`, `,`, `=` are rejected
        // in the *value*, and the same set plus space is rejected in the
        // *name*, to defeat a Cookie-splicing attack: a hostile string
        // pasted (or Keychain-injected) as a value like "real; other=evil"
        // would otherwise silently add a second cookie to the request, and
        // a similarly hostile name like "session-token=real; other" would
        // splice via the name half. NextAuth cookie names are letters,
        // digits, `-`, `.`, `_`; JWEs are base64url with dot separators;
        // neither ever legitimately contains these splitters.
        guard let safeName = RequestSafety.headerValue(cookieName),
              let safeValue = RequestSafety.headerValue(cookieValue),
              !safeName.contains(";"),
              !safeName.contains(","),
              !safeName.contains("="),
              !safeName.contains(" "),
              !safeValue.contains(";"),
              !safeValue.contains(",") else {
            deliver(.unauthorized)
            return
        }
        let cookieHeader = "\(safeName)=\(safeValue)"

        let group = DispatchGroup()
        // Atomic accumulator around a lock — three concurrent GETs feed it.
        let acc = PerplexityFetchAccumulator()

        for (url, kind) in [
            (creditsURL, PerplexityEndpointKind.credits),
            (rateLimitsURL, .rateLimits),
            (settingsURL, .settings),
        ] {
            group.enter()
            get(url, cookieHeader: cookieHeader) { data, status in
                defer { group.leave() }
                if let status = status, (status == 401 || status == 403) {
                    acc.setUnauthorized()
                    return
                }
                if status == 200, let data = data {
                    switch kind {
                    case .credits:
                        if let parsed = try? PerplexityUsageFetcher.parseCredits(data) {
                            acc.setCredits(parsed)
                        }
                    case .rateLimits:
                        if let parsed = try? PerplexityUsageFetcher.parseRateLimits(data) {
                            acc.setRateLimits(parsed)
                        }
                    case .settings:
                        if let parsed = try? PerplexityUsageFetcher.parseUserSettings(data) {
                            acc.setSettings(parsed)
                        }
                    }
                } else if let status = status {
                    // A non-success, non-auth status (429, 5xx, ...). Remember
                    // the highest-signal code so a total failure can surface it
                    // to the user rather than degrading to "Network error".
                    // 429 is Perplexity's shadow-ban / rate-limit response
                    // and is the most actionable — the user needs to slow
                    // down or wait, not re-paste a cookie.
                    acc.recordHttpError(status)
                }
            }
        }

        group.notify(queue: .global()) {
            let (unauthorized, httpError, snap) = acc.finalize()
            if unauthorized {
                deliver(.unauthorized)
            } else if snap.credits == nil && snap.rateLimits == nil && snap.settings == nil {
                // Every endpoint failed. Prefer the HTTP status when one is
                // remembered (429/5xx) — Codex round-3 review — else fall
                // back to networkError for a genuine transport failure.
                if let code = httpError {
                    deliver(.httpError(code))
                } else {
                    deliver(.networkError)
                }
            } else {
                deliver(.success(snap))
            }
        }
    }

    private func get(_ url: URL, cookieHeader: String, done: @escaping @Sendable (Data?, Int?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("https://www.perplexity.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://www.perplexity.ai/account/usage", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // Private session (see the `session` property comment) — critical
        // that this is NOT URLSession.shared, so Perplexity's Set-Cookie
        // responses cannot contaminate the process-wide cookie jar.
        session.dataTask(with: request) { data, response, error in
            if error != nil { done(nil, nil); return }
            let status = (response as? HTTPURLResponse)?.statusCode
            Log.info("Perplexity API response", .count(status ?? -1))
            done(data, status)
        }.resume()
    }
}

// MARK: - Endpoint kind + accumulator

/// Which endpoint a completion is reporting for. Nested in the transport
/// only (not part of the public surface).
private enum PerplexityEndpointKind {
    case credits, rateLimits, settings
}

/// Thread-safe accumulator for the three concurrent GETs. A final call to
/// `finalize()` collapses the state into a single snapshot + unauthorized
/// flag. Lock-protected because `dataTask` completions can land on any
/// queue.
///
/// `public` (rather than `private`) so TestRunner — a separate SwiftPM
/// target — can lock in the httpError priority ordering and multi-endpoint
/// partial-success shapes without going through a live URL session
/// (chk1 Omission #1 + #2). Codex round-4 flagged this as a small API
/// surface leak; we accept the leak because ClaudeUsageBar is an app-only
/// module with no external library consumers, so no downstream code can
/// depend on this shape. If the module ever gains an external API contract,
/// switch TestRunner to `@testable import ClaudeUsageBar` and revert this
/// to `internal`.
public final class PerplexityFetchAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var credits: PerplexityCredits?
    private var rateLimits: PerplexityRateLimits?
    private var settings: PerplexityUserSettings?
    private var unauthorized = false
    /// Highest-priority non-2xx status seen. Prioritises 429 (shadow-ban
    /// signal, most actionable), then 5xx, then anything else, so the
    /// finalize step surfaces the most useful code when every endpoint
    /// failed.
    private var httpError: Int?

    public init() {}

    public func setCredits(_ value: PerplexityCredits) {
        lock.lock(); defer { lock.unlock() }
        credits = value
    }
    public func setRateLimits(_ value: PerplexityRateLimits) {
        lock.lock(); defer { lock.unlock() }
        rateLimits = value
    }
    public func setSettings(_ value: PerplexityUserSettings) {
        lock.lock(); defer { lock.unlock() }
        settings = value
    }
    public func setUnauthorized() {
        lock.lock(); defer { lock.unlock() }
        unauthorized = true
    }
    public func recordHttpError(_ status: Int) {
        lock.lock(); defer { lock.unlock() }
        // Priority: 429 > 5xx > anything else. Only replace when the new
        // code carries strictly more signal.
        let priority: (Int) -> Int = { code in
            if code == 429 { return 3 }
            if code >= 500 && code < 600 { return 2 }
            return 1
        }
        if let existing = httpError {
            if priority(status) > priority(existing) {
                httpError = status
            }
        } else {
            httpError = status
        }
    }
    public func finalize() -> (Bool, Int?, PerplexityUsageSnapshot) {
        lock.lock(); defer { lock.unlock() }
        return (unauthorized, httpError, PerplexityUsageSnapshot(
            credits: credits,
            rateLimits: rateLimits,
            settings: settings
        ))
    }

    #if DEBUG
    /// Test-only accessor for the current httpError. Guarded behind DEBUG
    /// so it cannot be reached from production paths and stays out of
    /// release-binary symbol tables.
    public var currentHttpError: Int? {
        lock.lock(); defer { lock.unlock() }
        return httpError
    }
    #endif
}
