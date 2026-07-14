// PR 13-BE — Zoo Code UsageProvider store (feature-flag off).
//
// Twin of RooUsageStore, differing only in extensionId (.zoo vs .roo),
// id, displayName, and feature-flag key. See RooUsageStore for the
// full concurrency-model rationale and 3cc provenance.
//
// Zoo Code is the active fork of Roo (archived May 2026). Kept as a
// distinct store from Roo so users can toggle the two independently.
//
// Feature posture — `features.zoo.enabled` defaults false. Nothing
// registers a ZooUsageStore into `AppDelegate.providers` yet; that
// lands in PR 13-UI along with `ProviderCopy.help(for: "zoo")`.

import Foundation
import SwiftUI
import Combine

@MainActor
public final class ZooUsageStore: @preconcurrency UsageProvider {

    public let id: String = "zoo"
    public let displayName: String = "Zoo Code"
    public let featureFlagKey: String = "features.zoo.enabled"

    @Published public private(set) var snapshot: RooZooUsageSnapshot?
    @Published public private(set) var lastUpdatedAt: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var tccState: TCCState = .granted
    @Published public private(set) var deniedRootCount: Int = 0
    @Published public private(set) var overTaskCapCount: Int = 0

    private let defaults: UserDefaults
    private let resolveScanRoots: @Sendable () -> [RooZooPathResolver.ScanRoot]
    private let tccProbe: @Sendable (String) -> TCCState
    private let discoverTasks: @Sendable ([RooZooPathResolver.ScanRoot]) -> (tasks: [RooZooDiscoveredTask], overCap: Int)
    private let parseTasks: @Sendable ([RooZooDiscoveredTask]) -> RooZooUsageSnapshot
    private let workQueue: DispatchQueue
    private let clock: @Sendable () -> Date

    private var fetchGeneration: UInt64 = 0
    private var lastAppliedGrantedRootsKey: String?

    public init(
        defaults: UserDefaults = .standard,
        resolveScanRoots: @escaping @Sendable () -> [RooZooPathResolver.ScanRoot] = {
            RooZooPathResolver.resolveScanRoots(.current(), for: .zoo)
        },
        tccProbe: @escaping @Sendable (String) -> TCCState = { TCCProbe.probe(path: $0) },
        discoverTasks: @escaping @Sendable ([RooZooPathResolver.ScanRoot]) -> (tasks: [RooZooDiscoveredTask], overCap: Int) = {
            RooZooUsageFetcher.discoverTasks(under: $0)
        },
        parseTasks: @escaping @Sendable ([RooZooDiscoveredTask]) -> RooZooUsageSnapshot = {
            RooZooUsageFetcher.parseTasks($0)
        },
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.claude.usagebar.zoo.parse",
            qos: .utility
        ),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.resolveScanRoots = resolveScanRoots
        self.tccProbe = tccProbe
        self.discoverTasks = discoverTasks
        self.parseTasks = parseTasks
        self.workQueue = workQueue
        self.clock = clock
    }

    public var isEnabled: Bool { defaults.bool(forKey: featureFlagKey) }
    public var isConfigured: Bool { isEnabled }
    public var lastUpdated: Date? { lastUpdatedAt }
    public var errorMessage: String? { lastError }

    public var tiles: [UsageTile] {
        guard isEnabled else { return [] }
        return RooZooTileBuilder.build(
            providerId: "zoo",
            displayName: displayName,
            snapshot: snapshot,
            tccState: tccState,
            deniedRootCount: deniedRootCount,
            overTaskCapCount: overTaskCapCount,
            now: clock()
        )
    }

    public func fetch() {
        fetchGeneration &+= 1
        guard isEnabled else {
            snapshot = nil
            lastAppliedGrantedRootsKey = nil
            deniedRootCount = 0
            overTaskCapCount = 0
            return
        }
        let launchGeneration = fetchGeneration
        // 3cc R3 F1 fix: BOTH `resolveScanRoots()` and the TCC probe
        // now run on `workQueue` rather than the main actor. See
        // RooUsageStore.fetch() for full commentary.
        let resolve = self.resolveScanRoots
        let probe = self.tccProbe
        let discover = self.discoverTasks
        let parse = self.parseTasks
        let priorAppliedKey = self.lastAppliedGrantedRootsKey

        workQueue.async { [weak self] in
            let scanRoots = resolve()
            var grantedRoots: [RooZooPathResolver.ScanRoot] = []
            var deniedRoots: [RooZooPathResolver.ScanRoot] = []
            for root in scanRoots {
                switch probe(root.tasksDirectoryPath) {
                case .granted:     grantedRoots.append(root)
                case .denied:      deniedRoots.append(root)
                case .pathMissing: break
                }
            }
            let aggregated: TCCState
            if !grantedRoots.isEmpty {
                aggregated = .granted
            } else if !deniedRoots.isEmpty {
                aggregated = .denied
            } else {
                aggregated = .pathMissing
            }
            let deniedCount = deniedRoots.count
            let grantedKey = grantedRoots.map(\.tasksDirectoryPath).sorted().joined(separator: "\n")

            if aggregated != .granted {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    guard self.isEnabled else { return }
                    guard launchGeneration == self.fetchGeneration else { return }
                    self.tccState = aggregated
                    self.deniedRootCount = deniedCount
                    self.snapshot = nil
                    self.lastAppliedGrantedRootsKey = nil
                    self.lastError = nil
                    self.overTaskCapCount = 0
                }
                return
            }

            let (tasks, overCap) = discover(grantedRoots)
            let snap = parse(tasks)

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isEnabled else { return }
                guard launchGeneration == self.fetchGeneration else { return }
                self.tccState = .granted
                self.deniedRootCount = deniedCount
                if grantedKey != priorAppliedKey {
                    self.snapshot = nil
                }
                var stillAllGranted = true
                var newDeniedCount = 0
                for root in grantedRoots {
                    switch probe(root.tasksDirectoryPath) {
                    case .granted:     break
                    case .denied:      stillAllGranted = false; newDeniedCount += 1
                    case .pathMissing: break
                    }
                }
                if !stillAllGranted {
                    self.tccState = .denied
                    self.deniedRootCount = deniedCount + newDeniedCount
                    self.snapshot = nil
                    self.lastAppliedGrantedRootsKey = nil
                    self.overTaskCapCount = 0
                    return
                }
                self.snapshot = snap
                self.overTaskCapCount = overCap
                self.lastAppliedGrantedRootsKey = grantedKey
                self.lastUpdatedAt = self.clock()
                self.lastError = nil
                Log.info("Zoo tasks parsed", .count(snap.records.count))
            }
        }
    }

    public func clear() {
        snapshot = nil
        lastUpdatedAt = nil
        lastError = nil
        lastAppliedGrantedRootsKey = nil
        deniedRootCount = 0
        overTaskCapCount = 0
        fetchGeneration &+= 1
    }
}
