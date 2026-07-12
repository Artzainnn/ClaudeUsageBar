// PR 9-BE — GitHub Copilot usage fetcher (fine-grained PAT).
//
// Seventh non-Anthropic provider. Reads GitHub's public REST billing
// endpoint for the authenticated user's AI Credit spend:
//   GET /users/{username}/settings/billing/ai_credit/usage
// on api.github.com, with a fine-grained PAT carrying the `Plan (Read)`
// permission (Account permissions section). Verified against the mid-2026
// canonical OpenAPI spec (github/rest-api-description, API version
// 2026-03-10) and against docs.github.com/en/rest/billing/usage.
//
// Feature posture: features.copilot.enabled defaults false. Nothing
// registers a store into the live registry yet (the tile + Settings PAT
// paste sheet land in PR 9-UI). This file is compiled and unit-tested but
// inert at runtime until enabled.
//
// Deliberately out of scope for PR 9-BE (deferred to a follow-up PR if
// there's user demand):
//   - OAuth Device Flow to a bespoke ClaudeUsageBar GitHub App. Requires
//     a pre-registered client_id and a device-code prompt UX — meaningful
//     additional surface area. PAT paste (the same UX as DeepSeek/xAI/
//     OpenAI) is the shipped path for this milestone.
//   - The internal copilot_internal/* endpoints. GitHub explicitly does
//     not permit third-party clients to hit them, abuse-detection has
//     suspended accounts using them (github/copilot-language-server-release
//     #10), and their client_id gating (Iv1.b507a08c87ecfe98, VS Code
//     Copilot's own OAuth App id) means a bespoke GitHub App token would
//     be rejected anyway.
//
// Credential posture: the PAT is a spending credential (can view billing,
// scope-appropriate account info). Stored in KeychainStore, never logged.
// Only HTTP status codes go through Log.info(.count).

import Foundation

// MARK: - Snapshot pieces

/// One entry from `usageItems[]`. Every field is present on the wire for a
/// populated report (verified against the OpenAPI spec's required list); we
/// parse defensively so a schema tweak that adds/removes an optional field
/// does not throw.
public struct CopilotUsageItem: Equatable, Sendable {
    /// e.g. "Copilot AI Credits", "Copilot" for premium requests.
    public var product: String
    /// e.g. "AI Credit", "Copilot Premium Request".
    public var sku: String
    /// Model name, e.g. "GPT-5". Optional in some SKUs.
    public var model: String?
    /// e.g. "ai-credits", "requests". Do NOT gate the credit line on this
    /// field — SKU strings are the reliable discriminator per the research
    /// report (docs render `unitType: "credits"` in one place and
    /// `"ai-credits"` in another).
    public var unitType: String
    /// Per-unit price in USD. Fixed at 0.01 for AI Credit today.
    public var pricePerUnit: Double
    /// Total volume before any included allowance is applied. May be
    /// fractional (some captures show float grossQuantity like 3956.1799545)
    /// — do NOT decode as Int.
    public var grossQuantity: Double
    /// Gross USD amount (pricePerUnit * grossQuantity).
    public var grossAmount: Double
    /// Allowance already consumed within the included per-plan bucket.
    public var discountQuantity: Double
    public var discountAmount: Double
    /// Chargeable overage quantity (gross minus discount).
    public var netQuantity: Double
    /// Chargeable overage in USD. This is what the MTD tile sums.
    public var netAmount: Double

    public init(
        product: String,
        sku: String,
        model: String? = nil,
        unitType: String,
        pricePerUnit: Double,
        grossQuantity: Double,
        grossAmount: Double,
        discountQuantity: Double,
        discountAmount: Double,
        netQuantity: Double,
        netAmount: Double
    ) {
        self.product = product
        self.sku = sku
        self.model = model
        self.unitType = unitType
        self.pricePerUnit = pricePerUnit
        self.grossQuantity = grossQuantity
        self.grossAmount = grossAmount
        self.discountQuantity = discountQuantity
        self.discountAmount = discountAmount
        self.netQuantity = netQuantity
        self.netAmount = netAmount
    }
}

/// Parsed `/settings/billing/ai_credit/usage` body. `timePeriod` and `user`
/// are always present on a 200; `usageItems` can legitimately be `[]` when
/// the user's Copilot licence is billed through an organisation/enterprise
/// (the personal endpoint returns 200 with an empty array, NOT a 404).
public struct CopilotUsageSnapshot: Equatable, Sendable {
    public var year: Int
    public var month: Int?
    public var day: Int?
    public var user: String
    /// Optional top-level filter echo — the endpoint returns whatever
    /// `product` filter was requested, or nil when no filter.
    public var product: String?
    /// Same, for `model` filter.
    public var model: String?
    /// One entry per (SKU × model) combination for the requested period.
    public var items: [CopilotUsageItem]

    public init(
        year: Int = 0,
        month: Int? = nil,
        day: Int? = nil,
        user: String = "",
        product: String? = nil,
        model: String? = nil,
        items: [CopilotUsageItem] = []
    ) {
        self.year = year
        self.month = month
        self.day = day
        self.user = user
        self.product = product
        self.model = model
        self.items = items
    }

    /// Sum of `netAmount` across items — this is what the tile displays as
    /// "MTD spend". `max(0, …)` guards against a hostile server that emits
    /// negative amounts.
    public var netAmountMTDUSD: Double {
        max(0, items.reduce(0.0) { $0 + $1.netAmount })
    }

    /// Grouping helper for a "by SKU" breakdown tile. Ordered by
    /// descending net amount so the biggest line item is first.
    public var itemsBySkuDescending: [CopilotUsageItem] {
        items.sorted { $0.netAmount > $1.netAmount }
    }

    /// True when the endpoint returned a 200 with an empty items array —
    /// the documented signal that the user's Copilot licence is managed
    /// through an org/enterprise seat and the personal endpoint carries
    /// no data for them.
    public var isEmptyOrgBilled: Bool {
        items.isEmpty
    }
}

public enum CopilotUsageParseError: Error, Equatable {
    case invalidJSON
    case unexpectedShape(String)
}

// MARK: - Fetcher

public struct CopilotUsageFetcher: Sendable {

    public init() {}

    /// Keychain key under which the fine-grained PAT is stored.
    public static let patKeychainKey = "copilot.pat_token"

    /// Keychain key under which the user's GitHub login (needed for the
    /// path parameter) is stored. We derive this from the PAT via the
    /// `/user` endpoint at fetch time and persist it so subsequent fetches
    /// skip the extra round-trip.
    public static let loginKeychainKey = "copilot.github_login"

    /// GitHub REST API version this parser was verified against. Pinned so
    /// a client-driven change to a new schema is deliberate. Sunset for
    /// the previous version (2022-11-28) is 10 March 2028; migrating past
    /// then is a separate future PR.
    public static let apiVersion = "2026-03-10"

    // MARK: - Parsers

    /// Parse the `ai_credit/usage` response.
    public static func parseUsage(_ data: Data) throws -> CopilotUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CopilotUsageParseError.invalidJSON
        }
        // Codex round-1 finding #6: `usageItems` is REQUIRED per the
        // OpenAPI 2026-03-10 spec. A missing key is a schema violation
        // (proxy stripped it, GitHub broke the response) — NOT the same
        // as the documented `usageItems: []` "org-billed" signal, which
        // is an empty array. Refuse the missing case so we surface a
        // parse error rather than mis-labelling as org-billed.
        guard let items = json["usageItems"] as? [[String: Any]] else {
            throw CopilotUsageParseError.unexpectedShape("usageItems missing")
        }

        var snap = CopilotUsageSnapshot()
        if let period = json["timePeriod"] as? [String: Any] {
            snap.year = intOrZero(period["year"])
            snap.month = intOrNil(period["month"])
            snap.day = intOrNil(period["day"])
        }
        snap.user = (json["user"] as? String) ?? ""
        snap.product = json["product"] as? String
        snap.model = json["model"] as? String
        snap.items = items.compactMap { parseItem($0) }
        return snap
    }

    private static func parseItem(_ entry: [String: Any]) -> CopilotUsageItem? {
        // sku and product are the load-bearing discriminators; refuse an
        // item that lacks either rather than smuggling in an empty-string
        // line.
        guard let product = entry["product"] as? String, !product.isEmpty,
              let sku = entry["sku"] as? String, !sku.isEmpty else {
            return nil
        }
        return CopilotUsageItem(
            product: product,
            sku: sku,
            model: entry["model"] as? String,
            unitType: (entry["unitType"] as? String) ?? "",
            pricePerUnit: doubleOrZero(entry["pricePerUnit"]),
            grossQuantity: doubleOrZero(entry["grossQuantity"]),
            grossAmount: doubleOrZero(entry["grossAmount"]),
            discountQuantity: doubleOrZero(entry["discountQuantity"]),
            discountAmount: doubleOrZero(entry["discountAmount"]),
            netQuantity: doubleOrZero(entry["netQuantity"]),
            netAmount: doubleOrZero(entry["netAmount"])
        )
    }

    /// Parse `GET /user` (used to discover the authenticated user's login
    /// for the billing endpoint's `{username}` path parameter). Only the
    /// `login` field is consumed.
    public static func parseAuthenticatedUserLogin(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String, !login.isEmpty else {
            throw CopilotUsageParseError.unexpectedShape("missing user.login")
        }
        return login
    }

    // MARK: - Numeric coercion

    /// Int coercion. Rejects non-finite / oversize Doubles rather than
    /// trapping. Accepts numeric strings defensively (some third-party
    /// GitHub proxies stringify small integers).
    static func intOrNil(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double {
            guard d.isFinite else { return nil }
            return Int(exactly: d.rounded())
        }
        if let s = value as? String { return Int(s) }
        return nil
    }
    static func intOrZero(_ value: Any?) -> Int { intOrNil(value) ?? 0 }

    /// Double coercion. Non-finite → nil. Preserves fractional precision
    /// (GitHub's grossQuantity has been observed as 3956.1799545).
    static func doubleOrNil(_ value: Any?) -> Double? {
        if let d = value as? Double { return d.isFinite ? d : nil }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s).flatMap { $0.isFinite ? $0 : nil } }
        return nil
    }
    static func doubleOrZero(_ value: Any?) -> Double { doubleOrNil(value) ?? 0 }
}
