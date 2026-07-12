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
            // Use the modern data-protection keychain for every item, as the
            // security standard requires for spending credentials. Set on the
            // base query so read/update/delete all target the same keychain
            // the item was written to.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func read(_ key: String) -> Data? {
        if case .found(let data) = readResult(key) { return data }
        return nil
    }

    /// Richer read that distinguishes a missing item from a keychain that is
    /// present but unavailable (locked, access denied). Callers that gate a
    /// "not configured" onboarding state should use this so a transient
    /// unavailability is not mistaken for "no credential", which would wrongly
    /// prompt the user to re-paste. `read` remains for the common case.
    public func readResult(_ key: String) -> CredentialReadResult {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            if let data = item as? Data { return .found(data) }
            return .missing
        case errSecItemNotFound:
            return .missing
        default:
            // errSecInteractionNotAllowed (locked), errSecAuthFailed, etc.
            return .unavailable(status)
        }
    }

    public func write(_ key: String, _ value: Data) {
        // Upsert. Update first; if the item does not exist, add it. Crucially,
        // the update path ALSO refreshes kSecAttrAccessible so an item created
        // by an older build with a weaker accessibility class is upgraded to
        // the current one (rather than silently keeping the weak attribute).
        let query = baseQuery(key)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            // WhenUnlockedThisDeviceOnly: the credential is inaccessible
            // whenever the device is locked, never syncs to iCloud Keychain,
            // and does not migrate to a new device. This is the least-
            // privilege class mandated for spending credentials (stricter than
            // AfterFirstUnlock, which stays readable while locked).
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery(key)
            addQuery[kSecValueData as String] = value
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                // The item was neither updated nor added (e.g. locked keychain
                // or a duplicate race). Log the failure category (never the
                // value) so a silently-dropped write is diagnosable.
                Log.info("Keychain write failed", .count(Int(addStatus)))
            }
        } else if updateStatus != errSecSuccess {
            Log.info("Keychain update failed", .count(Int(updateStatus)))
        }
    }

    public func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }
}
