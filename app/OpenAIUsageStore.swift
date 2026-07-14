// PR 7-BE — OpenAI Platform UsageProvider conformer (dark code, flag off).
//
// Sixth provider. Reads an OpenAI organisation's token usage, month-to-date
// cost, and configured rate-limit ceilings via an Admin key (sk-admin-...),
// stored in the Keychain. Admin keys can view billing and manage users but
// cannot make inference calls — the UI gates the paste behind a warning.
//
// Feature posture: features.openai.enabled defaults false; nothing registers
// a store into the live registry yet (admin-key sheet + tiles land in PR 7-UI).
//
// The admin key never reaches a log line; only HTTP status codes are logged.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class OpenAIUsageStore: UsageProvider, PasteKeyProvider {

    public let id: String = "openai"
    public let displayName: String = "OpenAI Platform"
    public let featureFlagKey: String = "features.openai.enabled"

    // PasteKeyProvider — an Organization Admin key. These org endpoints are
    // admin-gated; there is no api.usage.read scoped-key fallback (confirmed
    // against the OpenAI Admin API reference), so the placeholder names the
    // admin key specifically.
    public let keyPlaceholder: String = "sk-admin-…"

    // MARK: Observable state

    @Published public private(set) var snapshot: OpenAIUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?

    private let credentials: CredentialStore
    private let transport: OpenAIUsageTransport
    private let defaults: UserDefaults

    public init(
        credentials: CredentialStore = KeychainStore(),
        transport: OpenAIUsageTransport = URLSessionOpenAITransport(),
        defaults: UserDefaults = .standard
    ) {
        self.credentials = credentials
        self.transport = transport
        self.defaults = defaults
    }

    // MARK: - Credential (PasteKeyProvider)

    /// True when the admin key is stored. An unreadable (locked) keychain
    /// counts as configured so a locked screen does not drop the provider
    /// back to the paste-key onboarding card.
    public var hasKey: Bool {
        switch credentials.readResult(OpenAIUsageFetcher.adminKeyKeychainKey) {
        case .found(let data): return !data.isEmpty
        case .unavailable:     return true
        case .missing:         return false
        }
    }

    public func saveKey(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            credentials.delete(OpenAIUsageFetcher.adminKeyKeychainKey)
        } else {
            credentials.write(OpenAIUsageFetcher.adminKeyKeychainKey, Data(trimmed.utf8))
        }
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
                id: "openai-needs-key",
                title: "OpenAI Platform",
                kind: .needsAccess(
                    path: "platform.openai.com",
                    guidance: "Paste an OpenAI Admin key (sk-admin-…) in Settings to track org spend and usage."
                )
            )]
        }

        guard let snap = snapshot else { return [] }

        var out: [UsageTile] = []

        // Month-to-date cost as a balance-style tile (a spend total, so no
        // reset; shown as an amount). The costs API returns the currency
        // lowercase ("usd"); uppercase it for display consistency with the
        // "USD" fallback.
        let currency = snap.costCurrency?.uppercased() ?? "USD"
        out.append(UsageTile(
            id: "openai-cost-mtd",
            title: "OpenAI spend (month to date)",
            kind: .text(status: String(format: "%@ %.2f", currency, snap.costMTDUSD), subtitle: nil)
        ))

        // Token usage over the last 24h, top models. Rendered as counter
        // tiles (total tokens per model) so the generic renderer handles it.
        for model in snap.tokensByModel.prefix(4) {
            out.append(UsageTile(
                id: "openai-tokens-\(model.model)",
                title: "OpenAI \(model.model) (24h)",
                kind: .counter(used: model.totalTokens, limit: nil, resetsAt: nil)
            ))
        }

        // Configured ceilings — reference context, top models by TPM.
        for limit in snap.rateLimits.prefix(3) {
            let tpm = limit.maxTokensPerMinute.map { "\($0) TPM" } ?? "—"
            let rpm = limit.maxRequestsPerMinute.map { "\($0) RPM" } ?? "—"
            out.append(UsageTile(
                id: "openai-ceiling-\(limit.model)",
                title: "OpenAI \(limit.model) limits",
                kind: .text(status: tpm, subtitle: rpm)
            ))
        }

        return out
    }

    // MARK: - Result application (testable seam)

    public func apply(_ result: OpenAIUsageResult, now: Date = Date()) {
        switch result {
        case .success(let snap):
            self.snapshot = snap
            self.lastUpdatedAt = now
            self.lastError = nil
        case .unauthorized:
            self.lastError = "Invalid OpenAI Admin key"
        case .httpError(let code):
            self.lastError = "HTTP \(code)"
        case .networkError:
            self.lastError = "Network error"
        }
    }

    // MARK: - UsageProvider: actions

    public func fetch() {
        guard isEnabled else { return }
        guard let data = credentials.read(OpenAIUsageFetcher.adminKeyKeychainKey),
              !data.isEmpty, let key = String(data: data, encoding: .utf8) else {
            snapshot = nil
            lastError = nil
            return
        }

        transport.fetchAll(adminKey: key) { [weak self] result in
            // Hop to the main actor to apply state. Task { @MainActor } is
            // safe whichever queue the transport delivers on — unlike
            // assumeIsolated, it cannot trap if a future/custom transport
            // calls back off-main.
            Task { @MainActor [weak self] in self?.apply(result) }
        }
    }

    public func clear() {
        credentials.delete(OpenAIUsageFetcher.adminKeyKeychainKey)
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
    }
}

// MARK: - Transport abstraction

public enum OpenAIUsageResult: Sendable {
    case success(OpenAIUsageSnapshot)
    case unauthorized
    case httpError(Int)
    case networkError
}

public protocol OpenAIUsageTransport: Sendable {
    func fetchAll(
        adminKey: String,
        completion: @escaping @Sendable (OpenAIUsageResult) -> Void
    )
}

/// Production transport. Chains usage/completions + costs (both required for
/// the headline tiles); rate_limits is best-effort (needs a project id, which
/// it discovers from /v1/organization/projects). Bodies are never logged.
public struct URLSessionOpenAITransport: OpenAIUsageTransport {
    private let base = "https://api.openai.com/v1/organization"

    public init() {}

    public func fetchAll(
        adminKey: String,
        completion: @escaping @Sendable (OpenAIUsageResult) -> Void
    ) {
        let deliver: @Sendable (OpenAIUsageResult) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }

        let now = Date()
        let completionsURL = base + Self.completionsQuery(now: now)
        let costsURL = base + Self.costsQuery(now: now)

        get(completionsURL, bearer: adminKey) { compData, compStatus in
            guard compStatus == 200, let compData = compData,
                  let tokens = try? OpenAIUsageFetcher.parseCompletions(compData) else {
                deliver(compStatus == 401 || compStatus == 403 ? .unauthorized
                        : (compStatus == nil ? .networkError : .httpError(compStatus!)))
                return
            }

            self.get(costsURL, bearer: adminKey) { costData, _ in
                let cost = costData.flatMap { try? OpenAIUsageFetcher.parseCosts($0) }
                let base = OpenAIUsageSnapshot(
                    tokensByModel: tokens,
                    costMTDUSD: cost?.usd ?? 0,
                    costCurrency: cost?.currency
                )
                // Rate limits are best-effort: discover a project id, then
                // fetch its ceilings. Any failure just omits that section.
                self.get("\(self.base)/projects?limit=1", bearer: adminKey) { projData, _ in
                    guard let projData = projData,
                          let projJSON = try? JSONSerialization.jsonObject(with: projData) as? [String: Any],
                          let projects = projJSON["data"] as? [[String: Any]],
                          let firstProject = projects.first,
                          let rawProjectId = firstProject["id"] as? String,
                          // The project id comes from the API response; encode
                          // it as a single path segment so it cannot alter the
                          // request path.
                          let projectId = RequestSafety.pathSegment(rawProjectId) else {
                        deliver(.success(base))
                        return
                    }
                    self.get("\(self.base)/projects/\(projectId)/rate_limits", bearer: adminKey) { rlData, _ in
                        let limits = rlData.flatMap { try? OpenAIUsageFetcher.parseRateLimits($0) } ?? []
                        let full = OpenAIUsageSnapshot(
                            tokensByModel: tokens,
                            costMTDUSD: cost?.usd ?? 0,
                            costCurrency: cost?.currency,
                            rateLimits: limits
                        )
                        deliver(.success(full))
                    }
                }
            }
        }
    }

    /// Query path (relative to `base`) for the completions/token-usage tile.
    ///
    /// Uses `bucket_width=1h` with `limit=24` for a TRUE rolling 24-hour
    /// window. A previous version used `bucket_width=1d`, which returns whole
    /// UTC-day buckets: with `start_time=now-24h` that folds in usage from
    /// 00:00 UTC of the prior day, so a tile labelled "(24h)" could sum up to
    /// ~48h of tokens. Hourly buckets bounded to 24 give exactly the last 24h.
    /// 24 hourly buckets fit a single page (the 1h max is 168), so no
    /// pagination is needed.
    public static func completionsQuery(now: Date) -> String {
        let dayAgo = Int(now.timeIntervalSince1970) - 24 * 3600
        return "/usage/completions?bucket_width=1h&group_by=model&limit=24&start_time=\(dayAgo)"
    }

    /// Query path (relative to `base`) for the month-to-date cost tile.
    /// `bucket_width=1d` from the start of the UTC month; `limit=31` is the
    /// 1d max and covers every day of the longest month in a single page.
    public static func costsQuery(now: Date) -> String {
        let monthStart = startOfUTCMonth(now)
        return "/costs?bucket_width=1d&group_by=line_item&limit=31&start_time=\(monthStart)"
    }

    /// Start of the current month in UTC, as a Unix timestamp.
    public static func startOfUTCMonth(_ date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month], from: date)
        let start = cal.date(from: comps) ?? date
        return Int(start.timeIntervalSince1970)
    }

    private func get(_ urlString: String, bearer: String, done: @escaping @Sendable (Data?, Int?) -> Void) {
        guard let url = URL(string: urlString) else { done(nil, nil); return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsageBar", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil { done(nil, nil); return }
            let status = (response as? HTTPURLResponse)?.statusCode
            Log.info("OpenAI org API response", .count(status ?? -1))
            done(data, status)
        }.resume()
    }
}
