// PR 7-BE — OpenAI Platform usage fetcher (developer API, Admin key).
//
// Reads an OpenAI ORGANIZATION's usage, cost, and configured rate limits via
// an Admin key (sk-admin-...). Admin keys can view billing and manage users
// but cannot make inference calls; the UI gates the paste behind a warning.
//
// Feature posture: features.openai.enabled defaults false; nothing registers
// a store into the live registry yet (tile + admin-key sheet land in PR 7-UI).
//
// Endpoints (all officially documented, Authorization: Bearer sk-admin-...):
//   GET /v1/organization/usage/completions?bucket_width=1d&group_by=model
//       -> tokens + request counts by model, bucketed by time.
//   GET /v1/organization/costs?bucket_width=1d&start_time=<month start>
//       -> spend by line item, bucketed; amount.value is USD dollars.
//   GET /v1/organization/projects/{project_id}/rate_limits
//       -> configured per-model RPM/TPM ceilings.
//
// The usage + costs endpoints share a bucketed page shape:
//   { "object": "page", "data": [ { "object": "bucket", "start_time": Int,
//     "end_time": Int, "results": [ <result> ] } ], "has_more": Bool,
//     "next_page": String|null }
// Results differ per endpoint. This fetcher parses each into flat aggregates
// the tiles consume.

import Foundation

// MARK: - Snapshot pieces

/// Per-model token totals aggregated across the returned usage buckets.
public struct OpenAIModelTokens: Equatable, Sendable {
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var requests: Int

    public init(model: String, inputTokens: Int = 0, outputTokens: Int = 0, requests: Int = 0) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.requests = requests
    }

    public var totalTokens: Int { inputTokens + outputTokens }
}

/// Per-model configured rate-limit ceilings (context, not remaining).
public struct OpenAIRateLimit: Equatable, Sendable {
    public var model: String
    public var maxRequestsPerMinute: Int?
    public var maxTokensPerMinute: Int?

    public init(model: String, maxRequestsPerMinute: Int? = nil, maxTokensPerMinute: Int? = nil) {
        self.model = model
        self.maxRequestsPerMinute = maxRequestsPerMinute
        self.maxTokensPerMinute = maxTokensPerMinute
    }
}

public struct OpenAIUsageSnapshot: Equatable, Sendable {
    /// Per-model token usage over the queried window (last 24h by default).
    public var tokensByModel: [OpenAIModelTokens]
    /// Month-to-date spend in USD, summed across cost buckets/line items.
    public var costMTDUSD: Double
    public var costCurrency: String?
    /// Configured per-model rate-limit ceilings.
    public var rateLimits: [OpenAIRateLimit]

    public init(
        tokensByModel: [OpenAIModelTokens] = [],
        costMTDUSD: Double = 0,
        costCurrency: String? = nil,
        rateLimits: [OpenAIRateLimit] = []
    ) {
        self.tokensByModel = tokensByModel
        self.costMTDUSD = costMTDUSD
        self.costCurrency = costCurrency
        self.rateLimits = rateLimits
    }
}

public enum OpenAIUsageParseError: Error, Equatable {
    case invalidJSON
    case unexpectedShape(String)
}

// MARK: - Fetcher

public struct OpenAIUsageFetcher: Sendable {

    public init() {}

    public static let adminKeyKeychainKey = "openai.admin_key"

    /// Iterate the `data[].results[]` buckets of a page response, calling
    /// `handle` for each result dictionary. Shared by usage and costs.
    private static func forEachResult(_ json: [String: Any], _ handle: ([String: Any]) -> Void) {
        guard let buckets = json["data"] as? [[String: Any]] else { return }
        for bucket in buckets {
            guard let results = bucket["results"] as? [[String: Any]] else { continue }
            for result in results { handle(result) }
        }
    }

    /// Parse GET /v1/organization/usage/completions. Aggregates token and
    /// request counts by model across all buckets. When group_by=model is
    /// not set, results carry no model field and fold into an "all" bucket.
    public static func parseCompletions(_ data: Data) throws -> [OpenAIModelTokens] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIUsageParseError.invalidJSON
        }
        var byModel: [String: OpenAIModelTokens] = [:]
        forEachResult(json) { result in
            let model = (result["model"] as? String) ?? "all"
            var entry = byModel[model] ?? OpenAIModelTokens(model: model)
            entry.inputTokens += intOr0(result["input_tokens"])
            entry.outputTokens += intOr0(result["output_tokens"])
            entry.requests += intOr0(result["num_model_requests"])
            byModel[model] = entry
        }
        // Stable order: highest total tokens first.
        return byModel.values.sorted { $0.totalTokens > $1.totalTokens }
    }

    /// Parse GET /v1/organization/costs. Sums `amount.value` (USD dollars)
    /// across all buckets/line items. Returns the total and the currency.
    public static func parseCosts(_ data: Data) throws -> (usd: Double, currency: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIUsageParseError.invalidJSON
        }
        var total = 0.0
        var currency: String?
        forEachResult(json) { result in
            guard let amount = result["amount"] as? [String: Any] else { return }
            total += doubleOr0(amount["value"])
            if currency == nil { currency = amount["currency"] as? String }
        }
        return (total, currency)
    }

    /// Parse GET /v1/organization/projects/{id}/rate_limits.
    public static func parseRateLimits(_ data: Data) throws -> [OpenAIRateLimit] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIUsageParseError.invalidJSON
        }
        guard let arr = json["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { entry in
            guard let model = entry["model"] as? String else { return nil }
            return OpenAIRateLimit(
                model: model,
                maxRequestsPerMinute: intOrNil(entry["max_requests_per_1_minute"]),
                maxTokensPerMinute: intOrNil(entry["max_tokens_per_1_minute"])
            )
        }
    }

    // MARK: Helpers

    private static func intOr0(_ v: Any?) -> Int { intOrNil(v) ?? 0 }
    private static func doubleOr0(_ v: Any?) -> Double { doubleOrNil(v) ?? 0 }

    private static func intOrNil(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
    private static func doubleOrNil(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }
}
