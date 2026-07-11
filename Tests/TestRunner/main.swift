// PR 2a — assertion-based test runner.
//
// Runs with `swift run TestRunner` from the repo root. Works with
// Command Line Tools alone; does not require Xcode.app / XCTest.
// Prints one line per test and exits nonzero if any assertion fails.
//
// When Xcode.app is installed, this runner can be promoted to XCTest
// or Apple's Testing framework without changing the assertion bodies.

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
    // SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    expectEqual(LogValue.identifier("hello").rendered, "<id: 2cf24dba>")
    // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
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

// MARK: - Summary

print("")
print("\(total - failed)/\(total) checks passed")
if failed > 0 {
    print("\(failed) FAILED")
    exit(1)
}
