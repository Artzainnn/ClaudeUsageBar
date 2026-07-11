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

// MARK: - Summary

print("")
print("\(total - failed)/\(total) checks passed")
if failed > 0 {
    print("\(failed) FAILED")
    exit(1)
}
