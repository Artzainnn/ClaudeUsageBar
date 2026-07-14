# ARCHITECTURE.md

Last generated: 2026-07-15. Auto-updated on every push to `main` via
`.github/workflows/update-architecture.yml`.

## 1. Project Overview

**ClaudeUsageBar** is a native macOS menubar app that shows AI usage
across multiple providers in one place. Its core design principle is
that nothing about your usage leaves your machine unless the specific
provider requires a remote fetch (Anthropic session cookie, DeepSeek
API balance, Perplexity credit balance, Copilot AI-Credit ledger,
Cursor dashboard). Every local provider (Claude Code, Cline, Roo,
Zoo, Continue, Windsurf, Cursor, JetBrains, Warp, Gemini CLI) reads
files that already exist on the user's Mac.

**Tech stack**:
- Swift 6 (language mode 6 as of PR #81; mixed mode with the
  TestRunner target on Swift 5).
- macOS 12+ deployment target.
- SwiftUI for the popover; AppKit for the menubar item, notifications,
  and app lifecycle.
- Universal binary (arm64 + x86_64) built via `app/build.sh`.
- SwiftPM library for unit tests (works with Command Line Tools alone;
  does not require Xcode.app).
- Assertion-based `TestRunner` executable — no XCTest, no
  swift-testing (both would require Xcode.app).
- Zero external dependencies. Foundation, SwiftUI, AppKit, Combine,
  WebKit only.

## 2. Directory Structure

```
ClaudeUsageBar/
├── ARCHITECTURE.md            ← this file (auto-updated)
├── CLAUDE.md                  ← project-level agent instructions
├── EXPANSION_PLAN.md          ← the long-term roadmap
├── Package.swift              ← SwiftPM manifest (library + TestRunner)
├── README.md
├── LICENSE
├── .github/
│   └── workflows/
│       ├── ci.yml             ← 5 static-grep guards + build+test
│       └── update-architecture.yml  ← auto-updates this file
├── app/
│   ├── ClaudeUsageBar.swift   ← @main + AppDelegate + UsageManager
│   │                              + StatusManager + UpdateManager
│   │                              + Anthropic-specific popover UI
│   ├── build.sh               ← universal binary builder (both arches)
│   ├── create_dmg.sh          ← DMG packager
│   ├── make_app_icon.sh       ← icon variants generator
│   ├── Info.plist
│   ├── ClaudeUsageBar.icns
│   │
│   ├── AnthropicUsageFetcher.swift  ← Anthropic /api/usage parser
│   ├── AnthropicUsageStore.swift    ← Anthropic UsageProvider adapter
│   │
│   ├── Log.swift              ← structured Log.info/.debug/.error
│   ├── UsageProvider.swift    ← protocol + ProviderBox + ProvidersModel
│   ├── ProviderCopy.swift     ← per-provider help / disclosure strings
│   │
│   ├── FileWatcher.swift      ← FSEvents-based file-change reactor
│   ├── SQLiteReader.swift     ← readonly sqlite reader with busy-timeout
│   ├── TCCState.swift         ← Full-Disk-Access probe abstraction
│   ├── StatusSource.swift     ← multi-status protocol + statuspage.io
│   │                             / Google Cloud parsers
│   │
│   ├── {Provider}UsageFetcher.swift ← per-provider pure-value-type parser
│   ├── {Provider}UsageStore.swift   ← per-provider @MainActor UsageProvider
│   ├── ClaudeCodePricing.swift      ← Anthropic LiteLLM pricing snapshot
│   └── (17 providers currently)
│
├── Tests/
│   └── TestRunner/
│       └── main.swift         ← 2000+ assertion tests (Swift 5 mode)
│
├── docs/
│   ├── migration/             ← migration blueprints (Swift 6)
│   └── superpowers/
│       ├── specs/             ← per-PR design specs
│       └── plans/             ← per-PR implementation plans
│
├── .pr-bodies/                ← local-only PR bodies (gitignored)
└── build/                     ← build artefacts (gitignored)
```

## 3. Architecture Pattern

**Two-layer split per provider**: every non-Anthropic provider is
split into a **Fetcher** (pure `Sendable` value type — parsing only,
no observable state) and a **Store** (`@MainActor final class`
`UsageProvider` conformer — owns `@Published` state and drives the
popover).

**Provider registration**: `AppDelegate.applicationDidFinishLaunching`
creates one store per provider and appends it to
`providers: [ProviderBox]`. `ProviderBox` type-erases the
associated-type `ObservableObject` requirement so SwiftUI can observe
a heterogeneous list.

**Feature-flag posture**: every provider except Anthropic starts
disabled (`features.<id>.enabled` defaults false in UserDefaults).
Users opt in via the Settings sheet.

**Fetch cadence**: a single 60-second `Timer` in AppDelegate calls
`providersModel.fetchEnabled()`, which iterates every enabled
provider's `fetch()`. Anthropic keeps its own 5-minute cadence.
`updateManager` polls the release channel every 3 hours.

**Popover render path**: `UsageView` observes `providersModel` (for
the non-Anthropic tile stack) plus `usageManager`, `statusManager`,
`updateManager`. Anthropic keeps its bespoke rendering; every other
provider goes through `ProviderSectionView` which dispatches on
`UsageTile.Kind`.

## 4. Core Components

### 4.1 AppDelegate (ClaudeUsageBar.swift:14)

`@MainActor class AppDelegate: NSObject, @preconcurrency NSApplicationDelegate`.
Owns the menubar `NSStatusItem`, `NSPopover`, four Timer instances,
and the heterogeneous provider list. Handles Cmd+U keyboard shortcut
via `RegisterEventHotKey`. Cleans up event monitors on popover
close.

### 4.2 UsageManager (ClaudeUsageBar.swift:470)

`@MainActor class UsageManager: ObservableObject`. Anthropic-specific
manager holding session cookie state, org id, 5-hour + weekly usage
snapshots, and the notification-threshold state machine (25/50/75/90
percent triggers). Owns the network call to
`https://claude.ai/api/organizations/{orgId}/usage` and hands parsed
data to `AnthropicUsageFetcher`.

### 4.3 StatusManager (ClaudeUsageBar.swift:882)

`@MainActor class StatusManager: ObservableObject`. Polls
`https://status.claude.com/api/v2/summary.json` every 5 minutes.
Tracks per-component enable/disable via UserDefaults, computes an
"effective indicator" that respects the user's tracked-component
set, and emits a system notification when the indicator transitions.
PR 14 introduced the `StatusSource` protocol + four new sources
(OpenAI, GitHub, xAI-via-grokinc.statuspage.io, Google Cloud),
feature-flagged off; the StatusManager migration to `[StatusSource]`
is a follow-up PR.

### 4.4 UpdateManager (ClaudeUsageBar.swift:1088)

`@MainActor class UpdateManager: ObservableObject`. Polls
`https://claudeusagebar.com/latest.json` every 3 hours. Delivers
version-update banners (keyed on `version`) and free-form
announcements (keyed on `id`), each with per-message notification
controls. The announcement channel is decoupled from the app
version so any message can be sent at any time without shipping a
new build. Uses `URLSession` in a `nonisolated` context; helpers
like `parseButtons`, `isSafeURL`, `allowedHostSuffixes` are
`nonisolated` for the URLSession callback path.

### 4.5 UsageProvider protocol (UsageProvider.swift:110)

```swift
@MainActor
public protocol UsageProvider: AnyObject, ObservableObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    var featureFlagKey: String { get }
    var isEnabled: Bool { get }
    var isConfigured: Bool { get }
    var lastUpdated: Date? { get }
    var errorMessage: String? { get }
    var tiles: [UsageTile] { get }
    func fetch()
    func clear()
}
```

Optional capabilities: `PasteKeyProvider` (single API key /
cookie / PAT), `SecondaryKeyProvider` (opt-in gated second key
with warning — xAI's management key uses this).

### 4.6 ProviderBox (UsageProvider.swift:164)

Type-erasing wrapper. Holds `nonisolated let provider: any
UsageProvider` — the `Sendable` requirement on `UsageProvider` makes
this legal under Swift 6 strict concurrency. Forwards
`objectWillChange` from the underlying provider's Combine
publisher so SwiftUI can observe the box.

### 4.7 UsageTile (UsageProvider.swift:73)

Value type for popover rendering. Five kinds:
- `.bar(fraction, resetsAt, badge)` — progress-bar tile.
- `.balance(remainingMinorUnits, currency, plan, resetsAt)` —
  monetary balance tile.
- `.counter(used, limit, resetsAt)` — used/limit counter.
- `.text(status, subtitle)` — freeform text.
- `.needsAccess(path, guidance)` — first-run onboarding for
  TCC-gated local providers.

### 4.8 FileWatcher (FileWatcher.swift)

FSEvents-based directory watcher with poll fallback, baseline race
protection, generation guards, and per-stream FSEventsContext. Used
by the local-file providers to know when the underlying JSONL or
sqlite has changed since the last fetch. Optional; the 60-second
timer already picks up changes.

### 4.9 SQLiteReader (SQLiteReader.swift)

Readonly, `query_only`, `busy_timeout`-configured sqlite reader
with a strict-ASCII sentinel identifier validator to reject
injection attempts on schema-introspection paths. Used by
`WindsurfUsageFetcher`, `CursorUsageFetcher`, `WarpUsageFetcher`.

### 4.10 TCCState (TCCState.swift)

Full Disk Access probe abstraction. `TCCProbe.probe(path:)` returns
`.granted | .denied | .pathMissing`. Used by every local-file
provider's fetch path — a denied probe surfaces a `.needsAccess`
tile with the "Grant Full Disk Access" guidance rather than a
silent empty snapshot.

## 5. Data Flow

### 5.1 Local-file provider (Claude Code / Cline / Roo / Zoo / Continue / JetBrains / Warp / Windsurf / Gemini)

```
Timer fires (60s)
  → providersModel.fetchEnabled()
    → store.fetch()
       ├─ bump fetchGeneration
       ├─ if not enabled, return
       ├─ dispatch to workQueue
       │   ├─ resolveScanRoots()
       │   ├─ TCC probe each root
       │   ├─ discoverFiles()
       │   ├─ parseFiles() → snapshot
       │   └─ Task { @MainActor
       │       ├─ guard isEnabled
       │       ├─ guard generation
       │       ├─ RE-PROBE each root (3cc R3 F5)
       │       ├─ if any denied → tccState = .denied, return
       │       └─ self.snapshot = snap
       │     }
       └─ ...
    → SwiftUI redraws provider section

Popover Refresh button → providersModel.fetchEnabled() (same path)
```

### 5.2 Live-API provider (Codex / DeepSeek / Zed / xAI / OpenAI /
     Perplexity / Copilot / Cursor)

Same shape, but `parseFiles()` is replaced by an HTTP call via
`URLSession.shared.dataTask`. Every provider has its own
`URLSession` config (timeout, redirect policy).

### 5.3 Anthropic (bespoke)

`UsageManager` owns the fetch. `AnthropicUsageStore` adapts
`UsageManager` to `UsageProvider` so it participates in the
generic provider list, but the popover still reaches into
`UsageManager` directly for the two Anthropic-specific bar tiles
(5h + weekly).

## 6. Database Schema

None. This app does not persist anything server-side. Local storage
is:
- **UserDefaults** — feature flags, per-component status tracking,
  notification thresholds, last-seen indicator.
- **Keychain** (`com.claude.usagebar.credentials` service, or the
  legacy `AnthropicSessionCookie` account) — DeepSeek API key,
  Perplexity session cookie, Copilot PAT, xAI keys, OpenAI Admin
  key, Cursor session tokens (mirrored from Cursor's own keychain
  item).
- **Local files** — the eight local-file providers read files
  already on disk. They never write.

## 7. API Layer

External HTTP endpoints:

| Provider | Endpoint | Auth |
|---|---|---|
| Anthropic | `https://claude.ai/api/organizations/{org}/usage` | Session cookie |
| Codex | `https://api.openai.com/v1/organizations/{org}/organization/usage` | Existing `~/.codex/auth.json` |
| DeepSeek | `https://api.deepseek.com/user/balance` | API key |
| Zed | `https://api.zed.dev/user/usage` | Keychain login |
| xAI | `https://api.x.ai/v1/api-key`, `/v1/language-models`, `/v1/models` | Inference + optional Management key |
| OpenAI | `https://api.openai.com/v1/organization/usage/*` | Admin key |
| Perplexity | `https://api.perplexity.ai/perplexity/user/credit-balance`, etc. | Session cookie (four accepted formats) |
| Copilot | `https://api.github.com/users/{login}/settings/billing/ai_credit/usage` | Fine-grained PAT |
| Cursor | `https://cursor.com/api/dashboard/usage/*`, `https://api2.cursor.sh/oauth/token` | Cursor session (mirrored from Cursor's own Keychain) |
| Anthropic status | `https://status.claude.com/api/v2/summary.json` | None |
| Update channel | `https://claudeusagebar.com/latest.json` | None |
| OpenAI status | `https://status.openai.com/api/v2/summary.json` | None (PR #78, feature-flag off) |
| GitHub status | `https://www.githubstatus.com/api/v2/summary.json` | None (PR #78, feature-flag off) |
| xAI status | `https://grokinc.statuspage.io/api/v2/summary.json` | None (PR #78, feature-flag off) |
| Google Cloud status | `https://status.cloud.google.com/incidents.json` | None (PR #78, feature-flag off) |

Nothing calls JetBrains, Warp's server-side quota, or Google
Cloud's `serviceusage.googleapis.com` — all deferred / DMCA-
constrained. A CI static-grep guard enforces the JetBrains DMCA
constraint (never contact `api.jetbrains.ai` or
`grazie.aws.intellij.net`; only `app/ProviderCopy.swift` is
allowlisted for the two hostnames as documentation).

## 8. State Management

- **`@Published`** on every store's `snapshot`, `lastUpdatedAt`,
  `lastError`, `tccState`, plus per-provider counters like
  `deniedRootCount`, `overTaskCapCount`, `unknownModelRecordCount`.
- **`ProvidersModel: ObservableObject`** aggregates the
  heterogeneous provider list for SwiftUI.
- **Combine**: `ProviderBox` uses a `Combine.AnyCancellable` to
  forward `objectWillChange` from the underlying provider.
- **fetchGeneration counter**: every store has a
  `UInt64 fetchGeneration` counter incremented on every `fetch()`
  entry and on `clear()`. Completions check the generation before
  applying state — prevents stale in-flight fetches from
  overwriting fresh state.

## 9. Authentication & Authorization

- **Keychain-first**: every non-Anthropic credential is stored in
  the macOS Keychain via `KeychainStore.write(:_:_:)`
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). The
  frontend never sees the raw key after paste.
- **Anthropic exception**: legacy session cookie is stored in
  `UserDefaults` via `DefaultsStore` for backwards compat.
- **TCC probe**: every local-file provider probes Full Disk
  Access before opening any file. Denied → `.needsAccess` tile
  with copy directing the user to System Settings.

## 10. Configuration

**UserDefaults keys**:
- `features.<provider-id>.enabled` — per-provider opt-in
  (features.codex.enabled, features.deepseek.enabled, …).
  Every non-Anthropic provider defaults false.
- `features.status.<source>.enabled` — per-status-source opt-in
  (PR #78; still off).
- `tracked_component_ids` — array of Anthropic status
  components the user tracks.
- `status_notifications_enabled` — status-change notification opt-in.
- `last_effective_indicator` — for notification-on-transition
  bookkeeping.
- `last_notified_threshold` — Anthropic usage-percentage
  notification bookkeeping.
- `notif.enabled` — global notification enable.

**No environment variables** are consumed by the shipped binary
except for the two Cline overrides (`$CLINE_DATA_DIR`,
`$CLINE_DIR`), the Claude Code overrides
(`$CLAUDE_CONFIG_DIR`, `$XDG_CONFIG_HOME`), and the Gemini
override (`$GEMINI_CLI_HOME`).

## 11. Key Abstractions

- `RequestSafety` — percent-encode path segments, reject
  header-splitting characters. Used by every provider that
  constructs a URL from a user-supplied identifier.
- `LocalProviderAccessGuide` — shared "Grant Full Disk Access"
  onboarding copy factory. Every local-file provider's
  `.needsAccess` tile uses it.
- `CredentialStore` protocol + `DefaultsStore` + `KeychainStore`
  — pluggable credential backends.
- `ClaudeCodeUsageFetcher.readJsonlLines(from:sizeCap:)` — shared
  256 MB-capped streaming reader; Continue and Gemini both delegate
  to it.
- `ClaudeCodeUsageFetcher.parseTimestamp` — RFC 3339 parser with
  `[year2000, year2100)` bounds clamp.
- `ClaudeCodeUsageFetcher.safeInt` — hostile-numeric coercion
  with `CFBooleanGetTypeID` Bool guard.
- `ClaudeCodeUsageRecord.saturatingAdd` — non-wrapping addition
  clamped to `Int.max`.

## 12. Error Handling

Value-type fetchers use `try?` throughout — never propagate.
Store `fetch()` methods handle:
- File not readable → `unreadableFileCount++`.
- Line malformed → `malformedRecordCount++`.
- File over size cap → `overCapFileCount++`.
- TCC denied → `tccState = .denied`, `.needsAccess` tile.
- Path missing → `tccState = .pathMissing`, "not installed" tile.
- Task count over 10 000 (Roo/Zoo only) →
  `overTaskCapCount++`, "session cap hit" tile.

Every failure surfaces as a diagnostic tile. No silent zeroes.

## 13. Testing

`Tests/TestRunner/main.swift` (2 000+ assertions, Swift 5 mode
until a follow-up refactor). Runnable via `swift run TestRunner`
without Xcode.app.

Coverage:
- Per-provider fetcher: happy path, hostile numerics, malformed
  JSON, size-cap enforcement, timestamp variants + bounds clamp,
  unknown-model handling.
- Per-provider store: feature-flag off, TCC-denied /
  path-missing tiles, granted-loaded tile set, clear()
  invalidation, generation-race-on-completion, non-granted
  branch state hygiene.
- ProviderCopy: id regression guards for every provider,
  content-substring assertions on load-bearing user-facing
  phrases.
- Shared helpers: `safeInt`, `parseTimestamp`,
  `saturatingAdd`, `JSONCKeyExtractor`.

Under Swift 6 mode: the LIBRARY target is Swift 6 (2012 tests
still pass); the TestRunner target is deliberately Swift 5.

## 14. Build & Deployment

**Local build**:
```sh
cd app && ./build.sh
```
Produces `build/ClaudeUsageBar.app` (universal binary, arm64 +
x86_64). Signs with Developer ID (`Linkko Technology Pte Ltd
Q467HQ5432`) if the certificate is present in the local Keychain;
errors out otherwise (no ad-hoc fallback — ad-hoc signatures fail
notarisation).

**DMG packaging**:
```sh
cd app && ./create_dmg.sh
```

**CI**: `.github/workflows/ci.yml` runs 5 static-grep guards
(response-body leaks, secret exposure in logs, URL-string
interpolation, cookie/response-body in NSLog, DMCA hostnames
outside allowlist) plus builds both arches and runs the
TestRunner assertion suite.

**Release channel**: `website/latest.json` at
`claudeusagebar.com` — version + download URLs + optional
announcement banner. The `UpdateManager` polls this every 3 hours.

## 15. Integrations

**Local files read** (no writes):
- `~/.claude/projects/**/*.jsonl` — Claude Code sessions.
- `~/.claude` env-overridable via `$CLAUDE_CONFIG_DIR` /
  `$XDG_CONFIG_HOME`.
- `~/.cline/data/tasks/**/ui_messages.json` — Cline CLI.
- `~/Library/Application Support/{Code,Code - Insiders,VSCodium,Cursor,Cursor Nightly,Windsurf}/User/globalStorage/*/tasks/**/{ui_messages,history_item}.json` — Cline / Roo / Zoo VS Code extensions.
- `~/.continue/dev_data/0.2.0/tokensGenerated.jsonl` — Continue.
- `~/.gemini/tmp/<projectHash>/chats/session-*.jsonl` — Gemini
  CLI; env-overridable via `$GEMINI_CLI_HOME`.
- `~/Library/Application Support/{Cursor,Windsurf}/User/globalStorage/state.vscdb` — Cursor + Windsurf sqlite.
- `~/Library/Application Support/JetBrains/{IDE}{Version}/options/AIAssistantQuotaManager2.xml` — JetBrains AI Assistant.
- `~/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite`
  (+ Group Container + Preview fallbacks) — Warp AI.

**Web endpoints** — see §7.

## 16. Cross-Cutting Concerns

- **Logging**: `Log.info` / `Log.debug` / `Log.error` via
  `Log.swift`. Structured `.count(N)` and `.duration(s)`
  suffixes. Never logs raw response bodies, cookies, or PATs —
  enforced by CI static-grep guards.
- **Security**: no hardcoded secrets in source; every credential
  either lives in Keychain or is supplied by the user via a
  masked SecureField in Settings. `KeychainStore` uses
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` to prevent
  device-unlock-triggered exfiltration.
- **DMCA constraint**: JetBrains provider does NOT contact
  `api.jetbrains.ai` or `grazie.aws.intellij.net`. Enforced by
  the CI static-grep guard on `app/ProviderCopy.swift` (the
  ONE allowlisted file).
- **Testing mandate**: every new feature ships with unit tests
  at all applicable levels (fetcher parse tests, store state
  tests, id-regression guards). Follows the global CLAUDE.md
  testing rule.
- **British English**: user-facing copy uses British spelling
  (`authorised`, `honours`, `behaviour`). Enforced by review, not
  automation (there is no CI spell-check).
- **Swift 6 strict concurrency**: library target compiles under
  Swift 6 language mode as of PR #81. Every store is
  `@MainActor`; every fetcher is a pure `Sendable` value type.
  Static ISO formatters marked `nonisolated(unsafe)` with audit
  comments.
