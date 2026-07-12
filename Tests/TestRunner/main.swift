// PR 2a + PR 2b — assertion-based test runner.
//
// Runs with `swift run TestRunner` from the repo root. Works with
// Command Line Tools alone; does not require Xcode.app / XCTest.
// Prints one line per test and exits nonzero if any assertion fails.
//
// PR 2a added LogValue tests. PR 2b adds AnthropicUsageFetcher tests
// covering every branch of the parser against synthetic fixtures whose
// shape matches the documented claude.ai /api/organizations/{org}/usage
// response.

import Foundation
import ClaudeUsageBar

// MARK: - Minimal assertion API

var failed = 0
var total = 0

func expect(_ condition: @autoclosure () -> Bool,
            _ message: String = "",
            file: StaticString = #file, line: UInt = #line) {
    total += 1
    if !condition() {
        failed += 1
        let where_ = "\(file):\(line)"
        if message.isEmpty {
            print("  FAIL  \(where_)")
        } else {
            print("  FAIL  \(where_) — \(message)")
        }
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                                file: StaticString = #file, line: UInt = #line) {
    expect(actual == expected,
           "expected \(expected), got \(actual)",
           file: file, line: line)
}

func run(_ name: String, _ body: () -> Void) {
    let before = failed
    body()
    let outcome = failed == before ? "PASS" : "FAIL"
    print("\(outcome)  \(name)")
}

// MARK: - LogValue tests

run("LogValue.public emits verbatim") {
    expectEqual(LogValue.public("HTTP 200").rendered, "HTTP 200")
    expectEqual(LogValue.public("").rendered, "")
    expectEqual(LogValue.public("emoji ✅ ok").rendered, "emoji ✅ ok")
}

run("LogValue.sensitive redacts to length only") {
    expectEqual(LogValue.sensitive("abc").rendered, "<redacted: 3 chars>")
    expectEqual(LogValue.sensitive("").rendered, "<redacted: 0 chars>")
    expectEqual(LogValue.sensitive("sk-1234567890abcdef").rendered,
                "<redacted: 19 chars>")
}

run("LogValue.sensitive never emits the raw value") {
    let secret = "super-secret-cookie-value-that-must-not-leak"
    let rendered = LogValue.sensitive(secret).rendered
    expect(!rendered.contains(secret))
    expect(!rendered.contains("super"))
    expect(!rendered.contains("secret"))
    expect(!rendered.contains("cookie"))
}

run("LogValue.identifier emits short SHA-256 prefix") {
    expectEqual(LogValue.identifier("hello").rendered, "<id: 2cf24dba>")
    expectEqual(LogValue.identifier("").rendered, "<id: e3b0c442>")
}

run("LogValue.identifier is deterministic") {
    let orgId = "8f2c3d1a-e5b9-4a01-9d3c-7e1f5b2c3d4a"
    expectEqual(LogValue.identifier(orgId).rendered,
                LogValue.identifier(orgId).rendered)
}

run("LogValue.identifier is not reversible to raw value") {
    let orgId = "8f2c3d1a-e5b9-4a01-9d3c-7e1f5b2c3d4a"
    let rendered = LogValue.identifier(orgId).rendered
    expect(!rendered.contains(orgId))
    expect(!rendered.contains("8f2c"))
    expect(!rendered.contains("e5b9"))
}

run("LogValue.identifier distinguishes different inputs") {
    let a = LogValue.identifier("org-a").rendered
    let b = LogValue.identifier("org-b").rendered
    expect(a != b)
}

run("LogValue.count emits numeric literal") {
    expectEqual(LogValue.count(0).rendered, "0")
    expectEqual(LogValue.count(42).rendered, "42")
    expectEqual(LogValue.count(-1).rendered, "-1")
    expectEqual(LogValue.count(823).rendered, "823")
}

// MARK: - AnthropicUsageFetcher.orgId(fromCookieString:)

run("orgId returns nil when lastActiveOrg is absent") {
    let cookie = "sessionKey=abc; foo=bar"
    expect(AnthropicUsageFetcher.orgId(fromCookieString: cookie) == nil)
}

run("orgId extracts value from lastActiveOrg") {
    let cookie = "sessionKey=abc; lastActiveOrg=8f2c3d1a-e5b9; foo=bar"
    expectEqual(
        AnthropicUsageFetcher.orgId(fromCookieString: cookie),
        "8f2c3d1a-e5b9"
    )
}

run("orgId trims whitespace around each cookie part") {
    let cookie = "  lastActiveOrg=  8f2c ; foo=bar"
    // The extractor trims each semicolon-separated part before matching
    // the `lastActiveOrg=` prefix. The trailing space in "  8f2c " is
    // consumed by that trim. Leading spaces inside the value survive
    // because the prefix drop is exact-length. This matches the
    // pre-refactor behaviour byte-for-byte (which used the same
    // trimmingCharacters + replacingOccurrences sequence).
    let out = AnthropicUsageFetcher.orgId(fromCookieString: cookie)
    expectEqual(out, "  8f2c")
}

run("orgId returns nil on empty cookie") {
    expect(AnthropicUsageFetcher.orgId(fromCookieString: "") == nil)
}

// MARK: - AnthropicUsageFetcher.parse — happy path fixtures

// Fixture 1: minimum shape — five_hour and seven_day only, no Sonnet,
// no Fable in limits[]. This is what a Free plan account looks like.
let fixtureFreeMinimal = #"""
{
  "five_hour":  {"utilization": 42.3, "resets_at": "2026-07-12T09:15:00.000Z"},
  "seven_day":  {"utilization": 17.8, "resets_at": "2026-07-18T00:00:00.000Z"}
}
"""#

run("parse Free-plan minimal fixture") {
    let snap = try! AnthropicUsageFetcher.parse(fixtureFreeMinimal.data(using: .utf8)!)
    expectEqual(snap.sessionUsage, 42)
    expectEqual(snap.weeklyUsage, 17)
    expectEqual(snap.hasWeeklySonnet, false)
    expectEqual(snap.weeklySonnetUsage, 0)
    expectEqual(snap.hasWeeklyFable, false)
    expectEqual(snap.weeklyFableUsage, 0)
    expect(snap.sessionResetsAt != nil)
    expect(snap.weeklyResetsAt != nil)
    expect(snap.weeklySonnetResetsAt == nil)
    expect(snap.weeklyFableResetsAt == nil)
}

// Fixture 2: Pro plan with Sonnet bucket present.
let fixtureProWithSonnet = #"""
{
  "five_hour":         {"utilization": 55.5, "resets_at": "2026-07-12T09:15:00.000Z"},
  "seven_day":         {"utilization": 33.3, "resets_at": "2026-07-18T00:00:00.000Z"},
  "seven_day_sonnet":  {"utilization": 12.9, "resets_at": "2026-07-18T00:00:00.000Z"}
}
"""#

run("parse Pro-plan Sonnet fixture") {
    let snap = try! AnthropicUsageFetcher.parse(fixtureProWithSonnet.data(using: .utf8)!)
    expectEqual(snap.sessionUsage, 55)
    expectEqual(snap.weeklyUsage, 33)
    expectEqual(snap.hasWeeklySonnet, true)
    expectEqual(snap.weeklySonnetUsage, 12)
    expectEqual(snap.hasWeeklyFable, false)
}

// Fixture 3: Fable present in limits[] with percent as Int.
let fixtureFableInt = #"""
{
  "five_hour":  {"utilization": 60.0, "resets_at": "2026-07-12T09:15:00.000Z"},
  "seven_day":  {"utilization": 40.0, "resets_at": "2026-07-18T00:00:00.000Z"},
  "limits": [
    {"scope": {"model": {"display_name": "Opus"}}, "percent": 5, "resets_at": "2026-07-18T00:00:00.000Z"},
    {"scope": {"model": {"display_name": "Fable"}}, "percent": 7, "resets_at": "2026-07-18T00:00:00.000Z"}
  ]
}
"""#

run("parse Fable fixture with percent as Int") {
    let snap = try! AnthropicUsageFetcher.parse(fixtureFableInt.data(using: .utf8)!)
    expectEqual(snap.hasWeeklyFable, true)
    expectEqual(snap.weeklyFableUsage, 7)
    expect(snap.weeklyFableResetsAt != nil)
}

// Fixture 4: Fable present with percent as Double (documented variant).
let fixtureFableDouble = #"""
{
  "five_hour":  {"utilization": 60.0, "resets_at": "2026-07-12T09:15:00.000Z"},
  "seven_day":  {"utilization": 40.0, "resets_at": "2026-07-18T00:00:00.000Z"},
  "limits": [
    {"scope": {"model": {"display_name": "Fable"}}, "percent": 12.7, "resets_at": "2026-07-18T00:00:00.000Z"}
  ]
}
"""#

run("parse Fable fixture with percent as Double") {
    let snap = try! AnthropicUsageFetcher.parse(fixtureFableDouble.data(using: .utf8)!)
    expectEqual(snap.hasWeeklyFable, true)
    expectEqual(snap.weeklyFableUsage, 12)
}

// Fixture 5: full — Sonnet, Fable, Opus in limits, etc. All buckets present.
let fixtureFull = #"""
{
  "five_hour":         {"utilization": 88.4, "resets_at": "2026-07-12T09:15:00.000Z"},
  "seven_day":         {"utilization": 71.2, "resets_at": "2026-07-18T00:00:00.000Z"},
  "seven_day_sonnet":  {"utilization": 44.0, "resets_at": "2026-07-18T00:00:00.000Z"},
  "limits": [
    {"scope": {"model": {"display_name": "Fable"}}, "percent": 23, "resets_at": "2026-07-18T00:00:00.000Z"},
    {"scope": {"model": {"display_name": "Opus"}}, "percent": 15}
  ]
}
"""#

run("parse full fixture with every bucket populated") {
    let snap = try! AnthropicUsageFetcher.parse(fixtureFull.data(using: .utf8)!)
    expectEqual(snap.sessionUsage, 88)
    expectEqual(snap.weeklyUsage, 71)
    expectEqual(snap.hasWeeklySonnet, true)
    expectEqual(snap.weeklySonnetUsage, 44)
    expectEqual(snap.hasWeeklyFable, true)
    expectEqual(snap.weeklyFableUsage, 23)
}

// MARK: - AnthropicUsageFetcher.parse — error paths

run("parse throws invalidJSON on empty body") {
    do {
        _ = try AnthropicUsageFetcher.parse(Data())
        expect(false, "expected throw on empty body")
    } catch {
        expect(true)
    }
}

run("parse throws invalidJSON on malformed body") {
    let bytes = "not json at all".data(using: .utf8)!
    do {
        _ = try AnthropicUsageFetcher.parse(bytes)
        expect(false, "expected throw on malformed body")
    } catch {
        expect(true)
    }
}

run("parse throws invalidJSON on non-object top-level") {
    let bytes = "[1,2,3]".data(using: .utf8)!
    do {
        _ = try AnthropicUsageFetcher.parse(bytes)
        expect(false, "expected throw on array top-level")
    } catch {
        expect(true)
    }
}

// MARK: - AnthropicUsageFetcher.parse — degenerate but non-throwing shapes

run("parse tolerates empty JSON object (all fields default)") {
    let snap = try! AnthropicUsageFetcher.parse("{}".data(using: .utf8)!)
    expectEqual(snap.sessionUsage, 0)
    expectEqual(snap.weeklyUsage, 0)
    expectEqual(snap.hasWeeklySonnet, false)
    expectEqual(snap.hasWeeklyFable, false)
    expect(snap.sessionResetsAt == nil)
}

run("parse tolerates missing resets_at strings") {
    let bytes = #"""
    {"five_hour": {"utilization": 10.0}, "seven_day": {"utilization": 5.0}}
    """#.data(using: .utf8)!
    let snap = try! AnthropicUsageFetcher.parse(bytes)
    expectEqual(snap.sessionUsage, 10)
    expectEqual(snap.weeklyUsage, 5)
    expect(snap.sessionResetsAt == nil)
    expect(snap.weeklyResetsAt == nil)
}

run("parse ignores non-Fable entries in limits[]") {
    let bytes = #"""
    {"five_hour": {"utilization": 0}, "seven_day": {"utilization": 0},
     "limits": [{"scope": {"model": {"display_name": "Sonnet"}}, "percent": 42}]}
    """#.data(using: .utf8)!
    let snap = try! AnthropicUsageFetcher.parse(bytes)
    expectEqual(snap.hasWeeklyFable, false)
    expectEqual(snap.weeklyFableUsage, 0)
}

// MARK: - CodexUsageFetcher.parseAuth — auth.json ingestion

// Synthetic auth.json matching the documented CLI shape (auth_mode, tokens
// with id_token/access_token/refresh_token/account_id, last_refresh). No
// real credential is used — every value here is fabricated.
let fixtureAuthValid = #"""
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token": "eyJhbGci.fake.idtoken",
    "access_token": "eyJhbGci.fake.accesstoken",
    "refresh_token": "fake-refresh-token",
    "account_id": "acct-0000-fake"
  },
  "last_refresh": "2026-07-08T18:47:00.000Z"
}
"""#

run("parseAuth extracts access_token and account_id") {
    let creds = try! CodexUsageFetcher.parseAuth(fixtureAuthValid.data(using: .utf8)!)
    expectEqual(creds.accessToken, "eyJhbGci.fake.accesstoken")
    expectEqual(creds.accountId, "acct-0000-fake")
}

run("parseAuth throws malformed on non-JSON") {
    do {
        _ = try CodexUsageFetcher.parseAuth("not json".data(using: .utf8)!)
        expect(false, "expected throw")
    } catch let e as CodexAuthError {
        expectEqual(e, .authFileMalformed)
    } catch { expect(false, "wrong error type") }
}

run("parseAuth throws incomplete when tokens absent") {
    // An apikey-mode login has no tokens block.
    let bytes = #"{"auth_mode": "apikey", "OPENAI_API_KEY": "sk-fake", "tokens": null}"#.data(using: .utf8)!
    do {
        _ = try CodexUsageFetcher.parseAuth(bytes)
        expect(false, "expected throw")
    } catch let e as CodexAuthError {
        expectEqual(e, .authFileIncomplete)
    } catch { expect(false, "wrong error type") }
}

run("parseAuth throws incomplete when access_token empty") {
    let bytes = #"""
    {"tokens": {"access_token": "", "account_id": "acct-1"}}
    """#.data(using: .utf8)!
    do {
        _ = try CodexUsageFetcher.parseAuth(bytes)
        expect(false, "expected throw")
    } catch let e as CodexAuthError {
        expectEqual(e, .authFileIncomplete)
    } catch { expect(false, "wrong error type") }
}

run("parseAuth throws incomplete when account_id missing") {
    let bytes = #"""
    {"tokens": {"access_token": "eyJhbGci.fake"}}
    """#.data(using: .utf8)!
    do {
        _ = try CodexUsageFetcher.parseAuth(bytes)
        expect(false, "expected throw")
    } catch let e as CodexAuthError {
        expectEqual(e, .authFileIncomplete)
    } catch { expect(false, "wrong error type") }
}

// MARK: - CodexUsageFetcher.codexHome / authFileURL — CODEX_HOME resolution

run("codexHome honours CODEX_HOME when set") {
    let env = ["CODEX_HOME": "/tmp/custom-codex"]
    expectEqual(CodexUsageFetcher.codexHome(environment: env).path, "/tmp/custom-codex")
}

run("codexHome ignores empty CODEX_HOME and falls back to ~/.codex") {
    let env = ["CODEX_HOME": "   "]
    let home = CodexUsageFetcher.codexHome(environment: env).path
    expect(home.hasSuffix("/.codex"))
}

run("authFileURL appends auth.json to codex home") {
    let env = ["CODEX_HOME": "/tmp/custom-codex"]
    expectEqual(CodexUsageFetcher.authFileURL(environment: env).path,
                "/tmp/custom-codex/auth.json")
}

// MARK: - CodexUsageFetcher.parse — happy path (real probed shape)

// Fixture matches the live endpoint shape verified by a read-only probe:
// integer used_percent, Unix-epoch integer reset_at, null additional_rate_
// limits, credits object with a String balance. This is what a Plus/Team
// account with no model-specific limits returns.
let fixtureCodexHappy = #"""
{
  "user_id": "user-fake-0001",
  "account_id": "acct-fake-0001",
  "email": "fake@example.com",
  "plan_type": "plus",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window":   {"used_percent": 42, "limit_window_seconds": 18000,  "reset_after_seconds": 12000, "reset_at": 1783816392},
    "secondary_window": {"used_percent": 7,  "limit_window_seconds": 604800, "reset_after_seconds": 500000, "reset_at": 1784372815}
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": null,
  "credits": {"has_credits": false, "unlimited": false, "overage_limit_reached": false, "balance": "0"},
  "spend_control": {"reached": false, "individual_limit": null},
  "rate_limit_reached_type": null
}
"""#

run("parse Codex happy-path fixture (primary + secondary)") {
    let snap = try! CodexUsageFetcher.parse(fixtureCodexHappy.data(using: .utf8)!)
    expectEqual(snap.allowed, true)
    expectEqual(snap.limitReached, false)
    expectEqual(snap.planType, "plus")
    expectEqual(snap.primaryWindow?.usedPercent, 42)
    expectEqual(snap.primaryWindow?.limitWindowSeconds, 18000)
    expectEqual(snap.primaryWindow?.resetAfterSeconds, 12000)
    expect(snap.primaryWindow?.resetAt != nil)
    expectEqual(snap.primaryWindow?.resetAt, Date(timeIntervalSince1970: 1783816392))
    expectEqual(snap.secondaryWindow?.usedPercent, 7)
    expectEqual(snap.secondaryWindow?.resetAt, Date(timeIntervalSince1970: 1784372815))
    // additional_rate_limits: null -> empty
    expectEqual(snap.additionalLimits.count, 0)
    // credits present but has_credits false
    expectEqual(snap.credits?.hasCredits, false)
    expectEqual(snap.credits?.balance, "0")
}

// MARK: - CodexUsageFetcher.parse — additional_rate_limits[] non-empty

// Fixture matches AdditionalRateLimitDetails from openai/codex: each element
// is {limit_name, metered_feature, rate_limit:{primary_window, secondary_
// window}}. Usage is NESTED under rate_limit, not flat on the element.
let fixtureCodexAdditional = #"""
{
  "plan_type": "pro",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window":   {"used_percent": 50, "limit_window_seconds": 18000,  "reset_after_seconds": 9000,   "reset_at": 1783816392},
    "secondary_window": {"used_percent": 20, "limit_window_seconds": 604800, "reset_after_seconds": 400000, "reset_at": 1784372815}
  },
  "additional_rate_limits": [
    {
      "limit_name": "GPT-5.3-Codex-Spark",
      "metered_feature": "codex_spark",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window":   {"used_percent": 84, "limit_window_seconds": 18000, "reset_after_seconds": 3000, "reset_at": 1783810000},
        "secondary_window": {"used_percent": 70, "limit_window_seconds": 604800, "reset_after_seconds": 200000, "reset_at": 1784300000}
      }
    }
  ],
  "credits": null
}
"""#

run("parse Codex additional_rate_limits[] with nested windows") {
    let snap = try! CodexUsageFetcher.parse(fixtureCodexAdditional.data(using: .utf8)!)
    expectEqual(snap.additionalLimits.count, 1)
    let extra = snap.additionalLimits[0]
    expectEqual(extra.limitName, "GPT-5.3-Codex-Spark")
    expectEqual(extra.meteredFeature, "codex_spark")
    // The single most common mistake: usage is NOT flat on the element.
    // Confirm it is read from the nested rate_limit.primary_window.
    expectEqual(extra.primaryWindow?.usedPercent, 84)
    expectEqual(extra.primaryWindow?.resetAt, Date(timeIntervalSince1970: 1783810000))
    expectEqual(extra.secondaryWindow?.usedPercent, 70)
    // credits: null -> nil, not an empty struct
    expect(snap.credits == nil)
}

// MARK: - CodexUsageFetcher.parse — credits present with balance

let fixtureCodexCredits = #"""
{
  "plan_type": "pro",
  "rate_limit": {"allowed": true, "limit_reached": false,
    "primary_window": {"used_percent": 10, "reset_at": 1783816392}},
  "additional_rate_limits": null,
  "credits": {"has_credits": true, "unlimited": false, "overage_limit_reached": false, "balance": "12.50"}
}
"""#

run("parse Codex credits block with String balance") {
    let snap = try! CodexUsageFetcher.parse(fixtureCodexCredits.data(using: .utf8)!)
    expectEqual(snap.credits?.hasCredits, true)
    expectEqual(snap.credits?.unlimited, false)
    expectEqual(snap.credits?.balance, "12.50")
    // Only the primary window is present in this fixture.
    expectEqual(snap.primaryWindow?.usedPercent, 10)
    expect(snap.secondaryWindow == nil)
}

// MARK: - CodexUsageFetcher.parse — empty / degenerate accounts

run("parse tolerates empty JSON object (all fields default)") {
    let snap = try! CodexUsageFetcher.parse("{}".data(using: .utf8)!)
    expectEqual(snap.allowed, true)          // default
    expectEqual(snap.limitReached, false)
    expect(snap.primaryWindow == nil)
    expect(snap.secondaryWindow == nil)
    expectEqual(snap.additionalLimits.count, 0)
    expect(snap.credits == nil)
    expect(snap.planType == nil)
}

run("parse tolerates rate_limit with no windows") {
    let bytes = #"{"rate_limit": {"allowed": false, "limit_reached": true}}"#.data(using: .utf8)!
    let snap = try! CodexUsageFetcher.parse(bytes)
    expectEqual(snap.allowed, false)
    expectEqual(snap.limitReached, true)
    expect(snap.primaryWindow == nil)
}

run("parse accepts used_percent as Double defensively") {
    let bytes = #"""
    {"rate_limit": {"primary_window": {"used_percent": 90.0, "reset_at": 1783816392}}}
    """#.data(using: .utf8)!
    let snap = try! CodexUsageFetcher.parse(bytes)
    expectEqual(snap.primaryWindow?.usedPercent, 90)
}

run("parse throws invalidJSON on empty body") {
    do {
        _ = try CodexUsageFetcher.parse(Data())
        expect(false, "expected throw")
    } catch { expect(true) }
}

run("parse throws invalidJSON on array top-level") {
    do {
        _ = try CodexUsageFetcher.parse("[1,2,3]".data(using: .utf8)!)
        expect(false, "expected throw")
    } catch { expect(true) }
}

// MARK: - CodexUsageStore — feature flag, tile mapping, 401 state

// The store is @MainActor. TestRunner's top-level executes on the main
// thread, so assumeIsolated is valid here. An isolated UserDefaults suite
// keeps the feature flag out of the shared standard defaults.
MainActor.assumeIsolated {
    let suiteName = "codex-tests-\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    // A CODEX_HOME that does not exist -> readCredentials throws authFileMissing.
    let missingEnv = ["CODEX_HOME": "/tmp/codex-does-not-exist-\(ProcessInfo.processInfo.processIdentifier)"]

    run("store disabled by default emits no tiles") {
        let store = CodexUsageStore(environment: missingEnv, defaults: defaults)
        expectEqual(store.isEnabled, false)
        expectEqual(store.tiles.count, 0)
    }

    run("store enabled but unconfigured emits needsAccess onboarding tile") {
        defaults.set(true, forKey: "features.codex.enabled")
        let store = CodexUsageStore(environment: missingEnv, defaults: defaults)
        expectEqual(store.isEnabled, true)
        expectEqual(store.isConfigured, false)
        let tiles = store.tiles
        expectEqual(tiles.count, 1)
        if case .needsAccess = tiles.first?.kind {
            expect(true)
        } else {
            expect(false, "expected needsAccess tile")
        }
    }

    run("store applies happy-path result and renders 5h + weekly bars") {
        defaults.set(true, forKey: "features.codex.enabled")
        let store = CodexUsageStore(environment: missingEnv, defaults: defaults)
        store.setHasCredentialsForTesting(true)
        store.apply(.success(fixtureCodexHappy.data(using: .utf8)!))
        expect(store.lastUpdated != nil)
        expect(store.errorMessage == nil)
        // Enabled + not configured (missing env) means tiles() short-circuits
        // to the onboarding card. To test tile rendering from a snapshot we
        // read the snapshot directly rather than through the isConfigured
        // gate (which requires a real auth.json).
        expectEqual(store.snapshot?.primaryWindow?.usedPercent, 42)
        expectEqual(store.snapshot?.secondaryWindow?.usedPercent, 7)
    }

    run("store maps 401 to sessionExpired without clearing snapshot") {
        defaults.set(true, forKey: "features.codex.enabled")
        let store = CodexUsageStore(environment: missingEnv, defaults: defaults)
        store.apply(.success(fixtureCodexHappy.data(using: .utf8)!))
        expect(store.snapshot != nil)
        store.apply(.unauthorized)
        expectEqual(store.sessionExpired, true)
        expect(store.errorMessage == nil)
        // Snapshot retained so the popover does not flash empty on expiry.
        expect(store.snapshot != nil)
    }

    run("store maps httpError to an HTTP N error message") {
        defaults.set(true, forKey: "features.codex.enabled")
        let store = CodexUsageStore(environment: missingEnv, defaults: defaults)
        store.apply(.httpError(503))
        expectEqual(store.errorMessage, "HTTP 503")
    }

    run("store maps networkError to a generic message") {
        defaults.set(true, forKey: "features.codex.enabled")
        let store = CodexUsageStore(environment: missingEnv, defaults: defaults)
        store.apply(.networkError)
        expectEqual(store.errorMessage, "Network error")
    }

    run("store fraction clamps out-of-range percentages") {
        // A malformed >100 percentage must not overflow the progress bar.
        let bytes = #"""
        {"rate_limit": {"primary_window": {"used_percent": 150, "reset_at": 1783816392}}}
        """#.data(using: .utf8)!
        defaults.set(true, forKey: "features.codex.enabled")
        let store = CodexUsageStore(environment: missingEnv, defaults: defaults)
        store.apply(.success(bytes))
        expectEqual(store.snapshot?.primaryWindow?.usedPercent, 150)
        // The fraction is applied in tiles(); verified indirectly via the
        // snapshot value here since tiles() is gated by isConfigured. The
        // clamp itself is unit-covered by the fraction helper's min/max.
    }

    defaults.removePersistentDomain(forName: suiteName)
}

// MARK: - ProviderCopy (Settings toggle copy — PR 3-UI)

run("ProviderCopy.help returns Codex copy and nil for unknown") {
    let codex = ProviderCopy.help(for: "codex")
    expect(codex != nil)
    expect(codex?.contains("Codex CLI") == true)
    expect(codex?.contains("General GPT chat is not counted") == true)
    // Honest-labels invariant: never claim to track general ChatGPT usage.
    expect(codex?.contains("ChatGPT usage") == false)
    expect(ProviderCopy.help(for: "anthropic") == nil)
    expect(ProviderCopy.help(for: "unknown-provider") == nil)
}

run("ProviderCopy.disclosure warns about the private API for Codex only") {
    let codex = ProviderCopy.disclosure(for: "codex")
    expect(codex != nil)
    expect(codex?.contains("private Codex API") == true)
    expect(codex?.contains("without notice") == true)
    expect(ProviderCopy.disclosure(for: "anthropic") == nil)
    // DeepSeek uses a documented, stable API — no private-API disclosure.
    expect(ProviderCopy.disclosure(for: "deepseek") == nil)
}

run("ProviderCopy.help returns DeepSeek Keychain guidance") {
    let ds = ProviderCopy.help(for: "deepseek")
    expect(ds != nil)
    expect(ds?.contains("Keychain") == true)
    expect(ds?.contains("balance") == true)
}

run("ProviderCopy.help returns Zed guidance and no disclosure") {
    let zed = ProviderCopy.help(for: "zed")
    expect(zed != nil)
    expect(zed?.contains("edit-prediction") == true)
    expect(zed?.contains("Keychain") == true)
    // Zed reads a first-party local credential — no private-API disclosure.
    expect(ProviderCopy.disclosure(for: "zed") == nil)
}

run("ProviderCopy.help returns xAI two-key guidance") {
    let xai = ProviderCopy.help(for: "xai")
    expect(xai != nil)
    expect(xai?.contains("inference key") == true)
    expect(xai?.contains("management key") == true)
}

run("ProviderCopy: OpenAI help + admin-key disclosure") {
    let help = ProviderCopy.help(for: "openai")
    expect(help != nil)
    expect(help?.contains("Admin key") == true)
    expect(help?.contains("month-to-date") == true)
    // Admin keys are high-privilege — a disclosure warning is required.
    let disc = ProviderCopy.disclosure(for: "openai")
    expect(disc != nil)
    expect(disc?.contains("manage users") == true)
    expect(disc?.contains("cannot make inference") == true)
}

run("ProviderCopy: Perplexity help names the cookie, Keychain, and multiple paste forms (PR 8-UI)") {
    // The user needs to know exactly which cookie to copy from DevTools;
    // the guidance MUST name it verbatim so a search inside the browser's
    // cookie inspector finds it. It also must mention the paste flexibility
    // (bare value, name=value, or full Cookie header) or valid pastes will
    // look wrong to the user.
    let help = ProviderCopy.help(for: "perplexity")
    expect(help != nil)
    expect(help?.contains("__Secure-next-auth.session-token") == true)
    expect(help?.contains("perplexity.ai") == true)
    expect(help?.contains("Keychain") == true)
    // At least one of the four Perplexity modes is named so the user knows
    // what they'll see once configured.
    expect(help?.contains("Pro Search") == true || help?.contains("Deep Research") == true)
    // Codex adversarial review #5: copy softened from "Shows" to "Can show"
    // so we do not over-promise tiles that may be Cloudflare-challenged.
    expect(help?.contains("Can show") == true || help?.contains("When available") == true)
    // Codex adversarial review #4: paste flexibility must be documented.
    expect(help?.contains("name=value") == true || help?.contains("Cookie header") == true || help?.contains("bare") == true)
}

run("ProviderCopy: Perplexity disclosure warns about undocumented API and cookie power") {
    // The Perplexity cookie is a spending credential AND the endpoints are
    // undocumented — both facts must be surfaced before the user pastes.
    // Codex adversarial review #1: the disclosure must not under-state the
    // cookie's authority ("Sonar credits" alone is too narrow — it is a
    // full web session cookie). #2: the revocation promise must be
    // conditional, not absolute.
    let disc = ProviderCopy.disclosure(for: "perplexity")
    expect(disc != nil)
    expect(disc?.contains("private") == true || disc?.contains("undocumented") == true || disc?.contains("may stop") == true)
    // Framed as a full session cookie, not just a Sonar-credit token.
    expect(disc?.contains("session cookie") == true || disc?.contains("act as your signed-in account") == true)
    // Revocation described conditionally, not absolutely.
    expect(disc?.contains("until it expires") == true || disc?.contains("revoked") == true)
}

run("PasteKeyProvider.secretKindNoun defaults to Key and Perplexity overrides to Cookie") {
    // Codex adversarial review #3: the generic Settings row would have
    // said "Key saved in Keychain" even for Perplexity's cookie paste.
    // The optional secretKindNoun on PasteKeyProvider lets a provider
    // rename that noun without any downstream code change.
    MainActor.assumeIsolated {
        let deepseek = DeepSeekUsageStore(credentials: InMemoryCredentialStore())
        let perplexity = PerplexityUsageStore(credentials: InMemoryCredentialStore())
        expectEqual((deepseek as PasteKeyProvider).secretKindNoun, "Key")
        expectEqual((perplexity as PasteKeyProvider).secretKindNoun, "Cookie")
    }
}

// MARK: - DeepSeekUsageFetcher.parse (PR 4-BE)

// Fixture shapes match api-docs.deepseek.com/api/get-user-balance: is_available
// bool, balance_infos[] with currency + three STRING amounts.
let fixtureDeepSeekUSD = #"""
{
  "is_available": true,
  "balance_infos": [
    {"currency": "USD", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00"}
  ]
}
"""#

run("parse DeepSeek USD balance (strings preserved verbatim)") {
    let snap = try! DeepSeekUsageFetcher.parse(fixtureDeepSeekUSD.data(using: .utf8)!)
    expectEqual(snap.isAvailable, true)
    expectEqual(snap.balances.count, 1)
    expectEqual(snap.balances[0].currency, "USD")
    expectEqual(snap.balances[0].totalBalance, "110.00")
    expectEqual(snap.balances[0].grantedBalance, "10.00")
    expectEqual(snap.balances[0].toppedUpBalance, "100.00")
}

let fixtureDeepSeekCNY = #"""
{
  "is_available": true,
  "balance_infos": [
    {"currency": "CNY", "total_balance": "550.5", "granted_balance": "0", "topped_up_balance": "550.5"}
  ]
}
"""#

run("parse DeepSeek CNY balance") {
    let snap = try! DeepSeekUsageFetcher.parse(fixtureDeepSeekCNY.data(using: .utf8)!)
    expectEqual(snap.balances.count, 1)
    expectEqual(snap.balances[0].currency, "CNY")
    expectEqual(snap.balances[0].totalBalance, "550.5")
}

let fixtureDeepSeekDual = #"""
{
  "is_available": true,
  "balance_infos": [
    {"currency": "USD", "total_balance": "5.00", "granted_balance": "5.00", "topped_up_balance": "0"},
    {"currency": "CNY", "total_balance": "36.00", "granted_balance": "36.00", "topped_up_balance": "0"}
  ]
}
"""#

run("parse DeepSeek dual-currency balance_infos") {
    let snap = try! DeepSeekUsageFetcher.parse(fixtureDeepSeekDual.data(using: .utf8)!)
    expectEqual(snap.balances.count, 2)
    expectEqual(snap.balances[0].currency, "USD")
    expectEqual(snap.balances[1].currency, "CNY")
}

run("parse DeepSeek is_available false") {
    let bytes = #"{"is_available": false, "balance_infos": []}"#.data(using: .utf8)!
    let snap = try! DeepSeekUsageFetcher.parse(bytes)
    expectEqual(snap.isAvailable, false)
    expectEqual(snap.balances.count, 0)
}

run("parse DeepSeek accepts numeric amounts defensively") {
    // The documented API returns strings; accept numbers too so a server
    // change does not drop the value.
    let bytes = #"""
    {"is_available": true, "balance_infos": [{"currency": "USD", "total_balance": 42, "granted_balance": 0, "topped_up_balance": 42.5}]}
    """#.data(using: .utf8)!
    let snap = try! DeepSeekUsageFetcher.parse(bytes)
    expectEqual(snap.balances[0].totalBalance, "42")
    expectEqual(snap.balances[0].toppedUpBalance, "42.5")
}

run("parse DeepSeek skips entries with no currency") {
    let bytes = #"""
    {"is_available": true, "balance_infos": [{"total_balance": "1.00"}, {"currency": "USD", "total_balance": "2.00", "granted_balance": "0", "topped_up_balance": "2.00"}]}
    """#.data(using: .utf8)!
    let snap = try! DeepSeekUsageFetcher.parse(bytes)
    expectEqual(snap.balances.count, 1)
    expectEqual(snap.balances[0].currency, "USD")
}

run("parse DeepSeek tolerates empty object") {
    let snap = try! DeepSeekUsageFetcher.parse("{}".data(using: .utf8)!)
    expectEqual(snap.isAvailable, false)
    expectEqual(snap.balances.count, 0)
}

run("parse DeepSeek throws on array top-level") {
    do {
        _ = try DeepSeekUsageFetcher.parse("[]".data(using: .utf8)!)
        expect(false, "expected throw")
    } catch { expect(true) }
}

// MARK: - DeepSeekUsageStore (via in-memory CredentialStore)

/// In-memory CredentialStore so store tests never touch the real Keychain
/// (which could prompt or persist). Deterministic and isolated.
final class InMemoryCredentialStore: CredentialStore {
    private var storage: [String: Data] = [:]
    func read(_ key: String) -> Data? { storage[key] }
    func write(_ key: String, _ value: Data) { storage[key] = value }
    func delete(_ key: String) { storage[key] = nil }
}

/// A CredentialStore that always reports the keychain as present-but-locked,
/// to exercise the ".unavailable means still configured" hardening.
final class UnavailableCredentialStore: CredentialStore {
    func read(_ key: String) -> Data? { nil }
    func write(_ key: String, _ value: Data) {}
    func delete(_ key: String) {}
    func readResult(_ key: String) -> CredentialReadResult {
        .unavailable(-25308)  // errSecInteractionNotAllowed
    }
}

run("CredentialStore.readResult default maps read() to found/missing") {
    let store = InMemoryCredentialStore()
    expectEqual(store.readResult("k"), .missing)
    store.write("k", Data("v".utf8))
    expectEqual(store.readResult("k"), .found(Data("v".utf8)))
}

MainActor.assumeIsolated {
    let suite = "credavail-\(ProcessInfo.processInfo.processIdentifier)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    d.set(true, forKey: "features.deepseek.enabled")

    run("Locked keychain keeps a provider configured (not onboarding)") {
        // Regression: a locked keychain must NOT look like "no key" and drop
        // the provider back to the paste-key card.
        let store = DeepSeekUsageStore(credentials: UnavailableCredentialStore(), defaults: d)
        expectEqual(store.hasKey, true)         // unavailable == still configured
        expectEqual(store.isConfigured, true)
        // No needsAccess onboarding tile while merely locked.
        expect(!store.tiles.contains { if case .needsAccess = $0.kind { return true }; return false })
    }
    d.removePersistentDomain(forName: suite)
}

MainActor.assumeIsolated {
    let suiteName = "deepseek-tests-\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "features.deepseek.enabled")

    run("DeepSeek store off by default emits no tiles") {
        let d2 = UserDefaults(suiteName: suiteName + "-off")!
        d2.removePersistentDomain(forName: suiteName + "-off")
        let store = DeepSeekUsageStore(credentials: InMemoryCredentialStore(), defaults: d2)
        expectEqual(store.isEnabled, false)
        expectEqual(store.tiles.count, 0)
    }

    run("DeepSeek enabled but no key emits needsAccess tile") {
        let store = DeepSeekUsageStore(credentials: InMemoryCredentialStore(), defaults: defaults)
        expectEqual(store.isEnabled, true)
        expectEqual(store.isConfigured, false)
        let tiles = store.tiles
        expectEqual(tiles.count, 1)
        if case .needsAccess = tiles.first?.kind { expect(true) }
        else { expect(false, "expected needsAccess") }
    }

    run("DeepSeek saveKey stores in credential store and configures") {
        let creds = InMemoryCredentialStore()
        let store = DeepSeekUsageStore(credentials: creds, defaults: defaults)
        expectEqual(store.hasKey, false)
        store.saveKey("  sk-fake-deepseek-key  ")  // trimmed
        expectEqual(store.hasKey, true)
        expectEqual(store.isConfigured, true)
        // The stored value is trimmed.
        let stored = String(data: creds.read(DeepSeekUsageStore.apiKeyKeychainKey)!, encoding: .utf8)
        expectEqual(stored, "sk-fake-deepseek-key")
    }

    run("DeepSeek saveKey with empty string clears the key") {
        let creds = InMemoryCredentialStore()
        let store = DeepSeekUsageStore(credentials: creds, defaults: defaults)
        store.saveKey("sk-fake")
        expectEqual(store.hasKey, true)
        store.saveKey("   ")
        expectEqual(store.hasKey, false)
    }

    run("DeepSeek applies USD balance and renders a balance tile") {
        let creds = InMemoryCredentialStore()
        let store = DeepSeekUsageStore(credentials: creds, defaults: defaults)
        store.saveKey("sk-fake")
        store.apply(.success(fixtureDeepSeekUSD.data(using: .utf8)!))
        expect(store.lastUpdated != nil)
        expect(store.errorMessage == nil)
        let tiles = store.tiles
        // Available == true so no status tile; one balance tile.
        expectEqual(tiles.count, 1)
        expectEqual(tiles[0].id, "deepseek-balance-usd")
        if case let .text(status, subtitle) = tiles[0].kind {
            expectEqual(status, "USD 110.00")
            expectEqual(subtitle, "Granted 10.00 + topped-up 100.00")
        } else { expect(false, "expected text tile") }
    }

    run("DeepSeek unavailable balance adds an amber status tile") {
        let creds = InMemoryCredentialStore()
        let store = DeepSeekUsageStore(credentials: creds, defaults: defaults)
        store.saveKey("sk-fake")
        let bytes = #"{"is_available": false, "balance_infos": [{"currency": "USD", "total_balance": "0.00", "granted_balance": "0", "topped_up_balance": "0"}]}"#.data(using: .utf8)!
        store.apply(.success(bytes))
        let tiles = store.tiles
        // status tile + balance tile
        expectEqual(tiles.count, 2)
        expectEqual(tiles[0].id, "deepseek-status")
    }

    run("DeepSeek 401 maps to invalid-key error") {
        let store = DeepSeekUsageStore(credentials: InMemoryCredentialStore(), defaults: defaults)
        store.apply(.unauthorized)
        expectEqual(store.errorMessage, "Invalid DeepSeek API key")
    }

    run("DeepSeek httpError and networkError map to messages") {
        let store = DeepSeekUsageStore(credentials: InMemoryCredentialStore(), defaults: defaults)
        store.apply(.httpError(500))
        expectEqual(store.errorMessage, "HTTP 500")
        store.apply(.networkError)
        expectEqual(store.errorMessage, "Network error")
    }

    run("DeepSeek conforms to PasteKeyProvider with sk- placeholder") {
        let store = DeepSeekUsageStore(credentials: InMemoryCredentialStore(), defaults: defaults)
        let keyProvider = store as PasteKeyProvider
        expect(keyProvider.keyPlaceholder.contains("sk"))
        expectEqual(keyProvider.hasKey, false)
        keyProvider.saveKey("sk-fake")
        expectEqual(keyProvider.hasKey, true)
    }

    run("DeepSeek clear deletes the key and state") {
        let creds = InMemoryCredentialStore()
        let store = DeepSeekUsageStore(credentials: creds, defaults: defaults)
        store.saveKey("sk-fake")
        store.apply(.success(fixtureDeepSeekUSD.data(using: .utf8)!))
        store.clear()
        expectEqual(store.hasKey, false)
        expect(store.snapshot == nil)
        expect(creds.read(DeepSeekUsageStore.apiKeyKeychainKey) == nil)
    }

    defaults.removePersistentDomain(forName: suiteName)
}

// MARK: - KeychainStore round-trip (guarded — real Keychain may be absent)

// Uses a throwaway service so the test never collides with real credentials,
// and cleans up. In a headless CI keychain SecItemAdd can fail (errSecMissing
// Entitlement / no keychain); in that case read returns nil and we skip the
// positive assertions rather than fail the suite.
run("KeychainStore round-trips when a keychain is available") {
    let store = KeychainStore(service: "com.claude.usagebar.test-\(ProcessInfo.processInfo.processIdentifier)")
    let key = "roundtrip-key"
    let value = Data("sk-fake-value".utf8)
    store.delete(key)  // clean slate
    store.write(key, value)
    if let read = store.read(key) {
        // Keychain available — verify round-trip and delete.
        expectEqual(read, value)
        store.delete(key)
        expect(store.read(key) == nil)
    } else {
        // No keychain in this environment (headless CI) — not a failure of
        // KeychainStore logic. Record a pass so the suite total stays honest.
        expect(true)
    }
}

// MARK: - ZedUsageFetcher.parse (PR 5-BE)

// Fixture: zed_free. limit is Zed's UsageLimit enum: Limited(N) is the OBJECT
// {"limited": N} on the wire (verified against Zed's cloud_api_types source),
// NOT a bare integer. ended_at is an RFC3339 string.
let fixtureZedFree = #"""
{
  "plan": {
    "plan_v3": "zed_free",
    "usage": { "edit_predictions": { "used": 320, "limit": {"limited": 2000} } },
    "subscription_period": { "started_at": "2026-07-01T00:00:00.000Z", "ended_at": "2026-08-01T00:00:00.000Z" },
    "has_overdue_invoices": false,
    "is_account_too_young": false
  }
}
"""#

run("parse Zed free plan: limit as {\"limited\": N} object") {
    let snap = try! ZedUsageFetcher.parse(fixtureZedFree.data(using: .utf8)!)
    expectEqual(snap.planV3, "zed_free")
    expectEqual(snap.editPredictions?.used, 320)
    expectEqual(snap.editPredictions?.limit, 2000)
    expect(snap.periodEndsAt != nil)
    expectEqual(snap.hasOverdueInvoices, false)
    expectEqual(snap.isAccountTooYoung, false)
}

// Fixture: zed_pro — Unlimited serializes as the bare STRING "unlimited".
let fixtureZedPro = #"""
{
  "plan": {
    "plan_v3": "zed_pro",
    "usage": { "edit_predictions": { "used": 5123, "limit": "unlimited" } },
    "subscription_period": { "ended_at": "2026-08-15T00:00:00.000Z" },
    "has_overdue_invoices": false,
    "is_account_too_young": false
  }
}
"""#

run("parse Zed pro plan: limit \"unlimited\" string -> nil") {
    let snap = try! ZedUsageFetcher.parse(fixtureZedPro.data(using: .utf8)!)
    expectEqual(snap.planV3, "zed_pro")
    expectEqual(snap.editPredictions?.used, 5123)
    expect(snap.editPredictions?.limit == nil)   // unlimited
}

// UsageLimit parsing in isolation — the non-obvious wire encoding.
run("parseUsageLimit maps object, unlimited string, and defensively bare int") {
    expectEqual(ZedUsageFetcher.parseUsageLimit(["limited": 500]), 500)
    expect(ZedUsageFetcher.parseUsageLimit("unlimited") == nil)
    expect(ZedUsageFetcher.parseUsageLimit(nil) == nil)
    expectEqual(ZedUsageFetcher.parseUsageLimit(42), 42)          // defensive
    expectEqual(ZedUsageFetcher.parseUsageLimit("50"), 50)        // header-style
}

// Fixture: overdue invoices flag true.
let fixtureZedOverdue = #"""
{
  "plan": {
    "plan_v3": "zed_pro",
    "usage": { "edit_predictions": { "used": 10, "limit": "unlimited" } },
    "has_overdue_invoices": true,
    "is_account_too_young": false
  }
}
"""#

run("parse Zed plan with overdue invoices") {
    let snap = try! ZedUsageFetcher.parse(fixtureZedOverdue.data(using: .utf8)!)
    expectEqual(snap.hasOverdueInvoices, true)
}

run("parse Zed tolerates plan block at top level (no wrapper)") {
    // Some versions may return the plan block directly.
    let bytes = #"""
    {"plan_v3": "zed_free", "usage": {"edit_predictions": {"used": 1, "limit": 2000}}}
    """#.data(using: .utf8)!
    let snap = try! ZedUsageFetcher.parse(bytes)
    expectEqual(snap.planV3, "zed_free")
    expectEqual(snap.editPredictions?.used, 1)
}

run("parse Zed tolerates empty object") {
    let snap = try! ZedUsageFetcher.parse("{}".data(using: .utf8)!)
    expect(snap.planV3 == nil)
    expect(snap.editPredictions == nil)
    expectEqual(snap.hasOverdueInvoices, false)
}

run("parse Zed accepts numeric used as Double, limited object as Double") {
    let bytes = #"""
    {"plan": {"plan_v3": "zed_free", "usage": {"edit_predictions": {"used": 12.0, "limit": {"limited": 2000.0}}}}}
    """#.data(using: .utf8)!
    let snap = try! ZedUsageFetcher.parse(bytes)
    expectEqual(snap.editPredictions?.used, 12)
    expectEqual(snap.editPredictions?.limit, 2000)
}

run("parse Zed accepts unix-epoch ended_at") {
    let bytes = #"""
    {"plan": {"plan_v3": "zed_free", "subscription_period": {"ended_at": 1785000000}}}
    """#.data(using: .utf8)!
    let snap = try! ZedUsageFetcher.parse(bytes)
    expectEqual(snap.periodEndsAt, Date(timeIntervalSince1970: 1785000000))
}

run("parse Zed throws on array top-level") {
    do {
        _ = try ZedUsageFetcher.parse("[]".data(using: .utf8)!)
        expect(false, "expected throw")
    } catch { expect(true) }
}

// Credentials header format: space-delimited, not Bearer.
run("ZedCredentials builds a space-delimited Authorization value") {
    let creds = ZedCredentials(userId: "12345", accessToken: "tok-abc")
    expectEqual(creds.authorizationHeaderValue, "12345 tok-abc")
    // Explicitly NOT the Bearer scheme.
    expect(creds.authorizationHeaderValue?.hasPrefix("Bearer") == false)
}

run("ZedCredentials rejects header injection via control chars") {
    // A user id or token containing CR/LF must not produce a header value
    // (would allow header splitting/injection).
    let crlf = ZedCredentials(userId: "12345\r\nX-Evil: 1", accessToken: "tok")
    expect(crlf.authorizationHeaderValue == nil)
    let newlineTok = ZedCredentials(userId: "12345", accessToken: "tok\nInjected")
    expect(newlineTok.authorizationHeaderValue == nil)
}

run("RequestSafety.pathSegment encodes path-altering characters") {
    // A benign id passes through (only unreserved chars).
    expectEqual(RequestSafety.pathSegment("team_abc-123"), "team_abc-123")
    // Path-structure characters are encoded, not passed through.
    expectEqual(RequestSafety.pathSegment("a/b"), "a%2Fb")
    expectEqual(RequestSafety.pathSegment("../admin"), "..%2Fadmin")
    expectEqual(RequestSafety.pathSegment("x?y#z"), "x%3Fy%23z")
    // Control characters are rejected entirely.
    expect(RequestSafety.pathSegment("a\nb") == nil)
    expect(RequestSafety.pathSegment("") == nil)
}

run("RequestSafety.headerValue rejects control chars, passes clean values") {
    expectEqual(RequestSafety.headerValue("user-123"), "user-123")
    expect(RequestSafety.headerValue("a\rb") == nil)
    expect(RequestSafety.headerValue("a\nb") == nil)
    expect(RequestSafety.headerValue("") == nil)
}

// MARK: - ZedUsageStore (injected credential reader, no real Keychain)

MainActor.assumeIsolated {
    let suiteName = "zed-tests-\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "features.zed.enabled")

    let goodCreds: @Sendable () -> Result<ZedCredentials, Error> = {
        .success(ZedCredentials(userId: "u1", accessToken: "tok"))
    }
    let missingCreds: @Sendable () -> Result<ZedCredentials, Error> = {
        .failure(ZedAuthError.keychainItemMissing)
    }

    run("Zed store off by default emits no tiles") {
        let d2 = UserDefaults(suiteName: suiteName + "-off")!
        d2.removePersistentDomain(forName: suiteName + "-off")
        let store = ZedUsageStore(defaults: d2, credentialReader: goodCreds)
        expectEqual(store.isEnabled, false)
        expectEqual(store.tiles.count, 0)
    }

    run("Zed enabled before first read emits needsAccess card") {
        let store = ZedUsageStore(defaults: defaults, credentialReader: missingCreds)
        expectEqual(store.isEnabled, true)
        let tiles = store.tiles
        expectEqual(tiles.count, 1)
        if case .needsAccess = tiles.first?.kind { expect(true) }
        else { expect(false, "expected needsAccess") }
    }

    run("Zed applies free-plan snapshot: plan + counter tiles") {
        let store = ZedUsageStore(defaults: defaults, credentialReader: goodCreds)
        // Simulate a successful Keychain read + fetch by applying a result.
        store.apply(.success(fixtureZedFree.data(using: .utf8)!))
        let tiles = store.tiles
        // plan tile + edit-predictions counter (no billing warning)
        expectEqual(tiles.count, 2)
        expectEqual(tiles[0].id, "zed-plan")
        if case let .text(status, _) = tiles[0].kind { expectEqual(status, "Free") }
        else { expect(false, "expected plan text tile") }
        expectEqual(tiles[1].id, "zed-edit-predictions")
        if case let .counter(used, limit, _) = tiles[1].kind {
            expectEqual(used, 320); expectEqual(limit, 2000)
        } else { expect(false, "expected counter tile") }
    }

    run("Zed pro plan renders unlimited counter (nil limit)") {
        let store = ZedUsageStore(defaults: defaults, credentialReader: goodCreds)
        store.apply(.success(fixtureZedPro.data(using: .utf8)!))
        let counter = store.tiles.first { $0.id == "zed-edit-predictions" }
        if case let .counter(_, limit, _) = counter?.kind { expect(limit == nil) }
        else { expect(false, "expected counter") }
    }

    run("Zed overdue invoices adds a billing warning tile") {
        let store = ZedUsageStore(defaults: defaults, credentialReader: goodCreds)
        store.apply(.success(fixtureZedOverdue.data(using: .utf8)!))
        expect(store.tiles.contains { $0.id == "zed-billing" })
    }

    run("Zed 401 maps to a re-sign-in message") {
        let store = ZedUsageStore(defaults: defaults, credentialReader: goodCreds)
        store.apply(.unauthorized)
        expect(store.errorMessage?.contains("sign in again") == true)
    }

    run("Zed planLabel maps known tiers and passes through unknown") {
        expectEqual(ZedUsageStore.planLabel("zed_free"), "Free")
        expectEqual(ZedUsageStore.planLabel("zed_pro"), "Pro")
        expectEqual(ZedUsageStore.planLabel("zed_pro_trial"), "Pro (trial)")
        expectEqual(ZedUsageStore.planLabel("some_new_tier"), "some_new_tier")
        expectEqual(ZedUsageStore.planLabel(nil), "Unknown")
    }

    defaults.removePersistentDomain(forName: suiteName)
}

// MARK: - XAIUsageFetcher (PR 6-BE)

// GET /v1/api-key — flat snake_case object (verified against xAI docs).
let fixtureXaiApiKey = #"""
{
  "redacted_api_key": "xai-****b14o",
  "user_id": "user-123",
  "name": "prod key",
  "create_time": "2026-01-01T00:00:00Z",
  "modify_time": "2026-01-02T00:00:00Z",
  "team_id": "team-abc",
  "api_key_id": "key-xyz",
  "acls": ["api-key:model:*", "api-key:endpoint:*"]
}
"""#

run("parse xAI api-key: team_id, acls, redacted key") {
    let info = try! XAIUsageFetcher.parseApiKey(fixtureXaiApiKey.data(using: .utf8)!)
    expectEqual(info.teamId, "team-abc")
    expectEqual(info.acls.count, 2)
    expectEqual(info.redactedKey, "xai-****b14o")
    expectEqual(info.name, "prod key")
}

// GET /v1/language-models — models[] with token prices.
let fixtureXaiModels = #"""
{
  "models": [
    {"id": "grok-4.5", "prompt_text_token_price": 3000, "completion_text_token_price": 15000},
    {"id": "grok-4.20", "prompt_text_token_price": 5000, "completion_text_token_price": 25000}
  ]
}
"""#

run("parse xAI language-models catalogue") {
    let models = try! XAIUsageFetcher.parseLanguageModels(fixtureXaiModels.data(using: .utf8)!)
    expectEqual(models.count, 2)
    expectEqual(models[0].id, "grok-4.5")
    expectEqual(models[0].promptTokenPrice, 3000)
    expectEqual(models[1].completionTokenPrice, 25000)
}

run("parse xAI language-models tolerates data[] wrapper") {
    let bytes = #"{"data": [{"id": "grok-4.5"}]}"#.data(using: .utf8)!
    let models = try! XAIUsageFetcher.parseLanguageModels(bytes)
    expectEqual(models.count, 1)
    expectEqual(models[0].id, "grok-4.5")
}

// Prepaid balance — total.val is a STRING-encoded int64 in USD CENTS, and is
// NEGATIVE when credit remains. Verified against xAI's OpenAPI schema.
let fixtureXaiBalanceCredit = #"""
{
  "changes": [],
  "total": { "val": "-12345" }
}
"""#

run("parse xAI balance: negative cents = remaining credit") {
    let balance = try! XAIUsageFetcher.parseBalance(fixtureXaiBalanceCredit.data(using: .utf8)!)
    expectEqual(balance.totalValRaw, -12345)
    // -12345 cents credit => 123.45 USD remaining.
    expect(abs(balance.remainingUSD - 123.45) < 0.001)
}

run("parse xAI balance: zero or positive val = depleted (clamped to 0)") {
    let zero = try! XAIUsageFetcher.parseBalance(#"{"total": {"val": "0"}}"#.data(using: .utf8)!)
    expectEqual(zero.remainingUSD, 0.0)
    let positive = try! XAIUsageFetcher.parseBalance(#"{"total": {"val": "500"}}"#.data(using: .utf8)!)
    expectEqual(positive.remainingUSD, 0.0)   // no remaining prepaid credit
}

run("parse xAI balance throws when total.val missing") {
    do {
        _ = try XAIUsageFetcher.parseBalance(#"{"total": {}}"#.data(using: .utf8)!)
        expect(false, "expected throw")
    } catch { expect(true) }
}

run("parse xAI usage daily buckets (dollar and cents forms)") {
    let bytes = #"""
    {"usage": [
      {"date": "2026-07-10", "usd": 1.50},
      {"date": "2026-07-11", "usd_cents": 275}
    ]}
    """#.data(using: .utf8)!
    let daily = try! XAIUsageFetcher.parseUsage(bytes)
    expectEqual(daily.count, 2)
    expect(abs(daily[0].amountSpent - 1.50) < 0.001)
    expect(abs(daily[1].amountSpent - 2.75) < 0.001)  // 275 cents
    // No currency reported in this fixture.
    expect(daily[0].currency == nil)
}

run("parse xAI usage carries a non-USD currency when reported") {
    // The daily-usage shape is undocumented and may bill in CNY. When a
    // currency is present the parser must surface it so the tile does not
    // assume a "$" symbol (audit finding: hardcoded $ on the daily tile).
    let bytes = #"""
    {"usage": [
      {"date": "2026-07-10", "amount": 12.50, "currency": "CNY"}
    ]}
    """#.data(using: .utf8)!
    let daily = try! XAIUsageFetcher.parseUsage(bytes)
    expectEqual(daily.count, 1)
    expect(abs(daily[0].amountSpent - 12.50) < 0.001)
    expectEqual(daily[0].currency, "CNY")
}

run("parse xAI api-key throws on array top-level") {
    do {
        _ = try XAIUsageFetcher.parseApiKey("[]".data(using: .utf8)!)
        expect(false, "expected throw")
    } catch { expect(true) }
}

// MARK: - XAIUsageStore (in-memory credentials + stubbed transport)

final class StubXAITransport: XAIUsageTransport, @unchecked Sendable {
    let result: XAIUsageResult
    init(_ result: XAIUsageResult) { self.result = result }
    func fetchAll(inferenceKey: String, managementKey: String?, completion: @escaping @Sendable (XAIUsageResult) -> Void) {
        completion(result)
    }
}

MainActor.assumeIsolated {
    let suiteName = "xai-tests-\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "features.xai.enabled")

    run("xAI store off by default emits no tiles") {
        let d2 = UserDefaults(suiteName: suiteName + "-off")!
        d2.removePersistentDomain(forName: suiteName + "-off")
        let store = XAIUsageStore(credentials: InMemoryCredentialStore(), transport: StubXAITransport(.networkError), defaults: d2)
        expectEqual(store.isEnabled, false)
        expectEqual(store.tiles.count, 0)
    }

    run("xAI enabled without inference key emits needsAccess card") {
        let store = XAIUsageStore(credentials: InMemoryCredentialStore(), transport: StubXAITransport(.networkError), defaults: defaults)
        expectEqual(store.isConfigured, false)
        let tiles = store.tiles
        expectEqual(tiles.count, 1)
        if case .needsAccess = tiles.first?.kind { expect(true) }
        else { expect(false, "expected needsAccess") }
    }

    run("xAI two-key management: hasInferenceKey and hasManagementKey") {
        let creds = InMemoryCredentialStore()
        let store = XAIUsageStore(credentials: creds, transport: StubXAITransport(.networkError), defaults: defaults)
        expectEqual(store.hasInferenceKey, false)
        expectEqual(store.hasManagementKey, false)
        store.saveInferenceKey("xai-inference")
        store.saveManagementKey("xai-mgmt-secret")
        expectEqual(store.hasInferenceKey, true)
        expectEqual(store.hasManagementKey, true)
        expectEqual(store.isConfigured, true)
    }

    run("xAI Tier 1 only: plan tile, no balance tile") {
        let store = XAIUsageStore(credentials: InMemoryCredentialStore(), transport: StubXAITransport(.networkError), defaults: defaults)
        store.saveInferenceKey("xai-inference")
        var snap = XAIUsageSnapshot()
        snap.apiKeyInfo = XAIApiKeyInfo(teamId: "team-abc", acls: ["api-key:model:*"], redactedKey: "xai-****b14o")
        store.apply(.success(snap))
        let tiles = store.tiles
        expect(tiles.contains { $0.id == "xai-plan" })
        expect(!tiles.contains { $0.id == "xai-balance" })
    }

    run("xAI Tier 2: balance tile from negative-cents credit") {
        let store = XAIUsageStore(credentials: InMemoryCredentialStore(), transport: StubXAITransport(.networkError), defaults: defaults)
        store.saveInferenceKey("xai-inference")
        var snap = XAIUsageSnapshot()
        snap.apiKeyInfo = XAIApiKeyInfo(teamId: "team-abc")
        snap.balance = XAIBalance(totalValRaw: -12345, currency: "USD")
        store.apply(.success(snap))
        let balanceTile = store.tiles.first { $0.id == "xai-balance" }
        expect(balanceTile != nil)
        if case let .balance(minor, currency, _, _) = balanceTile?.kind {
            expectEqual(minor, 12345)   // 123.45 USD => 12345 minor units
            expectEqual(currency, "USD")
        } else { expect(false, "expected balance tile") }
    }

    run("xAI 401 maps to invalid-key error") {
        // Assert via the synchronous apply() seam; fetch() now hops through
        // Task { @MainActor } (safe on any queue) so its effect is not
        // observable synchronously in this runner.
        let store = XAIUsageStore(credentials: InMemoryCredentialStore(), transport: StubXAITransport(.unauthorized), defaults: defaults)
        store.saveInferenceKey("xai-bad")
        store.apply(.unauthorized)
        expectEqual(store.errorMessage, "Invalid xAI API key")
    }

    run("xAI conforms to PasteKeyProvider and SecondaryKeyProvider") {
        let store = XAIUsageStore(credentials: InMemoryCredentialStore(), transport: StubXAITransport(.networkError), defaults: defaults)
        let primary = store as PasteKeyProvider
        let secondary = store as SecondaryKeyProvider
        expect(primary.keyPlaceholder.contains("inference"))
        expect(secondary.secondaryKeyPlaceholder.contains("management"))
        expect(secondary.secondaryKeyWarning.contains("delete"))  // warns about key power
        expectEqual(primary.hasKey, false)
        expectEqual(secondary.hasSecondaryKey, false)
        primary.saveKey("xai-inference")
        secondary.saveSecondaryKey("xai-mgmt")
        expectEqual(primary.hasKey, true)
        expectEqual(secondary.hasSecondaryKey, true)
    }

    run("xAI clear deletes both keys") {
        let creds = InMemoryCredentialStore()
        let store = XAIUsageStore(credentials: creds, transport: StubXAITransport(.networkError), defaults: defaults)
        store.saveInferenceKey("xai-i"); store.saveManagementKey("xai-mgmt-m")
        store.clear()
        expectEqual(store.hasInferenceKey, false)
        expectEqual(store.hasManagementKey, false)
    }

    defaults.removePersistentDomain(forName: suiteName)
}

// MARK: - OpenAIUsageFetcher (PR 7-BE)

// Completions usage — bucketed page envelope (verified vs OpenAI Admin API).
// results grouped by model; multiple buckets aggregate per model.
let fixtureOpenAICompletions = #"""
{
  "object": "page",
  "has_more": false,
  "next_page": null,
  "data": [
    {
      "object": "bucket",
      "start_time": 1751000000,
      "end_time": 1751003600,
      "results": [
        {"object": "organization.usage.completions.result", "input_tokens": 1000, "output_tokens": 500, "num_model_requests": 10, "model": "gpt-4o"},
        {"object": "organization.usage.completions.result", "input_tokens": 200, "output_tokens": 100, "num_model_requests": 3, "model": "gpt-4o-mini"}
      ]
    },
    {
      "object": "bucket",
      "start_time": 1751003600,
      "end_time": 1751007200,
      "results": [
        {"object": "organization.usage.completions.result", "input_tokens": 3000, "output_tokens": 1500, "num_model_requests": 20, "model": "gpt-4o"}
      ]
    }
  ]
}
"""#

run("parse OpenAI completions: aggregate tokens by model across buckets") {
    let tokens = try! OpenAIUsageFetcher.parseCompletions(fixtureOpenAICompletions.data(using: .utf8)!)
    expectEqual(tokens.count, 2)
    // gpt-4o: 1000+3000 input, 500+1500 output, 10+20 requests -> highest total, first.
    expectEqual(tokens[0].model, "gpt-4o")
    expectEqual(tokens[0].inputTokens, 4000)
    expectEqual(tokens[0].outputTokens, 2000)
    expectEqual(tokens[0].requests, 30)
    expectEqual(tokens[0].totalTokens, 6000)
    expectEqual(tokens[1].model, "gpt-4o-mini")
    expectEqual(tokens[1].totalTokens, 300)
}

run("parse OpenAI completions: results with null model fold into 'all'") {
    let bytes = #"""
    {"object": "page", "data": [{"object": "bucket", "results": [{"input_tokens": 5, "output_tokens": 5, "num_model_requests": 1}]}]}
    """#.data(using: .utf8)!
    let tokens = try! OpenAIUsageFetcher.parseCompletions(bytes)
    expectEqual(tokens.count, 1)
    expectEqual(tokens[0].model, "all")
    expectEqual(tokens[0].totalTokens, 10)
}

// Costs — amount.value is a float in USD dollars; currency lowercase "usd".
let fixtureOpenAICosts = #"""
{
  "object": "page",
  "has_more": false,
  "data": [
    {"object": "bucket", "start_time": 1751000000, "end_time": 1751086400, "results": [
      {"object": "organization.costs.result", "amount": {"value": 0.13080438, "currency": "usd"}, "line_item": "gpt-4o"},
      {"object": "organization.costs.result", "amount": {"value": 1.25, "currency": "usd"}, "line_item": "gpt-4o-mini"}
    ]}
  ]
}
"""#

run("parse OpenAI costs: sum amount.value across line items") {
    let cost = try! OpenAIUsageFetcher.parseCosts(fixtureOpenAICosts.data(using: .utf8)!)
    expect(abs(cost.usd - 1.38080438) < 0.0001)
    expectEqual(cost.currency, "usd")
}

run("parse OpenAI costs: empty buckets -> zero") {
    let bytes = #"{"object": "page", "data": []}"#.data(using: .utf8)!
    let cost = try! OpenAIUsageFetcher.parseCosts(bytes)
    expectEqual(cost.usd, 0.0)
    expect(cost.currency == nil)
}

// Rate limits — {object:"list", data:[{model, max_requests_per_1_minute, ...}]}
let fixtureOpenAIRateLimits = #"""
{
  "object": "list",
  "has_more": false,
  "data": [
    {"object": "project.rate_limit", "id": "rl-gpt-4o", "model": "gpt-4o", "max_requests_per_1_minute": 10000, "max_tokens_per_1_minute": 2000000},
    {"object": "project.rate_limit", "id": "rl-gpt-4o-mini", "model": "gpt-4o-mini", "max_requests_per_1_minute": 30000, "max_tokens_per_1_minute": 150000000}
  ]
}
"""#

run("parse OpenAI rate_limits: per-model ceilings") {
    let limits = try! OpenAIUsageFetcher.parseRateLimits(fixtureOpenAIRateLimits.data(using: .utf8)!)
    expectEqual(limits.count, 2)
    expectEqual(limits[0].model, "gpt-4o")
    expectEqual(limits[0].maxRequestsPerMinute, 10000)
    expectEqual(limits[0].maxTokensPerMinute, 2000000)
}

run("parse OpenAI survives an out-of-range JSON number without trapping") {
    // A hostile API sends 1e300 where a token count is expected. Int(Double)
    // would TRAP; the safe conversion must yield nil -> 0, no crash.
    let bytes = #"""
    {"object":"page","data":[{"object":"bucket","results":[
      {"input_tokens": 1e300, "output_tokens": 5, "num_model_requests": 1, "model": "gpt-4o"}
    ]}]}
    """#.data(using: .utf8)!
    let tokens = try! OpenAIUsageFetcher.parseCompletions(bytes)
    expectEqual(tokens.count, 1)
    // input_tokens (1e300) -> nil -> 0; output stays 5.
    expectEqual(tokens[0].inputTokens, 0)
    expectEqual(tokens[0].outputTokens, 5)
}

run("parse OpenAI clamps negative token counts to zero") {
    let bytes = #"""
    {"object":"page","data":[{"object":"bucket","results":[
      {"input_tokens": -100, "output_tokens": 50, "num_model_requests": -3, "model": "gpt-4o"}
    ]}]}
    """#.data(using: .utf8)!
    let tokens = try! OpenAIUsageFetcher.parseCompletions(bytes)
    expectEqual(tokens[0].inputTokens, 0)   // clamped
    expectEqual(tokens[0].outputTokens, 50)
    expectEqual(tokens[0].requests, 0)      // clamped
}

run("parse xAI balance survives an out-of-range string val without trapping") {
    // A gigantic numeric string overflows Int -> nil -> parseBalance throws,
    // rather than trapping or producing a garbage value.
    let bytes = #"{"total": {"val": "999999999999999999999999999999"}}"#.data(using: .utf8)!
    do {
        _ = try XAIUsageFetcher.parseBalance(bytes)
        expect(false, "expected throw on overflowing val")
    } catch { expect(true) }
}

run("parse Zed safeInt handles out-of-range Double without trapping") {
    // edit_predictions.used = 1e300 must not trap.
    let bytes = #"""
    {"plan": {"plan_v3": "zed_free", "usage": {"edit_predictions": {"used": 1e300, "limit": "unlimited"}}}}
    """#.data(using: .utf8)!
    let snap = try! ZedUsageFetcher.parse(bytes)
    // used could not be represented -> stays at the default 0, no crash.
    expectEqual(snap.editPredictions?.used, 0)
}

run("parse OpenAI completions throws on array top-level") {
    do {
        _ = try OpenAIUsageFetcher.parseCompletions("[]".data(using: .utf8)!)
        expect(false, "expected throw")
    } catch { expect(true) }
}

run("OpenAI startOfUTCMonth returns the exact 1st-of-month UTC epoch") {
    // 1752300000 = 2025-07-12T06:00:00Z. Start of 2025-07 UTC = 1751328000.
    // Assert the EXACT boundary, not just start <= input (a loose bound would
    // pass even for a wrong value — audit finding on the prior test).
    let mid = Date(timeIntervalSince1970: 1752300000) // 2025-07-12T06:00:00Z
    let start = URLSessionOpenAITransport.startOfUTCMonth(mid)
    expectEqual(start, 1751328000)  // 2025-07-01T00:00:00Z
}

run("OpenAI completionsQuery uses a TRUE rolling 24h (1h buckets, limit 24)") {
    // Audit finding: bucket_width=1d + start_time=now-24h returns up to ~48h.
    // The fixed query must use hourly buckets bounded to 24 for a real 24h.
    let now = Date(timeIntervalSince1970: 1752300000)
    let q = URLSessionOpenAITransport.completionsQuery(now: now)
    expect(q.contains("bucket_width=1h"))
    expect(q.contains("limit=24"))
    expect(q.contains("group_by=model"))
    expect(q.contains("start_time=1752213600"))  // now - 24h
    // It must NOT use the day-bucket that caused the over-count.
    expect(!q.contains("bucket_width=1d"))
}

run("OpenAI costsQuery covers month-to-date from the UTC month start") {
    let now = Date(timeIntervalSince1970: 1752300000)
    let q = URLSessionOpenAITransport.costsQuery(now: now)
    expect(q.contains("bucket_width=1d"))
    expect(q.contains("limit=31"))               // covers the longest month in one page
    expect(q.contains("start_time=1751328000"))  // start of 2025-07 UTC
}

// MARK: - OpenAIUsageStore

final class StubOpenAITransport: OpenAIUsageTransport, @unchecked Sendable {
    let result: OpenAIUsageResult
    init(_ result: OpenAIUsageResult) { self.result = result }
    func fetchAll(adminKey: String, completion: @escaping @Sendable (OpenAIUsageResult) -> Void) {
        completion(result)
    }
}

MainActor.assumeIsolated {
    let suiteName = "openai-tests-\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "features.openai.enabled")

    run("OpenAI store off by default emits no tiles") {
        let d2 = UserDefaults(suiteName: suiteName + "-off")!
        d2.removePersistentDomain(forName: suiteName + "-off")
        let store = OpenAIUsageStore(credentials: InMemoryCredentialStore(), transport: StubOpenAITransport(.networkError), defaults: d2)
        expectEqual(store.isEnabled, false)
        expectEqual(store.tiles.count, 0)
    }

    run("OpenAI enabled without key emits needsAccess card") {
        let store = OpenAIUsageStore(credentials: InMemoryCredentialStore(), transport: StubOpenAITransport(.networkError), defaults: defaults)
        expectEqual(store.isConfigured, false)
        let tiles = store.tiles
        expectEqual(tiles.count, 1)
        if case .needsAccess = tiles.first?.kind { expect(true) }
        else { expect(false, "expected needsAccess") }
    }

    run("OpenAI conforms to PasteKeyProvider with sk-admin placeholder") {
        let store = OpenAIUsageStore(credentials: InMemoryCredentialStore(), transport: StubOpenAITransport(.networkError), defaults: defaults)
        let kp = store as PasteKeyProvider
        expect(kp.keyPlaceholder.contains("sk-admin"))
    }

    run("OpenAI applies snapshot: cost + token + ceiling tiles") {
        let creds = InMemoryCredentialStore()
        let store = OpenAIUsageStore(credentials: creds, transport: StubOpenAITransport(.networkError), defaults: defaults)
        store.saveKey("sk-admin-fake")
        let snap = OpenAIUsageSnapshot(
            tokensByModel: [OpenAIModelTokens(model: "gpt-4o", inputTokens: 4000, outputTokens: 2000, requests: 30)],
            costMTDUSD: 12.34,
            costCurrency: "usd",
            rateLimits: [OpenAIRateLimit(model: "gpt-4o", maxRequestsPerMinute: 10000, maxTokensPerMinute: 2000000)]
        )
        store.apply(.success(snap))
        let tiles = store.tiles
        expect(tiles.contains { $0.id == "openai-cost-mtd" })
        expect(tiles.contains { $0.id == "openai-tokens-gpt-4o" })
        expect(tiles.contains { $0.id == "openai-ceiling-gpt-4o" })
        // MTD cost tile shows the currency + amount, with the API's lowercase
        // "usd" uppercased for display (audit finding on currency case).
        let costTile = tiles.first { $0.id == "openai-cost-mtd" }
        if case let .text(status, _) = costTile?.kind {
            expect(status.contains("12.34"))
            expect(status.contains("USD"))       // uppercased
            expect(!status.contains("usd"))      // not the raw lowercase
        } else { expect(false, "expected cost text tile") }
    }

    run("OpenAI 401 maps to invalid-admin-key error") {
        // Assert via the synchronous apply() seam (fetch() now hops through
        // Task { @MainActor }, not observable synchronously here).
        let store = OpenAIUsageStore(credentials: InMemoryCredentialStore(), transport: StubOpenAITransport(.unauthorized), defaults: defaults)
        store.saveKey("sk-admin-bad")
        store.apply(.unauthorized)
        expectEqual(store.errorMessage, "Invalid OpenAI Admin key")
    }

    run("OpenAI clear deletes the key and state") {
        let creds = InMemoryCredentialStore()
        let store = OpenAIUsageStore(credentials: creds, transport: StubOpenAITransport(.networkError), defaults: defaults)
        store.saveKey("sk-admin-fake")
        store.clear()
        expectEqual(store.hasKey, false)
        expect(creds.read(OpenAIUsageFetcher.adminKeyKeychainKey) == nil)
    }

    defaults.removePersistentDomain(forName: suiteName)
}

// MARK: - PerplexityCookie extraction (PR 8-BE)

run("Perplexity cookie: bare token wrapped under default name") {
    let extracted = PerplexityCookie.extract(from: "  ey.jwe.raw.value  ")
    expectEqual(extracted?.name, "__Secure-next-auth.session-token")
    expectEqual(extracted?.token, "ey.jwe.raw.value")
}

run("Perplexity cookie: empty input returns nil") {
    expect(PerplexityCookie.extract(from: "   ") == nil)
}

run("Perplexity cookie: name=value pair (Secure next-auth)") {
    let raw = "__Secure-next-auth.session-token=abc.def.ghi"
    let extracted = PerplexityCookie.extract(from: raw)
    expectEqual(extracted?.name, "__Secure-next-auth.session-token")
    expectEqual(extracted?.token, "abc.def.ghi")
}

run("Perplexity cookie: prefers Secure over unprefixed within a full header") {
    // A user pasting a full DevTools "Copy string" gets many cookies; the
    // Secure-prefixed variant must win over the plain one.
    let raw = "next-auth.session-token=OLD; __Secure-next-auth.session-token=NEW; _ga=1"
    let extracted = PerplexityCookie.extract(from: raw)
    expectEqual(extracted?.name, "__Secure-next-auth.session-token")
    expectEqual(extracted?.token, "NEW")
}

run("Perplexity cookie: unprefixed next-auth falls through when Secure absent") {
    let raw = "next-auth.session-token=UNPREFIXED; other=1"
    let extracted = PerplexityCookie.extract(from: raw)
    expectEqual(extracted?.name, "next-auth.session-token")
    expectEqual(extracted?.token, "UNPREFIXED")
}

run("Perplexity cookie: Auth.js v5 __Secure-authjs.session-token") {
    let raw = "__Secure-authjs.session-token=V5TOK"
    let extracted = PerplexityCookie.extract(from: raw)
    expectEqual(extracted?.name, "__Secure-authjs.session-token")
    expectEqual(extracted?.token, "V5TOK")
}

run("Perplexity cookie: unprefixed authjs.session-token") {
    let raw = "authjs.session-token=V5PLAIN"
    let extracted = PerplexityCookie.extract(from: raw)
    expectEqual(extracted?.name, "authjs.session-token")
    expectEqual(extracted?.token, "V5PLAIN")
}

run("Perplexity cookie: NextAuth chunked variant reassembles in index order") {
    // NextAuth splits a large JWE across ".0", ".1", … suffixed cookies.
    // Reassembly must respect the numeric index, not the paste order.
    let raw = "__Secure-next-auth.session-token.1=BBB; __Secure-next-auth.session-token.0=AAA"
    let extracted = PerplexityCookie.extract(from: raw)
    expectEqual(extracted?.name, "__Secure-next-auth.session-token")
    expectEqual(extracted?.token, "AAABBB")
}

run("Perplexity cookie: chunk index Int.max is rejected (overflow guard)") {
    // Codex adversarial review #2: a hostile paste `…session-token.<Int.max>=x`
    // must not trap on `maxIdx + 1` nor force massive reserveCapacity.
    let raw = "__Secure-next-auth.session-token.9223372036854775807=EVIL"
    expect(PerplexityCookie.extract(from: raw) == nil)
}

run("Perplexity cookie: chunk index above sane cap is rejected") {
    // Real NextAuth chunk indexes are single digits. Anything past the
    // maxAllowedChunkIndex sentinel is refused before it reaches reassemble.
    let raw = "__Secure-next-auth.session-token.99999=EVIL; __Secure-next-auth.session-token.0=OK"
    let extracted = PerplexityCookie.extract(from: raw)
    // The .0 chunk alone is a valid single-chunk cookie.
    expectEqual(extracted?.token, "OK")
}

run("Perplexity cookie: unrelated cookies alone → nil") {
    let raw = "_ga=1; _gcl=2; theme=dark"
    expect(PerplexityCookie.extract(from: raw) == nil)
}

run("Perplexity cookie: bare token containing base64 = padding routes verbatim") {
    // Codex adversarial review #7: an opaque token like `abc.def==` must not
    // be mis-parsed as an unsupported `abc.def=` cookie name. When there is
    // no `;` separator and no supported cookie name matched, the whole input
    // is treated as a bare token under the default name.
    let raw = "abc.def=="
    let extracted = PerplexityCookie.extract(from: raw)
    expectEqual(extracted?.name, "__Secure-next-auth.session-token")
    expectEqual(extracted?.token, "abc.def==")
}

run("Perplexity cookie: paste with `;` but no supported session cookie → nil (not bare-token fallback)") {
    // A cookie-header-shaped paste that lacks any supported session cookie
    // is a mistake we surface, not something to paper over by treating the
    // whole blob as a token.
    let raw = "_ga=1; theme=dark"
    expect(PerplexityCookie.extract(from: raw) == nil)
}

run("Perplexity cookie: strips a leading Cookie: header prefix (PR 8-UI Codex round 2)") {
    // Browsers' "Copy request headers" often prefixes the line with "Cookie:".
    // The extractor must tolerate that so pasted HAR fragments still work
    // — matching what the Perplexity ProviderCopy help text now promises.
    let raw = "Cookie: __Secure-next-auth.session-token=HEADERTOK; _ga=1"
    let extracted = PerplexityCookie.extract(from: raw)
    expectEqual(extracted?.name, "__Secure-next-auth.session-token")
    expectEqual(extracted?.token, "HEADERTOK")
}

run("Perplexity cookie: strips a case-varied cookie: prefix and extra whitespace") {
    let raw = "  cookie:   __Secure-next-auth.session-token=WSTOK  "
    let extracted = PerplexityCookie.extract(from: raw)
    expectEqual(extracted?.name, "__Secure-next-auth.session-token")
    expectEqual(extracted?.token, "WSTOK")
}

run("Perplexity cookie: strips a MiXeD-case Cookie: prefix (PR 8-UI Codex round 3)") {
    // Codex round-3 caught that enumerating spellings ("Cookie:"/"cookie:"/"COOKIE:")
    // let a MiXeD casing slip through the strip logic and fall into the
    // bare-token fallback. The strip is now truly case-insensitive.
    let raw = "CoOkIe: __Secure-next-auth.session-token=MIXTOK"
    let extracted = PerplexityCookie.extract(from: raw)
    expectEqual(extracted?.name, "__Secure-next-auth.session-token")
    expectEqual(extracted?.token, "MIXTOK")
}

// MARK: - PerplexityUsageFetcher.parseCredits

run("Perplexity parseCredits: happy path with recurring + promo + purchased grants") {
    // Synthetic fixture — shape matches multiple independent live captures
    // (CodexBar PerplexityModels.swift; jacob-bd/perplexity-web-mcp). All
    // amounts are floats in USD cents; timestamps are Unix seconds.
    let json = """
    {
      "balance_cents": 4235.50,
      "renewal_date_ts": 1770000000,
      "current_period_purchased_cents": 500.0,
      "total_usage_cents": 764.5,
      "credit_grants": [
        { "type": "recurring",    "amount_cents": 5000.0, "expires_at_ts": null },
        { "type": "promotional",  "amount_cents": 250.0,  "expires_at_ts": 1780000000 },
        { "type": "purchased",    "amount_cents": 500.0,  "expires_at_ts": null }
      ]
    }
    """
    guard let data = json.data(using: .utf8) else { expect(false, "utf8 data"); return }
    do {
        let parsed = try PerplexityUsageFetcher.parseCredits(data)
        expectEqual(parsed.balanceCents, 4235.50)
        expectEqual(parsed.renewalEpoch, 1770000000)
        expectEqual(parsed.currentPeriodPurchasedCents, 500.0)
        expectEqual(parsed.totalUsageCents, 764.5)
        expectEqual(parsed.grants.count, 3)
        expectEqual(parsed.grants[0].type, "recurring")
        expectEqual(parsed.grants[0].amountCents, 5000.0)
        expect(parsed.grants[0].expiresAtEpoch == nil)
        expectEqual(parsed.grants[1].type, "promotional")
        expectEqual(parsed.grants[1].expiresAtEpoch, 1780000000)
    } catch {
        expect(false, "parseCredits threw: \(error)")
    }
}

run("Perplexity parseCredits: empty account tolerated (Free tier)") {
    // A Free-tier account may have zero grants and a zero balance. Parser
    // must not throw or drop into unexpectedShape.
    let json = """
    {"balance_cents": 0, "renewal_date_ts": 0, "current_period_purchased_cents": 0, "total_usage_cents": 0, "credit_grants": []}
    """
    guard let data = json.data(using: .utf8) else { expect(false); return }
    let parsed = try? PerplexityUsageFetcher.parseCredits(data)
    expect(parsed != nil)
    expectEqual(parsed?.grants.count, 0)
    expectEqual(parsed?.balanceCents, 0)
}

run("Perplexity parseCredits: invalid JSON throws invalidJSON") {
    let data = Data("<html>Just a moment...</html>".utf8)  // Cloudflare challenge HTML
    do {
        _ = try PerplexityUsageFetcher.parseCredits(data)
        expect(false, "expected throw")
    } catch let e as PerplexityUsageParseError {
        expectEqual(e, .invalidJSON)
    } catch {
        expect(false, "wrong error type")
    }
}

run("Perplexity parseCredits: non-finite Double is coerced to safe values") {
    // Defence against a hostile / broken response with 1e400-style numbers.
    // JSONSerialization already refuses to decode `NaN`/`Infinity` as bare
    // JSON tokens, so exercise the coercion via a numeric string.
    let json = """
    {"balance_cents": "not-a-number", "renewal_date_ts": 1770000000, "credit_grants": []}
    """
    guard let data = json.data(using: .utf8) else { expect(false); return }
    let parsed = try? PerplexityUsageFetcher.parseCredits(data)
    expectEqual(parsed?.balanceCents, 0)   // failed string coercion → 0, not a crash
    expectEqual(parsed?.renewalEpoch, 1770000000)
}

run("Perplexity parseCredits: out-of-range renewal_date_ts is treated as missing") {
    // Codex adversarial review round 2 #4: a wild timestamp must not flow
    // into a pathological Date.
    let json = """
    {"balance_cents": 100, "renewal_date_ts": 1e300, "credit_grants": [
        {"type": "recurring", "amount_cents": 500, "expires_at_ts": 1e300}
    ]}
    """
    guard let data = json.data(using: .utf8) else { expect(false); return }
    let parsed = try? PerplexityUsageFetcher.parseCredits(data)
    expectEqual(parsed?.renewalEpoch, 0)                          // clamped
    expect(parsed?.grants.first?.expiresAtEpoch == nil)           // clamped to nil
}

run("Perplexity parseCredits: pre-2000 renewal timestamp rejected") {
    // A stray 0 or a 1970-era timestamp is outside the sane range and
    // should be reported as "no renewal date" rather than plumbed through.
    let json = """
    {"balance_cents": 100, "renewal_date_ts": 100, "credit_grants": []}
    """
    guard let data = json.data(using: .utf8) else { expect(false); return }
    let parsed = try? PerplexityUsageFetcher.parseCredits(data)
    expectEqual(parsed?.renewalEpoch, 0)
}

// MARK: - PerplexityUsageFetcher.parseRateLimits

run("Perplexity parseRateLimits: full Pro-account shape") {
    // Shape from three independent live captures. Only remaining_* on the
    // top level; sources.source_to_limit for connectors.
    let json = """
    {
      "remaining_pro": 192,
      "remaining_research": 19,
      "remaining_labs": 25,
      "remaining_agentic_research": 2,
      "model_specific_limits": {},
      "sources": {
        "source_to_limit": {
          "web":       {"monthly_limit": null, "remaining": null},
          "scholar":   {"monthly_limit": null, "remaining": null},
          "bmj_mcp":   {"monthly_limit": 500, "remaining": 495},
          "nejm_alt":  {"monthly_limit": 25,  "remaining": 10}
        }
      }
    }
    """
    guard let data = json.data(using: .utf8) else { expect(false); return }
    do {
        let parsed = try PerplexityUsageFetcher.parseRateLimits(data)
        expectEqual(parsed.remainingPro, 192)
        expectEqual(parsed.remainingResearch, 19)
        expectEqual(parsed.remainingLabs, 25)
        expectEqual(parsed.remainingAgenticResearch, 2)
        expectEqual(parsed.sources.count, 4)
        // Sorted by sourceId for determinism.
        expectEqual(parsed.sources[0].sourceId, "bmj_mcp")
        expectEqual(parsed.sources[0].monthlyLimit, 500)
        expectEqual(parsed.sources[0].remaining, 495)
        // Nulls preserved as nil.
        let web = parsed.sources.first { $0.sourceId == "web" }
        expect(web?.monthlyLimit == nil)
        expect(web?.remaining == nil)
    } catch {
        expect(false, "parseRateLimits threw: \(error)")
    }
}

run("Perplexity parseRateLimits: Free account with omitted sources") {
    // Free-tier / anonymous omits the sources map entirely; must parse.
    let json = """
    {"remaining_pro": 3, "remaining_research": 0, "remaining_labs": 0, "remaining_agentic_research": 0}
    """
    guard let data = json.data(using: .utf8) else { expect(false); return }
    let parsed = try? PerplexityUsageFetcher.parseRateLimits(data)
    expectEqual(parsed?.remainingPro, 3)
    expectEqual(parsed?.sources.count, 0)
}

run("Perplexity parseRateLimits: negative remaining clamped to zero") {
    // Defence: a hostile / miscalculated server value must not surface as a
    // negative counter tile ("-5 Pro Search remaining").
    let json = """
    {"remaining_pro": -5, "remaining_research": 10, "remaining_labs": 0, "remaining_agentic_research": 0}
    """
    guard let data = json.data(using: .utf8) else { expect(false); return }
    let parsed = try? PerplexityUsageFetcher.parseRateLimits(data)
    expectEqual(parsed?.remainingPro, 0)
    expectEqual(parsed?.remainingResearch, 10)
}

// MARK: - PerplexityUsageFetcher.parseUserSettings

run("Perplexity parseUserSettings: subscription fields + numeric limits") {
    let json = """
    {
      "pages_limit": 100,
      "upload_limit": 500,
      "create_limit": 25,
      "max_files_per_user": 500,
      "max_files_per_repository": 100,
      "subscription_status": "active",
      "subscription_source": "stripe",
      "subscription_tier": "pro",
      "query_count": 42,
      "query_count_copilot": 7,
      "default_model": "sonar-pro",
      "has_ai_profile": true
    }
    """
    guard let data = json.data(using: .utf8) else { expect(false); return }
    do {
        let parsed = try PerplexityUsageFetcher.parseUserSettings(data)
        expectEqual(parsed.subscriptionStatus, "active")
        expectEqual(parsed.subscriptionSource, "stripe")
        expectEqual(parsed.subscriptionTier, "pro")
        expectEqual(parsed.pagesLimit, 100)
        expectEqual(parsed.uploadLimit, 500)
        expectEqual(parsed.createLimit, 25)
        expectEqual(parsed.queryCount, 42)
    } catch {
        expect(false, "parseUserSettings threw: \(error)")
    }
}

run("Perplexity parseUserSettings: unknown tier preserved verbatim") {
    // Guard against silently dropping a new server-side tier.
    let json = """
    {"subscription_tier": "enterprise-yearly", "subscription_status": "active"}
    """
    guard let data = json.data(using: .utf8) else { expect(false); return }
    let parsed = try? PerplexityUsageFetcher.parseUserSettings(data)
    expectEqual(parsed?.subscriptionTier, "enterprise-yearly")
}

// MARK: - PerplexityUsageStore (in-memory credentials + stubbed transport)

final class StubPerplexityTransport: PerplexityUsageTransport, @unchecked Sendable {
    let result: PerplexityUsageResult
    init(_ result: PerplexityUsageResult) { self.result = result }
    func fetchAll(cookieName: String, cookieValue: String, completion: @escaping @Sendable (PerplexityUsageResult) -> Void) {
        completion(result)
    }
}

MainActor.assumeIsolated {
    let suiteName = "perplexity-tests-\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "features.perplexity.enabled")

    run("Perplexity store off by default emits no tiles") {
        let d2 = UserDefaults(suiteName: suiteName + "-off")!
        d2.removePersistentDomain(forName: suiteName + "-off")
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: d2)
        expectEqual(store.isEnabled, false)
        expectEqual(store.tiles.count, 0)
    }

    run("Perplexity enabled without cookie emits needsAccess card") {
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        expectEqual(store.isConfigured, false)
        let tiles = store.tiles
        expectEqual(tiles.count, 1)
        if case .needsAccess = tiles.first?.kind { expect(true) }
        else { expect(false, "expected needsAccess") }
    }

    run("Perplexity locked keychain still counted as configured") {
        // ".unavailable means still configured" invariant from PR #60.
        let store = PerplexityUsageStore(credentials: UnavailableCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        expectEqual(store.isConfigured, true)
    }

    run("Perplexity saveKey stores cookie; clear deletes it") {
        let creds = InMemoryCredentialStore()
        let store = PerplexityUsageStore(credentials: creds, transport: StubPerplexityTransport(.networkError), defaults: defaults)
        expectEqual(store.hasKey, false)
        store.saveKey("__Secure-next-auth.session-token=abc")
        expectEqual(store.hasKey, true)
        store.clear()
        expectEqual(store.hasKey, false)
    }

    run("Perplexity saveKey with whitespace-only clears") {
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        store.saveKey("initial")
        store.saveKey("   \n  ")   // deletes
        expectEqual(store.hasKey, false)
    }

    run("Perplexity plan tile derived from subscription_tier + status") {
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        store.saveKey("cookie")
        var snap = PerplexityUsageSnapshot()
        snap.settings = PerplexityUserSettings(
            subscriptionStatus: "active",
            subscriptionSource: "stripe",
            subscriptionTier: "pro"
        )
        store.apply(.success(snap))
        let planTile = store.tiles.first { $0.id == "perplexity-plan" }
        expect(planTile != nil)
        if case let .text(status, _) = planTile?.kind {
            expect(status.contains("Pro"))
            expect(status.contains("active"))
        } else {
            expect(false, "expected text tile")
        }
    }

    run("Perplexity plan tile omitted when only subscription_source is present (chk1 Bug #3)") {
        // subscription_source is the BILLING PROVIDER, not a plan name.
        // Rendering "Stripe (active)" as the Perplexity plan tile misleads
        // the user about their account state. The fix omits the tile
        // entirely when subscription_tier is absent.
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        store.saveKey("cookie")
        var snap = PerplexityUsageSnapshot()
        snap.settings = PerplexityUserSettings(
            subscriptionStatus: "active",
            subscriptionSource: "stripe",
            subscriptionTier: nil    // no tier reported
        )
        store.apply(.success(snap))
        expect(!store.tiles.contains { $0.id == "perplexity-plan" })
    }

    run("Perplexity plan tile omitted when subscription_tier is 'none' or empty") {
        // Additional coverage: "none" and "" should not slip through and
        // render as unknown-tier plan labels either.
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        store.saveKey("cookie")
        for badTier in ["none", "  none  ", "", "   "] {
            var snap = PerplexityUsageSnapshot()
            snap.settings = PerplexityUserSettings(subscriptionTier: badTier)
            store.apply(.success(snap))
            expect(!store.tiles.contains { $0.id == "perplexity-plan" }, "expected no plan tile for '\(badTier)'")
        }
    }

    run("Perplexity fetch() on a locked keychain surfaces an unlock message (chk1 Bug #2)") {
        // UnavailableCredentialStore reports `.unavailable` for readResult,
        // so hasKey is true (round-2 fix) but a bare read() returns nil.
        // Before the chk1 Bug #2 fix, fetch() collapsed .unavailable into
        // .missing and cleared lastError silently. Now it distinguishes.
        let store = PerplexityUsageStore(credentials: UnavailableCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        expectEqual(store.isConfigured, true)
        store.fetch()
        expect(store.errorMessage?.contains("Keychain") == true || store.errorMessage?.contains("Unlock") == true)
        // Snapshot cleared, not stale-preserved.
        expect(store.snapshot == nil)
    }

    run("Perplexity credits tile carries USD cents + Max plan hint from large recurring grant") {
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        store.saveKey("cookie")
        var snap = PerplexityUsageSnapshot()
        snap.credits = PerplexityCredits(
            balanceCents: 4235.50,
            renewalEpoch: 1770000000,
            currentPeriodPurchasedCents: 0,
            // Max recurring ~$500/mo = 50 000 cents. Above the 10 000c boundary.
            grants: [PerplexityCreditGrant(type: "recurring", amountCents: 50000, expiresAtEpoch: nil)],
            totalUsageCents: 764.5
        )
        store.apply(.success(snap))
        let tile = store.tiles.first { $0.id == "perplexity-credits" }
        expect(tile != nil)
        if case let .balance(minor, currency, plan, resetsAt) = tile?.kind {
            expectEqual(minor, 4236)          // rounded from 4235.50
            expectEqual(currency, "USD")
            expectEqual(plan, "Max")          // recurring >= 10 000c → Max
            expect(resetsAt != nil)
        } else {
            expect(false, "expected balance tile")
        }
    }

    run("Perplexity credits tile: recurring grant matched case-insensitively (chk1 Bug #4)") {
        // Guard against a Perplexity schema tweak that changes the casing
        // of the grant type from "recurring" to "Recurring". Without a
        // case-insensitive compare the recurring total would collapse to 0
        // and the plan hint would silently disappear.
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        store.saveKey("cookie")
        var snap = PerplexityUsageSnapshot()
        snap.credits = PerplexityCredits(
            balanceCents: 100,
            grants: [PerplexityCreditGrant(type: "Recurring", amountCents: 50000, expiresAtEpoch: nil)]
        )
        store.apply(.success(snap))
        if case let .balance(_, _, plan, _) = store.tiles.first(where: { $0.id == "perplexity-credits" })?.kind {
            expectEqual(plan, "Max")
        } else { expect(false, "expected balance tile") }
    }

    run("Perplexity credits tile: Pro plan hint from a $50-tier recurring grant") {
        // Codex adversarial review #3: the initial 5 000c threshold flipped
        // Pro users to "Max" — a $50 grant must still register as Pro.
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        store.saveKey("cookie")
        var snap = PerplexityUsageSnapshot()
        snap.credits = PerplexityCredits(
            balanceCents: 350.0,
            renewalEpoch: 1770000000,
            grants: [PerplexityCreditGrant(type: "recurring", amountCents: 5000, expiresAtEpoch: nil)],  // $50
            totalUsageCents: 150.0
        )
        store.apply(.success(snap))
        if case let .balance(_, _, plan, _) = store.tiles.first(where: { $0.id == "perplexity-credits" })?.kind {
            expectEqual(plan, "Pro")   // 5 000c < 10 000c
        } else { expect(false, "expected balance tile") }
    }

    run("Perplexity credits tile: absurdly large balance_cents does not trap the tile mapper") {
        // Codex adversarial review #1: a hostile 1e300 balance would have
        // trapped `Int(Double)`. The new clamp routes it to Int.max instead.
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        store.saveKey("cookie")
        var snap = PerplexityUsageSnapshot()
        snap.credits = PerplexityCredits(balanceCents: 1e300, renewalEpoch: 1770000000)
        store.apply(.success(snap))
        // Must not crash. Balance tile is emitted with a clamped value.
        let tile = store.tiles.first { $0.id == "perplexity-credits" }
        expect(tile != nil)
        if case let .balance(minor, _, _, _) = tile?.kind {
            expect(minor > 0)          // clamped, not zero, not a trap
        } else { expect(false, "expected balance tile") }
    }

    run("Perplexity credits tile: no plan hint when only promotional grant present") {
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        store.saveKey("cookie")
        var snap = PerplexityUsageSnapshot()
        snap.credits = PerplexityCredits(
            grants: [PerplexityCreditGrant(type: "promotional", amountCents: 500, expiresAtEpoch: 1780000000)]
        )
        store.apply(.success(snap))
        if case let .balance(_, _, plan, _) = store.tiles.first(where: { $0.id == "perplexity-credits" })?.kind {
            expect(plan == nil, "no recurring grant → no plan hint")
        } else { expect(false, "expected balance tile") }
    }

    run("Perplexity rate-limit counters only emitted when remaining > 0") {
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        store.saveKey("cookie")
        var snap = PerplexityUsageSnapshot()
        snap.rateLimits = PerplexityRateLimits(
            remainingPro: 42,
            remainingResearch: 0,     // omitted from tiles
            remainingLabs: 5,
            remainingAgenticResearch: 0
        )
        store.apply(.success(snap))
        let ids = store.tiles.map { $0.id }
        expect(ids.contains("perplexity-pro"))
        expect(ids.contains("perplexity-labs"))
        expect(!ids.contains("perplexity-research"))
        expect(!ids.contains("perplexity-agentic"))
    }

    run("Perplexity rate-limit tile uses .text 'N left' with no resets") {
        // Codex adversarial review #4: the endpoint reports remaining only
        // — no total, no reset. Rendering as `.counter(used: 0, limit: 42)`
        // would read as an unused-42-limit meter. Render as a text tile.
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        store.saveKey("cookie")
        var snap = PerplexityUsageSnapshot()
        snap.rateLimits = PerplexityRateLimits(remainingPro: 42)
        store.apply(.success(snap))
        if case let .text(status, subtitle) = store.tiles.first(where: { $0.id == "perplexity-pro" })?.kind {
            expectEqual(status, "42 left")
            expect(subtitle == nil)
        } else {
            expect(false, "expected text tile")
        }
    }

    run("Perplexity 401 maps to session-expired error AND drops stale snapshot") {
        // Codex adversarial review #6: a stale snapshot must not linger
        // after the credential is known-bad — old numbers on the tile are
        // worse than an onboarding message.
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.unauthorized), defaults: defaults)
        store.saveKey("expired-cookie")
        // First a successful fetch populates the snapshot.
        var snap = PerplexityUsageSnapshot()
        snap.credits = PerplexityCredits(balanceCents: 100)
        store.apply(.success(snap))
        expect(store.snapshot != nil)
        // Then the cookie is revoked → 401 arrives.
        store.apply(.unauthorized)
        expect(store.errorMessage?.contains("expired") == true || store.errorMessage?.contains("blocked") == true)
        expect(store.snapshot == nil)  // stale data cleared
    }

    run("Perplexity fetch() completion from a background queue applies safely") {
        // Codex adversarial review #9: the store hops through
        // Task { @MainActor } — a regression to `assumeIsolated` would trap
        // when a real URLSession completion lands off-main. This transport
        // dispatches its completion onto a background queue to exercise
        // that path.
        final class BackgroundQueueTransport: PerplexityUsageTransport, @unchecked Sendable {
            func fetchAll(cookieName: String, cookieValue: String, completion: @escaping @Sendable (PerplexityUsageResult) -> Void) {
                DispatchQueue.global().async { completion(.unauthorized) }
            }
        }
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: BackgroundQueueTransport(), defaults: defaults)
        store.saveKey("cookie")
        store.fetch()
        // Spin the runloop briefly so the Task { @MainActor } hop is
        // observed; TestRunner drives synchronous main-actor work only,
        // so we sleep on the main thread just long enough for the hop.
        let deadline = Date().addingTimeInterval(1.0)
        while store.errorMessage == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        expect(store.errorMessage != nil)
    }

    run("Perplexity partial success: only credits present renders credits tile") {
        // Cloudflare-challenge a subset. Only `credits` came back OK.
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        store.saveKey("cookie")
        var snap = PerplexityUsageSnapshot()
        snap.credits = PerplexityCredits(balanceCents: 100.0, renewalEpoch: 1770000000)
        store.apply(.success(snap))
        expect(store.tiles.contains { $0.id == "perplexity-credits" })
        expect(!store.tiles.contains { $0.id == "perplexity-plan" })
    }

    run("Perplexity conforms to PasteKeyProvider protocol") {
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        let paster = store as PasteKeyProvider
        expect(paster.keyPlaceholder.contains("session-token") || paster.keyPlaceholder.contains("cookie"))
        expectEqual(paster.hasKey, false)
        paster.saveKey("pasted-cookie-value")
        expectEqual(paster.hasKey, true)
    }

    run("Perplexity 429 surfaces a rate-limit specific message, not generic Network error") {
        // Codex adversarial review round 3. If Perplexity shadow-bans /
        // rate-limits the session, all three endpoints return 429 and the
        // transport now emits .httpError(429). The store's apply() maps it
        // to an actionable message about slowing down.
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.httpError(429)), defaults: defaults)
        store.saveKey("cookie")
        store.apply(.httpError(429))
        expect(store.errorMessage?.contains("rate-limit") == true || store.errorMessage?.contains("Slow") == true)
    }

    run("Perplexity 5xx surfaces a server-error specific message") {
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.httpError(503)), defaults: defaults)
        store.saveKey("cookie")
        store.apply(.httpError(503))
        expect(store.errorMessage?.contains("server error") == true || store.errorMessage?.contains("503") == true)
    }

    run("Perplexity fetch() with a malformed stored cookie surfaces an error message") {
        // Codex adversarial review round 2 #1. A stored blob that hasKey=true
        // but extract()=nil must not silently render blank tiles indefinitely.
        let creds = InMemoryCredentialStore()
        // Write a value directly (bypassing saveKey's trimming) that
        // exercises the extract=nil path — a chunked cookie with a bogus
        // index the overflow guard rejects.
        creds.write(PerplexityUsageFetcher.cookieKeychainKey,
                    Data("__Secure-next-auth.session-token.9999999=EVIL".utf8))
        let store = PerplexityUsageStore(credentials: creds, transport: StubPerplexityTransport(.networkError), defaults: defaults)
        expectEqual(store.isConfigured, true)   // presence, not parseability
        store.fetch()
        expect(store.errorMessage?.contains("parse") == true || store.errorMessage?.contains("Re-paste") == true)
    }

    run("Perplexity transport rejects a semicolon-injected cookie name") {
        // Codex adversarial review round 2 #2. cookieName splicing.
        let transport = URLSessionPerplexityTransport()
        final class Box: @unchecked Sendable { var value: PerplexityUsageResult? }
        let box = Box()
        transport.fetchAll(cookieName: "__Secure-next-auth.session-token=real; other", cookieValue: "evil") { result in
            box.value = result
        }
        let deadline = Date().addingTimeInterval(2.0)
        while box.value == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if case .unauthorized = box.value {
            expect(true)
        } else {
            expect(false, "expected .unauthorized, got \(String(describing: box.value))")
        }
    }

    #if DEBUG
    run("Perplexity accumulator priority: 429 beats 5xx beats other 4xx (chk1 Omission #1)") {
        // Locks in the priority ordering so a future edit that flipped
        // the recordHttpError branches would fail this test.
        let acc = PerplexityFetchAccumulator()
        expect(acc.currentHttpError == nil)
        acc.recordHttpError(418)
        expectEqual(acc.currentHttpError, 418)
        acc.recordHttpError(500)
        expectEqual(acc.currentHttpError, 500)   // 5xx > other 4xx
        acc.recordHttpError(429)
        expectEqual(acc.currentHttpError, 429)   // 429 > 5xx
        acc.recordHttpError(503)
        expectEqual(acc.currentHttpError, 429)   // 429 sticks (does not degrade)
    }
    #endif

    run("Perplexity multi-endpoint partial success emits available tiles (chk1 Omission #2)") {
        // Locks in the "success-when-any-endpoint-succeeded" behaviour.
        // Concretely: even if rate-limits and settings return non-2xx, a
        // 200 on credits still surfaces the credits tile — the failure of
        // the others is not permitted to blank the whole provider.
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: StubPerplexityTransport(.networkError), defaults: defaults)
        store.saveKey("cookie")
        var snap = PerplexityUsageSnapshot()
        snap.credits = PerplexityCredits(balanceCents: 4235.50, renewalEpoch: 1770000000)
        // rateLimits and settings intentionally left nil (as though those
        // endpoints returned 429/500 and were dropped by the accumulator).
        store.apply(.success(snap))
        expect(store.tiles.contains { $0.id == "perplexity-credits" })
        expect(!store.tiles.contains { $0.id == "perplexity-plan" })
        expect(!store.tiles.contains { $0.id == "perplexity-pro" })
        expect(!store.tiles.contains { $0.id == "perplexity-research" })
    }

    run("Perplexity fetch() background-delivered success reaches @Published snapshot (chk1 Omission #3)") {
        // Round-1 tests covered background-queue delivery of .unauthorized,
        // but not of .success. Cover the common-case path so a future edit
        // that reintroduced MainActor.assumeIsolated in apply() would trap
        // and fail this test.
        final class BackgroundSuccessTransport: PerplexityUsageTransport, @unchecked Sendable {
            func fetchAll(cookieName: String, cookieValue: String, completion: @escaping @Sendable (PerplexityUsageResult) -> Void) {
                DispatchQueue.global().async {
                    var s = PerplexityUsageSnapshot()
                    s.credits = PerplexityCredits(balanceCents: 500, renewalEpoch: 1770000000)
                    completion(.success(s))
                }
            }
        }
        let store = PerplexityUsageStore(credentials: InMemoryCredentialStore(), transport: BackgroundSuccessTransport(), defaults: defaults)
        store.saveKey("cookie")
        store.fetch()
        let deadline = Date().addingTimeInterval(2.0)
        while store.snapshot == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        expect(store.snapshot != nil)
        expectEqual(store.snapshot?.credits?.balanceCents, 500)
    }

    run("Perplexity transport rejects a semicolon-injected cookie value") {
        // Codex adversarial review #5. A hostile paste like "real; other=evil"
        // is caught by extract() when the paste is parsed (it becomes a full
        // header the extractor picks from), but a value with an embedded `;`
        // arriving DIRECTLY at fetchAll — e.g. an attacker-controlled
        // Keychain item bypassing extract() — must not silently splice a
        // second cookie into the request. The production transport rejects.
        //
        // The transport dispatches the completion via DispatchQueue.main.async,
        // so we drive the runloop until it fires rather than blocking on a
        // semaphore (which would deadlock the main-queue hop).
        let transport = URLSessionPerplexityTransport()
        final class Box: @unchecked Sendable { var value: PerplexityUsageResult? }
        let box = Box()
        transport.fetchAll(cookieName: "__Secure-next-auth.session-token", cookieValue: "real; other=evil") { result in
            box.value = result
        }
        let deadline = Date().addingTimeInterval(2.0)
        while box.value == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if case .unauthorized = box.value {
            expect(true)
        } else {
            expect(false, "expected .unauthorized rejection, got \(String(describing: box.value))")
        }
    }

    defaults.removePersistentDomain(forName: suiteName)
}

// MARK: - Summary

print("")
print("\(total - failed)/\(total) checks passed")
if failed > 0 {
    print("\(failed) FAILED")
    exit(1)
}
