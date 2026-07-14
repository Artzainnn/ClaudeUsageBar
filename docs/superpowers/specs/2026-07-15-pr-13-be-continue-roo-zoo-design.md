# PR 13-BE — Continue + Roo / Zoo backends design

Date: 2026-07-15
Branch: `feat/continue-roo-be` off local main `c19641f`
Milestone: 6 (v1.8.0)
Scope: three feature-flag-off local backends. Nothing renders until PR 13-UI.

## Objective

Add local-file readers for three coding agents so users see their token usage
alongside the other providers already tracked:

- **Continue** — Anthropic-agnostic multi-provider AI code assistant. Local
  dev-data JSONL under `~/.continue/dev_data/0.2.0/tokensGenerated.jsonl`.
- **Roo Code** — Cline-family agent, extension id `RooVeterinaryInc.roo-cline`.
  Repo archived May 2026 but data survives on users' disks.
- **Zoo Code** — active Cline-family fork, extension id
  `ZooCodeOrganization.zoo-code`.

Every provider is feature-flag-off; no popover tile until PR 13-UI wires
`ProviderCopy.help` / `.disclosure` and registers the store's tile section.

## Verified upstream facts

Sources cited in the 3cc research pass.

### Continue

- Path constant: `getDevDataFilePath` in
  `github.com/continuedev/continue/blob/main/core/util/paths.ts:229`. Base is
  `~/.continue/dev_data/{schema}/{eventName}.jsonl`; schema is hard-coded
  `LOCAL_DEV_DATA_VERSION = "0.2.0"` in `core/data/log.ts:20`.
- Local logging is UNCONDITIONALLY ON —
  `core/data/log.ts:88` comment: `// Local logs (always on for all levels)`.
  The EXPANSION_PLAN's original onboarding copy ("Local logging is off by
  default, enable it in config.yaml") is factually wrong and is not adopted.
- `tokensGenerated.jsonl` schema per row (`packages/config-yaml/src/schemas/data/tokensGenerated/v0.2.0.ts`):

  ```
  {
    timestamp:          string  (ISO-8601, new Date().toISOString())
    userId:             string
    userAgent:          string  ("<ide>/<ver> (Continue/<ver>)")
    selectedProfileId:  string
    eventName:          string  (literal "tokensGenerated")
    schema:             string  (literal "0.2.0")
    model:              string
    provider:           string
    promptTokens:       number
    generatedTokens:    number
  }
  ```

  NO cost field. NO cache-tokens field. Tokens only.
- Ten sibling event streams exist under the same folder (autocomplete,
  chatFeedback, chatInteraction, editInteraction, editOutcome,
  nextEditOutcome, nextEditWithHistory, toolUsage, plus a legacy
  `quickEdit` under 0.1.0). We read only `tokensGenerated.jsonl`.
- Licence: Apache-2.0. No DMCA / ToS constraint.

### Roo Code

- Marketplace id: `RooVeterinaryInc.roo-cline` (case-sensitive publisher slug).
- Source repo `github.com/RooCodeInc/Roo-Code` is ARCHIVED
  (`"archived": true` via `gh api`). Extension frozen at v3.54.0 on the
  marketplace. Still present on many users' disks.

### Zoo Code

- Marketplace id: `ZooCodeOrganization.zoo-code`. This differs from the
  EXPANSION_PLAN's original `zooverinaryinc.zoo-code` — the plan's value is
  incorrect and is not adopted.
- Source repo `github.com/Zoo-Code-Org/Zoo-Code`. Apache-2.0. Active.

### Roo + Zoo file layout (identical to Cline)

- `{globalStorage}/<publisher.name>/tasks/{taskId}/ui_messages.json`
- `{globalStorage}/<publisher.name>/tasks/{taskId}/history_item.json`
- `{globalStorage}/<publisher.name>/tasks/{taskId}/api_conversation_history.json`

`ui_messages.json` uses the same Cline `{ ts, type, say, text, modelInfo }`
message array shape with JSON-encoded `{ tokensIn, tokensOut, cacheWrites,
cacheReads, cost }` in `text`. Verified in
`Zoo-Code/packages/types/src/message.ts:250-275`.

`history_item.json` is a pre-computed rollup per task, a flat JSON object with
fields `{ tokensIn, tokensOut, cacheWrites, cacheReads, totalCost, size }`.
Field is `totalCost`, NOT `cost` (per
`Zoo-Code/src/core/task-persistence/taskMetadata.ts:100-107`). Any parser
that assumes `cost` will return zero cost for every Roo/Zoo task.

### customStoragePath

Both Roo and Zoo respect a per-VS-Code workspace setting stored in the host's
`settings.json`:

- key `roo-cline.customStoragePath` for Roo
- key `zoo-code.customStoragePath` for Zoo

Source: `Zoo-Code/src/utils/storage.ts` — `vscode.workspace.getConfiguration(Package.name).get<string>("customStoragePath", "")`.

Neither extension supports env-var overrides (unlike Cline's `$CLINE_DATA_DIR`
/ `$CLINE_DIR`). This surfaces a design problem the Cline reader avoided.

### Deliberate rejections of the EXPANSION_PLAN

Two statements in EXPANSION_PLAN §8g / §8h are factually wrong and are
overridden in this spec:

1. §8g: "Local logging is off by default in Continue" — false; always on.
2. §8h: extension id `zooverinaryinc.zoo-code` — false; correct id is
   `ZooCodeOrganization.zoo-code`.

Also §8h says "Roo/Zoo adds `tokenUsageSchema` rollup — use it directly".
`tokenUsageSchema` is a Zod type for in-memory return values only; the
persisted rollup file is `history_item.json`. We use the persisted file.

## Architecture

### Files added

1. `app/ContinueUsageFetcher.swift` — value-type `Sendable struct`. JSONL
   line-by-line reader for `~/.continue/dev_data/0.2.0/tokensGenerated.jsonl`.
   Reuses `ClaudeCodeUsageFetcher.readJsonlLines` (accepts torn tail lines,
   per-line malformed counter). Timestamps via
   `ClaudeCodeUsageFetcher.parseTimestamp` (RFC 3339 with/without fractional
   seconds) with a `[year2000, year2100)` bounds clamp. Numeric fields via
   `ClaudeCodeUsageFetcher.safeInt` with a new `is Bool` guard. Tokens-only,
   no cost. Size cap 128 MB; if exceeded, tail-read strategy (seek to
   `EOF - 32 MB`, forward-scan to next newline) with an explicit diagnostic
   distinguishing this from a corrupt file.

2. `app/ContinueUsageStore.swift` — `@MainActor` `UsageProvider`. Mirrors the
   `ClineUsageStore.fetch()` pattern with **re-probe-on-completion** (not
   the plain `ClaudeCodeUsageStore.fetch()` pattern which lacks that fix).
   Owns `@Published snapshot`, `tccState`, `lastUpdatedAt`, `lastError`,
   `fetchGeneration`, `clock` injection. Feature flag
   `features.continue.enabled` default false.

3. `app/RooZooPathResolver.swift` —

   - Six VS Code family hosts × two extension ids = 12 baseline scan roots:
     - `Code`, `Code - Insiders`, `VSCodium`, `Cursor`, `Cursor Nightly`,
       `Windsurf`.
     - `RooVeterinaryInc.roo-cline`, `ZooCodeOrganization.zoo-code`.
   - Plus `customStoragePath` discovery from each host's `settings.json`.
   - Targeted state-machine extractor for keys
     `"roo-cline.customStoragePath"` and `"zoo-code.customStoragePath"`.
     Never full-JSONC-parses the file. Handles `//` inside string values by
     tokenising strings vs code. No comment-stripping regex.
   - Value validation ladder: expand `~`, standardise path, resolve
     symlinks via `realpath`, verify inside `$HOME` tree (reject `/System`,
     `/Library`, `/Applications`, `/private/etc`), verify is-directory,
     verify readable, reject variable substitutions (`$`, `${`, `%20`).
   - All I/O against a `customStoragePath` wrapped in a 5-second timeout
     via `DispatchWorkItem.wait(timeout:)`. Timeout marks the root
     unreachable rather than blocking the fetch queue.
   - Filesystem-identity dedupe (`stat()` dev + inode, symlink-follow) so a
     `customStoragePath` pointing at a default location does not scan the
     same directory twice.
   - Case-folded standardised-path fallback for paths that do not yet exist.

4. `app/RooZooUsageFetcher.swift` — reads `history_item.json` FIRST via a
   dedicated `parseHistoryItem` reader (flat object, field name `totalCost`).
   Falls back to `ui_messages.json` (via
   `ClineUsageFetcher.parse(uiMessages:...)` with the sayKind set passed as
   a parameter) ONLY when history_item.json is absent, empty, or fails
   parse. Fallback and rollup are exclusive per task — never both. Task-id
   dedupe across Roo↔Zoo (a task with the same id in both extension trees
   collapses to one record). Per-provider task cap: 10 000 most-recent by
   directory mtime descending, with diagnostic tile "Only 10 000 most-recent
   sessions counted" when the cap is hit. Size cap 128 MB for the
   `ui_messages.json` fallback (Roo/Zoo sessions can be longer than
   Cline's). One shared parser, parameterised by
   `RooZooExtension { case roo; case zoo }` for scan-root selection.

5. `app/RooUsageStore.swift` — `@MainActor` `UsageProvider`. `id = "roo"`,
   `displayName = "Roo Code"`, `featureFlagKey = "features.roo.enabled"`.
   Uses `ClineUsageStore.fetch()` pattern with re-probe-on-completion.

6. `app/ZooUsageStore.swift` — same shape. `id = "zoo"`,
   `displayName = "Zoo Code"`, `featureFlagKey = "features.zoo.enabled"`.

### Files modified

- `app/ClaudeUsageBar.swift` — `AppDelegate.applicationDidFinishLaunching`
  registers the three new stores after `WarpUsageStore`.

- `app/ClaudeCodeUsageFetcher.swift` — two small hardening changes:
  1. Add `if value is Bool { return 0 }` guard at the top of `safeInt`.
     Prevents Bool-to-Int coercion via NSNumber bridging (a JSON `true`
     silently becoming `1` in a token count).
  2. Add `[year2000, year2100)` bounds clamp to `parseTimestamp` return.
     Currently unbounded; a hostile file could inject a year-3000
     timestamp that would break bucket sorts.

- `Package.swift` — add six new sources.

### No CI guard changes

Continue and Roo/Zoo are Apache-2.0. No DMCA-style constraint. The seven
existing static-grep guards plus the copy-only shape guard pass unchanged.

## Data flow

### Continue

```
timer 60s
  → ContinueUsageStore.fetch()
    bumps fetchGeneration
    guard isEnabled
    scanRoots = [~/.continue/dev_data/0.2.0/tokensGenerated.jsonl]
    tccProbe every root → grantedRoots
    if all denied, surface .denied, return
    grantedKey change → drop stale snapshot
    workQueue.async
      urls = discoverFile (single JSONL, not directory enum)
      snap = ContinueUsageFetcher.parse(files: urls)
              readJsonlLines → per-line JSON parse
              safeInt each numeric (with Bool guard)
              parseTimestamp with [2000, 2100) clamp
              tokens-only, no cost
      Task { @MainActor [weak self]
        guard isEnabled
        guard launchGeneration == fetchGeneration
        re-probe every root — abort on any newly-.denied
        self.snapshot = snap
        self.lastUpdatedAt = clock()
      }
```

### Roo / Zoo

```
timer 60s
  → Roo|ZooUsageStore.fetch()  (both stores; independent fetchGeneration)
    bumps fetchGeneration
    guard isEnabled
    scanRoots = RooZooPathResolver.resolveScanRoots(.roo | .zoo)
      6 baseline hosts × ONE extension id
      + customStoragePath discovery from every host's settings.json
        state-machine key extractor
        value validation + realpath containment
        5s timeout on any I/O
      dedupe by inode + case-fold fallback
    tccProbe every root → grantedRoots
    workQueue.async
      urls = RooZooUsageFetcher.discoverTasks(grantedRoots, cap: 10000)
              sorted by directory mtime desc, capped
      snap = RooZooUsageFetcher.parseTasks(urls, extension: .roo | .zoo)
              for each task:
                if history_item.json exists AND parses non-empty:
                  parseHistoryItem  →  record with totalCost
                else if ui_messages.json exists:
                  ClineUsageFetcher.parse(uiMessages:, sayKinds:, sourceFile:)
                  →  records aggregated to per-task total
                else:
                  skip (in-flight task with neither file, or empty task)
              taskId-dedupe (Roo ∩ Zoo same taskId → keep first)
      Task { @MainActor [weak self]
        guard isEnabled + generation + re-probe (identical to ClineStore)
        self.snapshot = snap
        self.lastUpdatedAt = clock()
      }
```

## Error handling

Every failure mode maps to a user-visible state (never a silent zero):

- `tccState == .denied` on all roots → `.needsAccess` onboarding tile.
- `tccState == .pathMissing` on all roots → "no sessions found" text tile.
- `snapshot.unreadableFileCount > 0` OR `malformedRecordCount > 0` →
  informational "Some sessions skipped" diagnostic tile with counts.
- `snapshot.overCapFileCount > 0` → distinct diagnostic tile "N sessions
  too large to parse (>128 MB); history rollup used when available".
- 10 000-task cap hit → diagnostic tile "Only 10 000 most-recent sessions
  counted".
- customStoragePath timeout → diagnostic tile "Custom storage path
  unreachable (5s timeout)".
- customStoragePath validation fail → log once per generation, no tile
  (settings.json contents are the user's responsibility; we skip and move
  on).

## Testing

Additional test files (in `Tests/TestRunner/`):

- `test_continue_usage_fetcher.swift` — ISO-8601 timestamp variants
  (with/without fractional seconds, `Z` vs `+00:00` vs `+0000`); hostile
  numerics (`1e300`, `"9999999999999999999999999"`, `null`, `-1`, `true`,
  `[1,2,3]`, `NaN`); torn tail lines; empty file; file with only
  malformed lines; over-cap file with tail-read behaviour.
- `test_continue_usage_store.swift` — feature-flag on/off transitions;
  re-probe-on-completion TCC race; clock injection; generation-counter
  invalidation on clear() and disable().
- `test_roo_zoo_path_resolver.swift` — customStoragePath extraction from a
  synthetic settings.json with `//` inside a URL string value, trailing
  commas, CRLF line endings, BOM at file start, nested `/* */` attempts;
  validation ladder (paths pointing at `/System`, `/private/etc`, symlink
  to `/System`, non-existent, non-directory, path with `$HOME`, path with
  `${var}`); timeout simulation.
- `test_roo_zoo_usage_fetcher.swift` — history_item.json happy path (with
  `totalCost` field), history_item.json empty file, history_item.json
  malformed → ui_messages.json fallback, both files present → history wins,
  both files absent → task skipped, task-id dedupe across Roo∩Zoo, 10k cap
  hit, sayKind set parameterisation (adds a Roo v3.20+ retry-accounting
  sayKind that Cline doesn't have).
- `test_roo_usage_store.swift` / `test_zoo_usage_store.swift` — flag
  on/off, TCC race, clock injection.

Baseline: 1693/1693 tests. Target: ~1750–1780 tests (roughly 60–90 new
tests). Both arches compile clean via `app/build.sh`. Every CI guard
passes unchanged.

## Non-breaking guarantee

- Three new feature flags, all default false.
- Existing 15 providers unchanged.
- No changes to `Anthropic*`, popover render path, or timer cadence.
- Two small hardening changes to `ClaudeCodeUsageFetcher.safeInt` and
  `.parseTimestamp` are additive: `safeInt(true)` now returns 0 instead of
  1 (a numeric field must not accept a Bool), and `parseTimestamp` now
  clamps to `[2000, 2100)` (a schema break would previously have leaked
  through). Both changes are covered by additional tests.

## Deferred / not doing

- Continue's other nine JSONL streams (autocomplete, editOutcome, etc.).
  Only `tokensGenerated.jsonl` is consumed; the rest could power a future
  "tools used today" tile if a user asks.
- Continue's legacy `0.1.0/` dev-data folder. Old-version schema not
  verified; population of users still on pre-2024 Continue is negligible.
- Cost tile for Continue. Would require a cross-provider LiteLLM pricing
  snapshot (~30 model families beyond Anthropic). Deferred to a future
  PR if a user requests it.
- Live Roo/Zoo API endpoints. Neither extension exposes a public HTTP
  API; local files are the sole data source.
- FileWatcher-driven delta scans for Roo/Zoo. The 60-second timer plus
  the 10k-task cap is sufficient for now; delta scans are a future
  optimisation if a heavy user reports slowness.

## Adversarial-review provenance

Design ran through three parallel 3cc reviewers before this spec was
written:

- R1 correctness/consistency — surfaced 12 findings; the top-5
  (`totalCost` vs `cost` field name, dedicated `parseHistoryItem`,
  sayKind set parameterisation, taskId dedupe for Roo↔Zoo, ISO-8601 for
  Continue timestamps) are all reflected above.
- R2 YAGNI/scope — surfaced 8 findings; three accepted (cut legacy
  0.1.0 path; cut settings.json full-JSONC parsing in favour of targeted
  state-machine extraction; don't over-parameterise a namespace enum),
  four rejected with rationale (keep three feature flags for
  independent Roo toggling; keep stat() dedupe for baseline-vs-custom
  collision; keep ui_messages.json fallback for in-flight tasks; keep
  two stores for Roo and Zoo).
- R3 failure modes — surfaced 26 findings across 4 severity tiers; the
  five block-merge items (JSONC stripping footgun, ISO-8601 timestamp
  wrong parser, TCC race re-probe missing, network mount hang timeout,
  10 000 task cap) are all reflected above.

All 3cc rounds ran adversarially (Codex-style). No consensus was assumed
between reviewers; each was given the same architecture text and a
different lens.

## Estimate

LOC: ~700 (larger than EXPANSION_PLAN's 180-LOC estimate; 3cc findings
drove up the count with the state-machine JSONC key extractor, the
timeout wrapper, the tail-read strategy, and the additional tests).
Effort: 4–6 hours of implementation + 3–4 Codex adversarial-review
rounds against the diff before push.
