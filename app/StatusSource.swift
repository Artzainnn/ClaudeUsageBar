// PR 14 — StatusSource abstraction (feature-flagged off).
//
// The existing `StatusManager` polls `status.claude.com` directly. This
// file introduces a `StatusSource` protocol so the manager can host
// multiple provider status pages: Anthropic (existing), OpenAI,
// GitHub, xAI (via grokinc.statuspage.io), and Google Cloud.
//
// Feature posture — `features.multiStatus.enabled` defaults false.
// When off, `StatusManager` continues to poll Anthropic directly via
// the existing code path; the new sources are unused. When on, the
// manager fetches every enabled source and aggregates per-source
// snapshots into a unified indicator.
//
// This PR ships the protocol + four new sources with the aggregation
// primitive. The popover UI still renders the Anthropic-only view;
// per-source card rendering lands in a follow-up PR.
//
// Verified upstream (research pass 2026-07-15):
//
//   - Anthropic:    https://status.claude.com/api/v2/summary.json
//                   statuspage.io v2, full shape.
//   - OpenAI:       https://status.openai.com/api/v2/summary.json
//                   statuspage.io v2, `.incidents` optional (absent
//                   from response when empty).
//   - GitHub:       https://www.githubstatus.com/api/v2/summary.json
//                   statuspage.io v2, full shape.
//   - xAI:          https://grokinc.statuspage.io/api/v2/summary.json
//                   statuspage.io v2, full shape. NOTE: the marketing
//                   URL `https://status.x.ai/api/v2/summary.json`
//                   returns 403 for non-browser clients (Cloudflare
//                   bot management); use the canonical
//                   grokinc.statuspage.io host.
//   - Google Cloud: https://status.cloud.google.com/incidents.json
//                   Google's own bare-array format, NOT statuspage.io.

import Foundation

// MARK: - Common types

/// Per-source snapshot delivered to `StatusManager` after a fetch.
struct StatusSnapshot: Equatable, Sendable {
    /// One of statuspage.io's four indicator strings, or an
    /// equivalent Google-Cloud-derived value: `none | minor | major
    /// | critical`. Empty string when the fetch failed and no prior
    /// state should be trusted.
    var indicator: String
    /// Human description ("All Systems Operational", "Partially
    /// Degraded Service"). Empty when the fetch failed.
    var description: String
    /// Non-resolved incidents (best-effort — some sources omit
    /// resolved incidents from the summary endpoint).
    var incidents: [StatusIncident]
    /// All known components. Empty for sources that do not expose a
    /// component list (Google Cloud).
    var components: [StatusComponent]
    /// Non-operational components.
    var affectedComponents: [AffectedComponent]

    init(
        indicator: String = "",
        description: String = "",
        incidents: [StatusIncident] = [],
        components: [StatusComponent] = [],
        affectedComponents: [AffectedComponent] = []
    ) {
        self.indicator = indicator
        self.description = description
        self.incidents = incidents
        self.components = components
        self.affectedComponents = affectedComponents
    }
}

/// A single source that produces status snapshots on demand.
internal protocol StatusSource: Sendable {
    /// Machine identifier: `"anthropic" | "openai" | "github" |
    /// "xai" | "gcloud"`. Used for feature flags and per-source
    /// UserDefaults keys.
    var id: String { get }

    /// User-facing card title.
    var displayName: String { get }

    /// Public web URL for the "View full status" link.
    var webURL: URL { get }

    /// Feature-flag key that gates polling of this source. When the
    /// flag is false, `StatusManager` should not call `fetch(_:)`.
    var featureFlagKey: String { get }

    /// Fetch a snapshot. Completion delivered on an arbitrary
    /// queue; the caller must hop to main before touching UI state.
    /// Networking failures deliver an empty `StatusSnapshot()` — do
    /// NOT complete with nil, so the aggregation math stays simple.
    func fetch(_ completion: @escaping @Sendable (StatusSnapshot) -> Void)
}

// MARK: - Statuspage.io v2 shared parser

/// Parses a statuspage.io v2 `/api/v2/summary.json` payload. Anthropic,
/// OpenAI, GitHub, and xAI (via grokinc.statuspage.io) all share this
/// shape.
///
/// Handles OpenAI's slim variant that omits `.incidents` when empty:
/// missing top-level `incidents` yields an empty list rather than a
/// parse failure.
internal enum StatuspageV2Parser {

    static func parse(_ data: Data) -> StatusSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? [String: Any],
              let indicator = status["indicator"] as? String,
              let description = status["description"] as? String else {
            return nil
        }

        var incidents: [StatusIncident] = []
        if let raw = json["incidents"] as? [[String: Any]] {
            for inc in raw {
                guard let id = inc["id"] as? String,
                      let name = inc["name"] as? String,
                      let st = inc["status"] as? String else { continue }
                // Filter resolved / postmortem — they aren't
                // user-actionable on a live status card.
                if st == "resolved" || st == "postmortem" { continue }
                let updates = inc["incident_updates"] as? [[String: Any]] ?? []
                let latest = (updates.first?["body"] as? String) ?? ""
                let compIds = (inc["components"] as? [[String: Any]] ?? [])
                    .compactMap { $0["id"] as? String }
                incidents.append(StatusIncident(
                    id: id, name: name, status: st, latestUpdate: latest,
                    updatedAt: parseIsoDate(inc: inc),
                    componentIds: compIds
                ))
            }
        }

        var components: [StatusComponent] = []
        var affected: [AffectedComponent] = []
        if let raw = json["components"] as? [[String: Any]] {
            for c in raw {
                guard let id = c["id"] as? String,
                      let name = c["name"] as? String,
                      let st = c["status"] as? String else { continue }
                components.append(StatusComponent(id: id, name: name, status: st))
                if st != "operational" {
                    affected.append(AffectedComponent(id: id, name: name, status: st))
                }
            }
        }

        return StatusSnapshot(
            indicator: indicator,
            description: description,
            incidents: incidents,
            components: components,
            affectedComponents: affected
        )
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseIsoDate(inc: [String: Any]) -> Date? {
        let updates = inc["incident_updates"] as? [[String: Any]] ?? []
        let dateStr = (updates.first?["created_at"] as? String)
            ?? (inc["updated_at"] as? String)
        guard let s = dateStr else { return nil }
        return isoFormatter.date(from: s) ?? isoFormatterNoFractional.date(from: s)
    }
}

// MARK: - Statuspage.io concrete sources

/// Base type for statuspage.io v2 sources. Concrete sources supply
/// endpoint URL, id, and display name.
internal struct StatuspageV2Source: StatusSource, Sendable {
    let id: String
    let displayName: String
    let webURL: URL
    let featureFlagKey: String
    let endpoint: URL

    init(
        id: String,
        displayName: String,
        webURL: URL,
        featureFlagKey: String,
        endpoint: URL
    ) {
        self.id = id
        self.displayName = displayName
        self.webURL = webURL
        self.featureFlagKey = featureFlagKey
        self.endpoint = endpoint
    }

    func fetch(_ completion: @escaping @Sendable (StatusSnapshot) -> Void) {
        let request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let snap = StatuspageV2Parser.parse(data) else {
                completion(StatusSnapshot())
                return
            }
            completion(snap)
        }.resume()
    }
}

internal extension StatuspageV2Source {
    static let anthropic = StatuspageV2Source(
        id: "anthropic",
        displayName: "Anthropic",
        webURL: URL(string: "https://status.claude.com")!,
        featureFlagKey: "features.status.anthropic.enabled",
        endpoint: URL(string: "https://status.claude.com/api/v2/summary.json")!
    )

    static let openai = StatuspageV2Source(
        id: "openai",
        displayName: "OpenAI",
        webURL: URL(string: "https://status.openai.com")!,
        featureFlagKey: "features.status.openai.enabled",
        endpoint: URL(string: "https://status.openai.com/api/v2/summary.json")!
    )

    static let github = StatuspageV2Source(
        id: "github",
        displayName: "GitHub",
        webURL: URL(string: "https://www.githubstatus.com")!,
        featureFlagKey: "features.status.github.enabled",
        endpoint: URL(string: "https://www.githubstatus.com/api/v2/summary.json")!
    )

    // xAI's marketing status URL (status.x.ai) 403s all non-browser
    // clients via Cloudflare bot management (verified 2026-07-15).
    // Use the canonical statuspage.io host.
    static let xai = StatuspageV2Source(
        id: "xai",
        displayName: "xAI (Grok)",
        webURL: URL(string: "https://grokinc.statuspage.io")!,
        featureFlagKey: "features.status.xai.enabled",
        endpoint: URL(string: "https://grokinc.statuspage.io/api/v2/summary.json")!
    )
}

// MARK: - Google Cloud (bespoke shape)

/// Google Cloud's `incidents.json` is a bare array of incident
/// objects, NOT statuspage.io. There is no server-side overall
/// indicator; we synthesise one from the active-incident severities.
internal enum GoogleCloudStatusParser {

    /// Parse `incidents.json`. Filters to currently-affecting incidents
    /// (`end` missing or null OR `currently_affected_locations` non-
    /// empty), maps each to a `StatusIncident`, and derives an overall
    /// indicator from the worst active `status_impact`/`severity`
    /// pair.
    static func parse(_ data: Data) -> StatusSnapshot? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var active: [StatusIncident] = []
        var affected: [AffectedComponent] = []
        var worstSeverity = 0

        for inc in arr {
            let end = inc["end"]
            let hasEnd = !(end is NSNull) && (end as? String) != nil
            let currentlyAffecting = (inc["currently_affected_locations"] as? [Any])?.isEmpty == false
            // Include if not ended, OR if currently_affected_locations
            // is still populated (Google sometimes leaves `end` empty
            // for ongoing incidents).
            guard !hasEnd || currentlyAffecting else { continue }

            guard let id = inc["id"] as? String,
                  let name = inc["external_desc"] as? String else { continue }
            let statusImpact = (inc["status_impact"] as? String) ?? "SERVICE_INFORMATION"
            let severity = (inc["severity"] as? String) ?? "low"
            let mostRecent = inc["most_recent_update"] as? [String: Any]
            let latest = (mostRecent?["text"] as? String) ?? ""

            let sevScore = severityScore(statusImpact: statusImpact, severity: severity)
            if sevScore > worstSeverity { worstSeverity = sevScore }

            let compIds = (inc["affected_products"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String }
            for p in inc["affected_products"] as? [[String: Any]] ?? [] {
                if let pid = p["id"] as? String, let pname = p["title"] as? String {
                    affected.append(AffectedComponent(id: pid, name: pname, status: mapStatus(sevScore: sevScore)))
                }
            }

            active.append(StatusIncident(
                id: id,
                name: name,
                status: statusImpact,
                latestUpdate: latest,
                updatedAt: parseGCTimestamp(mostRecent?["when"] as? String),
                componentIds: compIds
            ))
        }

        let (indicator, description) = mapOverall(worstSeverity: worstSeverity)
        return StatusSnapshot(
            indicator: indicator,
            description: description,
            incidents: active,
            components: [],  // GC has no top-level component list
            affectedComponents: affected
        )
    }

    /// Map (status_impact × severity) to a coarse severity score.
    /// Higher is worse. `AVAILABLE` scores 0; `SERVICE_INFORMATION`
    /// with low severity scores 0-1; `SERVICE_DISRUPTION` and
    /// `SERVICE_OUTAGE` scale from 2 to 3.
    static func severityScore(statusImpact: String, severity: String) -> Int {
        // Prefer explicit outage/disruption impact regardless of the
        // separately-published severity field (which sometimes lags).
        switch statusImpact {
        case "SERVICE_OUTAGE":     return 3
        case "SERVICE_DISRUPTION":
            switch severity {
            case "high":   return 3
            case "medium": return 2
            default:       return 2
            }
        case "SERVICE_INFORMATION":
            switch severity {
            case "high":   return 2
            case "medium": return 1
            default:       return 1
            }
        default:                   return 0
        }
    }

    static func mapStatus(sevScore: Int) -> String {
        switch sevScore {
        case 3: return "major_outage"
        case 2: return "partial_outage"
        case 1: return "degraded_performance"
        default: return "operational"
        }
    }

    static func mapOverall(worstSeverity: Int) -> (indicator: String, description: String) {
        switch worstSeverity {
        case 0: return ("none",     "All systems operational")
        case 1: return ("minor",    "Minor service disruption")
        case 2: return ("major",    "Service disruption")
        default: return ("critical", "Service outage")
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parseGCTimestamp(_ raw: String?) -> Date? {
        guard let s = raw else { return nil }
        return iso.date(from: s) ?? isoNoFrac.date(from: s)
    }
}

internal struct GoogleCloudStatusSource: StatusSource, Sendable {
    let id: String = "gcloud"
    let displayName: String = "Google Cloud"
    let webURL: URL = URL(string: "https://status.cloud.google.com")!
    let featureFlagKey: String = "features.status.gcloud.enabled"
    let endpoint: URL = URL(string: "https://status.cloud.google.com/incidents.json")!

    init() {}

    func fetch(_ completion: @escaping @Sendable (StatusSnapshot) -> Void) {
        let request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let snap = GoogleCloudStatusParser.parse(data) else {
                completion(StatusSnapshot())
                return
            }
            completion(snap)
        }.resume()
    }
}

// MARK: - Aggregation

internal enum StatusAggregator {

    /// Reduce a set of per-source snapshots to a single indicator
    /// using statuspage.io's severity ordering. Empty indicators
    /// (fetch failure) contribute nothing.
    static func aggregateIndicator(_ snapshots: [StatusSnapshot]) -> String {
        var worst = 0
        for s in snapshots {
            let score: Int
            switch s.indicator {
            case "none":     score = 0
            case "minor":    score = 1
            case "major":    score = 2
            case "critical": score = 3
            default:         score = -1  // failed fetch — do not
                                         // downgrade other sources'
                                         // signals
            }
            if score > worst { worst = score }
        }
        switch worst {
        case 0: return "none"
        case 1: return "minor"
        case 2: return "major"
        default: return "critical"
        }
    }
}
