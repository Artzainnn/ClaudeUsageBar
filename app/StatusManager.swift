// PR 21 — StatusManager lifted from ClaudeUsageBar.swift into the
// SwiftPM library so TestRunner can exercise it directly, AND the
// Anthropic fetch/parse now routes through `StatuspageV2Source.anthropic`
// instead of duplicating the statuspage.io v2 logic inline.
//
// Behavioural preservation (verified line-by-line against the pre-
// migration StatusManager in ClaudeUsageBar.swift ≤ de8fe77):
//
//   - `fetch()` still hits status.claude.com/api/v2/summary.json (via
//     `StatuspageV2Source.anthropic.endpoint`).
//   - First-fetch default component selection excludes "Claude for
//     Government" — unchanged.
//   - Notification-on-transition uses the *effective* (tracked-
//     component-filtered) indicator — unchanged.
//   - `hasFetched`, `lastUpdated`, `allComponents`, `indicator`,
//     `statusDescription`, `incidents`, `affectedComponents`,
//     `selectedComponentIds` — all still written on the main actor.
//
// The one strengthening: an empty snapshot from the source (network
// failure / malformed JSON) now no-ops rather than clobbering prior
// good state. Matches the contract PR #85 established for the four
// extra sources. Anthropic has never served an empty/malformed
// summary in the app's history — the guard is defensive.

import SwiftUI
import AppKit

@MainActor
public class StatusManager: ObservableObject {
    @Published public var indicator: String = "none"        // none | minor | major | critical (raw, global)
    @Published public var statusDescription: String = "All systems operational"
    @Published public var incidents: [StatusIncident] = []
    @Published public var affectedComponents: [AffectedComponent] = []
    @Published public var allComponents: [StatusComponent] = defaultTrackedComponents
    @Published public var selectedComponentIds: Set<String> = defaultTrackedComponentIdSet
    @Published public var lastUpdated: Date?
    @Published public var hasFetched: Bool = false

    // Injectable Anthropic source. Defaults to the real statuspage.io
    // v2 endpoint; tests inject a `StubStatusSource` to drive
    // deterministic snapshot delivery.
    private let anthropicSource: any StatusSource

    // PR 20 — multi-status extension. Each additional source (OpenAI,
    // GitHub, xAI, Google Cloud) polls independently when its
    // feature flag is on. The Anthropic path above is unchanged.
    //
    // `extraSources` is the static list of enabled sources; the
    // corresponding snapshots live in `extraSnapshots` keyed by
    // source.id. A card renders for every source whose snapshot has
    // been populated at least once (empty snapshots suppress the
    // card so the popover doesn't show noise on cold start).
    @Published public var extraSnapshots: [String: StatusSnapshot] = [:]
    // Last-notified per-source indicator, keyed by source.id. Used
    // for the notification-on-transition path.
    private var lastNotifiedIndicators: [String: String] = [:]

    /// Registered non-Anthropic status sources. Order matters — cards
    /// render in this order. Every source is behind a feature flag
    /// (`features.status.<id>.enabled`).
    public static let extraSources: [any StatusSource] = [
        StatuspageV2Source.openai,
        StatuspageV2Source.github,
        StatuspageV2Source.xai,
        GoogleCloudStatusSource(),
    ]

    /// Subset of `extraSources` enabled by the user.
    public var enabledExtraSources: [any StatusSource] {
        Self.extraSources.filter { source in
            UserDefaults.standard.bool(forKey: source.featureFlagKey)
        }
    }

    /// Rendered cards for every enabled source that has a
    /// non-empty snapshot. Consumers get `(source, snapshot)` pairs
    /// in the static extraSources order.
    public var extraStatusCards: [(source: any StatusSource, snapshot: StatusSnapshot)] {
        enabledExtraSources.compactMap { source in
            guard let snap = extraSnapshots[source.id],
                  !snap.indicator.isEmpty else { return nil }
            return (source, snap)
        }
    }

    /// Kick off a fetch of every ENABLED extra source. Each source
    /// completes on an arbitrary queue; results apply on the main
    /// actor. Failed fetches deliver an empty snapshot which we
    /// ignore (do not overwrite a good prior snapshot with an empty
    /// one).
    public func fetchExtraSources() {
        for source in enabledExtraSources {
            let sourceId = source.id
            let sourceLabel = source.displayName
            source.fetch { [weak self] snap in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    // An empty snapshot indicates the source's own
                    // fetch failed. Keep the prior snapshot in place
                    // rather than showing an empty card.
                    guard !snap.indicator.isEmpty else { return }
                    let previous = self.extraSnapshots[sourceId]?.indicator
                    self.extraSnapshots[sourceId] = snap
                    // Notification-on-transition, gated by
                    // `status_notifications_enabled` (same key as
                    // Anthropic).
                    if let previous = previous, previous != snap.indicator,
                       UserDefaults.standard.bool(forKey: "status_notifications_enabled") {
                        let notification = NSUserNotification()
                        if snap.indicator == "none" {
                            notification.title = "\(sourceLabel) is back online"
                            notification.informativeText = "All systems operational"
                        } else {
                            notification.title = "\(sourceLabel) status: \(snap.description)"
                            notification.informativeText = "Visit the \(sourceLabel) status page for details"
                        }
                        notification.soundName = NSUserNotificationDefaultSoundName
                        NSUserNotificationCenter.default.deliver(notification)
                    }
                    self.lastNotifiedIndicators[sourceId] = snap.indicator
                }
            }
        }
    }

    /// Clear every extra-source snapshot. Called when the user
    /// disables the multi-status flag OR when they clear a specific
    /// source's feature flag.
    public func clearExtraSource(_ id: String) {
        extraSnapshots.removeValue(forKey: id)
        lastNotifiedIndicators.removeValue(forKey: id)
    }

    public init(anthropicSource: any StatusSource = StatuspageV2Source.anthropic) {
        self.anthropicSource = anthropicSource
        if let saved = UserDefaults.standard.array(forKey: "tracked_component_ids") as? [String] {
            selectedComponentIds = Set(saved)
        }
        // Clean up legacy debug pref if present
        UserDefaults.standard.removeObject(forKey: "status_preview_mode")
    }

    public func toggleComponent(_ id: String) {
        if selectedComponentIds.contains(id) {
            selectedComponentIds.remove(id)
        } else {
            selectedComponentIds.insert(id)
        }
        UserDefaults.standard.set(Array(selectedComponentIds), forKey: "tracked_component_ids")
    }

    public func isTracked(_ id: String) -> Bool {
        selectedComponentIds.contains(id)
    }

    // MARK: - Filtered/effective views (respect tracked components)

    public var filteredAffectedComponents: [AffectedComponent] {
        affectedComponents.filter { selectedComponentIds.contains($0.id) }
    }

    public var filteredIncidents: [StatusIncident] {
        incidents.filter { incident in
            guard !incident.componentIds.isEmpty else { return true }
            return incident.componentIds.contains(where: { selectedComponentIds.contains($0) })
        }
    }

    public var effectiveIndicator: String {
        let trackedComponents = allComponents.filter { selectedComponentIds.contains($0.id) }
        let max = trackedComponents.map { severity(for: $0.status) }.max() ?? 0
        switch max {
        case 0:  return "none"
        case 1:  return "minor"
        case 2:  return "major"
        default: return "critical"
        }
    }

    private func severity(for componentStatus: String) -> Int {
        switch componentStatus {
        case "operational":          return 0
        case "under_maintenance":    return 1
        case "degraded_performance": return 1
        case "partial_outage":       return 2
        case "major_outage":         return 3
        default:                     return 0
        }
    }

    // MARK: - Fetch/apply pipeline (now routed via StatusSource)

    /// Kick off an Anthropic status fetch. Completes on an arbitrary
    /// queue; result applies on the main actor via `apply(_:)`.
    public func fetch() {
        anthropicSource.fetch { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.apply(snapshot)
            }
        }
    }

    /// Apply a fetched snapshot. Public so tests can drive the
    /// pipeline synchronously without spinning a URLSession stub.
    public func apply(_ snapshot: StatusSnapshot) {
        // Failed fetch — leave prior state untouched.
        guard !snapshot.indicator.isEmpty else { return }

        let isFirstFetch = !hasFetched

        indicator = snapshot.indicator
        statusDescription = snapshot.description
        incidents = snapshot.incidents
        affectedComponents = snapshot.affectedComponents
        if !snapshot.components.isEmpty {
            allComponents = snapshot.components
            // First time we see real components: track all except Claude for Government by default
            if UserDefaults.standard.array(forKey: "tracked_component_ids") == nil {
                let defaultIds = snapshot.components
                    .filter { !$0.name.localizedCaseInsensitiveContains("Government") }
                    .map { $0.id }
                selectedComponentIds = Set(defaultIds)
                UserDefaults.standard.set(Array(selectedComponentIds),
                                          forKey: "tracked_component_ids")
            }
        }
        lastUpdated = Date()
        hasFetched = true

        // Notify on transitions of EFFECTIVE (filtered) indicator
        let effective = effectiveIndicator
        let previous = UserDefaults.standard.string(forKey: "last_effective_indicator")
        if !isFirstFetch, let previous = previous, previous != effective {
            notifyStatusChange(to: effective, description: snapshot.description)
        }
        UserDefaults.standard.set(effective, forKey: "last_effective_indicator")
    }

    private func notifyStatusChange(to indicator: String, description: String) {
        guard UserDefaults.standard.bool(forKey: "status_notifications_enabled") else { return }

        let notification = NSUserNotification()
        if indicator == "none" {
            notification.title = "Claude is back online"
            notification.informativeText = "All systems operational"
        } else {
            notification.title = "Claude status: \(description)"
            notification.informativeText = "Visit status.anthropic.com for details"
        }
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent status-change notification: \(indicator)")
    }
}
