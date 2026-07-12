// swift-tools-version:5.9
//
// SwiftPM manifest — additive scaffolding for testing, not a replacement for
// the existing build path.
//
// `swift build` compiles the library against the source under `app/`.
// `swift run TestRunner` executes the assertion-based test runner (works
// with Command Line Tools alone; does not require Xcode.app / XCTest).
// The legacy `app/build.sh` continues to work unchanged — it invokes
// `swiftc` directly and produces the `.app` bundle. Both paths compile
// the same file.
//
// Why not XCTest / swift-testing?
// Both XCTest and Apple's newer `Testing` framework require `xctest`
// tooling that ships with Xcode.app, not with the Command Line Tools
// package. To keep the test path usable on any Mac with CLT installed,
// PR 2a ships a plain executable test runner. PR 16 (Swift 6 migration)
// or a maintainer decision to install Xcode.app can promote this to
// XCTest later without changing the test bodies (they're just
// assertion functions).
//
// PR 2a intentionally introduces only the scaffold plus one first test
// suite (LogValueTests). PR 2b lands the AnthropicUsageFetcher extraction
// and its fixture-based tests using the same runner.

import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "ClaudeUsageBar", targets: ["ClaudeUsageBar"]),
        .executable(name: "TestRunner", targets: ["TestRunner"])
    ],
    targets: [
        .target(
            name: "ClaudeUsageBar",
            path: "app",
            exclude: [
                // The @main app entry point (compiled by build.sh into the
                // .app bundle, but not part of the SwiftPM library which is
                // only for testable extracted types).
                "ClaudeUsageBar.swift",
                // Assets, build scripts, and docs — not compiled sources.
                "build.sh",
                "create_dmg.sh",
                "make_app_icon.sh",
                "Info.plist",
                "ClaudeUsageBar.icns",
                "claudeusagebar-icon.png",
                "LICENSE",
                "README.md",
                // AnthropicUsageStore depends on UsageManager (defined in the
                // excluded @main entry point) so it is compiled only by
                // build.sh into the .app bundle, not by the SwiftPM library.
                // Listed here explicitly to silence the "unhandled file"
                // warning now that `sources` is an allow-list.
                "AnthropicUsageStore.swift"
            ],
            sources: [
                "Log.swift",
                "AnthropicUsageFetcher.swift",
                "UsageProvider.swift",
                "CodexUsageFetcher.swift",
                // CodexUsageStore has no dependency on UsageManager (unlike
                // AnthropicUsageStore), so it lives in the library where the
                // TestRunner can exercise its tile-generation and 401 →
                // session-expired mapping through a stubbed transport.
                "CodexUsageStore.swift",
                // DeepSeek: fetcher + KeychainStore + store. Same rationale —
                // no UsageManager dependency, so it is unit-testable here.
                "DeepSeekUsageFetcher.swift",
                "DeepSeekUsageStore.swift",
                // Zed: reads Zed's own Keychain item; same rationale.
                "ZedUsageFetcher.swift",
                "ZedUsageStore.swift",
                // xAI Developer: two-key, two-host; same rationale.
                "XAIUsageFetcher.swift",
                "XAIUsageStore.swift",
                // OpenAI Platform: admin key, three org endpoints.
                "OpenAIUsageFetcher.swift",
                "OpenAIUsageStore.swift",
                // Perplexity: cookie in Keychain, three cookie-authed endpoints.
                "PerplexityUsageFetcher.swift",
                "PerplexityUsageStore.swift"
                // AnthropicUsageStore.swift depends on UsageManager
                // (defined in ClaudeUsageBar.swift), so it stays in the
                // app-bundle compile only, not in the SwiftPM library
                // target. Tests for AnthropicUsageStore live in the
                // full-app integration tier, not this unit-test layer.
            ]
        ),
        .executableTarget(
            name: "TestRunner",
            dependencies: ["ClaudeUsageBar"],
            path: "Tests/TestRunner"
        )
    ]
)
