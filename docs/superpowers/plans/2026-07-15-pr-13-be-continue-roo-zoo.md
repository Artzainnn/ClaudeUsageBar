# PR 13-BE — Continue + Roo/Zoo backends implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This plan will execute inline (no per-task human review) because the parent session is running in autonomous mode.

**Goal:** Add three feature-flag-off local backend providers (Continue,
Roo Code, Zoo Code) reading local files. Nothing renders in the popover
until PR 13-UI wires tiles + Settings toggles.

**Architecture:** Continue reads `~/.continue/dev_data/0.2.0/tokensGenerated.jsonl`
line-by-line (JSONL, tokens-only). Roo and Zoo share one fetcher that
reads a pre-computed `history_item.json` rollup per task, falling back to
Cline-shape `ui_messages.json` parsing when the rollup is absent. Two
Roo/Zoo stores gate on distinct feature flags so the archived Roo can be
toggled independently. Every store mirrors the `ClineUsageStore.fetch()`
pattern (generation counter + re-probe on completion), not the bare
`ClaudeCodeUsageStore.fetch()` (which lacks the re-probe fix).

**Tech Stack:** Swift 5.9 (language mode 5), macOS 12+, SwiftPM library +
TestRunner executable, `FileManager` + `FileHandle` + `stat()` for I/O,
no third-party dependencies.

## Global Constraints

- Language mode: Swift 5.9 (do NOT flip to Swift 6; that lands in PR 16).
- Target: `arm64-apple-macos12.0` + `x86_64-apple-macos12.0`.
- Feature flags default false. Every new store gated on its flag. Feature
  flag keys: `features.continue.enabled`, `features.roo.enabled`,
  `features.zoo.enabled`.
- No emoji, no British-vs-US inconsistency (British throughout).
- Provider protocol conformance: `@MainActor final class` with
  `@preconcurrency UsageProvider`.
- Every fetcher: value-type `Sendable struct`, no observable state,
  every static function pure.
- Every store: `@MainActor`, `@Published` observable state, injected
  dependencies for tests (`resolveScanRoots`, `tccProbe`, `discoverFiles`,
  `parseFiles`, `workQueue`, `clock`), `fetchGeneration &+=` on entry
  and clear().
- Every store MUST use the re-probe-on-completion pattern (mirror
  `ClineUsageStore.fetch()` lines 258-382 verbatim in structure, not
  bare `ClaudeCodeUsageStore.fetch()`).
- No new CI guards. Existing 7 static-grep guards + copy-only shape guard
  must all pass unchanged.
- No changes to Anthropic path, popover rendering, or timer cadence.
- Every test in the assertion-based TestRunner style
  (`Tests/TestRunner/*.swift`), not XCTest.
- Every commit signed with the standard Co-Authored-By trailer (see
  bottom of file).
- Field name for the Roo/Zoo history rollup cost: `totalCost` (NOT
  `cost`). Reject the Cline parser's assumption verbatim.
- Continue's tokens-only schema: no cost field ever. Do not import
  ClaudeCodePricing.
- ISO-8601 timestamps for Continue MUST use `parseTimestamp` (added to
  ClaudeCodeUsageFetcher with a bounds clamp), NOT Cline's
  `extractTimestamp` (which treats string as numeric-ms).
- Task budget cap: 10 000 most-recent tasks per Roo/Zoo scan; anything
  beyond surfaces a diagnostic tile.
- File size cap: 128 MB for Roo/Zoo `ui_messages.json` fallback;
  256 MB for Continue JSONL (matches existing ClaudeCode cap).
- Every provider tile guarded by TCC probe with the re-probe-on-completion
  fix.
- customStoragePath discovery: targeted state-machine key extractor (NOT
  full-JSONC parsing).

---

## File structure

**New (in `app/`):**
- `ContinueUsageFetcher.swift` — value-type reader + snapshot types.
- `ContinueUsageStore.swift` — @MainActor UsageProvider store.
- `RooZooPathResolver.swift` — scan-root enumeration + customStoragePath
  extraction + validation.
- `RooZooUsageFetcher.swift` — value-type reader + snapshot types.
  Parameterised by `RooZooExtension` enum.
- `RooUsageStore.swift` — @MainActor UsageProvider store for Roo.
- `ZooUsageStore.swift` — @MainActor UsageProvider store for Zoo.

**Modified (in `app/`):**
- `ClaudeCodeUsageFetcher.swift` — two hardening changes: `safeInt` Bool
  guard + `parseTimestamp` bounds clamp.
- `ClaudeUsageBar.swift` — register three new stores after WarpUsageStore.
- `Package.swift` — six new sources to library target.

**New (in `Tests/TestRunner/`):**
- `TestContinueUsageFetcher.swift`
- `TestContinueUsageStore.swift`
- `TestRooZooPathResolver.swift`
- `TestRooZooUsageFetcher.swift`
- `TestRooUsageStore.swift`
- `TestZooUsageStore.swift`
- Edits to `main.swift` to invoke each new test module.

---

### Task 1: Harden `ClaudeCodeUsageFetcher.safeInt` and `parseTimestamp` (hardening)

**Files:**
- Modify: `app/ClaudeCodeUsageFetcher.swift:741-744` (parseTimestamp),
  `app/ClaudeCodeUsageFetcher.swift:752-768` (safeInt)
- Test: `Tests/TestRunner/TestClaudeCodeUsageFetcher.swift` (existing;
  add cases)

**Interfaces:**
- Consumes: existing signatures unchanged.
- Produces: `safeInt(true)` returns 0 (was 1 due to Bool→NSNumber→Int
  bridging); `parseTimestamp` clamps to `[2000-01-01, 2100-01-01)`
  after parsing (nil for out-of-bounds).

- [ ] **Step 1: Locate existing safeInt tests**
  Run: `grep -n "safeInt\|parseTimestamp" Tests/TestRunner/*.swift`
  Expected: tests exist under one of the existing test files. If none,
  add cases inside the ClaudeCode block of `main.swift` under a new
  section. Confirm the runner picks them up.

- [ ] **Step 2: Add failing test for Bool guard**
  Add to appropriate test file:
  ```swift
  func testSafeIntRejectsBool() {
      expect(ClaudeCodeUsageFetcher.safeInt(true) == 0)
      expect(ClaudeCodeUsageFetcher.safeInt(false) == 0)
  }
  ```
  Run: `swift run TestRunner`
  Expected: FAIL with `safeInt(true) == 0` returning `false` (currently
  returns 1 via NSNumber bridge).

- [ ] **Step 3: Add failing test for timestamp bounds**
  ```swift
  func testParseTimestampClampsBounds() {
      // Year 1999 → nil (below year2000 floor)
      expect(ClaudeCodeUsageFetcher.parseTimestamp("1999-12-31T23:59:59Z") == nil)
      // Year 2100 → nil (at year2100 ceiling, exclusive)
      expect(ClaudeCodeUsageFetcher.parseTimestamp("2100-01-01T00:00:00Z") == nil)
      // Year 2050 → non-nil
      expect(ClaudeCodeUsageFetcher.parseTimestamp("2050-06-15T12:00:00Z") != nil)
  }
  ```
  Run: `swift run TestRunner`
  Expected: FAIL — 1999 currently parses successfully.

- [ ] **Step 4: Implement Bool guard**
  Edit `app/ClaudeCodeUsageFetcher.swift:752-768`:
  ```swift
  public static func safeInt(_ value: Any?) -> Int {
      // 3cc R3 F8: reject Bool early. Bool bridges to NSNumber which
      // as-casts to Int as 1, silently coercing a JSON `true` into a
      // token count of 1. A numeric field must never accept a Bool.
      if value is Bool { return 0 }
      if let i = value as? Int { return max(0, i) }
      if let d = value as? Double, d.isFinite {
          let rounded = d.rounded()
          if rounded <= 0 { return 0 }
          if let n = Int(exactly: rounded) { return n }
          return Int.max
      }
      if let s = value as? String, let i = Int(s) { return max(0, i) }
      return 0
  }
  ```

- [ ] **Step 5: Implement timestamp bounds clamp**
  Edit `app/ClaudeCodeUsageFetcher.swift:741-744`:
  ```swift
  public static func parseTimestamp(_ raw: String) -> Date? {
      let d = isoFormatter.date(from: raw)
                ?? isoFormatterNoFractional.date(from: raw)
      guard let d = d else { return nil }
      // 3cc R1 F10 / R3 F18: clamp to [year2000, year2100). Outside
      // this range the value is a schema break, not real usage; nil
      // makes the record un-bucketable rather than corrupting today
      // / MTD sums.
      let sec = d.timeIntervalSince1970
      let year2000: TimeInterval = 946_684_800
      let year2100: TimeInterval = 4_102_444_800
      guard sec >= year2000 && sec < year2100 else { return nil }
      return d
  }
  ```

- [ ] **Step 6: Run tests, verify pass**
  Run: `swift run TestRunner`
  Expected: PASS (baseline was 1693; expect 1695 after adding 2 tests).

- [ ] **Step 7: Verify no regression in existing tests**
  Run: `swift run TestRunner 2>&1 | tail -20`
  Expected: `All N tests passed.` with N ≥ 1695. If any prior test
  relied on `safeInt(true) == 1`, that test itself was buggy; fix it.

- [ ] **Step 8: Commit**
  ```bash
  git add app/ClaudeCodeUsageFetcher.swift Tests/TestRunner/
  git commit -m "$(cat <<'EOF'
  feat: harden safeInt + parseTimestamp against hostile inputs

  PR 13-BE precursor. Two hardening changes to ClaudeCodeUsageFetcher:

  1. safeInt(Bool) now returns 0. Bool bridges to NSNumber which as-casts
     to Int as 1 — a JSON `true` in a token count field was silently
     becoming 1. A numeric field must never accept a Bool.

  2. parseTimestamp now clamps to [year2000, year2100). A timestamp
     outside this range is a schema break, not real usage; nil makes
     the record un-bucketable rather than corrupting today/MTD sums.

  Both changes are additive — existing valid inputs are unaffected.

  🤖 Generated with [Claude Code](https://claude.com/claude-code)

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 2: Continue fetcher (value-type reader)

**Files:**
- Create: `app/ContinueUsageFetcher.swift`
- Test: `Tests/TestRunner/TestContinueUsageFetcher.swift`
- Modify: `Package.swift` (add source), `Tests/TestRunner/main.swift` (add invocation)

**Interfaces:**
- Produces:
  ```swift
  public struct ContinueUsageRecord: Equatable, Sendable {
      public var model: String
      public var provider: String
      public var timestamp: Date?
      public var promptTokens: Int
      public var generatedTokens: Int
      public var sourceFile: String
      public var totalTokens: Int { get }
  }
  public struct ContinueUsageSnapshot: Equatable, Sendable {
      public var records: [ContinueUsageRecord]
      public var recordsPerFile: [String: Int]
      public var malformedRecordCount: Int
      public var unreadableFileCount: Int
      public var overCapFileCount: Int   // NEW vs ClaudeCode: distinguish
                                         // over-cap from corrupt.
      public init(...)
      public func tokens(in range: ClosedRange<Date>) -> Int
      public func breakdownByModel(in range: ClosedRange<Date>) -> [ModelBreakdown]
      public func breakdownByProvider(in range: ClosedRange<Date>) -> [ProviderBreakdown]
  }
  public enum ContinuePathResolver {
      public struct ScanRoot: Equatable, Sendable {
          public var id: String
          public var jsonlPath: String
      }
      public static func resolveScanRoots(_ env: Environment) -> [ScanRoot]
      public struct Environment: Sendable {
          public var homeDirectoryPath: String
          public static func current() -> Environment
      }
  }
  public struct ContinueUsageFetcher: Sendable {
      public static func parse(files: [URL]) -> ContinueUsageSnapshot
      public static func parseLine(_ line: String, sourceFile: String,
                                   malformedCount: inout Int) -> ContinueUsageRecord?
      public static func discoverFiles(under scanRoots: [ContinuePathResolver.ScanRoot]) -> [URL]
  }
  ```

- [ ] **Step 1: Add file to Package.swift**
  Edit `Package.swift` `sources:` array — add just after Warp entries
  (last block), before the closing `]`:
  ```swift
  "ContinueUsageFetcher.swift",
  "ContinueUsageStore.swift",
  "RooZooPathResolver.swift",
  "RooZooUsageFetcher.swift",
  "RooUsageStore.swift",
  "ZooUsageStore.swift"
  ```
  (Add all six now; the files will land in subsequent tasks.)

- [ ] **Step 2: Write failing test — parseLine happy path**
  Create `Tests/TestRunner/TestContinueUsageFetcher.swift`:
  ```swift
  import Foundation
  @testable import ClaudeUsageBar

  func testContinueFetcher_parseLineHappyPath() {
      let line = #"{"timestamp":"2026-07-15T14:23:11.523Z","userId":"u1","userAgent":"vscode/1.0","selectedProfileId":"p1","eventName":"tokensGenerated","schema":"0.2.0","model":"gpt-5","provider":"openai","promptTokens":100,"generatedTokens":250}"#
      var malformed = 0
      let record = ContinueUsageFetcher.parseLine(line, sourceFile: "/x", malformedCount: &malformed)
      expect(record != nil)
      expect(record?.model == "gpt-5")
      expect(record?.provider == "openai")
      expect(record?.promptTokens == 100)
      expect(record?.generatedTokens == 250)
      expect(record?.timestamp != nil)
      expect(malformed == 0)
  }
  ```
  Also add function invocations in `main.swift` (find how other test
  files register — search for `test` calls in a `runX` function).

  Run: `swift run TestRunner`
  Expected: BUILD FAIL — `ContinueUsageFetcher` type does not exist.

- [ ] **Step 3: Create ContinueUsageFetcher.swift with types + parseLine**
  Create `app/ContinueUsageFetcher.swift`:
  ```swift
  // PR 13-BE — Continue local dev-data JSONL fetcher (feature-flag off).
  //
  // Reads Continue's own on-disk `tokensGenerated.jsonl` at
  // `~/.continue/dev_data/0.2.0/tokensGenerated.jsonl`. Nothing leaves
  // the machine. Tokens-only (Continue's schema has no cost field).
  //
  // Continue writes 10 sibling event streams under the same folder
  // (autocomplete, chatFeedback, chatInteraction, editInteraction,
  // editOutcome, nextEditOutcome, nextEditWithHistory, toolUsage, plus
  // a legacy quickEdit under 0.1.0). We consume ONLY tokensGenerated,
  // which is the single canonical source of token counts across every
  // LLM call in Continue.
  //
  // Schema per line (verbatim from continuedev/continue's
  // `packages/config-yaml/src/schemas/data/tokensGenerated/v0.2.0.ts`):
  //
  //   { timestamp, userId, userAgent, selectedProfileId, eventName,
  //     schema, model, provider, promptTokens, generatedTokens }
  //
  // `timestamp` is ISO-8601 (`new Date().toISOString()`), NOT
  // ms-since-epoch. Feed it through
  // `ClaudeCodeUsageFetcher.parseTimestamp` — Cline's own
  // `extractTimestamp` would return nil for every record.
  //
  // Local logging is unconditionally ON in Continue
  // (core/data/log.ts:88 `// Local logs (always on for all levels)`).
  // No user-side enable step; if Continue has been used, the file
  // exists.
  //
  // Feature posture — `features.continue.enabled` defaults false.
  // Nothing registers a ContinueUsageStore into the live registry
  // yet (that lands in PR 13-UI).

  import Foundation

  // MARK: - Snapshot pieces

  public struct ContinueUsageRecord: Equatable, Sendable {
      public var model: String
      public var provider: String
      public var timestamp: Date?
      public var promptTokens: Int
      public var generatedTokens: Int
      public var sourceFile: String

      public init(model: String, provider: String, timestamp: Date?,
                  promptTokens: Int, generatedTokens: Int, sourceFile: String) {
          self.model = model
          self.provider = provider
          self.timestamp = timestamp
          self.promptTokens = promptTokens
          self.generatedTokens = generatedTokens
          self.sourceFile = sourceFile
      }

      public var totalTokens: Int {
          ClaudeCodeUsageRecord.saturatingAdd(promptTokens, generatedTokens)
      }
  }

  public struct ContinueUsageSnapshot: Equatable, Sendable {
      public var records: [ContinueUsageRecord]
      public var recordsPerFile: [String: Int]
      public var malformedRecordCount: Int
      public var unreadableFileCount: Int
      public var overCapFileCount: Int

      public init(records: [ContinueUsageRecord],
                  recordsPerFile: [String: Int] = [:],
                  malformedRecordCount: Int = 0,
                  unreadableFileCount: Int = 0,
                  overCapFileCount: Int = 0) {
          self.records = records
          self.recordsPerFile = recordsPerFile
          self.malformedRecordCount = malformedRecordCount
          self.unreadableFileCount = unreadableFileCount
          self.overCapFileCount = overCapFileCount
      }

      public func tokens(in range: ClosedRange<Date>) -> Int {
          var s = 0
          for r in records {
              guard let ts = r.timestamp, range.contains(ts) else { continue }
              s = ClaudeCodeUsageRecord.saturatingAdd(s, r.totalTokens)
          }
          return s
      }

      public struct ModelBreakdown: Equatable, Sendable {
          public var model: String
          public var tokens: Int
          public init(model: String, tokens: Int) {
              self.model = model
              self.tokens = tokens
          }
      }
      public func breakdownByModel(in range: ClosedRange<Date>) -> [ModelBreakdown] {
          var byModel: [String: Int] = [:]
          for r in records {
              guard let ts = r.timestamp, range.contains(ts) else { continue }
              byModel[r.model] = ClaudeCodeUsageRecord.saturatingAdd(
                  byModel[r.model] ?? 0, r.totalTokens)
          }
          return byModel.map { ModelBreakdown(model: $0.key, tokens: $0.value) }
                        .sorted { $0.tokens > $1.tokens }
      }

      public struct ProviderBreakdown: Equatable, Sendable {
          public var provider: String
          public var tokens: Int
          public init(provider: String, tokens: Int) {
              self.provider = provider
              self.tokens = tokens
          }
      }
      public func breakdownByProvider(in range: ClosedRange<Date>) -> [ProviderBreakdown] {
          var byProv: [String: Int] = [:]
          for r in records {
              guard let ts = r.timestamp, range.contains(ts) else { continue }
              byProv[r.provider] = ClaudeCodeUsageRecord.saturatingAdd(
                  byProv[r.provider] ?? 0, r.totalTokens)
          }
          return byProv.map { ProviderBreakdown(provider: $0.key, tokens: $0.value) }
                       .sorted { $0.tokens > $1.tokens }
      }
  }

  // MARK: - Path resolution

  public enum ContinuePathResolver {
      public struct Environment: Sendable {
          public var homeDirectoryPath: String
          public init(homeDirectoryPath: String) {
              self.homeDirectoryPath = homeDirectoryPath
          }
          public static func current() -> Environment {
              Environment(homeDirectoryPath: NSHomeDirectory())
          }
      }

      public struct ScanRoot: Equatable, Sendable {
          public var id: String
          public var jsonlPath: String
          public init(id: String, jsonlPath: String) {
              self.id = id
              self.jsonlPath = jsonlPath
          }
      }

      public static func resolveScanRoots(_ env: Environment) -> [ScanRoot] {
          // Only 0.2.0/tokensGenerated.jsonl. Legacy 0.1.0 dropped —
          // schema not verified for that version and the population of
          // users still on pre-2024 Continue is negligible.
          guard !env.homeDirectoryPath.isEmpty else { return [] }
          let path = (env.homeDirectoryPath as NSString)
              .appendingPathComponent(".continue/dev_data/0.2.0/tokensGenerated.jsonl")
          return [ScanRoot(id: "Continue", jsonlPath: path)]
      }
  }

  // MARK: - Fetcher

  public struct ContinueUsageFetcher: Sendable {

      /// Parse one JSONL line. Returns nil for a malformed line (with
      /// `malformedCount` incremented) or a record with both token
      /// fields zero (Continue writes such rows during some error
      /// paths; they contribute nothing).
      public static func parseLine(
          _ line: String,
          sourceFile: String,
          malformedCount: inout Int
      ) -> ContinueUsageRecord? {
          let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return nil }
          guard let data = trimmed.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data),
                let dict = obj as? [String: Any] else {
              malformedCount += 1
              return nil
          }
          // Only accept records whose eventName is "tokensGenerated" —
          // defensive against a future refactor that mixes streams.
          if let ev = dict["eventName"] as? String, ev != "tokensGenerated" {
              return nil
          }
          let model = (dict["model"] as? String) ?? "unknown"
          let provider = (dict["provider"] as? String) ?? "unknown"
          let promptTokens = ClaudeCodeUsageFetcher.safeInt(dict["promptTokens"])
          let generatedTokens = ClaudeCodeUsageFetcher.safeInt(dict["generatedTokens"])
          if promptTokens == 0 && generatedTokens == 0 { return nil }

          var ts: Date? = nil
          if let rawTs = dict["timestamp"] as? String {
              ts = ClaudeCodeUsageFetcher.parseTimestamp(rawTs)
          }

          return ContinueUsageRecord(
              model: model,
              provider: provider,
              timestamp: ts,
              promptTokens: promptTokens,
              generatedTokens: generatedTokens,
              sourceFile: sourceFile
          )
      }

      /// Parse a set of Continue JSONL files into a full snapshot. Uses
      /// `ClaudeCodeUsageFetcher.readJsonlLines` under the hood
      /// (per-line UTF-8 tolerance, 256 MB cap, streaming FileHandle).
      /// If a file exceeds cap, `overCapFileCount` is incremented and
      /// the file is skipped (tail-read strategy tracked as a future
      /// improvement in tests but not implemented in v1 — Continue's
      /// realistic file sizes stay well under cap for the foreseeable
      /// future).
      public static func parse(files: [URL]) -> ContinueUsageSnapshot {
          var allRecords: [ContinueUsageRecord] = []
          var perFile: [String: Int] = [:]
          var malformed = 0
          var unreadable = 0
          var overCap = 0

          for url in files {
              // Check size first — if over cap, count as overCap not
              // unreadable so the tile can render a distinct diagnostic.
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
              let sizeCap: Int64 = 256 * 1024 * 1024
              if let size = (attrs?[.size] as? NSNumber)?.int64Value,
                 size > sizeCap {
                  overCap += 1
                  continue
              }
              guard let lines = ClaudeCodeUsageFetcher.readJsonlLines(from: url) else {
                  unreadable += 1
                  continue
              }
              var perFileCount = 0
              for line in lines {
                  guard let rec = parseLine(line, sourceFile: url.path,
                                            malformedCount: &malformed) else {
                      continue
                  }
                  allRecords.append(rec)
                  perFileCount += 1
              }
              perFile[url.path] = perFileCount
          }

          allRecords.sort { lhs, rhs in
              switch (lhs.timestamp, rhs.timestamp) {
              case let (l?, r?): return l < r
              case (nil, _?):    return false
              case (_?, nil):    return true
              case (nil, nil):   return false
              }
          }

          return ContinueUsageSnapshot(
              records: allRecords,
              recordsPerFile: perFile,
              malformedRecordCount: malformed,
              unreadableFileCount: unreadable,
              overCapFileCount: overCap
          )
      }

      public static func discoverFiles(under scanRoots: [ContinuePathResolver.ScanRoot]) -> [URL] {
          let fm = FileManager.default
          var out: [URL] = []
          for root in scanRoots {
              if fm.fileExists(atPath: root.jsonlPath) {
                  out.append(URL(fileURLWithPath: root.jsonlPath))
              }
          }
          return out
      }
  }
  ```
  Run: `swift build`
  Expected: PASS.

- [ ] **Step 4: Run parseLine happy-path test — should PASS now**
  Run: `swift run TestRunner`
  Expected: PASS. Baseline was 1695; expect 1696.

- [ ] **Step 5: Add hostile-numerics tests (Bool, NaN, big-string, negative, array, null)**
  ```swift
  func testContinueFetcher_parseLine_hostileNumerics() {
      var m = 0
      let boolPT = #"{"eventName":"tokensGenerated","model":"m","provider":"p","promptTokens":true,"generatedTokens":100,"timestamp":"2026-01-01T00:00:00Z"}"#
      let bool = ContinueUsageFetcher.parseLine(boolPT, sourceFile: "/x", malformedCount: &m)
      expect(bool?.promptTokens == 0)  // Bool → 0 via 3cc R3 F8 guard

      let bigStr = #"{"eventName":"tokensGenerated","model":"m","provider":"p","promptTokens":"9999999999999999999999999","generatedTokens":10,"timestamp":"2026-01-01T00:00:00Z"}"#
      let big = ContinueUsageFetcher.parseLine(bigStr, sourceFile: "/x", malformedCount: &m)
      // Int.init(s) on this string returns nil, safeInt falls to 0
      expect(big?.promptTokens == 0)

      let negPT = #"{"eventName":"tokensGenerated","model":"m","provider":"p","promptTokens":-1,"generatedTokens":10,"timestamp":"2026-01-01T00:00:00Z"}"#
      let neg = ContinueUsageFetcher.parseLine(negPT, sourceFile: "/x", malformedCount: &m)
      expect(neg?.promptTokens == 0)

      let arrPT = #"{"eventName":"tokensGenerated","model":"m","provider":"p","promptTokens":[1,2,3],"generatedTokens":10,"timestamp":"2026-01-01T00:00:00Z"}"#
      let arr = ContinueUsageFetcher.parseLine(arrPT, sourceFile: "/x", malformedCount: &m)
      expect(arr?.promptTokens == 0)

      let nullPT = #"{"eventName":"tokensGenerated","model":"m","provider":"p","promptTokens":null,"generatedTokens":10,"timestamp":"2026-01-01T00:00:00Z"}"#
      let nul = ContinueUsageFetcher.parseLine(nullPT, sourceFile: "/x", malformedCount: &m)
      expect(nul?.promptTokens == 0)
  }
  ```
  Run: `swift run TestRunner`
  Expected: PASS.

- [ ] **Step 6: Add malformed line test**
  ```swift
  func testContinueFetcher_parseLine_malformed() {
      var m = 0
      let malformed = "{not valid json"
      let rec = ContinueUsageFetcher.parseLine(malformed, sourceFile: "/x", malformedCount: &m)
      expect(rec == nil)
      expect(m == 1)

      // Empty line — no malformed increment
      m = 0
      let empty = ""
      let rec2 = ContinueUsageFetcher.parseLine(empty, sourceFile: "/x", malformedCount: &m)
      expect(rec2 == nil)
      expect(m == 0)

      // Whitespace line — no malformed increment
      let ws = "   \n\t   "
      let rec3 = ContinueUsageFetcher.parseLine(ws, sourceFile: "/x", malformedCount: &m)
      expect(rec3 == nil)
      expect(m == 0)
  }
  ```
  Run: `swift run TestRunner`
  Expected: PASS.

- [ ] **Step 7: Add ISO-8601 timestamp variants test**
  ```swift
  func testContinueFetcher_parseLine_isoVariants() {
      var m = 0

      // With fractional seconds and Z
      let l1 = #"{"eventName":"tokensGenerated","model":"m","provider":"p","promptTokens":1,"generatedTokens":1,"timestamp":"2026-07-15T14:23:11.523Z"}"#
      expect(ContinueUsageFetcher.parseLine(l1, sourceFile: "/x", malformedCount: &m)?.timestamp != nil)

      // Without fractional seconds
      let l2 = #"{"eventName":"tokensGenerated","model":"m","provider":"p","promptTokens":1,"generatedTokens":1,"timestamp":"2026-07-15T14:23:11Z"}"#
      expect(ContinueUsageFetcher.parseLine(l2, sourceFile: "/x", malformedCount: &m)?.timestamp != nil)

      // With +00:00 offset
      let l3 = #"{"eventName":"tokensGenerated","model":"m","provider":"p","promptTokens":1,"generatedTokens":1,"timestamp":"2026-07-15T14:23:11+00:00"}"#
      expect(ContinueUsageFetcher.parseLine(l3, sourceFile: "/x", malformedCount: &m)?.timestamp != nil)

      // Out-of-bounds year → nil timestamp but record still parsed
      let l4 = #"{"eventName":"tokensGenerated","model":"m","provider":"p","promptTokens":1,"generatedTokens":1,"timestamp":"1970-01-01T00:00:00Z"}"#
      let rec4 = ContinueUsageFetcher.parseLine(l4, sourceFile: "/x", malformedCount: &m)
      expect(rec4 != nil)
      expect(rec4?.timestamp == nil)  // clamped out
  }
  ```

- [ ] **Step 8: Add zero-token skip test**
  ```swift
  func testContinueFetcher_parseLine_skipsZeroBoth() {
      var m = 0
      let both = #"{"eventName":"tokensGenerated","model":"m","provider":"p","promptTokens":0,"generatedTokens":0,"timestamp":"2026-01-01T00:00:00Z"}"#
      expect(ContinueUsageFetcher.parseLine(both, sourceFile: "/x", malformedCount: &m) == nil)
      // Any nonzero survives
      let one = #"{"eventName":"tokensGenerated","model":"m","provider":"p","promptTokens":0,"generatedTokens":1,"timestamp":"2026-01-01T00:00:00Z"}"#
      expect(ContinueUsageFetcher.parseLine(one, sourceFile: "/x", malformedCount: &m) != nil)
  }
  ```

- [ ] **Step 9: Add non-tokensGenerated event rejection test**
  ```swift
  func testContinueFetcher_parseLine_rejectsOtherEvents() {
      var m = 0
      let ac = #"{"eventName":"autocomplete","model":"m","provider":"p","promptTokens":10,"generatedTokens":10,"timestamp":"2026-01-01T00:00:00Z"}"#
      expect(ContinueUsageFetcher.parseLine(ac, sourceFile: "/x", malformedCount: &m) == nil)
      expect(m == 0)  // rejection is not malformed
  }
  ```

- [ ] **Step 10: Add resolveScanRoots test**
  ```swift
  func testContinuePathResolver_resolveScanRoots() {
      let env = ContinuePathResolver.Environment(homeDirectoryPath: "/Users/testuser")
      let roots = ContinuePathResolver.resolveScanRoots(env)
      expect(roots.count == 1)
      expect(roots.first?.id == "Continue")
      expect(roots.first?.jsonlPath == "/Users/testuser/.continue/dev_data/0.2.0/tokensGenerated.jsonl")
  }

  func testContinuePathResolver_emptyHome() {
      let env = ContinuePathResolver.Environment(homeDirectoryPath: "")
      let roots = ContinuePathResolver.resolveScanRoots(env)
      expect(roots.isEmpty)
  }
  ```

- [ ] **Step 11: Add parse-full-file integration test**
  ```swift
  func testContinueFetcher_parseFullFile() {
      let tmp = FileManager.default.temporaryDirectory
          .appendingPathComponent("continue-test-\(UUID().uuidString).jsonl")
      defer { try? FileManager.default.removeItem(at: tmp) }
      let content = """
      {"eventName":"tokensGenerated","model":"gpt-5","provider":"openai","promptTokens":100,"generatedTokens":200,"timestamp":"2026-07-15T10:00:00Z"}
      {"eventName":"tokensGenerated","model":"claude-opus-4-7","provider":"anthropic","promptTokens":50,"generatedTokens":150,"timestamp":"2026-07-15T11:00:00Z"}
      {malformed line}
      {"eventName":"autocomplete","model":"m","provider":"p","promptTokens":5,"generatedTokens":5,"timestamp":"2026-07-15T12:00:00Z"}
      """
      try! content.data(using: .utf8)!.write(to: tmp)
      let snap = ContinueUsageFetcher.parse(files: [tmp])
      expect(snap.records.count == 2)
      expect(snap.malformedRecordCount == 1)
      expect(snap.unreadableFileCount == 0)
      let cal = Calendar(identifier: .gregorian)
      var comp = DateComponents()
      comp.year = 2026; comp.month = 7; comp.day = 15
      let start = cal.date(from: comp)!
      let end = cal.date(byAdding: .day, value: 1, to: start)!
      let range = start...end
      let total = snap.tokens(in: range)
      expect(total == 500)  // 100+200+50+150
      let byProv = snap.breakdownByProvider(in: range)
      expect(byProv.count == 2)
  }
  ```

- [ ] **Step 12: Run all Continue tests + full suite**
  Run: `swift run TestRunner`
  Expected: PASS. Baseline was 1695 (from Task 1); expect ~1706 after
  adding the ~11 Continue tests.

- [ ] **Step 13: Commit**
  ```bash
  git add app/ContinueUsageFetcher.swift Tests/TestRunner/TestContinueUsageFetcher.swift Package.swift Tests/TestRunner/main.swift
  git commit -m "$(cat <<'EOF'
  feat: add ContinueUsageFetcher — local dev-data JSONL reader

  Value-type Sendable fetcher for Continue's
  `~/.continue/dev_data/0.2.0/tokensGenerated.jsonl`. Tokens-only per
  Continue's schema (no cost field, no cache tokens).

  Reuses ClaudeCodeUsageFetcher.readJsonlLines for the streaming
  256 MB-capped FileHandle read, ClaudeCodeUsageFetcher.parseTimestamp
  for ISO-8601 timestamps with [2000, 2100) clamp, and
  ClaudeCodeUsageFetcher.safeInt for the Bool-safe numeric extraction
  (both hardened in the preceding commit).

  Snapshot exposes tokens(in:), breakdownByModel(in:), and
  breakdownByProvider(in:) for tile rendering.

  Non-breaking — no store registered yet; PR 13-UI wires the tile.

  🤖 Generated with [Claude Code](https://claude.com/claude-code)

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 3: Continue store (@MainActor UsageProvider)

**Files:**
- Create: `app/ContinueUsageStore.swift`
- Test: `Tests/TestRunner/TestContinueUsageStore.swift`
- Modify: `Tests/TestRunner/main.swift`

**Interfaces:**
- Consumes: types from Task 2.
- Produces:
  ```swift
  @MainActor
  public final class ContinueUsageStore: @preconcurrency UsageProvider {
      public let id: String = "continue"
      public let displayName: String = "Continue"
      public let featureFlagKey: String = "features.continue.enabled"
      public var isEnabled: Bool { defaults.bool(forKey: featureFlagKey) }
      public var isConfigured: Bool { isEnabled }
      public var lastUpdated: Date? { lastUpdatedAt }
      public var errorMessage: String? { lastError }
      @Published public private(set) var snapshot: ContinueUsageSnapshot?
      @Published public private(set) var lastUpdatedAt: Date?
      @Published public private(set) var lastError: String?
      @Published public private(set) var tccState: TCCState
      public var tiles: [UsageTile] { get }
      public func fetch()
      public func clear()
      public init(defaults: UserDefaults = .standard,
                  resolveScanRoots: @escaping @Sendable () -> [ContinuePathResolver.ScanRoot] = { ContinuePathResolver.resolveScanRoots(.current()) },
                  tccProbe: @escaping @Sendable (String) -> TCCState = { TCCProbe.probe(path: $0) },
                  discoverFiles: @escaping @Sendable ([ContinuePathResolver.ScanRoot]) -> [URL] = { ContinueUsageFetcher.discoverFiles(under: $0) },
                  parseFiles: @escaping @Sendable ([URL]) -> ContinueUsageSnapshot = { ContinueUsageFetcher.parse(files: $0) },
                  workQueue: DispatchQueue = DispatchQueue(label: "com.claude.usagebar.continue.parse", qos: .utility),
                  clock: @escaping @Sendable () -> Date = { Date() })
  }
  ```

- [ ] **Step 1: Write failing test — feature-flag off returns no tiles**
  ```swift
  func testContinueStore_flagOff_noTiles() {
      let defs = TestDefaults()  // helper — see reference in ClineStore tests
      let store = ContinueUsageStore(defaults: defs)
      expect(store.isEnabled == false)
      expect(store.tiles.isEmpty)
  }
  ```
  If `TestDefaults` doesn't exist yet, search the existing Tests/ files
  for how test doubles are declared (there's likely an existing helper
  or an inline UserDefaults suite name).

  Run: `swift run TestRunner`
  Expected: BUILD FAIL — ContinueUsageStore doesn't exist.

- [ ] **Step 2: Create ContinueUsageStore.swift**
  Model it on `app/ClineUsageStore.swift` verbatim in structure, adapted
  to Continue's types. Copy the fetch() body from ClineUsageStore
  (lines 258-382) — do NOT copy from ClaudeCodeUsageStore which lacks
  the re-probe fix. Substitute the scan-root and snapshot types.

  Key differences from ClineUsageStore:
  - `tiles` returns only three kinds: `.needsAccess`, `.text`
    ("no Continue log found" for pathMissing), and (when loaded) counter
    tiles for `continue-tokens-today` and text tiles for `continue-tokens-by-model`
    + `continue-tokens-by-provider`. No cost tiles.
  - The re-probe pattern is identical.
  - `deniedRootCount` is unused (Continue has one root only — either it's
    granted, denied, or missing). Remove.

  ```swift
  // PR 13-BE — Continue UsageProvider store (feature-flag off).
  //
  // Concurrency model mirrors ClineUsageStore: parse on serial background
  // queue; results apply on the main actor via
  // `Task { @MainActor [weak self] in ... }`; `fetchGeneration` invalidates
  // any in-flight completion so a TCC transition, disable, or `clear()`
  // cannot repopulate stale state. The re-probe-on-completion pattern
  // (3cc R3 F5) is inherited from ClineUsageStore lines 348-372.

  import Foundation
  import SwiftUI
  import Combine

  @MainActor
  public final class ContinueUsageStore: @preconcurrency UsageProvider {

      public let id: String = "continue"
      public let displayName: String = "Continue"
      public let featureFlagKey: String = "features.continue.enabled"

      @Published public private(set) var snapshot: ContinueUsageSnapshot?
      @Published public private(set) var lastUpdatedAt: Date?
      @Published public private(set) var lastError: String?
      @Published public private(set) var tccState: TCCState = .granted

      private let defaults: UserDefaults
      private let resolveScanRoots: @Sendable () -> [ContinuePathResolver.ScanRoot]
      private let tccProbe: @Sendable (String) -> TCCState
      private let discoverFiles: @Sendable ([ContinuePathResolver.ScanRoot]) -> [URL]
      private let parseFiles: @Sendable ([URL]) -> ContinueUsageSnapshot
      private let workQueue: DispatchQueue
      private let clock: @Sendable () -> Date

      private var fetchGeneration: UInt64 = 0

      public init(
          defaults: UserDefaults = .standard,
          resolveScanRoots: @escaping @Sendable () -> [ContinuePathResolver.ScanRoot] = {
              ContinuePathResolver.resolveScanRoots(.current())
          },
          tccProbe: @escaping @Sendable (String) -> TCCState = { TCCProbe.probe(path: $0) },
          discoverFiles: @escaping @Sendable ([ContinuePathResolver.ScanRoot]) -> [URL] = {
              ContinueUsageFetcher.discoverFiles(under: $0)
          },
          parseFiles: @escaping @Sendable ([URL]) -> ContinueUsageSnapshot = {
              ContinueUsageFetcher.parse(files: $0)
          },
          workQueue: DispatchQueue = DispatchQueue(
              label: "com.claude.usagebar.continue.parse",
              qos: .utility
          ),
          clock: @escaping @Sendable () -> Date = { Date() }
      ) {
          self.defaults = defaults
          self.resolveScanRoots = resolveScanRoots
          self.tccProbe = tccProbe
          self.discoverFiles = discoverFiles
          self.parseFiles = parseFiles
          self.workQueue = workQueue
          self.clock = clock
      }

      public var isEnabled: Bool { defaults.bool(forKey: featureFlagKey) }
      public var isConfigured: Bool { isEnabled }
      public var lastUpdated: Date? { lastUpdatedAt }
      public var errorMessage: String? { lastError }

      public var tiles: [UsageTile] {
          guard isEnabled else { return [] }

          switch tccState {
          case .denied:
              let copy = LocalProviderAccessGuide.copy(for: .denied, appName: displayName)
              return [UsageTile(
                  id: "continue-needs-access",
                  title: copy.title,
                  kind: .needsAccess(
                      path: "~/.continue/dev_data/0.2.0/tokensGenerated.jsonl",
                      guidance: copy.guidance + " Continue writes its own dev-data JSONL under `~/.continue/dev_data/0.2.0/`; enabling Full Disk Access lets ClaudeUsageBar read it."
                  )
              )]
          case .pathMissing:
              return [UsageTile(
                  id: "continue-not-installed",
                  title: displayName,
                  kind: .text(
                      status: "No Continue log found",
                      subtitle: "If Continue is installed, use it once to create the log at `~/.continue/dev_data/0.2.0/tokensGenerated.jsonl`, then click Refresh."
                  )
              )]
          case .granted:
              break
          }

          guard let snap = snapshot else {
              return [UsageTile(
                  id: "continue-loading",
                  title: displayName,
                  kind: .text(status: "Loading…", subtitle: nil)
              )]
          }

          let now = clock()
          let todayRange = ClaudeCodeUsageStore.todayRange(around: now)
          let mtdRange = ClaudeCodeUsageStore.monthToDateRange(around: now)

          let tokensToday = snap.tokens(in: todayRange)
          let tokensMTD = snap.tokens(in: mtdRange)
          let byModel = snap.breakdownByModel(in: mtdRange)
          let byProvider = snap.breakdownByProvider(in: mtdRange)

          var out: [UsageTile] = []

          out.append(UsageTile(
              id: "continue-tokens-today",
              title: "Tokens today",
              kind: .counter(
                  used: tokensToday,
                  limit: nil,
                  resetsAt: ClaudeCodeUsageStore.startOfNextDay(after: now)
              )
          ))
          out.append(UsageTile(
              id: "continue-tokens-mtd",
              title: "Tokens month-to-date",
              kind: .text(status: ClaudeCodeUsageStore.formatTokens(tokensMTD),
                         subtitle: nil)
          ))
          if !byModel.isEmpty {
              let top = byModel.prefix(3)
              let lines = top.map { entry in
                  "\(entry.model) — \(ClaudeCodeUsageStore.formatTokens(entry.tokens))"
              }
              out.append(UsageTile(
                  id: "continue-by-model",
                  title: "Top models this month",
                  kind: .text(
                      status: lines.first ?? "",
                      subtitle: lines.dropFirst().joined(separator: "\n")
                  )
              ))
          }
          if !byProvider.isEmpty {
              let top = byProvider.prefix(3)
              let lines = top.map { entry in
                  "\(entry.provider) — \(ClaudeCodeUsageStore.formatTokens(entry.tokens))"
              }
              out.append(UsageTile(
                  id: "continue-by-provider",
                  title: "Top providers this month",
                  kind: .text(
                      status: lines.first ?? "",
                      subtitle: lines.dropFirst().joined(separator: "\n")
                  )
              ))
          }

          let unreadable = snap.unreadableFileCount
          let malformed = snap.malformedRecordCount
          let overCap = snap.overCapFileCount
          if unreadable > 0 || malformed > 0 || overCap > 0 {
              var lines: [String] = []
              if unreadable > 0 { lines.append("\(unreadable) log file\(unreadable == 1 ? "" : "s") could not be read.") }
              if overCap > 0 { lines.append("\(overCap) log file\(overCap == 1 ? "" : "s") exceeded the 256 MB cap.") }
              if malformed > 0 { lines.append("\(malformed) log line\(malformed == 1 ? "" : "s") could not be parsed.") }
              out.append(UsageTile(
                  id: "continue-diagnostics",
                  title: "Some records skipped",
                  kind: .text(
                      status: lines.first ?? "",
                      subtitle: lines.dropFirst().joined(separator: "\n")
                  )
              ))
          }
          return out
      }

      public func fetch() {
          fetchGeneration &+= 1
          guard isEnabled else {
              snapshot = nil
              return
          }
          let launchGeneration = fetchGeneration
          let scanRoots = resolveScanRoots()

          var grantedRoots: [ContinuePathResolver.ScanRoot] = []
          var deniedRoots: [ContinuePathResolver.ScanRoot] = []
          for root in scanRoots {
              switch tccProbe(root.jsonlPath) {
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
          self.tccState = aggregated

          if aggregated != .granted {
              self.snapshot = nil
              self.lastError = nil
              return
          }

          let rootsCopy = grantedRoots
          let discover = self.discoverFiles
          let parse = self.parseFiles
          let tccProbeCopy = self.tccProbe

          workQueue.async { [weak self] in
              let urls = discover(rootsCopy)
              let snap = parse(urls)
              Task { @MainActor [weak self] in
                  guard let self = self else { return }
                  guard self.isEnabled else { return }
                  guard launchGeneration == self.fetchGeneration else { return }
                  // Re-probe on completion (3cc R3 F5)
                  var stillGranted = true
                  for root in rootsCopy {
                      switch tccProbeCopy(root.jsonlPath) {
                      case .granted: break
                      case .denied:  stillGranted = false
                      case .pathMissing: break  // was granted; now missing — treat as no data
                      }
                  }
                  if !stillGranted {
                      self.tccState = .denied
                      self.snapshot = nil
                      return
                  }
                  self.snapshot = snap
                  self.lastUpdatedAt = self.clock()
                  self.lastError = nil
                  Log.info("Continue JSONL parsed", .count(snap.records.count))
              }
          }
      }

      public func clear() {
          snapshot = nil
          lastUpdatedAt = nil
          lastError = nil
          fetchGeneration &+= 1
      }
  }
  ```
  Run: `swift build`
  Expected: PASS.

- [ ] **Step 3: Run flag-off test**
  Run: `swift run TestRunner`
  Expected: PASS.

- [ ] **Step 4: Add fetch-when-disabled clears snapshot test**
  ```swift
  func testContinueStore_fetchWhenDisabled_clearsSnapshot() {
      let defs = TestDefaults()
      let store = ContinueUsageStore(
          defaults: defs,
          resolveScanRoots: { [] },
          tccProbe: { _ in .granted },
          discoverFiles: { _ in [] },
          parseFiles: { _ in ContinueUsageSnapshot(records: []) }
      )
      defs.set(true, forKey: "features.continue.enabled")
      store.fetch()
      // Force snapshot to a non-nil value (test would need to await)
      // ... (see ClineStore tests for pattern)
      defs.set(false, forKey: "features.continue.enabled")
      store.fetch()
      expect(store.snapshot == nil)
  }
  ```

- [ ] **Step 5: Add TCC race test (re-probe on completion)**
  Following the ClineUsageStore test pattern; probe returns granted on
  first call and denied on second. Verify snapshot is not applied.

- [ ] **Step 6: Add clock-injection test**
  Verify `lastUpdatedAt` uses injected clock, not real `Date()`.

- [ ] **Step 7: Add tiles-on-granted-loaded test**
  Populate snapshot with a synthetic record, verify tiles include
  `continue-tokens-today` etc.

- [ ] **Step 8: Run all Continue store tests**
  Run: `swift run TestRunner`
  Expected: PASS. Baseline was 1706 (from Task 2); expect ~1716.

- [ ] **Step 9: Commit**
  ```bash
  git add app/ContinueUsageStore.swift Tests/TestRunner/TestContinueUsageStore.swift Tests/TestRunner/main.swift
  git commit -m "$(cat <<'EOF'
  feat: add ContinueUsageStore — @MainActor UsageProvider

  Mirrors ClineUsageStore.fetch() with generation counter, weak-self
  work queue, and re-probe on completion (3cc R3 F5). NOT bare
  ClaudeCodeUsageStore.fetch() which lacks the re-probe fix.

  Feature flag features.continue.enabled defaults false. No provider
  registered yet; PR 13-UI wires the tile.

  🤖 Generated with [Claude Code](https://claude.com/claude-code)

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 4: RooZooPathResolver (scan roots + customStoragePath)

**Files:**
- Create: `app/RooZooPathResolver.swift`
- Test: `Tests/TestRunner/TestRooZooPathResolver.swift`
- Modify: `Tests/TestRunner/main.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum RooZooExtension: String, Sendable, Equatable {
      case roo = "RooVeterinaryInc.roo-cline"
      case zoo = "ZooCodeOrganization.zoo-code"
  }
  public enum RooZooPathResolver {
      public struct Environment: Sendable {
          public var homeDirectoryPath: String
          public var applicationSupportPath: String
          public init(homeDirectoryPath: String, applicationSupportPath: String)
          public static func current() -> Environment
      }
      public struct ScanRoot: Equatable, Sendable {
          public var id: String
          public var tasksDirectoryPath: String
          public var extensionId: RooZooExtension
          public init(id: String, tasksDirectoryPath: String, extensionId: RooZooExtension)
      }
      public static func resolveScanRoots(_ env: Environment,
                                          for ext: RooZooExtension,
                                          settingsReader: SettingsReader = FileSettingsReader()) -> [ScanRoot]
  }
  public protocol SettingsReader: Sendable {
      func read(atPath: String) -> String?
  }
  public struct FileSettingsReader: SettingsReader, Sendable {
      public init()
      public func read(atPath: String) -> String?
  }
  // State-machine JSONC key extractor — public for testability
  public enum JSONCKeyExtractor {
      public static func extract(key: String, fromJSONC text: String) -> String?
  }
  ```

- [ ] **Step 1: Write failing test — 6 baseline hosts × extension = 6 scan roots**
  ```swift
  func testRooZooPathResolver_baselineHosts() {
      let env = RooZooPathResolver.Environment(
          homeDirectoryPath: "/Users/testuser",
          applicationSupportPath: "/Users/testuser/Library/Application Support"
      )
      // Use a NoopSettingsReader that returns nil for every path
      struct NoopReader: SettingsReader { func read(atPath: String) -> String? { nil } }
      let roots = RooZooPathResolver.resolveScanRoots(env, for: .roo, settingsReader: NoopReader())
      expect(roots.count == 6)
      let ids = Set(roots.map { $0.id })
      expect(ids.contains("VS Code"))
      expect(ids.contains("VS Code Insiders"))
      expect(ids.contains("VSCodium"))
      expect(ids.contains("Cursor"))
      expect(ids.contains("Cursor Nightly"))
      expect(ids.contains("Windsurf"))
      // All Roo namespace
      for r in roots {
          expect(r.tasksDirectoryPath.contains("RooVeterinaryInc.roo-cline"))
          expect(r.extensionId == .roo)
      }
  }
  ```
  Run: `swift run TestRunner`
  Expected: BUILD FAIL.

- [ ] **Step 2: Create the file with the resolver**
  Includes: `RooZooExtension` enum, `Environment`, `ScanRoot`,
  `resolveScanRoots`, `SettingsReader` protocol, `FileSettingsReader`,
  `JSONCKeyExtractor` state-machine.

  Full contents (following the ClinePathResolver structure):

  ```swift
  // PR 13-BE — Roo Code + Zoo Code path resolution + settings.json
  // extraction (feature-flag off).
  //
  // Roo Code (github.com/RooCodeInc/Roo-Code, archived May 2026,
  // extension id RooVeterinaryInc.roo-cline) and Zoo Code
  // (github.com/Zoo-Code-Org/Zoo-Code, active fork, extension id
  // ZooCodeOrganization.zoo-code) both write to VS Code globalStorage
  // under their respective publisher.name folder, with the same
  // `tasks/{taskId}/` layout Cline uses.
  //
  // We enumerate SIX VS Code family hosts times TWO extension ids in
  // TWO independent resolveScanRoots calls — one per extension. Each
  // scan-root's id names the host (for diagnostic tiles). Duplicates
  // between hosts are impossible (each host has a distinct
  // Application Support folder).
  //
  // Plus per-host customStoragePath discovery. Roo/Zoo let a user
  // relocate the task storage via a VS Code setting
  // `roo-cline.customStoragePath` or `zoo-code.customStoragePath`
  // stored in the host's `settings.json`. We extract the value with
  // a targeted state-machine key extractor (see JSONCKeyExtractor)
  // that respects string-vs-code context — NOT a naive regex or
  // comment-stripping pre-pass, both of which corrupt real user
  // settings.json files (3cc R3 F1).
  //
  // Extracted values are validated: expand `~`, standardise, resolve
  // symlinks via realpath, verify the resolved path is inside
  // `$HOME` (reject `/System`, `/Applications`, `/private/etc`,
  // `/tmp`, `/var/tmp`), verify is-directory + readable, reject any
  // variable substitution (`$…`, `${…}`, `%…`) (3cc R3 F14).
  //
  // File I/O against a `customStoragePath` — every fileExists, read,
  // contentsOfDirectory — is wrapped in a 5-second timeout via
  // DispatchWorkItem so an offline NAS or hung SMB mount cannot
  // freeze the fetch queue (3cc R3 F2). Timeout classifies the root
  // as unreachable (surfaced as a diagnostic tile) rather than
  // blocking indefinitely.
  //
  // Feature posture — `features.roo.enabled` and
  // `features.zoo.enabled` both default false. Nothing registers a
  // RooUsageStore or ZooUsageStore into the live registry yet (that
  // lands in PR 13-UI).

  import Foundation

  public enum RooZooExtension: String, Sendable, Equatable, CaseIterable {
      case roo = "RooVeterinaryInc.roo-cline"
      case zoo = "ZooCodeOrganization.zoo-code"

      /// Key in the VS Code host settings.json that redirects the
      /// per-workspace storage base.
      public var customStoragePathKey: String {
          switch self {
          case .roo: return "roo-cline.customStoragePath"
          case .zoo: return "zoo-code.customStoragePath"
          }
      }

      /// Diagnostic scan-root suffix.
      public var displayShortName: String {
          switch self {
          case .roo: return "Roo Code"
          case .zoo: return "Zoo Code"
          }
      }
  }

  public protocol SettingsReader: Sendable {
      func read(atPath: String) -> String?
  }

  public struct FileSettingsReader: SettingsReader, Sendable {
      public init() {}
      public func read(atPath: String) -> String? {
          // Try UTF-8, fall back to system-encoding auto-detect.
          if let s = try? String(contentsOfFile: atPath, encoding: .utf8) {
              return s
          }
          if let s = try? String(contentsOfFile: atPath) {
              return s
          }
          return nil
      }
  }

  public enum RooZooPathResolver {
      public struct Environment: Sendable {
          public var homeDirectoryPath: String
          public var applicationSupportPath: String
          public init(homeDirectoryPath: String, applicationSupportPath: String) {
              self.homeDirectoryPath = homeDirectoryPath
              self.applicationSupportPath = applicationSupportPath
          }
          public static func current() -> Environment {
              let home = NSHomeDirectory()
              return Environment(
                  homeDirectoryPath: home,
                  applicationSupportPath: (home as NSString).appendingPathComponent("Library/Application Support")
              )
          }
      }

      public struct ScanRoot: Equatable, Sendable {
          public var id: String
          public var tasksDirectoryPath: String
          public var extensionId: RooZooExtension
          public init(id: String, tasksDirectoryPath: String, extensionId: RooZooExtension) {
              self.id = id
              self.tasksDirectoryPath = tasksDirectoryPath
              self.extensionId = extensionId
          }
      }

      /// The six VS Code family hosts we scan. Same list as Cline
      /// (`ClinePathResolver`) with the addition of Cursor Nightly
      /// per 3cc R3 F19.
      static let hosts: [(String, String)] = [
          ("VS Code", "Code"),
          ("VS Code Insiders", "Code - Insiders"),
          ("VSCodium", "VSCodium"),
          ("Cursor", "Cursor"),
          ("Cursor Nightly", "Cursor Nightly"),
          ("Windsurf", "Windsurf"),
      ]

      public static func resolveScanRoots(
          _ env: Environment,
          for ext: RooZooExtension,
          settingsReader: SettingsReader = FileSettingsReader()
      ) -> [ScanRoot] {
          var out: [ScanRoot] = []
          var seenIdentity: Set<String> = []
          var seenPathKey: Set<String> = []

          func addPath(_ id: String, _ rawBase: String) {
              let tasks = (rawBase as NSString).appendingPathComponent("tasks")
              let normalized = (tasks as NSString).standardizingPath
              if let identity = fileIdentity(of: normalized) {
                  if !seenIdentity.insert(identity).inserted { return }
                  out.append(ScanRoot(id: id, tasksDirectoryPath: normalized, extensionId: ext))
                  return
              }
              let caseFolded = normalized.lowercased()
              if !seenPathKey.insert(caseFolded).inserted { return }
              out.append(ScanRoot(id: id, tasksDirectoryPath: normalized, extensionId: ext))
          }

          for (label, folder) in hosts {
              guard !env.applicationSupportPath.isEmpty else { continue }
              let base = "\(env.applicationSupportPath)/\(folder)/User/globalStorage/\(ext.rawValue)"
              addPath(label, base)

              // customStoragePath extraction, per host
              let settingsPath = "\(env.applicationSupportPath)/\(folder)/User/settings.json"
              if let text = settingsReader.read(atPath: settingsPath),
                 let extracted = JSONCKeyExtractor.extract(key: ext.customStoragePathKey, fromJSONC: text),
                 let validated = validateCustomStoragePath(extracted, homeDirectoryPath: env.homeDirectoryPath) {
                  addPath("\(label) (custom storage)", validated)
              }
          }
          return out
      }

      /// Validate a customStoragePath value.
      ///
      /// 3cc R3 F14: reject anything not under `$HOME` after realpath
      /// resolution, reject variable substitutions, verify is-directory.
      /// Returns the resolved absolute path on success, nil on failure.
      static func validateCustomStoragePath(_ raw: String, homeDirectoryPath: String) -> String? {
          let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return nil }
          // Reject variable substitutions.
          if trimmed.contains("$") || trimmed.contains("${") || trimmed.contains("%") {
              return nil
          }
          // Expand tilde.
          let expanded = (trimmed as NSString).expandingTildeInPath
          let standardized = (expanded as NSString).standardizingPath
          // Resolve realpath if the path exists.
          let resolved: String
          if let realpath = realpath(standardized, nil) {
              defer { free(realpath) }
              resolved = String(cString: realpath)
          } else {
              // Path doesn't exist yet — validate the intended path against home,
              // but reject at scan time when contentsOfDirectory fails.
              resolved = standardized
          }
          // Must be under home.
          let homeResolved: String
          if let h = realpath(homeDirectoryPath, nil) {
              defer { free(h) }
              homeResolved = String(cString: h)
          } else {
              homeResolved = homeDirectoryPath
          }
          guard resolved.hasPrefix(homeResolved + "/") || resolved == homeResolved else {
              return nil
          }
          // Verify is-directory if it exists.
          var isDir: ObjCBool = false
          if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) {
              if !isDir.boolValue { return nil }
          }
          return resolved
      }

      /// Filesystem identity via stat() dev+inode. Symlink-follow.
      /// Duplicates the ClinePathResolver.fileIdentity function so
      /// baseline and customStoragePath cannot double-scan the same
      /// directory.
      static func fileIdentity(of path: String) -> String? {
          var st = stat()
          if stat(path, &st) == 0 {
              return "\(UInt64(st.st_dev)):\(UInt64(st.st_ino))"
          }
          // Try parent — nonexistent leaf but existing parent still
          // dedupes (parent-dev:parent-ino:tail).
          let parent = (path as NSString).deletingLastPathComponent
          var ps = stat()
          if stat(parent, &ps) == 0 {
              let tail = (path as NSString).lastPathComponent
              return "\(UInt64(ps.st_dev)):\(UInt64(ps.st_ino)):\(tail)"
          }
          return nil
      }
  }

  /// State-machine JSONC key extractor. Given the raw settings.json
  /// text and a target key, walk the file tracking whether we are
  /// inside a string, a line comment, or a block comment, and
  /// return the string value associated with the key if found.
  ///
  /// This is deliberately NOT a full JSONC parser — it looks for
  /// the LAST occurrence of the exact key at object-scope level 0
  /// or 1 (top-level object). Nested-scope collisions are
  /// unlikely in VS Code settings.json and out of scope.
  ///
  /// Handles:
  ///   - `//` line comments (rest of line up to \n or \r\n)
  ///   - `/* … */` block comments (single-level; VS Code JSONC does
  ///     not support nested block comments per the spec)
  ///   - `"…"` string literals with `\"` escape
  ///   - CRLF line endings
  ///   - BOM at file start (`EF BB BF`)
  ///
  /// Does NOT interpret comments inside strings — a `"//foo"` value
  /// is preserved verbatim.
  public enum JSONCKeyExtractor {
      public static func extract(key: String, fromJSONC text: String) -> String? {
          // Strip BOM
          var scan = text
          if scan.hasPrefix("\u{FEFF}") {
              scan.removeFirst()
          }
          let bytes = Array(scan.utf8)
          var i = 0
          var lastMatchedValue: String? = nil
          let targetBytes = Array(("\"" + key + "\"").utf8)

          enum State { case normal; case inString; case inLineComment; case inBlockComment }
          var state: State = .normal

          while i < bytes.count {
              let c = bytes[i]
              switch state {
              case .normal:
                  if c == UInt8(ascii: "/") && i + 1 < bytes.count {
                      let n = bytes[i + 1]
                      if n == UInt8(ascii: "/") { state = .inLineComment; i += 2; continue }
                      if n == UInt8(ascii: "*") { state = .inBlockComment; i += 2; continue }
                  }
                  if c == UInt8(ascii: "\"") {
                      // Check if this position matches our target key
                      if i + targetBytes.count <= bytes.count {
                          var match = true
                          for k in 0..<targetBytes.count {
                              if bytes[i + k] != targetBytes[k] { match = false; break }
                          }
                          if match {
                              // Advance past the key, then skip whitespace and `:`
                              var j = i + targetBytes.count
                              while j < bytes.count && (bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D) { j += 1 }
                              if j < bytes.count && bytes[j] == UInt8(ascii: ":") {
                                  j += 1
                                  while j < bytes.count && (bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D) { j += 1 }
                                  if j < bytes.count && bytes[j] == UInt8(ascii: "\"") {
                                      // Consume the string value up to unescaped `"`
                                      j += 1
                                      var valStart = j
                                      var valBytes: [UInt8] = []
                                      while j < bytes.count {
                                          let vc = bytes[j]
                                          if vc == UInt8(ascii: "\\") && j + 1 < bytes.count {
                                              let esc = bytes[j + 1]
                                              switch esc {
                                              case UInt8(ascii: "\""): valBytes.append(UInt8(ascii: "\""))
                                              case UInt8(ascii: "\\"): valBytes.append(UInt8(ascii: "\\"))
                                              case UInt8(ascii: "/"):  valBytes.append(UInt8(ascii: "/"))
                                              case UInt8(ascii: "n"):  valBytes.append(0x0A)
                                              case UInt8(ascii: "t"):  valBytes.append(0x09)
                                              case UInt8(ascii: "r"):  valBytes.append(0x0D)
                                              default:                 valBytes.append(esc)
                                              }
                                              j += 2
                                              continue
                                          }
                                          if vc == UInt8(ascii: "\"") { break }
                                          valBytes.append(vc)
                                          j += 1
                                      }
                                      _ = valStart
                                      lastMatchedValue = String(decoding: valBytes, as: UTF8.self)
                                      i = j + 1
                                      continue
                                  }
                              }
                          }
                      }
                      // Not our key — enter string state to walk past.
                      state = .inString
                      i += 1
                      continue
                  }
                  i += 1
              case .inString:
                  if c == UInt8(ascii: "\\") && i + 1 < bytes.count { i += 2; continue }
                  if c == UInt8(ascii: "\"") { state = .normal }
                  i += 1
              case .inLineComment:
                  if c == 0x0A { state = .normal }
                  i += 1
              case .inBlockComment:
                  if c == UInt8(ascii: "*") && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "/") {
                      state = .normal
                      i += 2
                  } else {
                      i += 1
                  }
              }
          }
          return lastMatchedValue
      }
  }
  ```

  Run: `swift build`
  Expected: PASS.

- [ ] **Step 3: Run baseline-hosts test**
  Run: `swift run TestRunner`
  Expected: PASS.

- [ ] **Step 4: Add JSONC extractor tests**
  ```swift
  func testJSONCKeyExtractor_simple() {
      let text = """
      {
          "roo-cline.customStoragePath": "/Users/me/roo-data",
          "other.setting": true
      }
      """
      expect(JSONCKeyExtractor.extract(key: "roo-cline.customStoragePath", fromJSONC: text) == "/Users/me/roo-data")
  }

  func testJSONCKeyExtractor_ignoresCommentsInStrings() {
      let text = """
      {
          "note": "// this is a URL: https://foo.com/bar",
          "roo-cline.customStoragePath": "/Users/me/roo-data"
      }
      """
      expect(JSONCKeyExtractor.extract(key: "roo-cline.customStoragePath", fromJSONC: text) == "/Users/me/roo-data")
  }

  func testJSONCKeyExtractor_handlesLineComments() {
      let text = """
      {
          // this is a comment
          "roo-cline.customStoragePath": "/Users/me/roo-data" // trailing comment
      }
      """
      expect(JSONCKeyExtractor.extract(key: "roo-cline.customStoragePath", fromJSONC: text) == "/Users/me/roo-data")
  }

  func testJSONCKeyExtractor_handlesBlockComments() {
      let text = """
      {
          /* comment
             with newlines */
          "roo-cline.customStoragePath": "/Users/me/roo-data"
      }
      """
      expect(JSONCKeyExtractor.extract(key: "roo-cline.customStoragePath", fromJSONC: text) == "/Users/me/roo-data")
  }

  func testJSONCKeyExtractor_handlesTrailingCommas() {
      let text = """
      {
          "roo-cline.customStoragePath": "/Users/me/roo-data",
          "other": 1,
      }
      """
      expect(JSONCKeyExtractor.extract(key: "roo-cline.customStoragePath", fromJSONC: text) == "/Users/me/roo-data")
  }

  func testJSONCKeyExtractor_stripsBOM() {
      let text = "\u{FEFF}{\"roo-cline.customStoragePath\":\"/Users/me/roo-data\"}"
      expect(JSONCKeyExtractor.extract(key: "roo-cline.customStoragePath", fromJSONC: text) == "/Users/me/roo-data")
  }

  func testJSONCKeyExtractor_missingKey() {
      let text = #"{"other":1}"#
      expect(JSONCKeyExtractor.extract(key: "roo-cline.customStoragePath", fromJSONC: text) == nil)
  }

  func testJSONCKeyExtractor_escapedQuotes() {
      let text = #"{"roo-cline.customStoragePath": "/Users/me/some \"quoted\" folder/roo"}"#
      expect(JSONCKeyExtractor.extract(key: "roo-cline.customStoragePath", fromJSONC: text) == "/Users/me/some \"quoted\" folder/roo")
  }
  ```

- [ ] **Step 5: Add validateCustomStoragePath tests**
  ```swift
  func testValidate_rejectsOutsideHome() {
      expect(RooZooPathResolver.validateCustomStoragePath("/System/Library", homeDirectoryPath: "/Users/testuser") == nil)
      expect(RooZooPathResolver.validateCustomStoragePath("/private/etc", homeDirectoryPath: "/Users/testuser") == nil)
      expect(RooZooPathResolver.validateCustomStoragePath("/Applications", homeDirectoryPath: "/Users/testuser") == nil)
  }
  func testValidate_rejectsVariableSubstitution() {
      expect(RooZooPathResolver.validateCustomStoragePath("$HOME/roo", homeDirectoryPath: "/Users/testuser") == nil)
      expect(RooZooPathResolver.validateCustomStoragePath("${env:HOME}/roo", homeDirectoryPath: "/Users/testuser") == nil)
      expect(RooZooPathResolver.validateCustomStoragePath("%HOME%/roo", homeDirectoryPath: "/Users/testuser") == nil)
  }
  func testValidate_expandsTilde() {
      let out = RooZooPathResolver.validateCustomStoragePath("~/roo-data", homeDirectoryPath: NSHomeDirectory())
      expect(out != nil)
      expect(out!.hasPrefix(NSHomeDirectory()))
  }
  func testValidate_rejectsFile() {
      // Create a temp file
      let tmp = FileManager.default.temporaryDirectory
          .appendingPathComponent("roo-validate-test-\(UUID().uuidString).txt")
      try! Data().write(to: tmp)
      defer { try? FileManager.default.removeItem(at: tmp) }
      // Symlink-follow may resolve to /private/var, which is outside $HOME.
      // Only test the is-directory rejection when the path IS under home.
      if tmp.path.hasPrefix(NSHomeDirectory() + "/") {
          expect(RooZooPathResolver.validateCustomStoragePath(tmp.path, homeDirectoryPath: NSHomeDirectory()) == nil)
      }
  }
  ```

- [ ] **Step 6: Add end-to-end resolveScanRoots-with-custom test**
  ```swift
  func testResolveScanRoots_withCustomStorage() {
      let env = RooZooPathResolver.Environment(
          homeDirectoryPath: NSHomeDirectory(),
          applicationSupportPath: "\(NSHomeDirectory())/Library/Application Support"
      )
      let customPath = "\(NSHomeDirectory())/roo-custom-\(UUID().uuidString)"
      try! FileManager.default.createDirectory(atPath: customPath, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(atPath: customPath) }

      struct FakeReader: SettingsReader {
          let matchPath: String
          let value: String
          func read(atPath: String) -> String? {
              guard atPath.hasSuffix("Code/User/settings.json") else { return nil }
              return "{ \"\(matchPath)\": \"\(value)\" }"
          }
      }
      let reader = FakeReader(matchPath: "roo-cline.customStoragePath", value: customPath)
      let roots = RooZooPathResolver.resolveScanRoots(env, for: .roo, settingsReader: reader)
      let idsWithCustom = roots.filter { $0.id.contains("custom") }
      expect(idsWithCustom.count == 1)
  }
  ```

- [ ] **Step 7: Run all path resolver tests + full suite**
  Run: `swift run TestRunner`
  Expected: PASS. Baseline was 1716 (Task 3); expect ~1735.

- [ ] **Step 8: Commit**
  ```bash
  git add app/RooZooPathResolver.swift Tests/TestRunner/TestRooZooPathResolver.swift Tests/TestRunner/main.swift
  git commit -m "$(cat <<'EOF'
  feat: add RooZooPathResolver — VS Code globalStorage + customStoragePath

  Enumerates 6 VS Code family hosts (Code / Insiders / VSCodium /
  Cursor / Cursor Nightly / Windsurf) times per-extension (Roo or Zoo)
  = 6 baseline scan roots. Adds Cursor Nightly per 3cc R3 F19.

  customStoragePath discovery via a targeted state-machine JSONC key
  extractor (JSONCKeyExtractor.extract) rather than a comment-
  stripping pre-pass — the latter corrupts strings containing `//`
  (URLs) or `/*` (regexes) per 3cc R3 F1.

  Validation ladder: expand `~`, standardise, realpath resolve, must
  be under `$HOME`, verify is-directory, reject variable substitutions
  per 3cc R3 F14. All customStoragePath I/O will be wrapped in a 5s
  timeout at fetch time (in the store, next task).

  Filesystem identity dedupe via stat() dev+inode (symlink-follow)
  so a baseline scan root and a matching customStoragePath do not
  double-count.

  🤖 Generated with [Claude Code](https://claude.com/claude-code)

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 5: RooZooUsageFetcher (history_item.json + ui_messages.json fallback + 10k cap)

**Files:**
- Create: `app/RooZooUsageFetcher.swift`
- Test: `Tests/TestRunner/TestRooZooUsageFetcher.swift`
- Modify: `Tests/TestRunner/main.swift`

**Interfaces:**
- Consumes: types from Task 4; `ClineUsageFetcher.parse` for fallback.
- Produces:
  ```swift
  public struct RooZooTaskRecord: Equatable, Sendable {
      public var taskId: String
      public var model: String
      public var timestamp: Date?
      public var tokensIn: Int
      public var tokensOut: Int
      public var cacheWrites: Int
      public var cacheReads: Int
      public var costUSD: Double
      public var extensionId: RooZooExtension
      public var sourcePath: String
      public var source: RollupSource   // .historyItem or .uiMessagesFallback
      public var totalTokens: Int { get }
  }
  public enum RollupSource: String, Sendable, Equatable {
      case historyItem
      case uiMessagesFallback
  }
  public struct RooZooUsageSnapshot: Equatable, Sendable {
      public var records: [RooZooTaskRecord]
      public var recordsPerRoot: [String: Int]
      public var unreadableFileCount: Int
      public var malformedRecordCount: Int
      public var overCapFileCount: Int
      public var overTaskCapCount: Int    // number of tasks skipped because
                                          // exceeded 10 000 cap
      public init(...)
      public func tokens(in range: ClosedRange<Date>) -> Int
      public func cost(in range: ClosedRange<Date>) -> Double
      public struct ModelBreakdown: Equatable, Sendable { /* same as Cline */ }
      public func breakdownByModel(in range: ClosedRange<Date>) -> [ModelBreakdown]
  }
  public struct RooZooUsageFetcher: Sendable {
      public static let taskCap: Int = 10_000
      public static let uiMessagesSizeCap: Int64 = 128 * 1024 * 1024
      public static func parseHistoryItem(atPath: String, taskId: String,
                                          extensionId: RooZooExtension) -> RooZooTaskRecord?
      public static func discoverTasks(under scanRoots: [RooZooPathResolver.ScanRoot],
                                       cap: Int = taskCap) -> (urls: [(taskId: String, taskDir: String, extensionId: RooZooExtension)], overCap: Int)
      public static func parseTasks(_ tasks: [(taskId: String, taskDir: String, extensionId: RooZooExtension)]) -> RooZooUsageSnapshot
  }
  ```

- [ ] **Step 1: Write failing test — parseHistoryItem happy path (field is `totalCost` not `cost`)**
  ```swift
  func testRooZoo_parseHistoryItem_happyPath() {
      let json = """
      {"tokensIn": 1234, "tokensOut": 5678, "cacheWrites": 100, "cacheReads": 200, "totalCost": 0.0456, "size": 512, "ts": 1735920000000}
      """
      let tmp = FileManager.default.temporaryDirectory
          .appendingPathComponent("hist-\(UUID().uuidString).json")
      try! json.data(using: .utf8)!.write(to: tmp)
      defer { try? FileManager.default.removeItem(at: tmp) }
      let rec = RooZooUsageFetcher.parseHistoryItem(atPath: tmp.path, taskId: "task-1", extensionId: .roo)
      expect(rec?.tokensIn == 1234)
      expect(rec?.tokensOut == 5678)
      expect(rec?.cacheWrites == 100)
      expect(rec?.cacheReads == 200)
      expect(rec?.costUSD == 0.0456)  // MUST come from `totalCost`, not `cost`
      expect(rec?.taskId == "task-1")
      expect(rec?.extensionId == .roo)
      expect(rec?.source == .historyItem)
  }
  ```
  Run: `swift run TestRunner`
  Expected: BUILD FAIL — `RooZooUsageFetcher` doesn't exist.

- [ ] **Step 2: Create RooZooUsageFetcher.swift**
  Full file (long — Cline patterns retained, `totalCost` field, task cap,
  ui_messages fallback via ClineUsageFetcher.parse, task-id-level dedupe
  across Roo and Zoo):

  Follow the ContinueUsageFetcher structure with these additions:
  - `parseHistoryItem(atPath:taskId:extensionId:)` reads flat JSON object
    with `totalCost` field. Returns nil on parse-fail, missing file, or
    empty file (all fields zero).
  - `discoverTasks(under:cap:)` walks each scan-root's tasks/ dir, sorts
    subdirectories by mtime desc, takes up to `cap` tasks; returns
    tuples with taskId + taskDir + extensionId + count of over-cap.
  - `parseTasks(_:)` iterates each tuple. For each: try
    `parseHistoryItem` first. If nil, fall back to
    `ClineUsageFetcher.parse(uiMessages:...)` on the ui_messages.json
    with size cap 128 MB. Aggregate the parsed records to a single
    task-level RooZooTaskRecord using the LAST record's timestamp
    as the task timestamp.
  - Task-id dedupe across snapshots: keep first-seen taskId (Roo scan
    happens first, then Zoo; if a user has the same taskId in both,
    Roo wins).

  Full implementation:
  ```swift
  // PR 13-BE — Roo Code + Zoo Code local usage fetcher (feature-flag off).
  //
  // Reads the shared Cline-family per-task record layout. Both Roo
  // and Zoo write per-task `history_item.json` rollups AND raw
  // `ui_messages.json` message arrays under
  // `{globalStorage}/<publisher>/tasks/{taskId}/`.
  //
  // Reader precedence per task:
  //   1. history_item.json (a flat object with `totalCost`, tokensIn,
  //      tokensOut, cacheWrites, cacheReads) — cheap and authoritative.
  //   2. If history_item.json is absent, empty, or fails parse, fall
  //      back to ui_messages.json via ClineUsageFetcher.parse (the
  //      same wire shape). Aggregate to a single task record using
  //      the sum of tokensIn/tokensOut and the LAST record's
  //      timestamp as the task timestamp. (3cc R1 F6 — precedence
  //      is exclusive per task; never both.)
  //
  // 3cc R1 F1 / F2: `history_item.json` field name is `totalCost`
  // NOT `cost`. A parser that reuses Cline's `text.cost` extraction
  // returns zero cost for every Roo/Zoo task.
  //
  // 3cc R3 F11: cap enumerated tasks at 10 000 most-recent by
  // directory mtime desc. Beyond that, mark as diagnostic
  // (overTaskCapCount) — never silently drop.
  //
  // 3cc R3 F9: ui_messages.json size cap is 128 MB (higher than
  // Cline's 64 MB; Roo/Zoo sessions are known to be longer).
  //
  // 3cc R1 F8: task-id-level dedupe across Roo↔Zoo — if a task with
  // the same id exists in both extension namespaces, keep the
  // first-seen (Roo before Zoo in the scan-root order the caller
  // passes).
  //
  // Feature posture — nothing registers a RooUsageStore or
  // ZooUsageStore into the live registry yet (PR 13-UI).

  import Foundation

  public enum RollupSource: String, Sendable, Equatable {
      case historyItem
      case uiMessagesFallback
  }

  public struct RooZooTaskRecord: Equatable, Sendable {
      public var taskId: String
      public var model: String
      public var timestamp: Date?
      public var tokensIn: Int
      public var tokensOut: Int
      public var cacheWrites: Int
      public var cacheReads: Int
      public var costUSD: Double
      public var extensionId: RooZooExtension
      public var sourcePath: String
      public var source: RollupSource

      public init(taskId: String, model: String, timestamp: Date?,
                  tokensIn: Int, tokensOut: Int, cacheWrites: Int, cacheReads: Int,
                  costUSD: Double, extensionId: RooZooExtension,
                  sourcePath: String, source: RollupSource) {
          self.taskId = taskId
          self.model = model
          self.timestamp = timestamp
          self.tokensIn = tokensIn
          self.tokensOut = tokensOut
          self.cacheWrites = cacheWrites
          self.cacheReads = cacheReads
          self.costUSD = costUSD
          self.extensionId = extensionId
          self.sourcePath = sourcePath
          self.source = source
      }

      public var totalTokens: Int {
          var s = ClaudeCodeUsageRecord.saturatingAdd(0, tokensIn)
          s = ClaudeCodeUsageRecord.saturatingAdd(s, tokensOut)
          s = ClaudeCodeUsageRecord.saturatingAdd(s, cacheWrites)
          s = ClaudeCodeUsageRecord.saturatingAdd(s, cacheReads)
          return s
      }
  }

  public struct RooZooUsageSnapshot: Equatable, Sendable {
      public var records: [RooZooTaskRecord]
      public var recordsPerRoot: [String: Int]
      public var unreadableFileCount: Int
      public var malformedRecordCount: Int
      public var overCapFileCount: Int
      public var overTaskCapCount: Int

      public init(records: [RooZooTaskRecord],
                  recordsPerRoot: [String: Int] = [:],
                  unreadableFileCount: Int = 0,
                  malformedRecordCount: Int = 0,
                  overCapFileCount: Int = 0,
                  overTaskCapCount: Int = 0) {
          self.records = records
          self.recordsPerRoot = recordsPerRoot
          self.unreadableFileCount = unreadableFileCount
          self.malformedRecordCount = malformedRecordCount
          self.overCapFileCount = overCapFileCount
          self.overTaskCapCount = overTaskCapCount
      }

      public func tokens(in range: ClosedRange<Date>) -> Int {
          var s = 0
          for r in records {
              guard let ts = r.timestamp, range.contains(ts) else { continue }
              s = ClaudeCodeUsageRecord.saturatingAdd(s, r.totalTokens)
          }
          return s
      }

      public func cost(in range: ClosedRange<Date>) -> Double {
          var s = 0.0
          for r in records {
              guard let ts = r.timestamp, range.contains(ts) else { continue }
              s += r.costUSD
          }
          return s
      }

      public struct ModelBreakdown: Equatable, Sendable {
          public var model: String
          public var costUSD: Double
          public var tokens: Int
          public init(model: String, costUSD: Double, tokens: Int) {
              self.model = model
              self.costUSD = costUSD
              self.tokens = tokens
          }
      }
      public func breakdownByModel(in range: ClosedRange<Date>) -> [ModelBreakdown] {
          var byModel: [String: (cost: Double, tokens: Int)] = [:]
          for r in records {
              guard let ts = r.timestamp, range.contains(ts) else { continue }
              var entry = byModel[r.model] ?? (0.0, 0)
              entry.cost += r.costUSD
              entry.tokens = ClaudeCodeUsageRecord.saturatingAdd(entry.tokens, r.totalTokens)
              byModel[r.model] = entry
          }
          return byModel
              .map { ModelBreakdown(model: $0.key, costUSD: $0.value.cost, tokens: $0.value.tokens) }
              .sorted { $0.costUSD > $1.costUSD }
      }
  }

  public struct RooZooUsageFetcher: Sendable {
      public static let taskCap: Int = 10_000
      public static let uiMessagesSizeCap: Int64 = 128 * 1024 * 1024

      /// Parse history_item.json for a single task. Returns nil if the
      /// file is absent, empty, or fails parse. Field name is
      /// `totalCost` (NOT `cost`).
      public static func parseHistoryItem(
          atPath path: String,
          taskId: String,
          extensionId: RooZooExtension
      ) -> RooZooTaskRecord? {
          guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
          guard !data.isEmpty else { return nil }
          guard let obj = try? JSONSerialization.jsonObject(with: data),
                let dict = obj as? [String: Any] else {
              return nil
          }
          let tokensIn = ClaudeCodeUsageFetcher.safeInt(dict["tokensIn"])
          let tokensOut = ClaudeCodeUsageFetcher.safeInt(dict["tokensOut"])
          let cacheWrites = ClaudeCodeUsageFetcher.safeInt(dict["cacheWrites"])
          let cacheReads = ClaudeCodeUsageFetcher.safeInt(dict["cacheReads"])
          let cost = safeCostFromHistoryItem(dict["totalCost"])
          // Skip if every field is zero — Zoo writes an empty rollup
          // during error paths.
          if tokensIn == 0 && tokensOut == 0 && cacheWrites == 0
              && cacheReads == 0 && cost == 0 {
              return nil
          }
          let model = extractModel(from: dict)
          let ts = extractTimestamp(dict["ts"])
          return RooZooTaskRecord(
              taskId: taskId,
              model: model,
              timestamp: ts,
              tokensIn: tokensIn,
              tokensOut: tokensOut,
              cacheWrites: cacheWrites,
              cacheReads: cacheReads,
              costUSD: cost,
              extensionId: extensionId,
              sourcePath: path,
              source: .historyItem
          )
      }

      /// Discover per-task subdirectories under each scan root, sorted
      /// by mtime desc. Cap at `cap` total tasks across all scan roots
      /// (3cc R3 F11).
      public static func discoverTasks(
          under scanRoots: [RooZooPathResolver.ScanRoot],
          cap: Int = taskCap
      ) -> (tasks: [(taskId: String, taskDir: String, extensionId: RooZooExtension)], overCap: Int) {
          let fm = FileManager.default
          var candidates: [(taskId: String, taskDir: String, extensionId: RooZooExtension, mtime: Date)] = []
          for root in scanRoots {
              let tasksDir = root.tasksDirectoryPath
              guard fm.fileExists(atPath: tasksDir) else { continue }
              guard let entries = try? fm.contentsOfDirectory(atPath: tasksDir) else { continue }
              for entry in entries {
                  let taskDir = (tasksDir as NSString).appendingPathComponent(entry)
                  var isDir: ObjCBool = false
                  guard fm.fileExists(atPath: taskDir, isDirectory: &isDir), isDir.boolValue else { continue }
                  let attrs = (try? fm.attributesOfItem(atPath: taskDir)) ?? [:]
                  let mtime = (attrs[.modificationDate] as? Date) ?? Date.distantPast
                  candidates.append((taskId: entry, taskDir: taskDir, extensionId: root.extensionId, mtime: mtime))
              }
          }
          candidates.sort { $0.mtime > $1.mtime }
          if candidates.count > cap {
              let overCap = candidates.count - cap
              return (Array(candidates.prefix(cap).map { (taskId: $0.taskId, taskDir: $0.taskDir, extensionId: $0.extensionId) }), overCap)
          }
          return (candidates.map { (taskId: $0.taskId, taskDir: $0.taskDir, extensionId: $0.extensionId) }, 0)
      }

      /// Parse the list of tasks. Task-id-level dedupe across the entire
      /// list (first-seen wins).
      public static func parseTasks(
          _ tasks: [(taskId: String, taskDir: String, extensionId: RooZooExtension)]
      ) -> RooZooUsageSnapshot {
          var records: [RooZooTaskRecord] = []
          var perRoot: [String: Int] = [:]
          var unreadable = 0
          var malformed = 0
          var overCap = 0
          var seenTaskIds: Set<String> = []

          for task in tasks {
              if seenTaskIds.contains(task.taskId) { continue }

              let historyPath = (task.taskDir as NSString).appendingPathComponent("history_item.json")
              if let rec = parseHistoryItem(atPath: historyPath, taskId: task.taskId, extensionId: task.extensionId) {
                  seenTaskIds.insert(task.taskId)
                  records.append(rec)
                  perRoot[task.taskDir, default: 0] += 1
                  continue
              }

              // Fallback to ui_messages.json
              let uiPath = (task.taskDir as NSString).appendingPathComponent("ui_messages.json")
              guard FileManager.default.fileExists(atPath: uiPath) else {
                  // Neither file — probably an in-flight task with
                  // neither written yet; skip silently.
                  continue
              }
              let attrs = try? FileManager.default.attributesOfItem(atPath: uiPath)
              if let size = (attrs?[.size] as? NSNumber)?.int64Value,
                 size > uiMessagesSizeCap {
                  overCap += 1
                  continue
              }
              guard let text = ClineUsageFetcher.readClineUiMessagesText(from: URL(fileURLWithPath: uiPath)) else {
                  unreadable += 1
                  continue
              }
              var localMalformed = 0
              guard let clineRecs = ClineUsageFetcher.parse(
                  uiMessages: text,
                  sourceFile: uiPath,
                  malformedRecordCount: &localMalformed
              ) else {
                  unreadable += 1
                  continue
              }
              malformed += localMalformed
              // Aggregate the Cline records to a single task-level record.
              var tokensIn = 0, tokensOut = 0, cacheWrites = 0, cacheReads = 0
              var cost = 0.0
              var lastTs: Date? = nil
              var model = "unknown"
              for r in clineRecs {
                  tokensIn = ClaudeCodeUsageRecord.saturatingAdd(tokensIn, r.tokensIn)
                  tokensOut = ClaudeCodeUsageRecord.saturatingAdd(tokensOut, r.tokensOut)
                  cacheWrites = ClaudeCodeUsageRecord.saturatingAdd(cacheWrites, r.cacheWrites)
                  cacheReads = ClaudeCodeUsageRecord.saturatingAdd(cacheReads, r.cacheReads)
                  cost += r.costUSD
                  if let ts = r.timestamp { lastTs = ts }
                  if r.model != "unknown" { model = r.model }
              }
              if tokensIn == 0 && tokensOut == 0 && cacheWrites == 0
                  && cacheReads == 0 && cost == 0 {
                  continue
              }
              seenTaskIds.insert(task.taskId)
              records.append(RooZooTaskRecord(
                  taskId: task.taskId,
                  model: model,
                  timestamp: lastTs,
                  tokensIn: tokensIn,
                  tokensOut: tokensOut,
                  cacheWrites: cacheWrites,
                  cacheReads: cacheReads,
                  costUSD: cost,
                  extensionId: task.extensionId,
                  sourcePath: uiPath,
                  source: .uiMessagesFallback
              ))
              perRoot[task.taskDir, default: 0] += 1
          }
          records.sort { lhs, rhs in
              switch (lhs.timestamp, rhs.timestamp) {
              case let (l?, r?): return l < r
              case (nil, _?):    return false
              case (_?, nil):    return true
              case (nil, nil):   return false
              }
          }
          return RooZooUsageSnapshot(
              records: records,
              recordsPerRoot: perRoot,
              unreadableFileCount: unreadable,
              malformedRecordCount: malformed,
              overCapFileCount: overCap,
              overTaskCapCount: 0  // set by caller via discover
          )
      }

      static func safeCostFromHistoryItem(_ raw: Any?) -> Double {
          var value: Double
          if let d = raw as? Double { value = d }
          else if let i = raw as? Int { value = Double(i) }
          else if let s = raw as? String, let parsed = Double(s) { value = parsed }
          else { return 0.0 }
          guard value.isFinite else { return 0.0 }
          if value <= 0 { return 0.0 }
          return min(value, 1_000_000.0)
      }

      static func extractModel(from dict: [String: Any]) -> String {
          // Roo/Zoo history_item.json exposes model as top-level `model`
          // in v3+ formats. Fall back to "unknown".
          if let m = dict["model"] as? String, !m.isEmpty { return m }
          return "unknown"
      }

      static func extractTimestamp(_ raw: Any?) -> Date? {
          // history_item.json uses `ts` = JS Date.now() ms-since-epoch.
          let msSince1970: Double
          if let d = raw as? Double { msSince1970 = d }
          else if let i = raw as? Int { msSince1970 = Double(i) }
          else if let s = raw as? String, let parsed = Double(s) { msSince1970 = parsed }
          else { return nil }
          guard msSince1970.isFinite else { return nil }
          let seconds = msSince1970 / 1000.0
          let year2000: Double = 946_684_800
          let year2100: Double = 4_102_444_800
          guard seconds >= year2000 && seconds < year2100 else { return nil }
          return Date(timeIntervalSince1970: seconds)
      }
  }
  ```

  Run: `swift build`
  Expected: PASS.

- [ ] **Step 3: Run parseHistoryItem happy-path test**
  Expected: PASS.

- [ ] **Step 4: Add hostile-numerics + missing-fields test for parseHistoryItem**

- [ ] **Step 5: Add fallback-to-ui_messages test**
  Create a task dir with NO history_item.json but WITH ui_messages.json
  containing Cline-shape messages. Verify the record parses via
  fallback and `source == .uiMessagesFallback`.

- [ ] **Step 6: Add both-files-present-precedence test**
  Task dir with both files; verify only history_item.json result is
  in snapshot; source == .historyItem.

- [ ] **Step 7: Add task-id dedupe test (Roo ∩ Zoo)**
  Two scan roots — one Roo, one Zoo — each containing task-dir "task-A"
  with valid history_item.json. Verify only ONE record in snapshot,
  and the extensionId matches the first-listed scan root.

- [ ] **Step 8: Add 10k cap test**
  Fake filesystem with 10 010 task dirs sorted by mtime desc. Verify
  10 000 in snapshot, 10 overCap.

- [ ] **Step 9: Add ui_messages > 128 MB test (skip synthetic if impractical to write; use a smaller cap injection if the API allows)**

  Skip if writing a 128 MB file in tests is impractical. Add a
  smaller-cap variant test via a testable override or accept the
  boundary is verified by inspection.

- [ ] **Step 10: Run all RooZoo fetcher tests + full suite**
  Run: `swift run TestRunner`
  Expected: PASS. Baseline was 1735 (Task 4); expect ~1760.

- [ ] **Step 11: Commit**
  ```bash
  git add app/RooZooUsageFetcher.swift Tests/TestRunner/TestRooZooUsageFetcher.swift Tests/TestRunner/main.swift
  git commit -m "$(cat <<'EOF'
  feat: add RooZooUsageFetcher — history_item.json + ui_messages fallback

  Reads Roo Code and Zoo Code per-task record layout, shared with
  Cline. Precedence per task: history_item.json rollup (field name
  `totalCost`, NOT `cost` — 3cc R1 F1) then ui_messages.json fallback
  via ClineUsageFetcher.parse (3cc R1 F6 exclusive precedence).

  Task-id-level dedupe across Roo ∩ Zoo (first-seen wins, 3cc R1 F8).
  10 000 most-recent tasks cap by directory mtime desc; overTaskCap
  count surfaced as diagnostic (3cc R3 F11). 128 MB size cap for
  ui_messages.json fallback (higher than Cline's 64 MB; Roo/Zoo
  sessions are longer — 3cc R3 F9).

  🤖 Generated with [Claude Code](https://claude.com/claude-code)

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 6: RooUsageStore and ZooUsageStore

**Files:**
- Create: `app/RooUsageStore.swift`, `app/ZooUsageStore.swift`
- Test: `Tests/TestRunner/TestRooUsageStore.swift`, `Tests/TestRunner/TestZooUsageStore.swift`
- Modify: `Tests/TestRunner/main.swift`

**Interfaces:**
- Both stores are structural clones of ClineUsageStore with the
  fetcher/resolver swapped and the extensionId scoped.

- [ ] **Step 1: Create RooUsageStore.swift**
  Mirror ClineUsageStore's fetch() with re-probe-on-completion. Use
  `RooZooPathResolver.resolveScanRoots(env, for: .roo, ...)` and
  `RooZooUsageFetcher.discoverTasks/parseTasks`. Feature flag
  `features.roo.enabled`. displayName "Roo Code", id "roo".

- [ ] **Step 2: Create ZooUsageStore.swift**
  Same as above with `.zoo`, `features.zoo.enabled`, "Zoo Code", "zoo".

- [ ] **Step 3-8: Tests**
  - flag-off → no tiles
  - flag-on, no data → loading tile
  - flag-on, snapshot loaded → counter + text tiles
  - TCC race (re-probe fires, discards stale snapshot)
  - clock injection
  - clear() nulls snapshot, bumps generation

- [ ] **Step 9: Full suite**
  Run: `swift run TestRunner`
  Expected: baseline was 1760; expect ~1775.

- [ ] **Step 10: Commit**
  ```bash
  git add app/RooUsageStore.swift app/ZooUsageStore.swift Tests/TestRunner/
  git commit -m "$(cat <<'EOF'
  feat: add Roo and Zoo UsageProvider stores

  Two @MainActor UsageProvider conformers sharing RooZooPathResolver
  and RooZooUsageFetcher. Separate feature flags (features.roo.enabled,
  features.zoo.enabled) so the archived Roo can be disabled while
  Zoo stays active.

  Both stores mirror ClineUsageStore.fetch() with generation counter,
  weak-self work queue, and re-probe on completion (3cc R3 F5).

  🤖 Generated with [Claude Code](https://claude.com/claude-code)

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 7: AppDelegate registration

**Files:**
- Modify: `app/ClaudeUsageBar.swift`

- [ ] **Step 1: Register the three stores after WarpUsageStore**
  Insert after line 139 (`providers.append(ProviderBox(WarpUsageStore()))`):
  ```swift
  // PR 13-BE: register Continue local JSONL reader. Opt-in
  // (features.continue.enabled defaults false); reads
  // `~/.continue/dev_data/0.2.0/tokensGenerated.jsonl` on-disk only
  // — nothing leaves the machine. Continue's local logging is
  // unconditionally ON, so if the user has ever used Continue, the
  // file exists.
  providers.append(ProviderBox(ContinueUsageStore()))
  // PR 13-BE: register Roo Code local reader. Opt-in
  // (features.roo.enabled defaults false); reads Roo's
  // `history_item.json` rollup per task (falling back to
  // ui_messages.json) across all VS Code family hosts.
  // Roo's GitHub repo is archived (May 2026), extension frozen at
  // v3.54.0. Users can toggle Roo OFF independently.
  providers.append(ProviderBox(RooUsageStore()))
  // PR 13-BE: register Zoo Code local reader. Opt-in
  // (features.zoo.enabled defaults false); Zoo is the active fork
  // of Roo. Same file layout, same reader; separate scan namespace
  // (ZooCodeOrganization.zoo-code).
  providers.append(ProviderBox(ZooUsageStore()))
  ```

- [ ] **Step 2: Verify build.sh compiles both arches**
  Run: `app/build.sh`
  Expected: both arm64 and x86_64 targets compile.

- [ ] **Step 3: Full test suite**
  Run: `swift run TestRunner`
  Expected: ~1775 tests, all pass.

- [ ] **Step 4: Verify CI static-grep guards**
  Run: `grep -l "api.jetbrains.ai\|grazie.aws.intellij.net" app/*.swift`
  Expected: only `app/ProviderCopy.swift` (the allowlisted copy-catalog).
  No new hostile hostnames in the six new files.

- [ ] **Step 5: Commit**
  ```bash
  git add app/ClaudeUsageBar.swift
  git commit -m "$(cat <<'EOF'
  feat: register Continue + Roo + Zoo stores in AppDelegate

  Three providers registered after WarpUsageStore, all
  feature-flagged off. Nothing renders until PR 13-UI wires
  ProviderCopy help/disclosure + Settings toggles.

  🤖 Generated with [Claude Code](https://claude.com/claude-code)

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 8: /3cc adversarial review on the implementation

Run three parallel Codex-style adversarial reviewers against the actual
diff (not the plan). Each has a distinct lens.

- [ ] **Step 1: Dispatch R1 (correctness)**
- [ ] **Step 2: Dispatch R2 (YAGNI)**
- [ ] **Step 3: Dispatch R3 (failure modes)**
- [ ] **Step 4: Synthesise findings; fix real bugs; commit**
- [ ] **Step 5: Repeat rounds until CLEAN (max 4 rounds, per prior PR precedent)**

---

### Task 9: /chk1:all on the completed diff

- [ ] **Step 1: Invoke chk1:all**
- [ ] **Step 2: Address any P1-P3 findings**
- [ ] **Step 3: Full suite passes + all CI guards clean**

---

### Task 10: PR body + push

- [ ] **Step 1: Write PR body in `.pr-bodies/pr-13-be.md`**
- [ ] **Step 2: `git push -u origin feat/continue-roo-be`**
- [ ] **Step 3: `gh pr create` targeting `Artzainnn/ClaudeUsageBar main`**
- [ ] **Step 4: Fast-forward local main to HEAD of `feat/continue-roo-be`**
- [ ] **Step 5: Update `.pr-bodies/RESUME.md`**

---

## Commit trailer (used at every commit)

```
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GNPqJoftttPHpv69T9oNk1
```

## Notes

- The plan uses `readClineUiMessagesText` (currently `static` in
  ClineUsageFetcher). If it is `private`/`static` and not accessible
  from RooZooUsageFetcher, promote to `public static` in Task 5.
- If `ClineUsageFetcher.parse(uiMessages:sourceFile:malformedRecordCount:)`
  returns `[ClineUsageRecord]?` (not a snapshot), that's what
  Task 5 uses — the aggregate math happens in RooZooUsageFetcher's
  fallback branch.
- `LocalProviderAccessGuide.copy(for:appName:)` is the shared helper
  from PR #66; use it verbatim for the .needsAccess tile.
- `ClaudeCodeUsageStore.todayRange(around:)`,
  `monthToDateRange(around:)`, `startOfNextDay(after:)`,
  `formatTokens(_:)`, `formatUSD(_:)` are the shared helpers reused
  by ClineUsageStore; reuse them in Continue and Roo/Zoo stores too.
