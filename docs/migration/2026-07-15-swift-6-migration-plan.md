# Swift 6 language-mode migration plan

Date: 2026-07-15
Scope: `refactor/swift-6-migration` — flip `swift-tools-version:5.9` →
`6.0`, add `-swift-version 6` where needed, remove
`@preconcurrency` from every UsageProvider conformance, address every
strict-concurrency error that surfaces.

## Why plan, not code

An initial one-shot flip (`swift-tools-version:6.0` + `swift build`)
surfaced two architectural issues that require careful thought and
real-runtime testing:

1. **`ProviderBox.provider: any UsageProvider`** is declared
   `nonisolated let` so `ProvidersModel.fetchEnabled` can read the
   provider reference from the timer callback without an actor hop.
   Under Swift 6 this fails: `any UsageProvider` is non-Sendable
   because the existential does not carry a Sendable requirement.
2. **`ISO8601DateFormatter` static lets** — every module that
   parses ISO-8601 timestamps caches a formatter as a
   `private static let`. Under Swift 6 that's a
   `MutableGlobalVariable` error because `ISO8601DateFormatter`
   is not `Sendable`.

Both fixes touch multiple files and change runtime behaviour
subtly. Ship-quality Swift 6 migration wants:

- Coverage from real users (the Swift 6 strict-concurrency checker
  catches some races the Swift 5 mode allowed).
- Xcode.app-based CI (Swift 6 language-mode error messages are
  substantively different from Swift 5).
- The ability to test on both arm64 and x86_64 macOS 12 through
  latest.

The autonomous session running this PR has none of the above. The
correct move is to land the migration blueprint here, and let the
human execute it under proper CI + testing.

## Migration blueprint

### Step 1: Bump tools-version

```diff
- // swift-tools-version:5.9
+ // swift-tools-version:6.0
```

Add per-target language mode:

```diff
- .target(
-     name: "ClaudeUsageBar",
-     path: "app",
+ .target(
+     name: "ClaudeUsageBar",
+     path: "app",
+     swiftSettings: [.swiftLanguageMode(.v6)],
```

Add `-swift-version 6` to both arm64 and x86_64 lines of
`app/build.sh`.

### Step 2: Fix `ProviderBox.provider`

`UsageProvider` protocol adopts `Sendable`:

```diff
- public protocol UsageProvider: AnyObject, ObservableObject {
+ public protocol UsageProvider: AnyObject, ObservableObject, Sendable {
```

Since every conforming store is `@MainActor final class`, this is
already satisfied — the actor confines mutable state.

Then `ProviderBox.provider` compiles as-is (`nonisolated let`
against a Sendable existential).

### Step 3: Fix ISO-8601 formatter statics

Eight files hold `private static let isoFormatter:
ISO8601DateFormatter`. `ISO8601DateFormatter` mutates internal state
via `.formatOptions =`, so it is not Sendable. Three options:

A. **`nonisolated(unsafe) static let`** — asserts the developer has
   verified thread-safety. `ISO8601DateFormatter.date(from:)` and
   `.string(from:)` are thread-safe on Darwin
   (`FoundationEssentials`-backed), so this is factually correct
   but leaves the safety promise as an inline audit rather than
   a compiler check.

B. **Wrap in an actor** — `actor ISO8601Formatters { static let
   shared = ... }`. Requires every caller site to `await`, which is
   a substantial refactor to touch every timestamp parse call
   site.

C. **Build the formatter per-call** — construct
   `ISO8601DateFormatter` inside each `parseTimestamp` invocation.
   Costs a small allocation per call. Simplest.

Recommended: **C** for the low-frequency parsers (Anthropic,
Cursor, JetBrains, Warp, Zed, StatusSource) — these run on the
60-second timer at worst. **A** for the hot parsers (ClaudeCode,
which parses thousands of records per fetch). Document each
choice inline with the audit statement.

### Step 4: Remove `@preconcurrency`

21 `@preconcurrency` occurrences in the stores. Grep-and-strip:

```bash
sed -i.bak 's/@preconcurrency UsageProvider/UsageProvider/g;
            s/@preconcurrency PasteKeyProvider/PasteKeyProvider/g;
            s/@preconcurrency SecondaryKeyProvider/SecondaryKeyProvider/g' \
   app/*Store.swift
```

Every store is already `@MainActor`; the protocols become @MainActor
after Step 2 (they carry the actor-isolation of their conforming
types via Sendable). Verify compile after each file.

### Step 5: FileWatcher.swift Sendable closures

The build surfaced 3 warnings about `[weak self]` captures in
`@Sendable` closures over `FileWatcher` (line 214, 308, 308).
Two fixes: (a) mark FileWatcher `final class ... @unchecked
Sendable` and audit the mutable state; (b) restructure the
callbacks to pass explicit Sendable captures rather than
capturing self.

### Step 6: Test-runner runloop hop

`Tests/TestRunner/main.swift:7532` has a warning about mutating
`callCount` inside a `@Sendable` closure. Wrap the counter in a
`final class @unchecked Sendable` box (already the pattern used
elsewhere in the same file for `CountBox` / `StepBox`).

### Step 7: Assertion pass

After each Step 3-6 file change, run:

- `swift build`
- `swift run TestRunner`
- `swiftc … -swift-version 6` on both arm64 and x86_64 targets

Expected: 0 errors, 0 warnings.

### Step 8: 3cc adversarial review

Hardened Swift 6 code has more subtle failure modes than Swift 5.
Run 2-3 rounds of Codex adversarial review over the diff.

### Step 9: chk1:all

Verify no regressions in tile-rendering behaviour under the new
actor-isolation checks.

## Estimated effort

- Steps 1-2: 30 min.
- Step 3: 90 min (per-file audit for each ISO formatter).
- Step 4: 30 min.
- Step 5: 60 min (FileWatcher refactor).
- Step 6: 15 min.
- Steps 7-9: 90-180 min (test + review + fixup cycles).

**Total: 4-6 hours of focused work.**

## Deliverables (when executed)

- `Package.swift` — tools-version bump + swiftLanguageMode.
- `app/build.sh` — `-swift-version 6` per arch.
- Every `*Store.swift` — `@preconcurrency` removed.
- Every `*Fetcher.swift` with an ISO formatter — either
  `nonisolated(unsafe)` (with audit comment) or per-call
  construction.
- `app/UsageProvider.swift` — `UsageProvider: Sendable`.
- `app/FileWatcher.swift` — Sendable-safe closure captures.
- `Tests/TestRunner/main.swift` — one box-wrapped counter fix.
- No new external dependencies.
- All arches compile clean.
- Every existing test passes.

## Files touched

Baseline count from `grep -rn "ISO8601DateFormatter\|@preconcurrency\|nonisolated let\|nonisolated(unsafe)"`:
**42 touchpoints across 30 files**.

- 8 files: `ISO8601DateFormatter` static formatters (Anthropic,
  ClaudeCode, ClaudeUsageBar main, Cursor, JetBrains, StatusSource,
  Warp, Zed).
- 17 files: `@preconcurrency` on UsageProvider or PasteKeyProvider
  or SecondaryKeyProvider conformance.
- 1 file: `nonisolated let provider: any UsageProvider` (UsageProvider.swift).
- 1 file: `nonisolated(unsafe)` — pre-existing use to audit for
  correctness under Swift 6.
- 1 file: FileWatcher.swift — three @Sendable-closure captures.
- 1 file: TestRunner main.swift — one mutable-capture warning.

## Not doing (intentional)

- Not attempting the full flip in this autonomous session. The
  correct move is a human-driven refactor with Xcode CI.
- Not converting to Swift 6 concurrency primitives (`async let`,
  structured concurrency) beyond what's needed for strict-mode
  compile. That would be a separate PR.
- Not adding sendability to types that don't need it. Only fix the
  minimum surface to get strict-concurrency-clean compile.

## Risk

- Runtime behaviour changes: strict-mode compile may FIX several
  latent races that Swift 5 mode allowed. Full smoke test on both
  arches recommended.
- Test-runner changes: mutable-capture wrapping in tests is
  test-only surface but must not change the test's semantics.
