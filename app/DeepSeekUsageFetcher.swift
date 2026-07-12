// PR 4-BE — DeepSeek usage fetcher + the first Keychain credential store.
//
// DeepSeek is the template "paste-a-key" provider: the user pastes an
// `sk-...` API key, which is stored in the macOS Keychain (a spending
// credential — it must never sit in UserDefaults). The provider then polls
// `GET https://api.deepseek.com/user/balance` for the account balance.
//
// This file ships two things:
//   1. DeepSeekUsageFetcher — Sendable value type, pure parser, mirroring
//      the Anthropic/Codex fetchers. Fixtures hit `parse(_:)`.
//   2. KeychainStore — the first concrete CredentialStore (the protocol was
//      introduced in PR 47). Backs every future spending credential
//      (DeepSeek key, Perplexity cookie, OpenAI admin key, ...).
//
// Response shape (verified against api-docs.deepseek.com/api/get-user-balance):
//   {
//     "is_available": Bool,          // is the balance sufficient for calls
//     "balance_infos": [
//       { "currency": "USD" | "CNY",
//         "total_balance":     String,   // amounts are STRINGS, not numbers
//         "granted_balance":   String,   // from promotions
//         "topped_up_balance": String }  // paid top-ups
//     ]
//   }
// All amounts are strings and are preserved verbatim — we do not reinterpret
// currency or arithmetic on them beyond what the balance tile needs.

import Foundation
import Security

// MARK: - Snapshot

/// One currency's balance breakdown from `balance_infos[]`.
public struct DeepSeekBalance: Equatable, Sendable {
    /// "USD" or "CNY" as returned by the endpoint.
    public var currency: String
    /// Total balance, verbatim string (e.g. "110.00").
    public var totalBalance: String
    /// Promotional / granted portion, verbatim string.
    public var grantedBalance: String
    /// Paid top-up portion, verbatim string.
    public var toppedUpBalance: String

    public init(
        currency: String,
        totalBalance: String,
        grantedBalance: String,
        toppedUpBalance: String
    ) {
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
    }
}

/// A parsed snapshot of the `/user/balance` response.
public struct DeepSeekUsageSnapshot: Equatable, Sendable {
    /// Whether the balance is sufficient for API calls. When false the tile
    /// turns amber and the balance is de-emphasised.
    public var isAvailable: Bool
    /// One entry per currency present on the account. Usually a single
    /// currency, but the endpoint returns an array.
    public var balances: [DeepSeekBalance]

    public init(isAvailable: Bool = false, balances: [DeepSeekBalance] = []) {
        self.isAvailable = isAvailable
        self.balances = balances
    }
}

public enum DeepSeekUsageParseError: Error, Equatable {
    case invalidJSON
    case unexpectedShape(String)
}

// MARK: - Fetcher

/// Pure parser for the DeepSeek balance endpoint. Value type, no observable
/// state. The Store owns the HTTP call and applies the snapshot.
public struct DeepSeekUsageFetcher: Sendable {

    public init() {}

    /// Parse the JSON body of a `/user/balance` response. Throws
    /// `invalidJSON` only when the top level is not a JSON object. A sparse
    /// but well-formed body (empty balance_infos) parses to a snapshot with
    /// an empty `balances` array, matching how the sibling fetchers tolerate
    /// minimal shapes.
    public static func parse(_ data: Data) throws -> DeepSeekUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeepSeekUsageParseError.invalidJSON
        }

        var snap = DeepSeekUsageSnapshot()
        if let available = json["is_available"] as? Bool {
            snap.isAvailable = available
        }

        if let infos = json["balance_infos"] as? [[String: Any]] {
            snap.balances = infos.compactMap { info in
                guard let currency = info["currency"] as? String else { return nil }
                return DeepSeekBalance(
                    currency: currency,
                    totalBalance: stringAmount(info["total_balance"]),
                    grantedBalance: stringAmount(info["granted_balance"]),
                    toppedUpBalance: stringAmount(info["topped_up_balance"])
                )
            }
        }

        return snap
    }

    /// Balances are strings on the wire; preserve them verbatim. Accept a
    /// number defensively (in case the API ever returns one) and stringify
    /// it, and fall back to "0" when the field is absent.
    private static func stringAmount(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let i = value as? Int { return String(i) }
        if let d = value as? Double { return String(d) }
        return "0"
    }
}

// MARK: - KeychainStore

/// First concrete CredentialStore (protocol from PR 47). Stores spending
/// credentials in the macOS login Keychain as generic passwords, keyed by a
/// per-app service plus the caller's key. Every provider that holds a
/// spending credential (DeepSeek API key, Perplexity cookie, OpenAI admin
/// key) uses this rather than UserDefaults.
///
/// The service string namespaces our items so they never collide with other
/// apps' Keychain entries. `read` returns nil for a missing item (not an
/// error); `write` upserts; `delete` is idempotent.
public struct KeychainStore: CredentialStore {
    /// Keychain service used to namespace this app's items.
    private let service: String

    public init(service: String = "com.claude.usagebar.credentials") {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func read(_ key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    public func write(_ key: String, _ value: Data) {
        // Upsert: try to update an existing item first; if none exists, add.
        let query = baseQuery(key)
        let attributes: [String: Any] = [kSecValueData as String: value]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery(key)
            addQuery[kSecValueData as String] = value
            // Only unlocked-while-this-device flags; the credential never
            // syncs to iCloud Keychain and is unavailable before first
            // unlock. Matches least-privilege for a spending credential.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    public func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }
}
