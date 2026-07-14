// PR 12-UI (Codex R3 P1#1 rework): the per-provider user-facing help and
// disclosure strings live in this dedicated file so the CI DMCA
// static-grep guard can allowlist ONLY this file — and no other — for
// legitimate bare-hostname references in prose.
//
// Prior placement (`app/UsageProvider.swift`) also housed `DefaultsStore`
// and other executable code; a whole-file allowlist on that file would
// have permitted a future edit to add `URL(string: "https://api.jetbrains.ai/…")`
// undetected. This file contains ONLY copy — no URL construction, no
// networking, no credential handling. If a maintainer adds executable
// code here, the code review must reject it OR tighten the allowlist
// simultaneously.
//
// This file is the ONE allowlisted path in
// `.github/workflows/ci.yml`'s DMCA guard. Adding a second allowlisted
// path requires updating the allowlist AND a code-review sign-off in
// the PR body.

import Foundation

// MARK: - ProviderCopy

/// Per-provider help and disclosure copy for the Settings toggles. Kept in
/// the library (not the app view file) so the strings are unit-testable —
/// they are user-facing and must not silently change. Returns nil for a
/// provider with no bespoke copy.
public enum ProviderCopy {
    /// Explanatory help shown under a provider's Settings toggle.
    public static func help(for id: String) -> String? {
        switch id {
        case "codex":
            return "Codex counters cover the Codex CLI, IDE extensions, Slack, and Cloud tasks — one shared 5-hour and weekly pool. General GPT chat is not counted. Reads your existing `codex auth login` session; run it in a terminal if prompted."
        case "deepseek":
            return "Shows your DeepSeek platform balance (granted + topped-up), per currency. Paste a DeepSeek API key below; it is stored in your macOS Keychain and used only to read the balance."
        case "zed":
            return "Shows your Zed plan and edit-prediction usage. Reads the login Zed already saved in your Keychain — macOS will ask once to allow it. Sign in to Zed first, then click Refresh."
        case "xai":
            return "Shows your xAI (Grok) API key permissions. Paste an inference key (xai-…) below. Add a management key too to also see prepaid balance and daily usage. Both are stored in your Keychain."
        case "openai":
            return "Shows your OpenAI organisation's month-to-date spend, token usage by model, and configured rate limits. Paste an Organization Admin key (sk-admin-…); it is stored in your Keychain."
        case "perplexity":
            return "Can show your Perplexity plan, credit balance, and per-mode remaining queries (Pro Search, Deep Research, Labs, Agentic) when available. Sign in on perplexity.ai, open your browser's cookie inspector, and paste your __Secure-next-auth.session-token cookie below — the bare value, a name=value pair, or the full copied Cookie header all work. It is stored in your Keychain."
        case "copilot":
            return "Shows your GitHub Copilot chargeable AI-Credit overage (net) month-to-date, plus the top SKU line items. Note: usage covered by your plan's included allowance shows as $0 — only overage is charged. Create a fine-grained PAT on github.com (Settings → Developer settings → Personal access tokens → Fine-grained tokens), set the resource owner to your own account, then under Account permissions grant 'Plan: Read-only'. Paste the github_pat_… token below; it is stored in your Keychain."
        case "claudeCode":
            return "Reads your local Claude Code session logs (`~/.claude/projects/**/*.jsonl`) to show tokens used today, cost today, and cost month-to-date, broken down by model. Nothing leaves your Mac; no key or sign-in is needed. Costs are calculated locally from a bundled snapshot of Anthropic's published rates."
        case "cline":
            return "Reads your local Cline session logs. In VS Code, VS Code Insiders, VSCodium, Cursor, or Windsurf: `<host>/User/globalStorage/saoudrizwan.claude-dev/tasks/{taskId}/ui_messages.json`. For the Cline CLI: `$CLINE_DATA_DIR/tasks/…`, `$CLINE_DIR/data/tasks/…`, or `~/.cline/data/tasks/…`. Shows tokens used today, cost today, and cost month-to-date, broken down by model. Nothing leaves your Mac; no key or sign-in is needed. Costs come from Cline's own precomputed per-turn total — the same number you see inside the extension or CLI."
        case "windsurf":
            return "Reads Windsurf's own local plan info from `~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb` (the `windsurf.settings.cachedPlanInfo` row) to show your plan name and remaining daily / weekly / credit windows, with reset times. Nothing leaves your Mac; no key or pasted credential is needed in this app. Sign in to Windsurf itself and open a Cascade chat once so Windsurf writes the row, then click Refresh here."
        case "cursor":
            return "Reads Cursor's own local session from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (the `cursorAuth/accessToken`, `cursorAuth/refreshToken`, and `cursorAuth/stripeMembershipType` rows), then calls Cursor's own web dashboard API to show your plan, month-to-date usage against the billing cycle, any on-demand spend, and the top models this cycle by cost. No key or paste is required in this app — it reuses Cursor's local session. The access token is sent as a session cookie to `cursor.com`, and the refresh token may be sent to `api2.cursor.sh` if a refresh is needed. Sign in to Cursor first."
        case "jetbrains":
            return "Reads your JetBrains AI Assistant quota from a local XML file — `AIAssistantQuotaManager2.xml` — that JetBrains IDEs write under `~/Library/Application Support/JetBrains/{IDE}{Version}/options/` (and `~/Library/Application Support/Google/AndroidStudio{Version}/options/` for Android Studio). Shows your used-of-quota bar, the next refill date (in UTC), and which IDE the reading belongs to when you have more than one. Nothing leaves your Mac; no key or pasted credential is needed in this app. AI Assistant must be enabled inside a JetBrains IDE at least once for the file to exist — sign in to the JetBrains IDE first if the tile shows 'not installed'."
        case "warp":
            return "Reads Warp's own local state database at `~/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite` (falling back to `~/Library/Group Containers/2BBY89MBSN.dev.warp/warp.sqlite` for App-Store installs, and `~/Library/Application Support/dev.warp.Warp-Preview/warp.sqlite` for the Preview channel) to show how many AI requests you have sent today. Nothing leaves your Mac; no key or pasted credential is needed in this app. Only today's AI-request count is shown — Warp's own credit balance and rate limits are NOT read here."
        case "continue":
            return "Reads Continue's local dev-data at `~/.continue/dev_data/0.2.0/tokensGenerated.jsonl` to show tokens used today, tokens month-to-date, and the top models and providers this month. Continue writes this file automatically every time you use it — no key, no sign-in, and no configuration are needed. Nothing leaves your Mac. If the file does not exist yet, use Continue once in your IDE and click Refresh here."
        case "roo":
            return "Reads Roo Code's local per-task rollups (`history_item.json` — the same numbers you see inside Roo). Enumerates every VS Code family host (VS Code, VS Code Insiders, VSCodium, Cursor, Cursor Nightly, Windsurf) under `RooVeterinaryInc.roo-cline`, and honours a `roo-cline.customStoragePath` override if you have configured one in your VS Code settings. Nothing leaves your Mac; no key or sign-in is needed. Costs come from Roo's own precomputed per-turn total — the same figure it shows internally."
        case "zoo":
            return "Reads Zoo Code's local per-task rollups (`history_item.json` — the same numbers you see inside Zoo). Enumerates every VS Code family host (VS Code, VS Code Insiders, VSCodium, Cursor, Cursor Nightly, Windsurf) under `ZooCodeOrganization.zoo-code`, and honours a `zoo-code.customStoragePath` override if you have configured one. Nothing leaves your Mac; no key or sign-in is needed. Costs come from Zoo's own precomputed per-turn total — the same figure it shows internally."
        case "gemini":
            return "Reads the Gemini CLI's local session logs at `~/.gemini/tmp/<projectHash>/chats/session-*.jsonl` (the same files the `gemini` command writes as you use it). Honours `$GEMINI_CLI_HOME` if you have relocated Gemini's data directory. Shows tokens used today, cost today, and cost month-to-date, broken down by model. Nothing leaves your Mac; no key or sign-in is needed. Costs are calculated locally from a bundled snapshot of Google's published per-token rates for Gemini 2.5 Pro / 2.5 Flash / 2.0 Flash / 2.0 Flash-Lite / 1.5 Pro / 1.5 Flash."
        default:
            return nil
        }
    }

    /// A warning line shown for providers backed by a private/undocumented
    /// API that may break without notice. Rendered in an accent colour.
    public static func disclosure(for id: String) -> String? {
        switch id {
        case "codex":
            return "Uses OpenAI's private Codex API. It may stop working without notice."
        case "openai":
            return "An Admin key can view billing and manage users in your OpenAI organisation. It cannot make inference calls. Store yours only if you are comfortable with this app holding it."
        case "perplexity":
            return "Uses Perplexity's private web-app endpoints. They may stop working without notice. The pasted value is a full Perplexity web session cookie — it can let this app act as your signed-in account, including spending or purchasing credits your plan allows, until it expires or is revoked (for example by signing out or clearing sessions on perplexity.ai)."
        case "copilot":
            return "Use a fine-grained PAT (github_pat_…), NOT a classic token. Grant only 'Plan: Read' under Account permissions — nothing else. Set an expiry so an accidentally-leaked token becomes worthless. Classic PATs with broader scopes can spend money on your GitHub account; do not paste one here. Treat a PAT like a password — anyone with it can act as you without triggering your 2FA prompt. Clearing this key deletes it from your Mac's Keychain but does NOT revoke it on GitHub — to revoke, visit github.com Settings → Developer settings → Personal access tokens and delete it there."
        case "claudeCode":
            return "Costs are estimates based on Anthropic's published per-token rates at the time this build was released. They are not a receipt from Anthropic and may differ from your actual bill. When new Claude models ship, unpriced records show tokens but $0 cost until the next app update; a 'Pricing update available' tile appears when this happens."
        case "cline":
            return "Costs come from Cline itself — this app reads Cline's precomputed per-turn total and sums them. If Cline's rate table is out of date, or the API-request record was not fully written (a crash mid-turn), the numbers will not match your provider's bill exactly. If a Cline install exists on this Mac but its data cannot be read, a 'Partial access' tile appears; grant Full Disk Access in System Settings to include it."
        case "cursor":
            return "Uses Cursor's own web dashboard API. It is not a public API — Cursor may change or remove it at any time, in which case this tile will stop updating until this app is updated. If your access token expires the app refreshes it silently against `api2.cursor.sh`'s OAuth endpoint using the same client ID Cursor.app itself uses. If the refresh reports 'logged out' or fails, or if a refreshed token is still rejected on retry, a 'Sign in again in Cursor' tile appears — clearing this provider does not sign you out of Cursor; sign in inside Cursor itself, then click Refresh here."
        case "jetbrains":
            return "Reads a LOCAL XML file only — as a DMCA constraint, this app deliberately does NOT contact `api.jetbrains.ai` or `grazie.aws.intellij.net` (JetBrains's own quota API), and a CI static-grep guard enforces that constraint in the source. The XML format is internal to JetBrains's `PersistentStateComponent` and may change between IDE versions; if it does, a 'JetBrains quota format changed' tile appears until this app is updated. Refill dates are shown in UTC because JetBrains publishes them in UTC — a value like `1 Aug UTC` may render as 31 Jul or 2 Aug in your local timezone."
        case "warp":
            return "The Warp state-database schema is not documented — this app reads two known table names (`ai_queries` and `agent_conversations`) with six accepted timestamp column names (`created_at`, `createdAt`, `timestamp`, `ts`, `date`, `time`) in three accepted formats (integer seconds since 1970, integer milliseconds since 1970, and ISO-8601 / sqlite datetime text). If Warp ships an update that renames a column or table this app does not recognise, a 'Warp database format changed' tile appears until this app is updated. Warp's own server-side credit balance and rate limits are NOT read here — the `wk-`-prefixed API-key GraphQL path is deferred to a follow-up PR."
        case "continue":
            return "Tokens only — Continue's `tokensGenerated.jsonl` schema records `promptTokens` and `generatedTokens` per LLM call but does not record cost. Continue routes calls to whichever provider you have configured (OpenAI, Anthropic, Google, xAI, DeepSeek, Ollama, and others), so a single cost estimate would require a cross-provider pricing table this app does not ship. If Continue's dev-data schema changes (currently pinned at `0.2.0`), this tile may stop updating until this app is updated to match. Only the `tokensGenerated` stream is read — Continue's nine other dev-data streams (autocomplete outcomes, edit outcomes, tool usage) are ignored."
        case "roo":
            return "Roo Code's GitHub repo is ARCHIVED (May 2026) — the extension is frozen at v3.54.0 on the marketplace. This app still reads Roo's on-disk data (nothing changed there when the repo archived), but Roo itself will not receive further updates from its original maintainer; if you have migrated to Zoo Code (the active fork), enable that provider instead and disable this one. Costs come from Roo itself — if Roo's precomputed per-turn total drifted from your provider's actual bill, the numbers here will reflect Roo's number, not the bill. If the on-disk data grows past the 10 000 most-recent tasks cap, a 'Session cap hit' tile appears — the numbers reflect the newest 10 000 sessions only."
        case "zoo":
            return "Zoo Code is the active fork of Roo Code (archived May 2026). Same file layout, same reader; enabling both providers scans both namespaces independently, and duplicate task IDs across the two (which shouldn't happen but can if you migrated by copying tasks) collapse to a single record. Costs come from Zoo itself — if Zoo's precomputed per-turn total drifted from your provider's actual bill, the numbers here will reflect Zoo's number, not the bill. If the on-disk data grows past the 10 000 most-recent tasks cap, a 'Session cap hit' tile appears — the numbers reflect the newest 10 000 sessions only."
        case "gemini":
            return "Costs are estimates based on Google's published per-token rates at the time this build was released. They are not a receipt from Google and may differ from your actual bill (Vertex enterprise billing, discounted commit-use pricing, or free-tier credits are NOT applied). When Google ships a new Gemini model that isn't in the bundled pricing snapshot, its records show tokens but $0 cost until this app is updated; a 'Pricing update available' tile surfaces when this happens. Tiered pricing (Gemini 2.5 Pro's >200k context surcharge) is not applied per-request — the on-disk log doesn't carry cumulative context length. Server-side quota via `serviceusage.googleapis.com` is NOT read here."
        default:
            return nil
        }
    }
}
