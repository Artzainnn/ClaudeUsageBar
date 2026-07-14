// PR 3-BE — Codex UsageProvider conformer (dark code, feature-flag off).
//
// CodexUsageStore is the second UsageProvider (after AnthropicUsageStore).
// It holds the observable state for the Codex tiles and drives the fetch
// against `GET https://chatgpt.com/backend-api/wham/usage`, parsing the
// response through the Sendable CodexUsageFetcher.
//
// Feature posture in PR 3-BE:
//   - `features.codex.enabled` defaults FALSE. Every provider except
//     Anthropic is opt-in; existing v1.3.1 users see zero change.
//   - Nothing appends a CodexUsageStore into AppDelegate.providers yet.
//     The popover wiring, Settings toggle, and shared-timer registration
//     land in PR 3-UI. This file is compiled and unit-tested but inert at
//     runtime until the flag is turned on and the store is registered.
//
// Auth posture (plan Phase 1): read `~/.codex/auth.json` only. Do NOT
// initiate an in-app OAuth PKCE flow — using the Codex CLI's client id from
// a third-party GUI is impersonation-adjacent. Do NOT write back to
// auth.json on 401; instead surface a "session expired, run codex auth
// login" state. Writeback is deferred to Phase 1b.
//
// Labels: every tile is prefixed "Codex", never "ChatGPT". The 5-hour and
// weekly windows cover the Codex CLI, IDE extensions, Slack, and Cloud
// tasks — one shared pool. General GPT chat is not counted here.

import Foundation
import SwiftUI
import Combine

// @MainActor because the store owns @Published state observed by SwiftUI.
// @preconcurrency on the UsageProvider conformance defers strict
// actor-isolation checking until PR 16 migrates the protocol to @MainActor —
// identical staging to AnthropicUsageStore.
@MainActor
public final class CodexUsageStore: UsageProvider {

    public let id: String = "codex"
    public let displayName: String = "Codex (OpenAI)"
    public let featureFlagKey: String = "features.codex.enabled"

    // MARK: Observable state

    /// The most recent successfully parsed snapshot. Nil before the first
    /// successful fetch, or after a fetch that failed.
    @Published public private(set) var snapshot: CodexUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?
    /// True when auth.json is present and yields usable credentials. Set by
    /// each fetch attempt so the tile can distinguish "not configured yet"
    /// (needs onboarding card) from "configured but fetch failed" (error).
    @Published public private(set) var hasCredentials: Bool = false
    /// True when the last failure was a 401 — the user must re-run
    /// `codex auth login`. Distinct from a generic network error.
    @Published public private(set) var sessionExpired: Bool = false

    // Injected dependencies keep the store unit-testable. The default
    // production values read the real environment and hit the real
    // endpoint; tests inject a fixed environment and a stubbed transport.
    private let environment: [String: String]
    private let transport: CodexUsageTransport
    // Overrides UserDefaults for the feature flag in tests so a test does
    // not have to mutate the shared standard defaults. Defaults to .standard.
    private let defaults: UserDefaults

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: CodexUsageTransport = URLSessionCodexTransport(),
        defaults: UserDefaults = .standard
    ) {
        self.environment = environment
        self.transport = transport
        self.defaults = defaults
    }

    // MARK: - UsageProvider: feature flag

    /// Codex is opt-in. Unlike Anthropic (on by default for compat), an
    /// unset flag means OFF. The user turns it on in Settings (PR 3-UI).
    public var isEnabled: Bool {
        defaults.bool(forKey: featureFlagKey)
    }

    /// Configured means auth.json exists and parses. We probe the file
    /// lazily so `isConfigured` is honest even before the first fetch.
    public var isConfigured: Bool {
        (try? CodexUsageFetcher.readCredentials(environment: environment)) != nil
    }

    public var lastUpdated: Date? { lastUpdatedAt }

    public var errorMessage: String? { lastError }

    // MARK: - UsageProvider: tiles

    public var tiles: [UsageTile] {
        guard isEnabled else { return [] }

        // Not configured — render the onboarding card telling the user to
        // run `codex auth login`. This is a needsAccess tile, matching the
        // protocol's first-run onboarding kind.
        if !isConfigured {
            return [UsageTile(
                id: "codex-needs-auth",
                title: "Codex",
                kind: .needsAccess(
                    path: CodexUsageFetcher.authFileURL(environment: environment).path,
                    guidance: "Run `codex auth login` in a terminal, then click Refresh."
                )
            )]
        }

        // Configured but the session expired (401) — a distinct actionable
        // state, again pointing at re-login rather than a generic error.
        if sessionExpired {
            return [UsageTile(
                id: "codex-session-expired",
                title: "Codex",
                kind: .text(
                    status: "Codex session expired",
                    subtitle: "Run `codex auth login` in a terminal, then click Refresh."
                )
            )]
        }

        guard let snap = snapshot else {
            // Configured, no error, but no data yet (pre-first-fetch). Empty
            // tiles — the popover shows nothing for Codex until data lands,
            // matching Anthropic's pre-fetch behaviour.
            return []
        }

        var out: [UsageTile] = []

        if let primary = snap.primaryWindow {
            out.append(UsageTile(
                id: "codex-5h",
                title: "Codex (5 hour)",
                kind: .bar(
                    fraction: fraction(primary.usedPercent),
                    resetsAt: primary.resetAt,
                    badge: nil
                )
            ))
        }

        if let secondary = snap.secondaryWindow {
            out.append(UsageTile(
                id: "codex-weekly",
                title: "Codex (7 day)",
                kind: .bar(
                    fraction: fraction(secondary.usedPercent),
                    resetsAt: secondary.resetAt,
                    badge: nil
                )
            ))
        }

        // Zero or more model-specific limit lanes (per-model or promotional
        // caps, e.g. Spark). Empty on most accounts. Each lane's usage is
        // nested under its own primary/secondary window; a lane can surface
        // up to two bars. Index disambiguates the tile id when the server
        // omits a limit_name.
        for (index, limit) in snap.additionalLimits.enumerated() {
            let label = limit.limitName ?? limit.meteredFeature ?? "Additional limit \(index + 1)"
            if let primary = limit.primaryWindow {
                out.append(UsageTile(
                    id: "codex-additional-\(index)-5h",
                    title: "Codex \(label) (5 hour)",
                    kind: .bar(
                        fraction: fraction(primary.usedPercent),
                        resetsAt: primary.resetAt,
                        badge: nil
                    )
                ))
            }
            if let secondary = limit.secondaryWindow {
                out.append(UsageTile(
                    id: "codex-additional-\(index)-weekly",
                    title: "Codex \(label) (7 day)",
                    kind: .bar(
                        fraction: fraction(secondary.usedPercent),
                        resetsAt: secondary.resetAt,
                        badge: nil
                    )
                ))
            }
        }

        // Optional credits tile — only when the account actually carries a
        // credit balance. Suppressed otherwise so free/subscription accounts
        // do not see a confusing "0" credit line.
        if let credits = snap.credits, credits.hasCredits, let balance = credits.balance {
            out.append(UsageTile(
                id: "codex-credits",
                title: "Codex credits",
                kind: .text(
                    status: credits.unlimited ? "Unlimited" : balance,
                    subtitle: credits.overageLimitReached ? "Overage limit reached" : nil
                )
            ))
        }

        return out
    }

    /// Convert a 0…100 integer percentage into a 0.0…1.0 fraction, clamped
    /// so a malformed >100 value cannot overflow a progress bar.
    private func fraction(_ percent: Int) -> Double {
        min(max(Double(percent) / 100.0, 0.0), 1.0)
    }

    // MARK: - Result application (testable seam)

    /// Apply a transport result to observable state. Extracted from the
    /// async completion so the TestRunner can drive every branch (success,
    /// 401 → sessionExpired, httpError, networkError) synchronously without
    /// touching the network. `now` is injected so the lastUpdatedAt
    /// assertion is deterministic.
    public func apply(_ result: CodexUsageResult, now: Date = Date()) {
        switch result {
        case .success(let data):
            do {
                let snap = try CodexUsageFetcher.parse(data)
                self.snapshot = snap
                self.lastUpdatedAt = now
                self.lastError = nil
                self.sessionExpired = false
            } catch {
                self.lastError = "Could not parse Codex usage"
            }
        case .unauthorized:
            // 401 — surface the re-login state. Do NOT write back to
            // auth.json in PR 3-BE (Phase 1). Keep the last snapshot so the
            // popover does not flash empty, but flag expiry.
            self.sessionExpired = true
            self.lastError = nil
        case .httpError(let code):
            self.lastError = "HTTP \(code)"
        case .networkError:
            self.lastError = "Network error"
        }
    }

    /// Test-only helper to set credential presence without a real auth.json.
    /// Used by tile-rendering tests that inject a store with a fixed
    /// environment. Never called in production.
    public func setHasCredentialsForTesting(_ value: Bool) {
        self.hasCredentials = value
    }

    // MARK: - UsageProvider: actions

    public func fetch() {
        guard isEnabled else { return }

        let creds: CodexCredentials
        do {
            creds = try CodexUsageFetcher.readCredentials(environment: environment)
        } catch CodexAuthError.authFileMissing {
            // Not configured. Clear any stale data; tiles render the
            // onboarding card via isConfigured == false.
            hasCredentials = false
            snapshot = nil
            lastError = nil
            sessionExpired = false
            return
        } catch {
            hasCredentials = false
            snapshot = nil
            lastError = "Codex credentials unreadable"
            sessionExpired = false
            return
        }

        hasCredentials = true

        transport.fetchUsage(credentials: creds) { [weak self] result in
            // Hop to the main actor to apply @Published state. Task {
            // @MainActor } is safe whichever queue the transport delivers on
            // (cannot trap like assumeIsolated). The application logic lives
            // in `apply(_:)` so the TestRunner can drive every branch directly.
            Task { @MainActor [weak self] in self?.apply(result) }
        }
    }

    public func clear() {
        // PR 3-BE does not own the credential file — auth.json belongs to the
        // Codex CLI. "Clear" only drops our in-memory state; it never deletes
        // the user's CLI login. Turning the provider off is done via the
        // Settings toggle (PR 3-UI), not here.
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
        sessionExpired = false
        hasCredentials = false
    }
}

// MARK: - Transport abstraction

/// Result of a usage fetch. `unauthorized` is split out from `httpError` so
/// the store can render the distinct "session expired" state on 401.
public enum CodexUsageResult: Sendable {
    case success(Data)
    case unauthorized
    case httpError(Int)
    case networkError
}

/// Seam over the network so the store is unit-testable without hitting the
/// live endpoint. The completion MUST be delivered on the main queue.
public protocol CodexUsageTransport: Sendable {
    func fetchUsage(
        credentials: CodexCredentials,
        completion: @escaping @Sendable (CodexUsageResult) -> Void
    )
}

/// Production transport. Issues the real request with the Bearer token and
/// account-id header, mirroring the Codex CLI's own request. The response
/// body is never logged (it is tied to the user's account) — only the
/// status code goes through the categorical logger, matching the Anthropic
/// fetch site and satisfying the CI credential-leak guard.
public struct URLSessionCodexTransport: CodexUsageTransport {
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init() {}

    public func fetchUsage(
        credentials: CodexCredentials,
        completion: @escaping @Sendable (CodexUsageResult) -> Void
    ) {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsageBar", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let deliver: (CodexUsageResult) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }

            if error != nil {
                // Error object may reference the request; do not log it (it
                // can carry the URL with headers in some transports). A
                // generic marker is enough.
                deliver(.networkError)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                deliver(.networkError)
                return
            }

            Log.info("Codex usage API response", .count(http.statusCode))

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
