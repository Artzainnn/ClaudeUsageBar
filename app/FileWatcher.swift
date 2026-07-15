// PR 10a — FileWatcher (shared local-provider infrastructure).
//
// Watches a directory tree for changes and calls a Sendable closure
// whenever files under the tree are modified. Used by every local-file
// provider (Claude Code JSONL, Cline, JetBrains XML, etc.) to know when
// to re-parse.
//
// Two backends:
//
//   1. FSEventStreamCreate (primary). The macOS-native, high-fidelity
//      path — kernel-level notifications, no polling cost. Requires the
//      process to have permission to enumerate the target directory.
//      When granted, the callback fires within ~100 ms of a write.
//
//   2. 30-second dispatch-timer poll (fallback). Used when the caller
//      explicitly requests it (unit tests) OR when FSEventStreamStart
//      returns false. Compares directory-tree mtimes on each tick;
//      fires the callback only when at least one mtime changed since
//      the last tick.
//
// The class deliberately owns its Dispatch queue so the callback context
// is deterministic — every fire runs on a serial private queue, never on
// the FSEvents thread or on the main thread. Consumers hop to
// `Task { @MainActor }` themselves if they need main-actor state.
//
// Codex round-1 hardening — every one of these is a real bug in the
// naive implementation:
//
// A. FSEvents context. `Unmanaged.passRetained(self)` (not passUnretained)
//    plus an explicit release callback so an event in flight cannot
//    dereference a freed watcher.
//
// B. Queue-serialised lifecycle. ALL state mutation (start, stop, tick,
//    lastMtimes, onChange) is done on the private serial queue via
//    queue.sync from external callers. This means an already-enqueued
//    tick from before stop() runs, sees `running == false`, and returns
//    without invoking the callback — no race.
//
// C. Baseline is captured SYNCHRONOUSLY on the queue during start(),
//    not async. `queue.sync` from a public API called on some other
//    thread is fine; from the queue itself would deadlock, but our API
//    is only ever called by external owners.
//
// D. Generation counter. Every start() bumps `generation`; every
//    scheduled work item captures its launch generation. A tick from a
//    prior start() sees a mismatched generation and returns without
//    firing.

import Foundation
import CoreServices

/// A change event fired by `FileWatcher`. Every fire carries the paths
/// that FSEvents reported (or, in the poll fallback, the paths whose
/// mtimes advanced since the last tick).
public struct FileWatcherEvent: Sendable {
    /// The absolute paths that changed. For FSEvents, this may be
    /// directories rather than files — FSEvents coalesces per-file
    /// changes into directory-level events by default; the caller is
    /// expected to re-scan directory contents. For the poll fallback,
    /// this is the exact set of files whose mtimes advanced.
    public let paths: [String]
    /// True when this is the initial synthetic event fired shortly after
    /// `start()`. Local providers use this to trigger a first-run scan
    /// without waiting for a real filesystem change.
    public let isInitial: Bool

    public init(paths: [String], isInitial: Bool) {
        self.paths = paths
        self.isInitial = isInitial
    }
}

/// Backend the watcher runs. Callers rarely pick this explicitly — the
/// default `.auto` chooses FSEvents when available and falls back to
/// polling. Tests use `.pollOnly(interval:)` for determinism.
public enum FileWatcherBackend: Sendable {
    /// FSEvents preferred; falls back to polling if FSEventStreamStart
    /// returns false. The interval is used only for the fallback path.
    case auto(pollFallbackInterval: TimeInterval = 30.0)
    /// Force the poll fallback. Interval in seconds. Used by tests.
    case pollOnly(interval: TimeInterval)
}

/// A directory-tree watcher. `paths` is the set of directories to
/// observe; the callback fires whenever files under any of them change.
// PR 18: `@unchecked Sendable` because every mutable field (stream,
// onChange, pollSource, mtimeSnapshot) is only mutated inside the
// serial `queue` — see the `queue.sync`/`queue.async` calls in
// start/stop/tick. FSEvents callback + DispatchSourceTimer callback
// both hop back to `queue` before touching state. Callers get a
// Sendable reference they can safely share across actor boundaries.
public final class FileWatcher: @unchecked Sendable {

    /// Directory paths to watch. Each is a directory root; FSEvents
    /// watches recursively, and the poll fallback enumerates recursively.
    public let paths: [String]

    private let backend: FileWatcherBackend
    /// Serial queue where the callback fires. Owned by the watcher.
    private let queue: DispatchQueue
    /// Sendable callback. Retained until stop().
    private var onChange: (@Sendable (FileWatcherEvent) -> Void)?

    // FSEvents state — nil while stopped.
    private var stream: FSEventStreamRef?

    /// Per-stream context object owned by the FSEvents info pointer.
    /// Codex round-2 finding #1: storing generation on `self` was
    /// staleness-vulnerable — an FSEvents callback from stream N could
    /// read `self.streamGeneration` AFTER a stop+start had advanced it,
    /// and appear "current" to the guard. The per-stream context binds
    /// the generation to the specific stream instance, so a late
    /// callback from an old stream carries the OLD generation and drops
    /// on the guard.
    private final class FSEventsContext {
        weak var watcher: FileWatcher?
        let generation: UInt64
        init(watcher: FileWatcher, generation: UInt64) {
            self.watcher = watcher
            self.generation = generation
        }
    }

    // Poll state — nil while stopped.
    private var pollSource: DispatchSourceTimer?
    /// mtimes observed on the previous poll tick, keyed by absolute path.
    /// Nil while stopped; populated synchronously on start().
    private var lastMtimes: [String: Date]?

    /// True after `start()` — used to make `stop()` idempotent and to
    /// short-circuit already-enqueued tick handlers that fire after stop.
    private var running = false

    /// Monotonic counter bumped on every `start()`. Every scheduled work
    /// item captures its launch generation; a stale handler that fires
    /// after a stop/restart sees a mismatch and returns immediately.
    /// Closes Codex round-1 finding #4.
    private var generation: UInt64 = 0

    /// Key used to identify the private queue's context. `queue.sync`
    /// from within a callback that itself runs on the queue would
    /// deadlock (Codex round-2 finding #2); this key lets us detect
    /// that case and run the block inline instead.
    private let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    /// Construct a watcher. `paths` is the list of directory roots to
    /// observe (they need not exist — a missing directory is treated as
    /// empty and re-checked every tick). `backend` picks FSEvents (auto)
    /// or the poll fallback (pollOnly, for tests).
    public init(paths: [String], backend: FileWatcherBackend = .auto()) {
        self.paths = paths
        self.backend = backend
        self.queue = DispatchQueue(label: "com.claude.usagebar.filewatcher.\(UUID().uuidString)")
        // Tag the queue so `runSerial` can detect re-entry from a
        // callback running on the queue and switch to inline execution
        // instead of a self-deadlocking queue.sync.
        queue.setSpecific(key: queueKey, value: ObjectIdentifier(self))
    }

    /// Run `block` serially on the private queue. If the caller is
    /// already on the queue (i.e. this is being called from an onChange
    /// closure), run inline to avoid a queue.sync self-deadlock. Codex
    /// round-2 finding #2.
    private func runSerial(_ block: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == ObjectIdentifier(self) {
            block()
        } else {
            queue.sync(execute: block)
        }
    }

    deinit {
        // Cannot call stop() directly on the queue from deinit — the
        // final release may be happening on that very queue if a
        // callback is in flight (see Codex round-1 finding #1 for why
        // that is defensively prevented via passRetained). Instead,
        // tear down FSEvents and cancel the timer on the calling thread;
        // both APIs are documented as safe to call from any thread when
        // the object is fully going away.
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        if let source = pollSource {
            source.cancel()
        }
    }

    /// Start watching. Fires an "initial" event on the queue shortly
    /// after start returns so consumers can bootstrap without waiting
    /// for a real change. Idempotent — calling twice is a no-op.
    public func start(onChange: @escaping @Sendable (FileWatcherEvent) -> Void) {
        // Serialise all state mutation through the private queue via
        // runSerial(), which detects re-entry from an onChange callback
        // and runs inline. Codex round-1 #2 + round-2 #2.
        runSerial {
            if running { return }
            running = true
            generation &+= 1
            self.onChange = onChange
            let launchGeneration = generation

            switch backend {
            case .auto(let pollInterval):
                if !startFSEvents(generation: launchGeneration) {
                    startPoll(interval: pollInterval, generation: launchGeneration)
                }
            case .pollOnly(let interval):
                startPoll(interval: interval, generation: launchGeneration)
            }

            // Synthetic initial event so consumers can do a first scan
            // without waiting for a filesystem change. Enqueued async on
            // the same queue so it is delivered in order after any
            // baseline snapshot the poll fallback captured synchronously
            // above.
            let paths = self.paths
            queue.async { [weak self] in
                self?.fireInitialEvent(paths: paths, generation: launchGeneration)
            }
        }
    }

    /// Fire the synthetic initial event on the private queue. Extracted
    /// from the `queue.async` closure inside `start()` for symmetry with
    /// `fireIfCurrent` — both fire onChange under identical guards and
    /// both now assert on-queue at entry (PR 22 3cc consistency fix).
    private func fireInitialEvent(paths: [String], generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Same generation check — a stop+start race between the enqueue
        // and the fire drops this event.
        guard running && self.generation == generation else { return }
        onChange?(FileWatcherEvent(paths: paths, isInitial: true))
    }

    /// Stop watching. Idempotent and safe from any queue.
    public func stop() {
        runSerial {
            if !running { return }
            running = false
            generation &+= 1  // invalidate any pending work items

            if let stream = stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            if let source = pollSource {
                source.cancel()
                self.pollSource = nil
            }
            self.lastMtimes = nil
            self.onChange = nil
        }
    }

    // MARK: - FSEvents backend

    /// Build and start an FSEvents stream. Returns true on success, false
    /// if FSEventStreamStart refused (a signal we should fall back).
    /// Assumes it is called on the private queue.
    private func startFSEvents(generation: UInt64) -> Bool {
        // PR 22 — runtime enforcement of the "@unchecked Sendable"
        // invariant. `dispatchPrecondition(.onQueue:)` uses Swift's
        // `precondition()` semantics (NOT `assert()`): it fires in
        // BOTH DEBUG and RELEASE builds, aborting the process on
        // violation. That is stronger than the "compiled out in
        // release" claim the PR body originally made — corrected
        // in the follow-up audit (PR 26). Cheap defence-in-depth
        // for a class whose Sendable conformance depends on queue
        // serialisation.
        dispatchPrecondition(condition: .onQueue(queue))
        guard !paths.isEmpty else { return false }
        let cfPaths = paths as CFArray

        // Codex round-1 finding #1 + round-2 finding #1 + round-3 leak:
        // the info pointer owns a per-stream FSEventsContext that binds
        // the generation to THIS specific stream. Even if a late
        // callback arrives after stop+start, it carries the OLD
        // generation and fireIfCurrent drops it. The watcher reference
        // is `weak` — if the watcher deallocates for any reason, the
        // callback finds watcher=nil and returns.
        //
        // Ownership pattern per Codex round-3: `passRetained(ctx)`
        // creates the single +1 that represents "FSEvents owns this
        // context." NO retain callback, so FSEvents does not attempt
        // to bump the count — Apple's docs say retain/release are
        // optional, and if retain is nil, FSEvents treats the info
        // pointer as opaque and does not manage its refcount. The
        // single release callback drops that +1 when FSEvents itself
        // releases (via FSEventStreamRelease). Symmetric — no leak,
        // no UAF.
        //
        // Create-fail path: if FSEventStreamCreate returns nil, no
        // release callback ever fires, so we manually release the +1
        // before returning false.
        let ctx = FSEventsContext(watcher: self, generation: generation)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: ctxPtr,
            retain: nil,
            release: { info in
                guard let info = info else { return }
                Unmanaged<FSEventsContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents |
                           kFSEventStreamCreateFlagNoDefer |
                           kFSEventStreamCreateFlagIgnoreSelf)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, eventPathsRaw, _, _ in
                guard let info = info else { return }
                let ctx = Unmanaged<FSEventsContext>.fromOpaque(info).takeUnretainedValue()
                guard let watcher = ctx.watcher else { return }
                let raw = eventPathsRaw.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                var out: [String] = []
                out.reserveCapacity(Int(numEvents))
                for i in 0 ..< Int(numEvents) {
                    if let ptr = raw[i] {
                        out.append(String(cString: ptr))
                    }
                }
                let genAtFire = ctx.generation
                watcher.queue.async {
                    watcher.fireIfCurrent(paths: out, generation: genAtFire)
                }
            },
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            // Create failed — release the +1 we took above with passRetained.
            Unmanaged<FSEventsContext>.fromOpaque(ctxPtr).release()
            return false
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            // FSEventStreamRelease invokes our release callback, which
            // drops the +1 that `Unmanaged.passRetained(ctx)` created.
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    /// Called from the FSEvents callback (via a queue.async hop) and
    /// from the poll tick. Serialised on the private queue.
    fileprivate func fireIfCurrent(paths: [String], generation: UInt64) {
        // PR 22 — runtime enforcement of the "@unchecked Sendable"
        // invariant (see startFSEvents for rationale). Both callers
        // (FSEvents callback via queue.async, poll timer via
        // DispatchSource) already run on `queue`; a future
        // refactor that added an off-queue caller would trip here.
        dispatchPrecondition(condition: .onQueue(queue))
        // Generation guard — stop+start could have advanced generation
        // while this event was in flight.
        guard running && self.generation == generation else { return }
        onChange?(FileWatcherEvent(paths: paths, isInitial: false))
    }

    // MARK: - Poll fallback backend

    /// Assumes it is called on the private queue.
    private func startPoll(interval: TimeInterval, generation: UInt64) {
        // PR 22 — runtime enforcement of the queue-serialised
        // invariant. See startFSEvents for the design note.
        dispatchPrecondition(condition: .onQueue(queue))
        let safeInterval = max(1.0, interval)
        // Codex round-1 finding #3: capture baseline SYNCHRONOUSLY, on
        // the queue, right now. We are already on the queue (see caller
        // in start()), so this is a direct assignment. Anything created
        // between start() returning and the first tick is genuinely a
        // change; the diff will fire on the very next tick.
        lastMtimes = snapshotMtimes()

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + safeInterval, repeating: safeInterval)
        source.setEventHandler { [weak self] in
            self?.pollTick(generation: generation)
        }
        source.resume()
        self.pollSource = source
    }

    /// One tick of the poll fallback. Assumes it is called on the
    /// private queue. Generation check drops stale ticks from a prior
    /// start().
    private func pollTick(generation: UInt64) {
        // PR 22 — runtime enforcement of the queue-serialised
        // invariant. See startFSEvents for the design note.
        dispatchPrecondition(condition: .onQueue(queue))
        guard running && self.generation == generation else { return }
        let current = snapshotMtimes()
        guard let last = lastMtimes else {
            // Baseline lost (should not happen — start() sets it) —
            // record and return without firing.
            lastMtimes = current
            return
        }
        var changed: [String] = []
        for (path, mtime) in current where last[path] != mtime {
            changed.append(path)
        }
        for path in last.keys where current[path] == nil {
            changed.append(path)
        }
        if !changed.isEmpty {
            onChange?(FileWatcherEvent(paths: changed, isInitial: false))
        }
        lastMtimes = current
    }

    /// Walk every watched directory recursively and record mtimes.
    /// Assumes it is called on the private queue.
    private func snapshotMtimes() -> [String: Date] {
        // PR 22 — runtime enforcement of the queue-serialised
        // invariant. See startFSEvents for the design note.
        dispatchPrecondition(condition: .onQueue(queue))
        var out: [String: Date] = [:]
        let fm = FileManager.default
        for root in paths {
            guard fm.fileExists(atPath: root) else { continue }
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles],
                errorHandler: nil
            ) else { continue }
            for case let url as URL in enumerator {
                do {
                    let vals = try url.resourceValues(forKeys: [.contentModificationDateKey])
                    if let mtime = vals.contentModificationDate {
                        out[url.path] = mtime
                    }
                } catch {
                    // Individual file stat can fail (transient
                    // permission errors, race with deletion) — skip and
                    // continue rather than blowing up the whole tick.
                }
            }
        }
        return out
    }
}
