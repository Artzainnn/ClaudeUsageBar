// PR 6-BE — xAI Developer UsageProvider conformer (dark code, flag off).
//
// Fifth provider, and the first two-credential one. Tier 1 (inference key)
// is required and yields plan info; Tier 2 (management key) is optional and
// yields the prepaid balance + daily usage. Both keys live in the Keychain.
//
// Feature posture: features.xai.enabled defaults false; nothing registers a
// store into the live registry yet (two-key sheet + tiles land in PR 6-UI).
//
// Credentials never reach a log line; only HTTP status codes are logged.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class XAIUsageStore: UsageProvider, PasteKeyProvider, SecondaryKeyProvider {

    public let id: String = "xai"
    public let displayName: String = "xAI (Grok)"
    public let featureFlagKey: String = "features.xai.enabled"

    // PasteKeyProvider — the required Tier-1 inference key.
    public let keyPlaceholder: String = "xai-… (inference key)"
    // SecondaryKeyProvider — the optional, spending-capable management key.
    public let secondaryKeyPlaceholder: String = "xai-… (management key)"
    public let secondaryKeyLabel: String = "Enable balance + usage history (needs a management key)"
    public let secondaryKeyWarning: String = "A management key can create, rotate, and delete your xAI API keys. Only paste one if you understand that. It is stored in your Keychain and used only to read billing."

    // MARK: Observable state

    @Published public private(set) var snapshot: XAIUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?

    private let credentials: CredentialStore
    private let transport: XAIUsageTransport
    private let defaults: UserDefaults

    public init(
        credentials: CredentialStore = KeychainStore(),
        transport: XAIUsageTransport = URLSessionXAITransport(),
        defaults: UserDefaults = .standard
    ) {
        self.credentials = credentials
        self.transport = transport
        self.defaults = defaults
    }

    // MARK: - Credential management

    /// True when a credential is stored, treating an unreadable (locked)
    /// keychain as "still configured" so a locked screen does not drop the
    /// provider back to onboarding.
    private func hasStoredKey(_ keychainKey: String) -> Bool {
        switch credentials.readResult(keychainKey) {
        case .found(let data): return !data.isEmpty
        case .unavailable:     return true
        case .missing:         return false
        }
    }

    /// Tier 1 — the inference key (required).
    public var hasInferenceKey: Bool {
        hasStoredKey(XAIUsageFetcher.inferenceKeyKeychainKey)
    }

    /// Tier 2 — the management key (optional; unlocks balance + history).
    public var hasManagementKey: Bool {
        hasStoredKey(XAIUsageFetcher.managementKeyKeychainKey)
    }

    public func saveInferenceKey(_ raw: String) {
        saveOrClear(raw, key: XAIUsageFetcher.inferenceKeyKeychainKey)
    }

    public func saveManagementKey(_ raw: String) {
        saveOrClear(raw, key: XAIUsageFetcher.managementKeyKeychainKey)
    }

    // PasteKeyProvider conformance (primary = inference key).
    public var hasKey: Bool { hasInferenceKey }
    public func saveKey(_ raw: String) { saveInferenceKey(raw) }

    // SecondaryKeyProvider conformance (secondary = management key).
    public var hasSecondaryKey: Bool { hasManagementKey }
    public func saveSecondaryKey(_ raw: String) { saveManagementKey(raw) }

    private func saveOrClear(_ raw: String, key: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            credentials.delete(key)
        } else {
            credentials.write(key, Data(trimmed.utf8))
        }
        objectWillChange.send()
    }

    private func readKey(_ key: String) -> String? {
        guard let data = credentials.read(key), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - UsageProvider: feature flag

    public var isEnabled: Bool {
        defaults.bool(forKey: featureFlagKey)
    }

    /// Configured once the required Tier-1 inference key is present.
    public var isConfigured: Bool {
        hasInferenceKey
    }

    public var lastUpdated: Date? { lastUpdatedAt }
    public var errorMessage: String? { lastError }

    // MARK: - UsageProvider: tiles

    public var tiles: [UsageTile] {
        guard isEnabled else { return [] }

        if !isConfigured {
            return [UsageTile(
                id: "xai-needs-key",
                title: "xAI (Grok)",
                kind: .needsAccess(
                    path: "api.x.ai",
                    guidance: "Paste an xAI API key (xai-…) in Settings. Add a management key too for balance and usage history."
                )
            )]
        }

        guard let snap = snapshot else { return [] }

        var out: [UsageTile] = []

        // Plan / permissions tile from the ACLs.
        if let info = snap.apiKeyInfo {
            let acls = info.acls.isEmpty ? "API access" : info.acls.joined(separator: ", ")
            out.append(UsageTile(
                id: "xai-plan",
                title: "xAI API key",
                kind: .text(status: info.redactedKey ?? "Configured", subtitle: acls)
            ))
        }

        // Tier 2: prepaid balance. Only when a management key produced one.
        if let balance = snap.balance {
            let currency = balance.currency ?? "USD"
            // remainingUSD encapsulates the tick unit + credit sign; convert
            // to minor units for the balance tile.
            let minorUnits = Int((balance.remainingUSD * 100).rounded())
            out.append(UsageTile(
                id: "xai-balance",
                title: "xAI prepaid balance",
                kind: .balance(remainingMinorUnits: minorUnits, currency: currency, plan: nil, resetsAt: nil)
            ))
        }

        // Tier 2: rolled-up recent spend as a text tile (the small chart is a
        // UI concern for PR 6-UI; the backend surfaces the total here). The
        // amount is shown with its reported currency code rather than a bare
        // "$" — the daily-usage shape is undocumented and may bill in CNY, so
        // we do not assume USD. When no currency is reported, show a neutral
        // amount with no symbol.
        if !snap.daily.isEmpty {
            let total = snap.daily.reduce(0.0) { $0 + $1.amountSpent }
            let currency = snap.daily.compactMap { $0.currency }.first
            let status = currency.map { String(format: "%@ %.2f", $0, total) }
                ?? String(format: "%.2f", total)
            out.append(UsageTile(
                id: "xai-daily-usd",
                title: "xAI usage (recent)",
                kind: .text(status: status, subtitle: "\(snap.daily.count) days")
            ))
        }

        return out
    }

    // MARK: - Result application (testable seam)

    /// The transport gathers all endpoints and hands back a combined result
    /// so the store applies one snapshot. Extracted for synchronous testing.
    public func apply(_ result: XAIUsageResult, now: Date = Date()) {
        switch result {
        case .success(let snap):
            self.snapshot = snap
            self.lastUpdatedAt = now
            self.lastError = nil
        case .unauthorized:
            self.lastError = "Invalid xAI API key"
        case .httpError(let code):
            self.lastError = "HTTP \(code)"
        case .networkError:
            self.lastError = "Network error"
        }
    }

    // MARK: - UsageProvider: actions

    public func fetch() {
        guard isEnabled else { return }
        guard let inference = readKey(XAIUsageFetcher.inferenceKeyKeychainKey) else {
            snapshot = nil
            lastError = nil
            return
        }
        // Tier 2 is optional — pass the management key only if present.
        let management = readKey(XAIUsageFetcher.managementKeyKeychainKey)

        transport.fetchAll(inferenceKey: inference, managementKey: management) { [weak self] result in
            // Task { @MainActor } is safe on any delivery queue (cannot trap
            // like assumeIsolated if a transport calls back off-main).
            Task { @MainActor [weak self] in self?.apply(result) }
        }
    }

    public func clear() {
        // Clears BOTH keys (the user pasted them here) and the state.
        credentials.delete(XAIUsageFetcher.inferenceKeyKeychainKey)
        credentials.delete(XAIUsageFetcher.managementKeyKeychainKey)
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
    }
}

// MARK: - Transport abstraction

public enum XAIUsageResult: Sendable {
    case success(XAIUsageSnapshot)
    case unauthorized
    case httpError(Int)
    case networkError
}

/// Seam over the multi-endpoint fetch. The completion MUST be on the main
/// queue.
public protocol XAIUsageTransport: Sendable {
    func fetchAll(
        inferenceKey: String,
        managementKey: String?,
        completion: @escaping @Sendable (XAIUsageResult) -> Void
    )
}

/// Production transport. Chains: api-key -> language-models (Tier 1), then if
/// a management key + team id are present, prepaid/balance + usage (Tier 2).
/// Response bodies are never logged; only status codes.
public struct URLSessionXAITransport: XAIUsageTransport {
    private let apiHost = "https://api.x.ai"
    private let mgmtHost = "https://management-api.x.ai"

    public init() {}

    public func fetchAll(
        inferenceKey: String,
        managementKey: String?,
        completion: @escaping @Sendable (XAIUsageResult) -> Void
    ) {
        let deliver: @Sendable (XAIUsageResult) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }

        // Tier 1: GET /v1/api-key
        get("\(apiHost)/v1/api-key", bearer: inferenceKey) { data, status in
            guard status == 200, let data = data,
                  let info = try? XAIUsageFetcher.parseApiKey(data) else {
                deliver(status == 401 || status == 403 ? .unauthorized
                        : (status == nil ? .networkError : .httpError(status!)))
                return
            }

            // Tier 1: GET /v1/language-models. Build the snapshot immutably,
            // passing accumulated pieces forward into each nested closure
            // rather than mutating a captured var (which would not be
            // Sendable-safe across the async completion boundaries).
            self.get("\(self.apiHost)/v1/language-models", bearer: inferenceKey) { modelData, _ in
                let models: [XAIModel] = modelData.flatMap { try? XAIUsageFetcher.parseLanguageModels($0) } ?? []
                let tier1 = XAIUsageSnapshot(apiKeyInfo: info, models: models)

                // Tier 2 (optional): balance + usage, only with a management
                // key and a bootstrapped team id. The team id comes from the
                // api-key response (semi-trusted), so it is percent-encoded as
                // a single path segment — an id containing "/" or "?" cannot
                // alter the request path.
                guard let mgmt = managementKey, let rawTeam = info.teamId,
                      let team = RequestSafety.pathSegment(rawTeam) else {
                    deliver(.success(tier1))
                    return
                }

                self.get("\(self.mgmtHost)/v1/billing/teams/\(team)/prepaid/balance", bearer: mgmt) { balData, _ in
                    let balance: XAIBalance? = balData.flatMap { try? XAIUsageFetcher.parseBalance($0) }
                    self.post("\(self.mgmtHost)/v1/billing/teams/\(team)/usage", bearer: mgmt) { usageData, _ in
                        let daily: [XAIDailyUsage] = usageData.flatMap { try? XAIUsageFetcher.parseUsage($0) } ?? []
                        let full = XAIUsageSnapshot(apiKeyInfo: info, models: models, balance: balance, daily: daily)
                        deliver(.success(full))
                    }
                }
            }
        }
    }

    private func get(_ urlString: String, bearer: String, done: @escaping @Sendable (Data?, Int?) -> Void) {
        request(urlString, method: "GET", bearer: bearer, body: nil, done: done)
    }

    private func post(_ urlString: String, bearer: String, done: @escaping @Sendable (Data?, Int?) -> Void) {
        // Empty JSON body; the usage endpoint accepts a default date range.
        request(urlString, method: "POST", bearer: bearer, body: Data("{}".utf8), done: done)
    }

    private func request(_ urlString: String, method: String, bearer: String, body: Data?, done: @escaping @Sendable (Data?, Int?) -> Void) {
        guard let url = URL(string: urlString) else { done(nil, nil); return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsageBar", forHTTPHeaderField: "User-Agent")
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil { done(nil, nil); return }
            let status = (response as? HTTPURLResponse)?.statusCode
            Log.info("xAI API response", .count(status ?? -1))
            done(data, status)
        }.resume()
    }
}
