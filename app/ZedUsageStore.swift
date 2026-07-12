// PR 5-BE — Zed UsageProvider conformer (dark code, feature-flag off).
//
// Fourth provider. Zed is the read-from-the-app's-own-Keychain template: it
// holds no credential of its own, reading the token Zed itself stored. The
// first read triggers a macOS SecurityAgent prompt the user must allow once.
//
// Feature posture: features.zed.enabled defaults false; nothing registers a
// ZedUsageStore into the live registry yet (tile + toggle land in PR 5-UI).
//
// Auth: the Authorization header is "{user_id} {access_token}" — space
// delimited, NOT Bearer. Credentials never reach a log line; only the HTTP
// status code is logged.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class ZedUsageStore: @preconcurrency UsageProvider {

    public let id: String = "zed"
    public let displayName: String = "Zed"
    public let featureFlagKey: String = "features.zed.enabled"

    // MARK: Observable state

    @Published public private(set) var snapshot: ZedUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?
    /// True when Zed's Keychain item was readable on the last attempt.
    @Published public private(set) var hasKeychainAccess: Bool = false

    private let transport: ZedUsageTransport
    private let defaults: UserDefaults
    // Injected so tests can supply credentials without touching the real
    // Keychain. Production reads Zed's own item.
    private let credentialReader: @Sendable () -> Result<ZedCredentials, Error>

    public init(
        transport: ZedUsageTransport = URLSessionZedTransport(),
        defaults: UserDefaults = .standard,
        credentialReader: @escaping @Sendable () -> Result<ZedCredentials, Error> = {
            Result { try ZedUsageFetcher.readCredentials() }
        }
    ) {
        self.transport = transport
        self.defaults = defaults
        self.credentialReader = credentialReader
    }

    // MARK: - UsageProvider: feature flag

    public var isEnabled: Bool {
        defaults.bool(forKey: featureFlagKey)
    }

    /// Configured means Zed's Keychain item is readable. Probing it here
    /// would trigger the SecurityAgent prompt on every access, so we report
    /// the result of the last fetch attempt instead of probing eagerly.
    public var isConfigured: Bool {
        hasKeychainAccess
    }

    public var lastUpdated: Date? { lastUpdatedAt }

    public var errorMessage: String? { lastError }

    // MARK: - UsageProvider: tiles

    public var tiles: [UsageTile] {
        guard isEnabled else { return [] }

        // Before the first successful Keychain read, show an onboarding card
        // explaining the one-time prompt.
        if !hasKeychainAccess && snapshot == nil {
            return [UsageTile(
                id: "zed-needs-access",
                title: "Zed",
                kind: .needsAccess(
                    path: "zed.dev (Keychain)",
                    guidance: "Sign in to Zed, then click Refresh. macOS will ask once to let this app read Zed's saved login."
                )
            )]
        }

        guard let snap = snapshot else { return [] }

        var out: [UsageTile] = []

        // Plan tile — friendly label for the raw plan_v3 identifier.
        out.append(UsageTile(
            id: "zed-plan",
            title: "Zed plan",
            kind: .text(status: Self.planLabel(snap.planV3), subtitle: nil)
        ))

        // Edit-predictions counter. Shown when the plan reports the bucket.
        if let ep = snap.editPredictions {
            out.append(UsageTile(
                id: "zed-edit-predictions",
                title: "Edit predictions",
                kind: .counter(
                    used: ep.used,
                    limit: ep.limit,          // nil renders as unlimited
                    resetsAt: snap.periodEndsAt
                )
            ))
        }

        // Billing warning — only when there is a problem, so healthy accounts
        // stay uncluttered.
        if snap.hasOverdueInvoices || snap.isAccountTooYoung {
            let reason = snap.hasOverdueInvoices
                ? "You have overdue invoices on your Zed account."
                : "Your Zed account is too new for this feature yet."
            out.append(UsageTile(
                id: "zed-billing",
                title: "Zed billing",
                kind: .text(status: "Attention needed", subtitle: reason)
            ))
        }

        return out
    }

    /// Map Zed's raw plan_v3 identifier to a human label. Unknown values are
    /// shown verbatim so a new plan tier is never hidden.
    public static func planLabel(_ planV3: String?) -> String {
        // plan_v3 values from Zed source (cloud_api_types Plan enum):
        // zed_free, zed_pro, zed_pro_trial, zed_business, zed_vip, zed_student.
        switch planV3 {
        case "zed_free":       return "Free"
        case "zed_pro":        return "Pro"
        case "zed_pro_trial":  return "Pro (trial)"
        case "zed_business":   return "Business"
        case "zed_vip":        return "VIP"
        case "zed_student":    return "Student"
        case .some(let other): return other
        case .none:            return "Unknown"
        }
    }

    // MARK: - Result application (testable seam)

    public func apply(_ result: ZedUsageResult, now: Date = Date()) {
        switch result {
        case .success(let data):
            do {
                let snap = try ZedUsageFetcher.parse(data)
                self.snapshot = snap
                self.lastUpdatedAt = now
                self.lastError = nil
            } catch {
                self.lastError = "Could not parse Zed usage"
            }
        case .unauthorized:
            // Zed's stored token was rejected — the user must re-sign-in to
            // Zed itself; we cannot refresh it.
            self.lastError = "Zed session expired — sign in again in Zed."
        case .httpError(let code):
            self.lastError = "HTTP \(code)"
        case .networkError:
            self.lastError = "Network error"
        }
    }

    // MARK: - UsageProvider: actions

    public func fetch() {
        guard isEnabled else { return }

        let creds: ZedCredentials
        switch credentialReader() {
        case .success(let c):
            creds = c
            hasKeychainAccess = true
        case .failure:
            // Keychain item missing or the prompt was denied. Leave the
            // onboarding card up; not an error state.
            hasKeychainAccess = false
            snapshot = nil
            lastError = nil
            return
        }

        transport.fetchUser(credentials: creds) { [weak self] result in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.apply(result)
            }
        }
    }

    public func clear() {
        // Zed's Keychain item belongs to Zed, not to us — never delete it.
        // Clearing only drops our in-memory state and the access flag.
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
        hasKeychainAccess = false
    }
}

// MARK: - Transport abstraction

public enum ZedUsageResult: Sendable {
    case success(Data)
    case unauthorized
    case httpError(Int)
    case networkError
}

public protocol ZedUsageTransport: Sendable {
    func fetchUser(
        credentials: ZedCredentials,
        completion: @escaping @Sendable (ZedUsageResult) -> Void
    )
}

/// Production transport. Note the space-delimited Authorization value.
public struct URLSessionZedTransport: ZedUsageTransport {
    private let usersMeURL = URL(string: "https://cloud.zed.dev/client/users/me")!

    public init() {}

    public func fetchUser(
        credentials: ZedCredentials,
        completion: @escaping @Sendable (ZedUsageResult) -> Void
    ) {
        var request = URLRequest(url: usersMeURL)
        request.httpMethod = "GET"
        // Zed's client auth: "{user_id} {access_token}", NOT Bearer.
        request.setValue(credentials.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsageBar", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let deliver: (ZedUsageResult) -> Void = { result in
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

            Log.info("Zed users/me API response", .count(http.statusCode))

            switch http.statusCode {
            case 200:
                if let data = data {
                    deliver(.success(data))
                } else {
                    deliver(.networkError)
                }
            case 401, 403:
                deliver(.unauthorized)
            default:
                deliver(.httpError(http.statusCode))
            }
        }.resume()
    }
}
