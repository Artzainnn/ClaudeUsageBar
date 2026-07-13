// PR 2c — UsageProvider protocol and supporting types.
//
// This PR introduces the multi-provider surface without adding any new
// provider. It ships:
//
//   1. A `UsageProvider` protocol every provider will conform to.
//   2. A `UsageTile` value type for popover rendering.
//   3. A `ProviderBox` type-erasing wrapper so SwiftUI can observe a
//      collection of heterogeneous providers via a single ObservableObject.
//   4. `AnthropicUsageStore` — the first conformer, wrapping the existing
//      UsageManager. Behaviour identical to v1.3.1.
//
// Everything is additive. UsageManager is not removed. The popover is not
// yet driven by `[UsageProvider]` — that switch lands in a follow-up PR
// once at least one non-Anthropic provider exists.
//
// The two-layer split (Fetcher value type + Store observable class) is
// documented in EXPANSION_PLAN.md § 2. Fetchers are Sendable value types
// with no observable state (see AnthropicUsageFetcher in PR 2b). Stores
// hold @Published state on the main actor and are what SwiftUI observes.

import Foundation
import SwiftUI
import Combine

// MARK: - RequestSafety

/// Small hardening helpers for building credentialed requests from values
/// that originate in an API response (a team id, project id) or a keychain
/// account attribute (a user id). Server-issued strings are only semi-trusted:
/// a compromised or buggy endpoint could return an id containing "/", "?",
/// "#", or control characters that would alter the request path or split an
/// HTTP header. These helpers reject or encode such input.
public enum RequestSafety {
    /// Percent-encode a single URL PATH segment, rejecting characters that
    /// would change the path structure. Returns nil if the input is empty or
    /// contains characters not valid in a path segment even after encoding
    /// (control characters). "/" and "?" and "#" are encoded, not passed
    /// through, so an id like "../admin" cannot traverse the path.
    public static func pathSegment(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        // Reject control characters outright — they have no business in an id.
        if raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return nil
        }
        // Encode everything that is not an unreserved path character. This
        // encodes "/", "?", "#", "%", etc., so the segment cannot escape its
        // position in the path.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")   // RFC 3986 unreserved
        return raw.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// Validate a value destined for an HTTP header (e.g. a user id in an
    /// Authorization header). Rejects CR, LF, and other control characters
    /// that could split or inject headers. Returns the value unchanged when
    /// safe, or nil when it must not be sent.
    public static func headerValue(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return nil
        }
        return raw
    }
}

// MARK: - UsageTile

/// One renderable tile in the popover. A provider may contribute zero or
/// more tiles. The `Kind` enum encodes the presentation semantics without
/// coupling to a specific SwiftUI view; downstream PRs render each kind
/// with the appropriate component.
public struct UsageTile: Identifiable, Equatable, Sendable {
    public let id: String                   // "anthropic-5h", "codex-weekly"
    public let title: String                // "Session (5 hour)"
    public let kind: Kind

    public enum Kind: Equatable, Sendable {
        /// Progress-bar tile with a 0.0…1.0 fraction and optional reset time.
        case bar(fraction: Double, resetsAt: Date?, badge: String?)

        /// Balance tile — displayed as a monetary amount plus an optional
        /// plan label and reset time.
        case balance(remainingMinorUnits: Int, currency: String, plan: String?, resetsAt: Date?)

        /// Counter tile — used / limit with optional reset time.
        case counter(used: Int, limit: Int?, resetsAt: Date?)

        /// Freeform text tile — plan info, status warnings, "needs access".
        case text(status: String, subtitle: String?)

        /// The provider needs a permission the user has not granted.
        case needsAccess(path: String, guidance: String)
    }

    public init(id: String, title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

// MARK: - UsageProvider

/// Every provider (Anthropic, Codex, DeepSeek, Zed, xAI, OpenAI Platform,
/// Perplexity, Copilot, local-file readers) conforms to this protocol.
/// Providers are held in `AppDelegate.providers` as a heterogeneous
/// collection wrapped in `ProviderBox` for SwiftUI observation.
public protocol UsageProvider: AnyObject, ObservableObject {
    /// Stable identifier used for feature flags, notification-threshold
    /// tracking, and log correlation. Examples: "anthropic", "codex",
    /// "deepseek".
    var id: String { get }

    /// Display name in the popover section header and Settings toggle.
    var displayName: String { get }

    /// UserDefaults key that gates activation. Defaulted false. Reading and
    /// writing this flag is the provider's responsibility.
    var featureFlagKey: String { get }

    /// True when the user has activated the provider via Settings.
    var isEnabled: Bool { get }

    /// True when the provider has valid credentials or file access to
    /// operate. False means the tile should render a first-run onboarding
    /// state (paste key, grant access, etc.).
    var isConfigured: Bool { get }

    /// Timestamp of the most recent successful fetch. Nil before the
    /// first fetch.
    var lastUpdated: Date? { get }

    /// One-line human-readable error if the last fetch failed. Nil on
    /// success or when idle.
    var errorMessage: String? { get }

    /// Tiles this provider currently renders in the popover. Empty when
    /// the provider is disabled.
    var tiles: [UsageTile] { get }

    /// Kick off a fetch. Providers are responsible for their own cadence
    /// (5-minute Anthropic, 60-second Codex, hourly OpenAI Platform,
    /// etc.). This method is called by the shared timer in AppDelegate
    /// and may be called manually via the popover's Refresh button.
    func fetch()

    /// Clear stored state and (optionally) credentials. Called by the
    /// per-provider "Clear credentials" button in Settings.
    func clear()
}

// MARK: - ProviderBox

/// Type-erasing wrapper for SwiftUI. `@ObservedObject var: any UsageProvider`
/// does not compile in Swift 6 mode (existential + associated type) — the
/// box forwards `objectWillChange` from the underlying provider so views
/// can observe it uniformly.
///
/// This is one of the load-bearing catches from the pre-PR adversarial
/// review; the underlying protocol trial compiled fine, but the SwiftUI
/// observation site did not. `ProviderBox` is the fix.
@MainActor
public final class ProviderBox: ObservableObject, Identifiable {
    // `nonisolated` so consumers that are not themselves main-actor-isolated
    // (e.g. ProvidersModel.fetchEnabled, called from AppDelegate timer and
    // lifecycle closures) can read it without an actor hop. It is an
    // immutable `let` set once at init; the underlying provider's own methods
    // remain main-actor-isolated, so this only exposes the reference, not
    // unsynchronised mutable state.
    public nonisolated let provider: any UsageProvider
    // Cached at construction rather than reaching through `provider.id` on
    // every access — keeps `id` a nonisolated stored property so the
    // Identifiable conformance is Swift-6-strict-concurrency clean.
    public nonisolated let id: String

    private var cancellable: AnyCancellable?

    public init<P: UsageProvider>(_ provider: P) {
        self.provider = provider
        self.id = provider.id
        // Forward the underlying provider's change notifications so
        // SwiftUI redraws views observing this box.
        self.cancellable = provider.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
}

// MARK: - CredentialStore

/// Storage abstraction for provider credentials. Two backends:
/// `DefaultsStore` (for the legacy Anthropic cookie, retained for
/// backwards compatibility) and `KeychainStore` (for spending credentials
/// and any new provider going forward).
///
/// Concrete Keychain implementation lands in a follow-up PR once at
/// least one provider actually needs it. PR 2c ships the abstraction so
/// downstream PRs have a stable target.
public protocol CredentialStore {
    func read(_ key: String) -> Data?
    func write(_ key: String, _ value: Data)
    func delete(_ key: String)

    /// Read that distinguishes a genuinely absent credential (`.missing`)
    /// from a keychain that is present but unreadable (`.unavailable`, e.g.
    /// locked or access-denied). Only `.missing` should drive a provider's
    /// "not configured" onboarding state. The default implementation maps the
    /// plain `read` (found → `.found`, nil → `.missing`); `KeychainStore`
    /// overrides it to report the real status.
    func readResult(_ key: String) -> CredentialReadResult
}

public extension CredentialStore {
    func readResult(_ key: String) -> CredentialReadResult {
        if let data = read(key) { return .found(data) }
        return .missing
    }
}

/// Outcome of a credential read that separates a genuinely absent credential
/// (`.missing`) from a store that is present but unreadable (`.unavailable`,
/// e.g. a locked keychain). Only `.missing` should drive a "not configured"
/// onboarding state. `OSStatus` is Foundation's `Int32` security-result code.
public enum CredentialReadResult: Equatable {
    case found(Data)
    case missing
    case unavailable(OSStatus)
}

// MARK: - PasteKeyProvider

/// Optional capability for providers configured by pasting a secret (an API
/// key, a session cookie). The Settings toggle row shows a secure entry
/// field for any provider that conforms. Providers configured another way
/// (Codex reads a CLI file; Anthropic uses the cookie sheet) do not conform.
///
/// @MainActor because conformers are main-actor stores; the entry field is
/// itself on the main actor.
@MainActor
public protocol PasteKeyProvider {
    /// Placeholder shown in the entry field (e.g. "sk-…").
    var keyPlaceholder: String { get }
    /// True when a secret is currently stored.
    var hasKey: Bool { get }
    /// Store a pasted secret. Empty input clears it.
    func saveKey(_ raw: String)
    /// Human word for what the user pasted, used in status text like
    /// "Key saved in Keychain" or "Cookie saved in Keychain". Defaults to
    /// "Key" for API-key providers via the extension below; override on a
    /// concrete conformer for cookie/session providers (e.g. Perplexity).
    /// Declared as a protocol requirement — not just an extension — so
    /// existential dispatch (`box.provider as PasteKeyProvider`) picks up
    /// the concrete override rather than the default.
    var secretKindNoun: String { get }
}

public extension PasteKeyProvider {
    var secretKindNoun: String { "Key" }
}

// MARK: - SecondaryKeyProvider

/// Optional capability for providers that accept a SECOND, higher-privilege
/// secret gated behind a warning (e.g. xAI's management key, which can
/// create/rotate/delete API keys). The Settings row renders a second, opt-in
/// entry field with the warning text for any provider that conforms.
///
/// A provider adopting this must also adopt PasteKeyProvider for its primary
/// (required) key.
@MainActor
public protocol SecondaryKeyProvider {
    /// Placeholder for the secondary field.
    var secondaryKeyPlaceholder: String { get }
    /// Short label for the opt-in row (e.g. "Enable balance + history").
    var secondaryKeyLabel: String { get }
    /// Warning shown before the field (e.g. what the key can do).
    var secondaryKeyWarning: String { get }
    /// True when a secondary secret is stored.
    var hasSecondaryKey: Bool { get }
    /// Store a pasted secondary secret. Empty input clears it.
    func saveSecondaryKey(_ raw: String)
}

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
        default:
            return nil
        }
    }
}

/// UserDefaults-backed credential store. Used only for the legacy
/// Anthropic session cookie. New providers must use `KeychainStore`.
public struct DefaultsStore: CredentialStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func read(_ key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func write(_ key: String, _ value: Data) {
        defaults.set(value, forKey: key)
    }

    public func delete(_ key: String) {
        defaults.removeObject(forKey: key)
    }
}
