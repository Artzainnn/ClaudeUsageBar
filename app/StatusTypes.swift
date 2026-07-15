// PR 21 — Status-related value types lifted out of ClaudeUsageBar.swift
// so `StatusSource.swift` (and, by extension, `StatusManager`) can move
// into the SwiftPM library target and be exercised by TestRunner.
//
// These types were previously defined in the app-only compile unit
// (ClaudeUsageBar.swift). Nothing about their shape has changed — the
// move is source-compatible for every call site in the app bundle.
// All types are `public` so TestRunner can construct fixtures.

import Foundation

/// A live-or-recent statuspage incident. `status` is one of
/// `investigating | identified | monitoring | resolved | postmortem`.
/// Resolved/postmortem entries are filtered out by
/// `StatuspageV2Parser` before construction; the field is retained
/// verbatim for any consumer wanting to render the state.
public struct StatusIncident: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let latestUpdate: String
    public let updatedAt: Date?
    public let componentIds: [String]

    public init(
        id: String,
        name: String,
        status: String,
        latestUpdate: String,
        updatedAt: Date?,
        componentIds: [String]
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.latestUpdate = latestUpdate
        self.updatedAt = updatedAt
        self.componentIds = componentIds
    }
}

/// A statuspage component whose current status is not `operational`.
public struct AffectedComponent: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// One of `degraded_performance | partial_outage | major_outage |
    /// under_maintenance`. Google Cloud sources synthesise the same
    /// vocabulary from `status_impact` + `severity`.
    public let status: String

    public init(id: String, name: String, status: String) {
        self.id = id
        self.name = name
        self.status = status
    }
}

/// A statuspage component (regardless of current status). Used for the
/// tracked-component picker in the popover.
public struct StatusComponent: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// `operational | degraded_performance | partial_outage |
    /// major_outage | under_maintenance`.
    public let status: String

    public init(id: String, name: String, status: String) {
        self.id = id
        self.name = name
        self.status = status
    }
}

/// Cold-start fallback list of Anthropic components used before the
/// first successful fetch populates `StatusManager.allComponents`.
/// Ordering matches the popover's tracked-component picker.
public let defaultTrackedComponents: [StatusComponent] = [
    StatusComponent(id: "c-claude-ai",      name: "claude.ai",                            status: "operational"),
    StatusComponent(id: "c-claude-console", name: "Claude Console (platform.claude.com)", status: "operational"),
    StatusComponent(id: "c-claude-api",     name: "Claude API (api.anthropic.com)",       status: "operational"),
    StatusComponent(id: "c-claude-code",    name: "Claude Code",                          status: "operational"),
    StatusComponent(id: "c-claude-cowork",  name: "Claude Cowork",                        status: "operational"),
    StatusComponent(id: "c-claude-gov",     name: "Claude for Government",                status: "operational"),
]

/// Default tracked-component set. Excludes "Claude for Government" —
/// the vast majority of users are not on the FedRAMP tenant, and
/// tracking it produces false-positive alerts. Users can opt in via
/// the popover's tracked-component picker.
public let defaultTrackedComponentIdSet: Set<String> = Set(
    defaultTrackedComponents.map { $0.id }.filter { $0 != "c-claude-gov" }
)
