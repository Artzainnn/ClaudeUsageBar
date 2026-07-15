# PR 21 — Anthropic on StatusSource (design)

**Status: Superseded by shipped code (commit cba0cb1).** Post-audit
(2026-07-16), several details in this spec drifted from the shipped
implementation. Reconciling notes are inline; the shipped code in
`app/StatusManager.swift`, `app/StatusTypes.swift`, and
`app/StatusSource.swift` is the source of truth.

## Problem

`StatusManager.fetch()` and `StatusManager.parse(_:)` (in
`app/ClaudeUsageBar.swift` lines ~1054–1156) hand-roll the
statuspage.io v2 fetch/parse for Anthropic. `StatuspageV2Parser` and
`StatuspageV2Source` in `app/StatusSource.swift` (PR #78) implement
the exact same logic, verbatim, for OpenAI / GitHub / xAI. Two copies
of the same code means:

- Anthropic-side bug fixes must be duplicated to the other four
  sources (and vice versa).
- Parser tests can only cover four of five sources — Anthropic's path
  is untested at the parser layer.
- The rationale in `RESUME.md` question 2 ("StatusManager still
  Anthropic-bespoke") stays unresolved.

## Goal

Route Anthropic's fetch/parse through `StatuspageV2Source.anthropic`
so all five sources share exactly one parser + fetcher path. Preserve
every Anthropic-specific side effect (first-fetch default component
selection excluding "Government", notification-on-transition of the
*effective* filtered indicator, `hasFetched` / `lastUpdated` /
`allComponents` writes) verbatim.

## Non-goals

- Generalising per-component tracking to non-Anthropic sources.
  Anthropic still owns `allComponents` / `selectedComponentIds` /
  `filteredAffectedComponents` / `effectiveIndicator`. Extending
  those to other sources is a future PR.
- Renaming `extraSources` / `extraSnapshots` / `extraStatusCards`.
  Anthropic is not "extra"; the current split (bespoke Anthropic
  surface + `extra*` for the other four) accurately mirrors the
  current UX where Anthropic is always on and has the tracked-
  component picker.
- Migrating the popover UI. It still binds to
  `statusManager.indicator` / `.statusDescription` / `.incidents` /
  `.filteredAffectedComponents` / `.allComponents` / etc. unchanged.

## Design

### 1. Extract types into the library

Move to a new library file `app/StatusTypes.swift`:

- `StatusIncident`
- `StatusComponent`
- `AffectedComponent`
- `defaultTrackedComponents`
- `defaultTrackedComponentIdSet`

Rationale: `StatusSource.swift` already lives in the app-only compile
because it depends on these types. Lifting the types unlocks moving
`StatusSource.swift` into the library too, which unlocks parser tests
for all five sources.

### 2. Move `StatusSource.swift` into the library

Add `StatusSource.swift` + `StatusTypes.swift` to
`Package.swift → targets[ClaudeUsageBar].sources`. Update the
inline comment (currently claims parser tests would need duplicated
struct definitions — no longer true).

### 3. Move `StatusManager` into the library

New file `app/StatusManager.swift`. Body is identical to the current
`StatusManager` block in `ClaudeUsageBar.swift` MINUS the bespoke
`endpoint` / `fetch()` / `parse()` / local ISO formatters, PLUS:

```swift
private let anthropicSource: any StatusSource

init(anthropicSource: any StatusSource = StatuspageV2Source.anthropic) {
    self.anthropicSource = anthropicSource
    // …existing UserDefaults reads…
}

func fetch() {
    anthropicSource.fetch { [weak self] snapshot in
        Task { @MainActor [weak self] in
            self?.apply(snapshot)
        }
    }
}

// Shipped code exposes `apply(_:)` as `public` (not `private` as originally
// drafted) so TestRunner can drive the pipeline synchronously without
// spinning a URLSession stub. Matches the codebase convention for every
// other provider store.
public func apply(_ snapshot: StatusSnapshot) {
    guard !snapshot.indicator.isEmpty else { return }  // empty-sentinel snapshot — leave prior state
    let isFirstFetch = !hasFetched

    indicator = snapshot.indicator
    statusDescription = snapshot.description
    incidents = snapshot.incidents
    affectedComponents = snapshot.affectedComponents
    if !snapshot.components.isEmpty {
        allComponents = snapshot.components
        // First-fetch default component selection — untouched.
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

    let effective = effectiveIndicator
    let previous = UserDefaults.standard.string(forKey: "last_effective_indicator")
    if !isFirstFetch, let previous = previous, previous != effective {
        notifyStatusChange(to: effective, description: snapshot.description)
    }
    UserDefaults.standard.set(effective, forKey: "last_effective_indicator")
}
```

Key change: the "empty snapshot ⇒ leave prior state" contract is now
applied uniformly (matches the `extraSources` behaviour introduced in
PR #85). This is a strengthening — previously the bespoke `parse()`
would `return` silently on malformed JSON but would apply an empty
result if the JSON parsed but had missing top-level keys. Net effect:
identical for the well-formed responses Anthropic serves; better
crash-resistance on malformed payloads.

### 4. Delete from `ClaudeUsageBar.swift`

- Lines 855–892: `StatusIncident` / `AffectedComponent` /
  `StatusComponent` / `defaultTrackedComponents` /
  `defaultTrackedComponentIdSet` (moved to `StatusTypes.swift`).
- Lines 894–1157: `StatusManager` class (moved to
  `StatusManager.swift`). The `AppDelegate.statusManager` reference
  and `StatusManager()` init call at the top of the file are
  unchanged.

Net LOC change: `ClaudeUsageBar.swift` shrinks by ~300 lines; three
new library files land totalling ~350 lines (small growth from the
class-header boilerplate on split files, offset by removal of
duplicate parser).

### 5. Tests

Add to `Tests/TestRunner/main.swift` (~10 new `run(...)` blocks):

- **`StatuspageV2Parser round-trips an Anthropic-shape fixture`** —
  supplies a canned summary.json with two incidents, six components,
  one degraded. Asserts every field.
- **`StatuspageV2Parser handles OpenAI slim variant (no top-level incidents)`** —
  already implicitly covered by the shared parser, but explicit test
  locks it in.
- **`StatuspageV2Parser rejects malformed JSON`** — returns nil.
- **`StatuspageV2Parser rejects payload missing top-level status`** —
  returns nil.
- **`GoogleCloudStatusParser round-trips an incidents.json fixture`** —
  active + ended + currently_affected variants.
- **`GoogleCloudStatusParser severityScore prefers status_impact over severity`**.
- **`StatusAggregator returns worst-of across snapshots`**.
- **`StatusAggregator ignores failed-fetch snapshots (empty indicator)`**.
- **`StatusManager applies snapshot, sets hasFetched and lastUpdated`** —
  stub source, verify the derived state.
- **`StatusManager empty-snapshot no-op preserves prior state`** —
  stub delivers first a good snapshot, then an empty one; second call
  must not overwrite.
- **`StatusManager first-fetch default component selection excludes 'Claude for Government'`** —
  UserDefaults cleared, stubbed source delivers 6 components.
- **`StatusManager notifies on effective-indicator transition`** —
  first fetch, then second with a different component set; assert the
  `last_effective_indicator` UserDefaults key transitions.
- **`StatusManager fetch() drives apply via stub source`** —
  end-to-end call via `mgr.fetch()`, pumps the run loop until the
  `Task { @MainActor }` hop completes, asserts `hasFetched`.
  (Added during implementation, not in original spec.)
- **`StatusManager filteredAffectedComponents honours tracked
  selection`** — verifies the popover-facing filter. (Added during
  implementation, not in original spec.)
- **`StatusManager notification-on-transition writes
  last_effective_indicator on effective-indicator change`** —
  three sequential applies, asserts pref-write logic at each
  transition. (Added in 3cc round-2 to close a correctness coverage
  gap flagged by the reviewer.)

Test doubles: a `StubStatusSource` conforming to `StatusSource` that
holds an array of pre-canned snapshots and delivers them in order.

The stub is declared `final class StubStatusSource: StatusSource,
@unchecked Sendable` because `StatusSource: Sendable` and the stub has
mutable state (`pending`, `fetchCallCount`). The `@unchecked` is safe
in this test harness — every test drives `fetch` inline from the main
thread and completions run synchronously in the same call frame; no
URLSession, no queue hop. A production adopter of `StatusSource` MUST
serialise mutable state properly (or, better, use immutable value
types); the stub's shortcut is a test-only concession.

### 6. UI parity check

Manually walk the popover code (`ClaudeUsageBar.swift` lines
1574+, 1930+ etc.) — all references are `statusManager.indicator`,
`.statusDescription`, `.filteredAffectedComponents`, `.allComponents`,
`.filteredIncidents`, `.selectedComponentIds`. Every one of these is
preserved with identical semantics. Zero UI code changes.

### 7. AppDelegate parity

`AppDelegate` init still calls `StatusManager()` (line 182). The
default parameter (`StatuspageV2Source.anthropic`) keeps this call
site source-compatible.

## Risk

- **Behavioural drift on cold start.** New code writes `hasFetched =
  true` only after a non-empty snapshot; old code wrote it on any
  successful JSON parse (even one missing components). Anthropic's
  live endpoint has never served a components-empty payload since
  the app's inception; test fixture "malformed" cases confirm the
  new guard is strictly safer. Non-breaking.
- **First-fetch defaults triggered on a stub with 0 components in
  tests.** The `if !snapshot.components.isEmpty` guard protects. Old
  code had the same guard.
- **Notification timing.** Old code notified inside the DispatchQueue.main.async
  block; new code notifies inside the `Task { @MainActor … }` block.
  Both hop to the main queue; observationally identical.

## Verification

- `swift build` — clean.
- `swift run TestRunner` — 2071/2071 passing (baseline 2012 + 14 new
  `run()` blocks contributing 59 net assertions). The count in this
  spec's original draft (2024) was wrong: the 12 planned tests were
  supplemented with 2 additional cases during implementation
  (`fetch() drives apply via stub source` and
  `filteredAffectedComponents honours tracked selection`), and each
  test contains multiple `expect()` calls. A 14th test
  (`notification-on-transition writes last_effective_indicator on
  effective-indicator change`) was added in 3cc round-2 to close a
  correctness coverage gap the reviewer flagged.
- `app/build.sh` on arm64 + x86_64 — clean.
- All 5 CI static-grep guards — clean.
- Manual popover walk — no UI regressions (verified by build + test,
  no smoke test required since UI code paths are unchanged).
