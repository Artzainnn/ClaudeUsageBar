// PR 6-BE — xAI Developer usage fetcher (two-key, two-host).
//
// xAI is the first two-credential provider:
//   - Tier 1 (mandatory): an INFERENCE key (xai-...). Bootstraps team_id and
//     the model catalogue from api.x.ai. Gives plan info but no spend.
//   - Tier 2 (optional): a MANAGEMENT key. Reads the prepaid balance and
//     daily usage from management-api.x.ai. NB the management key also carries
//     the `xai-` prefix (it is NOT literally `xai-mgmt-`); it is a distinct
//     key issued from the console's Management Keys section, not
//     interchangeable with the inference key. Management keys can create /
//     rotate / delete API keys, so Tier 2 is gated behind an explicit warning
//     in the UI (PR 6-UI). Both keys live in the Keychain.
//
// Feature posture: features.xai.enabled defaults false; nothing registers a
// store into the live registry yet (tile + two-key sheet land in PR 6-UI).
//
// Hosts and auth (both Bearer):
//   api.x.ai            — inference key: GET /v1/api-key, GET /v1/language-models
//   management-api.x.ai — management key: GET  /v1/billing/teams/{team}/prepaid/balance
//                                          POST /v1/billing/teams/{team}/usage
//
// The prepaid-balance `total.val` unit and sign convention are the single
// riskiest interpretation here (the plan flags a live curl check before
// ship). To keep that correction cheap, ALL unit/sign logic lives in one
// documented function, `XAIBalance.remainingUSD`, and the parser stores the
// raw integer verbatim. See the note there.

import Foundation

// MARK: - Snapshot pieces

/// Result of GET /v1/api-key. Bootstraps the team id used for the management
/// endpoints, and carries the ACL list used to describe the plan/permissions.
public struct XAIApiKeyInfo: Equatable, Sendable {
    public var teamId: String?
    public var acls: [String]
    /// Redacted key label for display (never the raw key).
    public var redactedKey: String?
    public var name: String?

    public init(teamId: String? = nil, acls: [String] = [], redactedKey: String? = nil, name: String? = nil) {
        self.teamId = teamId
        self.acls = acls
        self.redactedKey = redactedKey
        self.name = name
    }
}

/// One model from GET /v1/language-models.
public struct XAIModel: Equatable, Sendable {
    public var id: String
    /// Prompt (input) price per token, in the unit the endpoint returns
    /// (xAI uses 1e-10 USD ticks per token for completion pricing). Stored
    /// verbatim; conversion is the tile's concern, not the fetcher's.
    public var promptTokenPrice: Int?
    public var completionTokenPrice: Int?

    public init(id: String, promptTokenPrice: Int? = nil, completionTokenPrice: Int? = nil) {
        self.id = id
        self.promptTokenPrice = promptTokenPrice
        self.completionTokenPrice = completionTokenPrice
    }
}

/// Prepaid balance from the management API.
public struct XAIBalance: Equatable, Sendable {
    /// The raw `total.val` integer, stored verbatim. Interpretation (unit +
    /// sign) is deliberately isolated in `remainingUSD` so it can be
    /// corrected after a live account check without touching the parser.
    public var totalValRaw: Int
    /// Currency code if the endpoint returns one (e.g. "USD").
    public var currency: String?

    public init(totalValRaw: Int, currency: String? = nil) {
        self.totalValRaw = totalValRaw
        self.currency = currency
    }

    /// Convert the raw `total.val` into remaining USD.
    ///
    /// UNIT + SIGN — the one place this interpretation lives, verified against
    /// xAI's management-API OpenAPI schema (the `total` object is documented
    /// as "Representation of USD Cents"):
    ///   - Unit: `total.val` is USD CENTS (1/100 USD). Divide by 100 for
    ///     dollars. NOTE: this is NOT the 1e-10 "tick" unit — that unit
    ///     applies to per-token MODEL PRICING (lineItem.unitPrice, documented
    ///     as 1/1_000_000 USD cents), not to the balance total. Getting this
    ///     wrong is an 8-order-of-magnitude error, so it is isolated here.
    ///   - Sign: the ledger convention makes credit-adding events negative and
    ///     spend positive, so `total.val` is NEGATIVE when prepaid credit
    ///     remains. Remaining credit in cents is `-val`; a zero or positive
    ///     value means no prepaid credit left (clamp to 0).
    /// `val` arrives as a string-encoded int64 on the wire; the parser stores
    /// it as an Int. A live curl check against a paid account can still
    /// correct this single function if the account data contradicts the docs.

    /// Per-token model pricing is expressed in 1/1_000_000 USD cents
    /// (micro-cents). Distinct from the balance unit above.
    public static let modelPriceMicroCentsPerCent = 1_000_000.0

    public var remainingUSD: Double {
        // Negative val = remaining credit; clamp non-negative val to 0.
        max(-Double(totalValRaw), 0) / 100.0
    }
}

/// One day's usage from the management usage endpoint.
public struct XAIDailyUsage: Equatable, Sendable {
    public var date: String   // ISO date (YYYY-MM-DD) as returned
    public var usdSpent: Double

    public init(date: String, usdSpent: Double) {
        self.date = date
        self.usdSpent = usdSpent
    }
}

/// Aggregate snapshot. Tier-1 fields are always present when configured;
/// Tier-2 fields (balance, daily) are nil until a management key is added.
public struct XAIUsageSnapshot: Equatable, Sendable {
    public var apiKeyInfo: XAIApiKeyInfo?
    public var models: [XAIModel]
    public var balance: XAIBalance?
    public var daily: [XAIDailyUsage]

    public init(
        apiKeyInfo: XAIApiKeyInfo? = nil,
        models: [XAIModel] = [],
        balance: XAIBalance? = nil,
        daily: [XAIDailyUsage] = []
    ) {
        self.apiKeyInfo = apiKeyInfo
        self.models = models
        self.balance = balance
        self.daily = daily
    }
}

public enum XAIUsageParseError: Error, Equatable {
    case invalidJSON
    case unexpectedShape(String)
}

// MARK: - Fetcher

public struct XAIUsageFetcher: Sendable {

    public init() {}

    /// Keychain keys for the two credentials.
    public static let inferenceKeyKeychainKey = "xai.inference_key"
    public static let managementKeyKeychainKey = "xai.management_key"

    // MARK: Tier 1 parsing

    /// Parse GET /v1/api-key. Tolerant of absent fields; the team_id is the
    /// one field the management endpoints depend on.
    public static func parseApiKey(_ data: Data) throws -> XAIApiKeyInfo {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XAIUsageParseError.invalidJSON
        }
        var info = XAIApiKeyInfo()
        // xAI has used both "team_id" and "teamId"; accept either.
        info.teamId = (json["team_id"] as? String) ?? (json["teamId"] as? String)
        if let acls = json["acls"] as? [String] {
            info.acls = acls
        }
        info.redactedKey = (json["redacted_api_key"] as? String) ?? (json["redactedApiKey"] as? String)
        info.name = json["name"] as? String
        return info
    }

    /// Parse GET /v1/language-models. The models live under a top-level
    /// "models" or "data" array depending on API version.
    public static func parseLanguageModels(_ data: Data) throws -> [XAIModel] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XAIUsageParseError.invalidJSON
        }
        let arr = (json["models"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) ?? []
        return arr.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return XAIModel(
                id: id,
                promptTokenPrice: intOrNil(entry["prompt_text_token_price"] ?? entry["prompt_token_price"]),
                completionTokenPrice: intOrNil(entry["completion_text_token_price"] ?? entry["completion_token_price"])
            )
        }
    }

    // MARK: Tier 2 parsing

    /// Parse the prepaid balance. Stores `total.val` verbatim; the unit/sign
    /// interpretation is in XAIBalance.remainingUSD.
    public static func parseBalance(_ data: Data) throws -> XAIBalance {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XAIUsageParseError.invalidJSON
        }
        // Balance may be under "total" or at the top level.
        let total = (json["total"] as? [String: Any]) ?? json
        guard let val = intOrNil(total["val"]) else {
            throw XAIUsageParseError.unexpectedShape("balance total.val missing")
        }
        let currency = (total["currency"] as? String) ?? (json["currency"] as? String)
        return XAIBalance(totalValRaw: val, currency: currency)
    }

    /// Parse the daily-usage response into date/USD points. Tolerant of the
    /// exact bucket shape: looks for a list of records each carrying a date
    /// and a USD amount (in ticks or dollars — see note).
    public static func parseUsage(_ data: Data) throws -> [XAIDailyUsage] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XAIUsageParseError.invalidJSON
        }
        // The daily buckets live under "usage", "data", or "daily".
        let buckets = (json["usage"] as? [[String: Any]])
            ?? (json["data"] as? [[String: Any]])
            ?? (json["daily"] as? [[String: Any]])
            ?? []
        return buckets.compactMap { bucket in
            guard let date = (bucket["date"] as? String) ?? (bucket["day"] as? String) else { return nil }
            // USD may be a dollar Double, or a cents Int (same unit as the
            // balance total). Prefer an explicit dollar field; fall back to a
            // cents field divided by 100. The exact daily-usage field names
            // are not documented, so this stays tolerant.
            let usd: Double
            if let d = doubleOrNil(bucket["usd"] ?? bucket["total_usd"] ?? bucket["amount_usd"]) {
                usd = d
            } else if let cents = intOrNil(bucket["cents"] ?? bucket["usd_cents"] ?? bucket["amount_cents"]) {
                usd = Double(cents) / 100.0
            } else {
                usd = 0
            }
            return XAIDailyUsage(date: date, usdSpent: usd)
        }
    }

    // MARK: Helpers

    private static func intOrNil(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func doubleOrNil(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
