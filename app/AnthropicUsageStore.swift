// PR 2c — first UsageProvider conformer.
//
// AnthropicUsageStore wraps the existing UsageManager (which retains all
// existing behaviour) and adapts it to the UsageProvider protocol. Nothing
// in UsageManager changes; this store forwards to it.
//
// This deliberate two-layer arrangement — Fetcher (Sendable value type,
// PR 2b), Store (ObservableObject, this PR), and legacy UsageManager
// (still the driver, unchanged) — lets us introduce the protocol
// without disturbing behaviour. A follow-up PR can eventually replace
// UsageManager with a direct Store implementation once the protocol
// surface has been exercised by multiple providers.

import Foundation
import SwiftUI
import Combine

// AnthropicUsageStore is `final` (not public) because its `init` takes a
// UsageManager, which is internal to the app module. This is intentional:
// the store is an app-level integration, not a library-level primitive.
// Library-level primitives live in Log.swift, AnthropicUsageFetcher.swift,
// and UsageProvider.swift.
// @preconcurrency defers strict actor-isolation checking against
// UsageProvider until PR 16 migrates the protocol itself to @MainActor.
// Under Swift 5 mode (current) this is a no-op; under Swift 6 it lets us
// stage the migration one provider at a time.
@MainActor
final class AnthropicUsageStore: @preconcurrency UsageProvider {

    let id: String = "anthropic"
    let displayName: String = "Claude (Anthropic)"
    let featureFlagKey: String = "features.anthropic.enabled"

    /// The underlying manager holds all state. AnthropicUsageStore just
    /// exposes it via the protocol. Its @Published properties drive the
    /// view; ProviderBox forwards their notifications.
    private let manager: UsageManager
    private var cancellables: Set<AnyCancellable> = []

    init(manager: UsageManager) {
        self.manager = manager
        // Re-broadcast the manager's changes as our own so ProviderBox
        // sees a single upstream. Combine subscription forwards them.
        manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Feature flag (Anthropic is on by default for existing users)

    /// Anthropic is unlike every other provider — it is on by default so
    /// existing v1.3.1 users see zero change on upgrade. Every subsequent
    /// provider defaults false and requires an explicit Settings toggle.
    var isEnabled: Bool {
        // If the key has never been written, default to true (compat with
        // pre-feature-flag builds). Writing false explicitly turns
        // Anthropic off, which is a supported state.
        if UserDefaults.standard.object(forKey: featureFlagKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: featureFlagKey)
    }

    var isConfigured: Bool {
        manager.hasFetchedData || UserDefaults.standard.string(forKey: "claude_session_cookie") != nil
    }

    var lastUpdated: Date? {
        manager.hasFetchedData ? manager.lastUpdated : nil
    }

    var errorMessage: String? {
        manager.errorMessage
    }

    // MARK: - Tiles

    var tiles: [UsageTile] {
        guard isEnabled else { return [] }
        guard manager.hasFetchedData else { return [] }

        var out: [UsageTile] = []

        out.append(UsageTile(
            id: "anthropic-5h",
            title: "Session (5 hour)",
            kind: .bar(
                fraction: manager.sessionPercentage,
                resetsAt: manager.sessionResetsAt,
                badge: nil
            )
        ))

        out.append(UsageTile(
            id: "anthropic-weekly",
            title: "Weekly (7 day)",
            kind: .bar(
                fraction: manager.weeklyPercentage,
                resetsAt: manager.weeklyResetsAt,
                badge: nil
            )
        ))

        if manager.hasWeeklySonnet {
            out.append(UsageTile(
                id: "anthropic-weekly-sonnet",
                title: "Weekly Sonnet (7 day)",
                kind: .bar(
                    fraction: manager.weeklySonnetPercentage,
                    resetsAt: manager.weeklySonnetResetsAt,
                    badge: nil
                )
            ))
        }

        // Fable surfaced only above 1% — same rule as the existing view.
        if manager.hasWeeklyFable && manager.weeklyFableUsage >= 1 {
            out.append(UsageTile(
                id: "anthropic-weekly-fable",
                title: "Weekly Fable (7 day)",
                kind: .bar(
                    fraction: manager.weeklyFablePercentage,
                    resetsAt: manager.weeklyFableResetsAt,
                    badge: nil
                )
            ))
        }

        return out
    }

    // MARK: - Actions

    func fetch() {
        guard isEnabled else { return }
        manager.fetchUsage()
    }

    func clear() {
        manager.clearSessionCookie()
    }
}
