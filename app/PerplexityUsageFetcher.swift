// PR 8-BE — Perplexity Pro/Max usage fetcher (session-cookie authenticated).
//
// Sixth non-Anthropic provider, first cookie-authenticated one. The user
// pastes their perplexity.ai session cookie (a spending credential — it lets
// the bearer make paid Sonar queries and can top up on-demand credits), so
// the cookie lives in the Keychain, never in UserDefaults.
//
// Auth ingestion accepts all four NextAuth v4/Auth.js v5 session cookie
// names ("__Secure-next-auth.session-token" (live default), "next-auth.
// session-token", "__Secure-authjs.session-token", "authjs.session-token"),
// plus the chunked variants (.0, .1, …) NextAuth splits large JWEs into.
// Bare tokens are accepted verbatim and sent under the default name.
//
// The three endpoints (all undocumented — perplexity.ai's own web UI calls
// them):
//   GET /rest/billing/credits?version=2.18&source=default
//        → balance_cents (float USD cents), renewal_date_ts (Unix seconds),
//          current_period_purchased_cents (float), credit_grants[] (each
//          { type: "recurring"|"promotional"|"purchased", amount_cents,
//          expires_at_ts?: Unix seconds }), total_usage_cents (float).
//   GET /rest/rate-limit/all
//        → remaining_pro, remaining_research, remaining_labs,
//          remaining_agentic_research (ints — REMAINING ONLY, no totals, no
//          resets), model_specific_limits {}, sources.source_to_limit
//          { source_id: { monthly_limit: int|nil, remaining: int|nil } }.
//          Total caps must be inferred client-side (plan lookup); the
//          endpoint reports no plan/tier field of its own.
//   GET /rest/user/settings
//        → subscription_status ("active"|"trialing"|"none"),
//          subscription_source, subscription_tier ("free"|"pro"|"max"), plus
//          pages/upload/create limits and query_count. Supplies the plan
//          label the rate-limit endpoint lacks.
//
// Cloudflare bot protection fronts perplexity.ai/rest/*. A residential-IP
// URLSession GET with a valid cookie + a browser-shaped User-Agent + Accept
// + Origin/Referer headers passes challenge on Macs today (verified across
// three independent OSS consumers). Data centre / VPS traffic gets 403-
// challenged regardless of cookie validity. We ship the browser headers
// and surface 401/403 as invalidToken, which is what the user actually
// needs to act on.
//
// Credentials never enter a log line; only status codes go through
// Log.info(.count). The CI credential-leak guard is extended in this PR to
// cover the `sessionCookie` name already, and `perplexity` variable prefixes
// where they exist.

import Foundation

// MARK: - Snapshot pieces

/// One entry from `credit_grants[]`. Type strings observed: "recurring"
/// (the monthly plan allotment), "promotional" (bonus, may expire), and
/// "purchased" (on-demand top-ups). Unknown types are preserved verbatim so
/// a new tier introduced server-side is not silently dropped.
public struct PerplexityCreditGrant: Equatable, Sendable {
    public var type: String
    public var amountCents: Double
    /// Unix epoch seconds; nil for grants that never expire (e.g. purchased).
    public var expiresAtEpoch: Double?

    public init(type: String, amountCents: Double, expiresAtEpoch: Double? = nil) {
        self.type = type
        self.amountCents = amountCents
        self.expiresAtEpoch = expiresAtEpoch
    }
}

/// Parsed `/rest/billing/credits` body.
public struct PerplexityCredits: Equatable, Sendable {
    /// Live balance in USD cents (float on the wire; we preserve precision).
    public var balanceCents: Double
    /// Renewal (start of next billing cycle) as Unix epoch seconds.
    public var renewalEpoch: Double
    /// On-demand purchases in the current billing period. May be reported
    /// both here and inside `credit_grants` as `purchased`; the store
    /// deduplicates by taking the max, per CodexBar convention.
    public var currentPeriodPurchasedCents: Double
    /// One entry per grant.
    public var grants: [PerplexityCreditGrant]
    /// Spend so far in the current billing period.
    public var totalUsageCents: Double

    public init(
        balanceCents: Double = 0,
        renewalEpoch: Double = 0,
        currentPeriodPurchasedCents: Double = 0,
        grants: [PerplexityCreditGrant] = [],
        totalUsageCents: Double = 0
    ) {
        self.balanceCents = balanceCents
        self.renewalEpoch = renewalEpoch
        self.currentPeriodPurchasedCents = currentPeriodPurchasedCents
        self.grants = grants
        self.totalUsageCents = totalUsageCents
    }
}

/// One entry from `sources.source_to_limit`. Both fields are nullable in the
/// wire shape; a null `monthlyLimit` means the source is unmetered.
public struct PerplexitySourceLimit: Equatable, Sendable {
    public var sourceId: String
    public var monthlyLimit: Int?
    public var remaining: Int?

    public init(sourceId: String, monthlyLimit: Int? = nil, remaining: Int? = nil) {
        self.sourceId = sourceId
        self.monthlyLimit = monthlyLimit
        self.remaining = remaining
    }
}

/// Parsed `/rest/rate-limit/all` body. Only remaining counts are on the
/// wire — no totals, no reset timestamps, no plan/tier field.
public struct PerplexityRateLimits: Equatable, Sendable {
    public var remainingPro: Int
    public var remainingResearch: Int
    public var remainingLabs: Int
    public var remainingAgenticResearch: Int
    public var sources: [PerplexitySourceLimit]

    public init(
        remainingPro: Int = 0,
        remainingResearch: Int = 0,
        remainingLabs: Int = 0,
        remainingAgenticResearch: Int = 0,
        sources: [PerplexitySourceLimit] = []
    ) {
        self.remainingPro = remainingPro
        self.remainingResearch = remainingResearch
        self.remainingLabs = remainingLabs
        self.remainingAgenticResearch = remainingAgenticResearch
        self.sources = sources
    }
}

/// Parsed subset of `/rest/user/settings`. The response is large; we ingest
/// only the fields that inform tiles. Everything else is deliberately
/// ignored to avoid tying us to churn on unrelated flags.
public struct PerplexityUserSettings: Equatable, Sendable {
    /// "active" | "trialing" | "none" | (other, preserved verbatim).
    public var subscriptionStatus: String?
    /// "stripe" | "revenuecat" | "none" | (other).
    public var subscriptionSource: String?
    /// "free" | "pro" | "max" | (other). The plan label the rate-limit
    /// endpoint lacks.
    public var subscriptionTier: String?
    /// Best-effort per-feature limits carried by the endpoint. Zero for
    /// absent fields.
    public var pagesLimit: Int
    public var uploadLimit: Int
    public var createLimit: Int
    public var queryCount: Int

    public init(
        subscriptionStatus: String? = nil,
        subscriptionSource: String? = nil,
        subscriptionTier: String? = nil,
        pagesLimit: Int = 0,
        uploadLimit: Int = 0,
        createLimit: Int = 0,
        queryCount: Int = 0
    ) {
        self.subscriptionStatus = subscriptionStatus
        self.subscriptionSource = subscriptionSource
        self.subscriptionTier = subscriptionTier
        self.pagesLimit = pagesLimit
        self.uploadLimit = uploadLimit
        self.createLimit = createLimit
        self.queryCount = queryCount
    }
}

/// Aggregate snapshot the store applies. Any subset may be nil when the
/// corresponding endpoint failed; the transport reports partial success by
/// filling only the pieces that came back OK. A hard 401/403 short-circuits
/// to `unauthorized` instead of a `success` with everything nil.
public struct PerplexityUsageSnapshot: Equatable, Sendable {
    public var credits: PerplexityCredits?
    public var rateLimits: PerplexityRateLimits?
    public var settings: PerplexityUserSettings?

    public init(
        credits: PerplexityCredits? = nil,
        rateLimits: PerplexityRateLimits? = nil,
        settings: PerplexityUserSettings? = nil
    ) {
        self.credits = credits
        self.rateLimits = rateLimits
        self.settings = settings
    }
}

public enum PerplexityUsageParseError: Error, Equatable {
    case invalidJSON
    case unexpectedShape(String)
}

// MARK: - Cookie normalisation

/// Session cookie forms Perplexity/NextAuth may present. Ordered
/// most-preferred first: the __Secure- prefixed pair takes priority since
/// perplexity.ai serves HTTPS-only and the __Secure- variant is the one live
/// consumers see today (July 2026).
public enum PerplexityCookie {
    /// The four accepted NextAuth session cookie names, in priority order.
    /// Insensitive to case for the match; casing is preserved for the header.
    public static let supportedSessionCookieNames: [String] = [
        "__Secure-next-auth.session-token",
        "__Secure-authjs.session-token",
        "next-auth.session-token",
        "authjs.session-token",
    ]

    /// Default cookie name to send when the user pasted only a bare token.
    public static let defaultSessionCookieName: String = "__Secure-next-auth.session-token"

    /// Extract a `(cookieName, token)` pair from whatever the user pasted:
    ///   - a bare token (no `;` and no `=`) → wrapped under the default cookie
    ///     name.
    ///   - a `name=value` pair or full cookie header (`a=1; b=2; …`) → the
    ///     highest-priority supported session cookie is picked.
    ///   - a paste that contains `=` but yields no supported cookie AND has
    ///     no `;` separators → treated as a bare token verbatim. This catches
    ///     opaque tokens with base64 padding (`abc.def==`) that would
    ///     otherwise be mis-parsed as `abc.def=` = empty (an unsupported cookie
    ///     name).
    ///   - NextAuth chunked variants (`__Secure-next-auth.session-token.0`,
    ///     `.1`, …) → reassembled in index order under the base name; the
    ///     chunk index is bounded to defeat overflow / mass-allocation
    ///     attacks.
    /// Returns nil when the input yields no usable cookie.
    public static func extract(from rawInput: String) -> (name: String, token: String)? {
        var trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Strip an optional leading "Cookie:" header prefix in any casing
        // (Cookie:, cookie:, CoOkIe:, …). Some browsers' "Copy as HAR" /
        // "Copy request headers" tools return the whole header line; the
        // user should not have to hand-strip it. Truly ASCII case-insensitive
        // so no spelling permutation falls through into the bare-token
        // fallback and stores the header line as a token.
        let prefixToken = "cookie:"
        if trimmed.count >= prefixToken.count {
            let head = trimmed.prefix(prefixToken.count)
            if head.lowercased() == prefixToken {
                trimmed = String(trimmed.dropFirst(prefixToken.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !trimmed.isEmpty else { return nil }

        // Bare token — no `=`, no `;`. Send under the default name.
        if !trimmed.contains("="), !trimmed.contains(";") {
            return (defaultSessionCookieName, trimmed)
        }

        // Otherwise parse `k=v; k=v; …` pairs.
        var pairs: [(String, String)] = []
        for chunk in trimmed.split(separator: ";") {
            let piece = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let val = String(piece[piece.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !val.isEmpty {
                pairs.append((key, val))
            }
        }
        if let picked = pickSessionCookie(from: pairs) {
            return picked
        }
        // Fallback: the input contains an `=` but did NOT parse into a
        // supported session cookie AND has no `;` separators, so it is most
        // likely a bare opaque token whose payload happens to contain `=`
        // (e.g. base64 padding). Send it verbatim under the default name.
        //
        // Exception: if the name-part LOOKS like a session-cookie form
        // (starts with one of the supported base names, e.g. a chunked
        // variant that failed the index-bound check), do NOT fall back —
        // that would let a hostile chunked-index paste smuggle a bogus
        // token through the overflow guard.
        if !trimmed.contains(";"),
           let firstEq = trimmed.firstIndex(of: "="),
           !looksLikeSessionCookieName(String(trimmed[..<firstEq])) {
            return (defaultSessionCookieName, trimmed)
        }
        return nil
    }

    /// True when `raw` starts with (or equals, case-insensitively) any of
    /// the four supported session-cookie base names. Used to prevent the
    /// bare-token fallback from swallowing a malformed session-cookie paste.
    private static func looksLikeSessionCookieName(_ raw: String) -> Bool {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        for expected in supportedSessionCookieNames {
            let base = expected.lowercased()
            if lower == base { return true }
            if lower.hasPrefix(base + ".") { return true }
        }
        return false
    }

    /// Pick the highest-priority supported session cookie from a name/value
    /// list. Handles NextAuth chunked cookies by reassembling in index order.
    static func pickSessionCookie(from pairs: [(String, String)]) -> (name: String, token: String)? {
        // Build case-insensitive lookup by lowercased key.
        var byLoweredName: [String: (String, String)] = [:]
        var chunkedByBase: [String: [Int: String]] = [:]
        for (k, v) in pairs {
            let lower = k.lowercased()
            byLoweredName[lower] = (k, v)
            for expected in supportedSessionCookieNames {
                let base = expected.lowercased() + "."
                guard lower.hasPrefix(base) else { continue }
                let suffix = String(lower.dropFirst(base.count))
                // Bound the chunk index defensively: NextAuth's real chunk
                // indexes are 0..~10 (each ~4 KB). Reject indexes outside
                // [0, maxAllowedChunkIndex] so a hostile paste of
                // `…session-token.9223372036854775807=x` cannot overflow the
                // `maxIdx + 1` arithmetic in `reassemble`, nor force a
                // ~2 GB reserveCapacity.
                guard let idx = Int(suffix), idx >= 0, idx <= maxAllowedChunkIndex else { continue }
                chunkedByBase[expected.lowercased(), default: [:]][idx] = v
            }
        }

        // Prefer a whole cookie over its chunked variant when both are present.
        for expected in supportedSessionCookieNames {
            let lower = expected.lowercased()
            if let (originalName, value) = byLoweredName[lower] {
                return (originalName, value)
            }
            if let chunks = chunkedByBase[lower], let reassembled = reassemble(chunks: chunks) {
                return (expected, reassembled)
            }
        }
        return nil
    }

    /// Absolute cap on the NextAuth chunk index. Real deployments have never
    /// been observed above single digits; 64 is a generous ceiling that
    /// still prevents pathological allocation.
    static let maxAllowedChunkIndex: Int = 64

    private static func reassemble(chunks: [Int: String]) -> String? {
        guard let maxIdx = chunks.keys.max() else { return nil }
        // Redundant safety net — pickSessionCookie already caps at
        // maxAllowedChunkIndex, but reassemble may be reached via a future
        // caller. `maxIdx + 1` cannot overflow here because maxIdx is bounded.
        guard maxIdx >= 0, maxIdx <= maxAllowedChunkIndex else { return nil }
        var parts: [String] = []
        parts.reserveCapacity(maxIdx + 1)
        for i in 0 ... maxIdx {
            guard let piece = chunks[i] else { return nil }  // gap → refuse
            parts.append(piece)
        }
        return parts.joined()
    }
}

// MARK: - Fetcher

public struct PerplexityUsageFetcher: Sendable {

    public init() {}

    /// Keychain key under which the pasted cookie is stored (raw input as
    /// pasted; parsing runs at fetch time so a user can update the paste
    /// format without needing to re-enter).
    public static let cookieKeychainKey = "perplexity.session_cookie"

    // MARK: Endpoint parsing

    /// Parse the `/rest/billing/credits` body.
    public static func parseCredits(_ data: Data) throws -> PerplexityCredits {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PerplexityUsageParseError.invalidJSON
        }
        var out = PerplexityCredits()
        out.balanceCents = doubleOrZero(json["balance_cents"])
        // Clamp Unix-second timestamps to a sane range. A wild value
        // ("1e300") would create a pathological Date which then flows into
        // DateFormatter downstream. saneEpochOrZero rejects anything outside
        // [Jan 2000, Jan 2100] and returns 0 (treated by the store as "no
        // renewal date"). Verified with round-2 Codex review #4.
        out.renewalEpoch = saneEpochOrZero(json["renewal_date_ts"])
        out.currentPeriodPurchasedCents = doubleOrZero(json["current_period_purchased_cents"])
        out.totalUsageCents = doubleOrZero(json["total_usage_cents"])
        if let grants = json["credit_grants"] as? [[String: Any]] {
            out.grants = grants.compactMap { entry in
                guard let type = entry["type"] as? String else { return nil }
                return PerplexityCreditGrant(
                    type: type,
                    amountCents: doubleOrZero(entry["amount_cents"]),
                    expiresAtEpoch: saneEpochOrNil(entry["expires_at_ts"])
                )
            }
        }
        return out
    }

    /// Sane bounds for a Unix-seconds timestamp coming off an untrusted API.
    /// Jan 1 2000 UTC .. Jan 1 2100 UTC — anything outside is treated as
    /// missing / garbage so a `Date` derived from it stays inside Foundation's
    /// safe range.
    static let minSaneEpoch: Double = 946684800   // 2000-01-01 UTC
    static let maxSaneEpoch: Double = 4102444800  // 2100-01-01 UTC

    /// Coerce to a Double epoch inside the sane range, else return 0.
    static func saneEpochOrZero(_ value: Any?) -> Double {
        saneEpochOrNil(value) ?? 0
    }

    /// Coerce to a Double epoch inside the sane range, else return nil.
    static func saneEpochOrNil(_ value: Any?) -> Double? {
        guard let d = doubleOrNil(value), d.isFinite,
              d >= minSaneEpoch, d <= maxSaneEpoch else { return nil }
        return d
    }

    /// Parse the `/rest/rate-limit/all` body.
    public static func parseRateLimits(_ data: Data) throws -> PerplexityRateLimits {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PerplexityUsageParseError.invalidJSON
        }
        var out = PerplexityRateLimits()
        out.remainingPro = max(0, intOrZero(json["remaining_pro"]))
        out.remainingResearch = max(0, intOrZero(json["remaining_research"]))
        out.remainingLabs = max(0, intOrZero(json["remaining_labs"]))
        out.remainingAgenticResearch = max(0, intOrZero(json["remaining_agentic_research"]))

        if let sources = json["sources"] as? [String: Any],
           let map = sources["source_to_limit"] as? [String: Any] {
            var parsed: [PerplexitySourceLimit] = []
            parsed.reserveCapacity(map.count)
            for (sourceId, raw) in map {
                guard let entry = raw as? [String: Any] else { continue }
                parsed.append(PerplexitySourceLimit(
                    sourceId: sourceId,
                    monthlyLimit: intOrNil(entry["monthly_limit"]),
                    remaining: intOrNil(entry["remaining"])
                ))
            }
            // Sort for deterministic tile ordering / test equality.
            out.sources = parsed.sorted { $0.sourceId < $1.sourceId }
        }
        return out
    }

    /// Parse the `/rest/user/settings` body. Only fields that inform tiles
    /// are extracted; everything else in the response is intentionally
    /// ignored to keep the parser resilient to churn on unrelated flags.
    public static func parseUserSettings(_ data: Data) throws -> PerplexityUserSettings {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PerplexityUsageParseError.invalidJSON
        }
        var out = PerplexityUserSettings()
        out.subscriptionStatus = json["subscription_status"] as? String
        out.subscriptionSource = json["subscription_source"] as? String
        out.subscriptionTier = json["subscription_tier"] as? String
        out.pagesLimit = max(0, intOrZero(json["pages_limit"]))
        out.uploadLimit = max(0, intOrZero(json["upload_limit"]))
        out.createLimit = max(0, intOrZero(json["create_limit"]))
        out.queryCount = max(0, intOrZero(json["query_count"]))
        return out
    }

    // MARK: Number coercion

    /// Int coercion. Accepts Int, finite Double (rounded), or a numeric
    /// string. Returns nil rather than trapping on a non-finite / oversize
    /// Double (`Int(1e300)` traps; `Int(exactly:)` does not).
    static func intOrNil(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double {
            guard d.isFinite else { return nil }
            return Int(exactly: d.rounded())
        }
        if let s = value as? String {
            return Int(s) ?? Double(s).flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil }
        }
        return nil
    }

    static func intOrZero(_ value: Any?) -> Int {
        intOrNil(value) ?? 0
    }

    /// Double coercion. Nil is returned only for a non-finite Double or a
    /// truly missing field; strings are parsed defensively.
    static func doubleOrNil(_ value: Any?) -> Double? {
        if let d = value as? Double { return d.isFinite ? d : nil }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s).flatMap { $0.isFinite ? $0 : nil } }
        return nil
    }

    static func doubleOrZero(_ value: Any?) -> Double {
        doubleOrNil(value) ?? 0
    }
}
