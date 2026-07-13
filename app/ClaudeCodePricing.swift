// PR 10b-BE — Claude model pricing snapshot for local cost computation.
//
// Snapshot of LiteLLM's `model_prices_and_context_window.json`, filtered
// to Anthropic-direct Claude models (no Bedrock, no Vertex — Claude Code
// hits api.anthropic.com). Snapshot date: 13 Jul 2026.
//
// Source: https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json
//
// Rate structure per model
// ------------------------
//   input_cost_per_token          — regular input tokens, USD per token
//   output_cost_per_token         — output tokens, USD per token
//   cache_creation_input_token_cost           — ephemeral_5m tier
//   cache_creation_input_token_cost_above_1hr — ephemeral_1h tier
//                                               (may be absent — older
//                                                models pre-dating the
//                                                1h tier fall back to
//                                                the 5m rate)
//   cache_read_input_token_cost               — cache-read tokens
//
// Sonnet-4 family adds "_above_200k_tokens" variants: once the input
// context in a single request exceeds 200 000 tokens, every input
// category shifts to the tiered rate. `_above_1hr_above_200k_tokens`
// crosses both dimensions for models that expose it. Threshold is
// computed from `inputTokens + cache*Tokens` on the SAME record — this
// matches Anthropic's per-request billing model, not a session-cumulative
// sum.
//
// Refresh discipline
// ------------------
// Bundled as a Swift literal so the app has no runtime GitHub-raw fetch
// dependency. A monthly background refresh from the upstream LiteLLM
// table is possible (out of scope for PR 10b-BE; the store surfaces
// `unknownModelRecordCount` on the snapshot so a future PR can prompt
// for an update). Users on a build older than a Claude release get
// TOKEN counts but $0 cost for the new model — never a wrong number.

import Foundation

/// Pricing snapshot with per-model rate rows. `default` bundles the
/// embedded LiteLLM extract; tests inject `ClaudeCodePricing(rates:)`
/// with synthetic values.
public struct ClaudeCodePricing: Sendable {

    /// Per-model rate dictionary. Keys are LiteLLM field names verbatim
    /// so the mapping to the source is auditable.
    public let rates: [String: [String: Double]]

    public init(rates: [String: [String: Double]]) {
        self.rates = rates
    }

    /// Compute USD cost for one record. Returns `(cost, isUnknownModel)`
    /// — the second bool signals "no pricing row for this model" so the
    /// caller can count unknown-model records for the pricing-refresh
    /// prompt.
    ///
    /// Threshold logic: if `inputTokens + cache*Tokens > 200_000` we
    /// switch to the tiered rate for models that have it. Sonnet-4-5
    /// and Sonnet-4-family expose the tier; every other model returns
    /// the base rate regardless (there is no tier to apply).
    public func cost(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreation5mTokens: Int,
        cacheCreation1hTokens: Int,
        cacheReadTokens: Int
    ) -> (costUSD: Double, isUnknownModel: Bool) {
        guard let row = rates[model] else {
            return (0.0, true)
        }

        // Codex round-2 finding #2: use saturating addition for the
        // threshold check. `Int64 &+` wraps to negative, so a hostile
        // clamped-to-Int.max input could make aboveTier false and
        // silently under-price a legitimate long-context Sonnet request.
        // Short-circuit as soon as we know we're above the threshold.
        let threshold = 200_000
        var runningInput = min(threshold + 1, max(0, inputTokens))
        if runningInput <= threshold {
            runningInput = ClaudeCodeUsageRecord
                .saturatingAdd(runningInput, cacheCreation5mTokens)
        }
        if runningInput <= threshold {
            runningInput = ClaudeCodeUsageRecord
                .saturatingAdd(runningInput, cacheCreation1hTokens)
        }
        if runningInput <= threshold {
            runningInput = ClaudeCodeUsageRecord
                .saturatingAdd(runningInput, cacheReadTokens)
        }
        let aboveTier = runningInput > threshold

        // Rate helpers — pick the tiered rate when available and the
        // request crosses the threshold; otherwise the base rate. Never
        // fall through to a wrong rate — a missing base rate means the
        // model row is malformed and we treat that category as $0.
        func rate(base: String, tier: String) -> Double {
            if aboveTier, let tiered = row[tier] { return tiered }
            return row[base] ?? 0.0
        }
        // Cache-creation-1hr uses the base rate when the tier-1hr field
        // is missing (older models pre-dating the 1h tier). Codex
        // round-2 finding #3: when the request crosses BOTH dimensions
        // and the exact double-cross rate is missing, use MAX of the
        // two single-dimension rates rather than one arbitrarily — the
        // 1h premium and the >200k premium are independent, so
        // charging only one dimension undercharges the customer
        // consistently. `max()` preserves the correct sign of the
        // pricing correction (never undercharges) even if the LiteLLM
        // table is missing a row.
        func cacheCreation1hRate() -> Double {
            let base = row["cache_creation_input_token_cost"] ?? 0.0
            let above1hr = row["cache_creation_input_token_cost_above_1hr"]
            let above200k = row["cache_creation_input_token_cost_above_200k_tokens"]
            let doubleCross = row["cache_creation_input_token_cost_above_1hr_above_200k_tokens"]

            if aboveTier {
                if let r = doubleCross { return r }
                // At least one of these should apply — pick the higher
                // (worst-case) rate if both are present.
                switch (above1hr, above200k) {
                case let (a?, b?): return max(a, b)
                case let (a?, nil): return a
                case let (nil, b?): return b
                case (nil, nil):    return base
                }
            }
            return above1hr ?? base
        }

        let inputRate = rate(
            base: "input_cost_per_token",
            tier: "input_cost_per_token_above_200k_tokens"
        )
        let outputRate = rate(
            base: "output_cost_per_token",
            tier: "output_cost_per_token_above_200k_tokens"
        )
        let cacheCreation5mRate = rate(
            base: "cache_creation_input_token_cost",
            tier: "cache_creation_input_token_cost_above_200k_tokens"
        )
        let cacheReadRate = rate(
            base: "cache_read_input_token_cost",
            tier: "cache_read_input_token_cost_above_200k_tokens"
        )

        let total = Double(inputTokens) * inputRate
            + Double(outputTokens) * outputRate
            + Double(cacheCreation5mTokens) * cacheCreation5mRate
            + Double(cacheCreation1hTokens) * cacheCreation1hRate()
            + Double(cacheReadTokens) * cacheReadRate

        return (total, false)
    }

    /// True when the pricing table contains a row for `model`.
    public func hasModel(_ model: String) -> Bool {
        rates[model] != nil
    }

    /// The default snapshot, bundled into the binary. Access this
    /// through `.default` rather than referencing `embeddedRates`
    /// directly — future refresh paths will overlay a downloaded file
    /// on top of the embedded default.
    public static let `default` = ClaudeCodePricing(rates: embeddedRates)

    // MARK: - Snapshot content
    //
    // Do NOT edit these numbers by hand. Regenerate from the LiteLLM
    // source by running the script in scripts/regenerate-pricing.py
    // (added under PR 10b-BE). Snapshot date lives in the header
    // comment above so a future contributor can measure staleness.
    public static let snapshotDate: String = "2026-07-13"

    // NOTE for reviewers: the field names below are LiteLLM's, not
    // Anthropic's. LiteLLM's `cache_creation_input_token_cost_above_1hr`
    // is what Anthropic documents as the 1h ephemeral-cache creation
    // rate (a distinct rate, NOT a 2× multiplier — an earlier draft of
    // the EXPANSION_PLAN suggested a 2× multiplier and this snapshot
    // supersedes that plan text).
    /// Backing snapshot dictionary. Public so tests can iterate every
    /// row for invariant checks (1h rate >= 5m rate, tiered rate >= base,
    /// etc.). Not intended for runtime use — read `.default.rates`.
    public static let embeddedRates: [String: [String: Double]] = [
        // Codex round-4 finding #1: LiteLLM does NOT have Anthropic-direct
        // rows for Claude 3.5 Sonnet or 3.5 Haiku (they only exist under
        // bedrock.* keys), but Claude Code emits the bare
        // "claude-3-5-sonnet-20241022" / "claude-3-5-haiku-20241022"
        // model ids for direct-API sessions. Historical sessions would
        // otherwise price at $0. Rates below are the Anthropic-direct
        // published rates as of the snapshot date (mirroring the bedrock
        // us-east-1 pricing that LiteLLM does have).
        "claude-3-5-sonnet-20241022": [
            "cache_creation_input_token_cost": 3.75e-06,
            "cache_read_input_token_cost": 3e-07,
            "input_cost_per_token": 3e-06,
            "output_cost_per_token": 1.5e-05,
        ],
        "claude-3-5-sonnet-20240620": [
            "cache_creation_input_token_cost": 3.75e-06,
            "cache_read_input_token_cost": 3e-07,
            "input_cost_per_token": 3e-06,
            "output_cost_per_token": 1.5e-05,
        ],
        "claude-3-5-haiku-20241022": [
            "cache_creation_input_token_cost": 1e-06,
            "cache_read_input_token_cost": 8e-08,
            "input_cost_per_token": 8e-07,
            "output_cost_per_token": 4e-06,
        ],
        "claude-3-7-sonnet-20250219": [
            "cache_creation_input_token_cost": 3.75e-06,
            "cache_creation_input_token_cost_above_1hr": 6e-06,
            "cache_read_input_token_cost": 3e-07,
            "input_cost_per_token": 3e-06,
            "output_cost_per_token": 1.5e-05,
        ],
        "claude-3-haiku-20240307": [
            "cache_creation_input_token_cost": 3e-07,
            // Codex round-2 finding #4: LiteLLM's
            // `cache_creation_input_token_cost_above_1hr = 6e-06` for
            // Claude 3 Haiku is inconsistent — it's higher than the 5m
            // rate but far above the Anthropic-documented "2× input"
            // pattern (2× 2.5e-07 = 5e-07). The LiteLLM row appears to
            // have been mis-copied from a Sonnet row. We omit the
            // wrong `_above_1hr` field so cache-creation-1h falls back
            // to the base 5m rate (defensive: never OVER-charge based
            // on a wrong upstream value; a small under-charge on this
            // legacy model is preferable to a 20× over-charge).
            "cache_read_input_token_cost": 3e-08,
            "input_cost_per_token": 2.5e-07,
            "output_cost_per_token": 1.25e-06,
        ],
        "claude-3-opus-20240229": [
            "cache_creation_input_token_cost": 1.875e-05,
            // Same LiteLLM data bug as Haiku 3: the copied
            // `_above_1hr = 6e-06` is LOWER than the base 5m rate
            // (1.875e-05). Removed so fallback uses the 5m rate.
            "cache_read_input_token_cost": 1.5e-06,
            "input_cost_per_token": 1.5e-05,
            "output_cost_per_token": 7.5e-05,
        ],
        "claude-4-opus-20250514": [
            "cache_creation_input_token_cost": 1.875e-05,
            "cache_read_input_token_cost": 1.5e-06,
            "input_cost_per_token": 1.5e-05,
            "output_cost_per_token": 7.5e-05,
        ],
        "claude-4-sonnet-20250514": [
            "cache_creation_input_token_cost": 3.75e-06,
            "cache_creation_input_token_cost_above_200k_tokens": 7.5e-06,
            "cache_read_input_token_cost": 3e-07,
            "cache_read_input_token_cost_above_200k_tokens": 6e-07,
            "input_cost_per_token": 3e-06,
            "input_cost_per_token_above_200k_tokens": 6e-06,
            "output_cost_per_token": 1.5e-05,
            "output_cost_per_token_above_200k_tokens": 2.25e-05,
        ],
        "claude-haiku-4-5": [
            "cache_creation_input_token_cost": 1.25e-06,
            "cache_creation_input_token_cost_above_1hr": 2e-06,
            "cache_read_input_token_cost": 1e-07,
            "input_cost_per_token": 1e-06,
            "output_cost_per_token": 5e-06,
        ],
        "claude-haiku-4-5-20251001": [
            "cache_creation_input_token_cost": 1.25e-06,
            "cache_creation_input_token_cost_above_1hr": 2e-06,
            "cache_read_input_token_cost": 1e-07,
            "input_cost_per_token": 1e-06,
            "output_cost_per_token": 5e-06,
        ],
        "claude-opus-4-1": [
            "cache_creation_input_token_cost": 1.875e-05,
            "cache_creation_input_token_cost_above_1hr": 3e-05,
            "cache_read_input_token_cost": 1.5e-06,
            "input_cost_per_token": 1.5e-05,
            "output_cost_per_token": 7.5e-05,
        ],
        "claude-opus-4-1-20250805": [
            "cache_creation_input_token_cost": 1.875e-05,
            "cache_creation_input_token_cost_above_1hr": 3e-05,
            "cache_read_input_token_cost": 1.5e-06,
            "input_cost_per_token": 1.5e-05,
            "output_cost_per_token": 7.5e-05,
        ],
        "claude-opus-4-20250514": [
            "cache_creation_input_token_cost": 1.875e-05,
            "cache_creation_input_token_cost_above_1hr": 3e-05,
            "cache_read_input_token_cost": 1.5e-06,
            "input_cost_per_token": 1.5e-05,
            "output_cost_per_token": 7.5e-05,
        ],
        "claude-opus-4-5": [
            "cache_creation_input_token_cost": 6.25e-06,
            "cache_creation_input_token_cost_above_1hr": 1e-05,
            "cache_read_input_token_cost": 5e-07,
            "input_cost_per_token": 5e-06,
            "output_cost_per_token": 2.5e-05,
        ],
        "claude-opus-4-5-20251101": [
            "cache_creation_input_token_cost": 6.25e-06,
            "cache_creation_input_token_cost_above_1hr": 1e-05,
            "cache_read_input_token_cost": 5e-07,
            "input_cost_per_token": 5e-06,
            "output_cost_per_token": 2.5e-05,
        ],
        "claude-opus-4-6": [
            "cache_creation_input_token_cost": 6.25e-06,
            "cache_creation_input_token_cost_above_1hr": 1e-05,
            "cache_read_input_token_cost": 5e-07,
            "input_cost_per_token": 5e-06,
            "output_cost_per_token": 2.5e-05,
        ],
        "claude-opus-4-6-20260205": [
            "cache_creation_input_token_cost": 6.25e-06,
            "cache_creation_input_token_cost_above_1hr": 1e-05,
            "cache_read_input_token_cost": 5e-07,
            "input_cost_per_token": 5e-06,
            "output_cost_per_token": 2.5e-05,
        ],
        "claude-opus-4-7": [
            "cache_creation_input_token_cost": 6.25e-06,
            "cache_creation_input_token_cost_above_1hr": 1e-05,
            "cache_read_input_token_cost": 5e-07,
            "input_cost_per_token": 5e-06,
            "output_cost_per_token": 2.5e-05,
        ],
        "claude-opus-4-7-20260416": [
            "cache_creation_input_token_cost": 6.25e-06,
            "cache_creation_input_token_cost_above_1hr": 1e-05,
            "cache_read_input_token_cost": 5e-07,
            "input_cost_per_token": 5e-06,
            "output_cost_per_token": 2.5e-05,
        ],
        "claude-opus-4-8": [
            "cache_creation_input_token_cost": 6.25e-06,
            "cache_creation_input_token_cost_above_1hr": 1e-05,
            "cache_read_input_token_cost": 5e-07,
            "input_cost_per_token": 5e-06,
            "output_cost_per_token": 2.5e-05,
        ],
        "claude-sonnet-4-20250514": [
            "cache_creation_input_token_cost": 3.75e-06,
            "cache_creation_input_token_cost_above_1hr": 6e-06,
            "cache_creation_input_token_cost_above_200k_tokens": 7.5e-06,
            "cache_read_input_token_cost": 3e-07,
            "cache_read_input_token_cost_above_200k_tokens": 6e-07,
            "input_cost_per_token": 3e-06,
            "input_cost_per_token_above_200k_tokens": 6e-06,
            "output_cost_per_token": 1.5e-05,
            "output_cost_per_token_above_200k_tokens": 2.25e-05,
        ],
        "claude-sonnet-4-5": [
            "cache_creation_input_token_cost": 3.75e-06,
            "cache_creation_input_token_cost_above_1hr": 6e-06,
            "cache_creation_input_token_cost_above_1hr_above_200k_tokens": 1.2e-05,
            "cache_creation_input_token_cost_above_200k_tokens": 7.5e-06,
            "cache_read_input_token_cost": 3e-07,
            "cache_read_input_token_cost_above_200k_tokens": 6e-07,
            "input_cost_per_token": 3e-06,
            "input_cost_per_token_above_200k_tokens": 6e-06,
            "output_cost_per_token": 1.5e-05,
            "output_cost_per_token_above_200k_tokens": 2.25e-05,
        ],
        "claude-sonnet-4-5-20250929": [
            "cache_creation_input_token_cost": 3.75e-06,
            "cache_creation_input_token_cost_above_1hr": 6e-06,
            "cache_creation_input_token_cost_above_1hr_above_200k_tokens": 1.2e-05,
            "cache_creation_input_token_cost_above_200k_tokens": 7.5e-06,
            "cache_read_input_token_cost": 3e-07,
            "cache_read_input_token_cost_above_200k_tokens": 6e-07,
            "input_cost_per_token": 3e-06,
            "input_cost_per_token_above_200k_tokens": 6e-06,
            "output_cost_per_token": 1.5e-05,
            "output_cost_per_token_above_200k_tokens": 2.25e-05,
        ],
        "claude-sonnet-4-6": [
            "cache_creation_input_token_cost": 3.75e-06,
            "cache_creation_input_token_cost_above_1hr": 6e-06,
            "cache_read_input_token_cost": 3e-07,
            "input_cost_per_token": 3e-06,
            "output_cost_per_token": 1.5e-05,
        ],
        "claude-sonnet-5": [
            "cache_creation_input_token_cost": 2.5e-06,
            "cache_creation_input_token_cost_above_1hr": 4e-06,
            "cache_read_input_token_cost": 2e-07,
            "input_cost_per_token": 2e-06,
            "output_cost_per_token": 1e-05,
        ],
    ]
}
