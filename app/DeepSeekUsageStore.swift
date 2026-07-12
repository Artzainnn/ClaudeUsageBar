// PR 4-BE — DeepSeek UsageProvider conformer (dark code, feature-flag off).
//
// Third provider (after Anthropic and Codex). DeepSeek is the "paste-a-key"
// template: the user pastes an `sk-...` API key, stored in the Keychain via
// KeychainStore, and the provider polls the account balance.
//
// Feature posture in PR 4-BE:
//   - `features.deepseek.enabled` defaults FALSE (opt-in, like every
//     non-Anthropic provider).
//   - Nothing registers a DeepSeekUsageStore into AppDelegate.providers yet;
//     the tile + Settings key-paste sheet land in PR 4-UI. This file is
//     compiled and unit-tested but inert at runtime until then.
//
// Credential posture: the API key is a spending credential. It is stored in
// the Keychain (never UserDefaults) and never logged. Only the HTTP status
// code is logged, satisfying the CI credential-leak guard.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class DeepSeekUsageStore: @preconcurrency UsageProvider, PasteKeyProvider {

    public let id: String = "deepseek"
    public let displayName: String = "DeepSeek"
    public let featureFlagKey: String = "features.deepseek.enabled"

    // PasteKeyProvider: the DeepSeek key is pasted by the user into Settings.
    public let keyPlaceholder: String = "sk-…"

    /// Keychain key under which the DeepSeek API key is stored.
    public static let apiKeyKeychainKey = "deepseek.api_key"

    // MARK: Observable state

    @Published public private(set) var snapshot: DeepSeekUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?

    private let credentials: CredentialStore
    private let transport: DeepSeekUsageTransport
    private let defaults: UserDefaults

    public init(
        credentials: CredentialStore = KeychainStore(),
        transport: DeepSeekUsageTransport = URLSessionDeepSeekTransport(),
        defaults: UserDefaults = .standard
    ) {
        self.credentials = credentials
        self.transport = transport
        self.defaults = defaults
    }

    // MARK: - Credential management

    /// True when an API key is stored. The key itself is never exposed. A
    /// keychain that is present but temporarily unreadable (locked) counts as
    /// configured, so a locked screen does not drop the provider back to the
    /// paste-key onboarding card.
    public var hasKey: Bool {
        switch credentials.readResult(Self.apiKeyKeychainKey) {
        case .found(let data): return !data.isEmpty
        case .unavailable:     return true
        case .missing:         return false
        }
    }

    /// Store a pasted API key (trimmed). Empty input clears the key instead.
    public func saveKey(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            credentials.delete(Self.apiKeyKeychainKey)
        } else {
            credentials.write(Self.apiKeyKeychainKey, Data(trimmed.utf8))
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

        // Not configured — onboarding card prompting the user to paste a key.
        if !isConfigured {
            return [UsageTile(
                id: "deepseek-needs-key",
                title: "DeepSeek",
                kind: .needsAccess(
                    path: "api.deepseek.com",
                    guidance: "Paste your DeepSeek API key (sk-…) in Settings to track your balance."
                )
            )]
        }

        guard let snap = snapshot else { return [] }

        var out: [UsageTile] = []

        // Availability warning tile — shown only when the balance is not
        // sufficient for API calls, so a healthy account stays uncluttered.
        if !snap.isAvailable {
            out.append(UsageTile(
                id: "deepseek-status",
                title: "DeepSeek",
                kind: .text(
                    status: "Balance too low",
                    subtitle: "Top up your DeepSeek account to keep making API calls."
                )
            ))
        }

        // One balance tile per currency. Total headline with the granted +
        // topped-up split as the subtitle. Amounts are shown verbatim (the
        // endpoint returns decimal strings), prefixed with the currency.
        for balance in snap.balances {
            out.append(UsageTile(
                id: "deepseek-balance-\(balance.currency.lowercased())",
                title: "DeepSeek balance (\(balance.currency))",
                kind: .text(
                    status: "\(balance.currency) \(balance.totalBalance)",
                    subtitle: "Granted \(balance.grantedBalance) + topped-up \(balance.toppedUpBalance)"
                )
            ))
        }

        return out
    }

    // MARK: - Result application (testable seam)

    /// Apply a transport result to observable state. Extracted so the
    /// TestRunner can drive every branch synchronously.
    public func apply(_ result: DeepSeekUsageResult, now: Date = Date()) {
        switch result {
        case .success(let data):
            do {
                let snap = try DeepSeekUsageFetcher.parse(data)
                self.snapshot = snap
                self.lastUpdatedAt = now
                self.lastError = nil
            } catch {
                self.lastError = "Could not parse DeepSeek balance"
            }
        case .unauthorized:
            // 401 — the pasted key is invalid or revoked. Surface an
            // actionable message; keep the key so the user can correct it in
            // Settings rather than silently losing it.
            self.lastError = "Invalid DeepSeek API key"
        case .httpError(let code):
            self.lastError = "HTTP \(code)"
        case .networkError:
            self.lastError = "Network error"
        }
    }

    // MARK: - UsageProvider: actions

    public func fetch() {
        guard isEnabled else { return }
        guard let keyData = credentials.read(Self.apiKeyKeychainKey),
              !keyData.isEmpty,
              let key = String(data: keyData, encoding: .utf8) else {
            // No key stored; tiles render the onboarding card.
            snapshot = nil
            lastError = nil
            return
        }

        transport.fetchBalance(apiKey: key) { [weak self] result in
            // Task { @MainActor } is safe on any delivery queue (cannot trap
            // like assumeIsolated if a transport calls back off-main).
            Task { @MainActor [weak self] in self?.apply(result) }
        }
    }

    public func clear() {
        // Clearing DeepSeek DOES delete its credential — unlike Codex, the
        // key belongs to this app (the user pasted it here), not to an
        // external CLI. This is the "Clear API key" action in Settings.
        credentials.delete(Self.apiKeyKeychainKey)
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
    }
}

// MARK: - Transport abstraction

public enum DeepSeekUsageResult: Sendable {
    case success(Data)
    case unauthorized
    case httpError(Int)
    case networkError
}

/// Seam over the network for unit testing. The completion MUST be delivered
/// on the main queue.
public protocol DeepSeekUsageTransport: Sendable {
    func fetchBalance(
        apiKey: String,
        completion: @escaping @Sendable (DeepSeekUsageResult) -> Void
    )
}

/// Production transport. Issues the real request with the Bearer key. The
/// response body is never logged; only the status code goes through the
/// categorical logger.
public struct URLSessionDeepSeekTransport: DeepSeekUsageTransport {
    private let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    public init() {}

    public func fetchBalance(
        apiKey: String,
        completion: @escaping @Sendable (DeepSeekUsageResult) -> Void
    ) {
        var request = URLRequest(url: balanceURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsageBar", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let deliver: (DeepSeekUsageResult) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }

            if error != nil {
                deliver(.networkError)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                deliver(.networkError)
                return
            }

            Log.info("DeepSeek balance API response", .count(http.statusCode))

            switch http.statusCode {
            case 200:
                if let data = data {
                    deliver(.success(data))
                } else {
                    deliver(.networkError)
                }
            case 401:
                deliver(.unauthorized)
            default:
                deliver(.httpError(http.statusCode))
            }
        }.resume()
    }
}
