// swift-tools-version:6.0
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
                // PR 12-UI — ProviderCopy extracted into its own file so
                // the CI DMCA static-grep guard can allowlist ONLY the
                // copy-catalog file (not UsageProvider.swift, which
                // also contains DefaultsStore executable code).
                "ProviderCopy.swift",
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
                "PerplexityUsageStore.swift",
                // GitHub Copilot: fine-grained PAT in Keychain, /user +
                // /users/{login}/settings/billing/ai_credit/usage.
                "CopilotUsageFetcher.swift",
                "CopilotUsageStore.swift",
                // PR 10a — shared local-provider infrastructure. Consumed
                // by every local-file provider from PR 10b onward.
                "FileWatcher.swift",
                "SQLiteReader.swift",
                "TCCState.swift",
                // PR 10b-BE — Claude Code local JSONL reader. Fetcher +
                // embedded pricing snapshot in the library so the
                // TestRunner can exercise dedupe and cost math directly.
                // Store lands in a follow-up file (same PR).
                "ClaudeCodePricing.swift",
                "ClaudeCodeUsageFetcher.swift",
                "ClaudeCodeUsageStore.swift",
                // PR 10c-BE — Cline local ui_messages.json reader.
                // Reuses ClaudeCodeUsageFetcher.safeInt +
                // ClaudeCodeUsageRecord.saturatingAdd + TCCProbe +
                // LocalProviderAccessGuide from PRs #66/#67. Does NOT
                // reuse ClaudeCodeUsageFetcher.readJsonlLines — Cline's
                // ui_messages.json is a single JSON array (not JSONL),
                // so the fetcher has its own `readClineUiMessagesText`
                // helper with a 64 MB streaming reader.
                "ClineUsageFetcher.swift",
                "ClineUsageStore.swift",
                // PR 11-BE — Windsurf + Cursor providers. Both read a
                // VS Code-style state.vscdb through SQLiteReader (PR #66)
                // and reuse TCCProbe + LocalProviderAccessGuide.
                // Cursor also performs live fetches to cursor.com and
                // api2.cursor.sh (via a Sendable transport protocol,
                // stubbed in tests).
                "WindsurfUsageFetcher.swift",
                "WindsurfUsageStore.swift",
                "CursorUsageFetcher.swift",
                "CursorUsageStore.swift",
                // PR 12-BE — JetBrains AI + Warp providers. Pure-local:
                // JetBrains reads an XML quota file per IDE, Warp reads
                // a schema-guarded sqlite. NEITHER contacts a JetBrains
                // API (DMCA constraint) NOR uses a Warp API key (that
                // path is deferred to a follow-up).
                "JetBrainsUsageFetcher.swift",
                "JetBrainsUsageStore.swift",
                "WarpUsageFetcher.swift",
                "WarpUsageStore.swift",
                // PR 13-BE — Continue local dev-data JSONL reader.
                // Reads ~/.continue/dev_data/0.2.0/tokensGenerated.jsonl.
                // Reuses ClaudeCodeUsageFetcher.readJsonlLines + parseTimestamp +
                // safeInt (the last hardened in the same PR to reject Bool).
                "ContinueUsageFetcher.swift",
                "ContinueUsageStore.swift",
                // PR 13-BE — Roo Code + Zoo Code local reader.
                // Both extensions share the Cline file layout under distinct
                // publisher.name namespaces. Shared fetcher / path resolver;
                // two stores so users can toggle Roo (archived) independently
                // from Zoo (active fork).
                "RooZooPathResolver.swift",
                "RooZooUsageFetcher.swift",
                "RooUsageStore.swift",
                "ZooUsageStore.swift",
                // PR 15-BE — Gemini Developer local JSONL reader.
                // Reads Gemini CLI's `~/.gemini/tmp/<projectHash>/chats/
                // session-*.jsonl`. Feature-flagged off. Tokens + cost
                // via a bundled per-token rate table.
                "GeminiUsageFetcher.swift",
                "GeminiUsageStore.swift"
                // AnthropicUsageStore.swift depends on UsageManager
                // (defined in ClaudeUsageBar.swift), so it stays in the
                // app-bundle compile only, not in the SwiftPM library
                // target. Tests for AnthropicUsageStore live in the
                // full-app integration tier, not this unit-test layer.
                //
                // PR 14 — StatusSource.swift depends on StatusIncident /
                // StatusComponent / AffectedComponent, which live in
                // ClaudeUsageBar.swift. Same rationale — app-only.
                // Parser tests would need duplicated struct
                // definitions in the library, which is not worth the
                // maintenance tax.
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "TestRunner",
            dependencies: ["ClaudeUsageBar"],
            path: "Tests/TestRunner",
            // PR 18: TestRunner now compiles under Swift 6 language
            // mode. The 992-line assertion harness's top-level
            // counters were wrapped in a `@MainActor Counters` class,
            // and `expect` / `expectEqual` / `run` marked
            // `@MainActor`. Every test call site already ran on the
            // main thread — the annotation makes that explicit and
            // Swift-6-strict-concurrency-clean.
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
