import SwiftUI
import AppKit

/// The app's preferences, in their own window. Opened from the status item's
/// right-click menu, so the popover only has to carry the usage itself.
struct SettingsView: View {
    /// Persisted, and written by AppDelegate.openSettings(page:) before the
    /// window shows: the popover's "Set Session Cookie…" lands on Accounts
    /// whichever page the user left the window on.
    static let pageKey = "settings_page"

    @ObservedObject var store: AccountsStore
    @ObservedObject var statusManager: StatusManager
    @AppStorage(SettingsView.pageKey) private var page: String = "accounts"
    @AppStorage("appearance_mode") private var appearanceMode: String = "system"
    @State private var cookieDrafts: [Int: String] = [:]

    // App-wide preferences. They live on slot 1 only because a UsageManager is
    // where the UserDefaults handle is; both accounts read the same keys, so
    // there is no second copy to keep in step.
    private var prefs: UsageManager { store.accounts[0] }

    /// The pasted-but-not-yet-saved cookie, keyed by slot so one account's
    /// draft can never be written onto the other's key.
    private func binding(for slot: Int) -> Binding<String> {
        Binding(get: { cookieDrafts[slot] ?? "" }, set: { cookieDrafts[slot] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Page", selection: $page) {
                Text("Accounts").tag("accounts")
                Text("General").tag("general")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)

            if page == "general" {
                generalPage
            } else {
                accountsPage
            }
        }
        .padding(20)
        .frame(width: 420)
        // Fixed height: the window takes its size from this view, and grows or
        // shrinks with it — on a page switch, when the Accessibility button
        // comes and goes, and when the live service list replaces the default.
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Accounts

    private var accountsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Session Cookie") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Go to Settings > Usage on claude.ai")
                    Text("2. Press F12 (or Cmd+Option+I)")
                    Text("3. Go to Network tab")
                    Text("4. Refresh page, click 'usage' request")
                    Text("5. Find 'Cookie' in Request Headers")
                    Text("6. Copy full cookie value (starts with anthropic-device-id=...)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .foregroundColor(.secondary)

                Button("View tutorial →") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Artzainnn/ClaudeUsageBar/blob/main/setup-guide.png")!)
                }
                .buttonStyle(.link)
            }

            ForEach(store.accounts, id: \.slot) { account in
                // displayName, not "Account \(slot)": once the user names an
                // account, the popover section header says "Work" and this said
                // "Account 2" — one account labelled two ways. Unnamed it still
                // reads "Account N".
                section(account.displayName) {
                    accountFields(account)
                }
            }
        }
    }

    private func accountFields(_ account: UsageManager) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name (optional)", text: Binding(
                get: { account.name },
                set: { account.name = $0; account.saveSettings() }
            ))
            .textFieldStyle(.roundedBorder)

            if account.hasCookie {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cookie saved ••••\(account.cookieSuffix)")
                    // Two cookies are indistinguishable by eye, so the address
                    // is the only way to tell which claude.ai account a slot
                    // actually holds.
                    if !account.email.isEmpty {
                        Text(account.email)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }

            // An account with no cookie renders no section in the popover, so
            // the error the buttons below can raise would otherwise have
            // nowhere to appear.
            if !account.hasCookie, let error = account.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }

            // The paste field always starts EMPTY. Pre-1.4 seeded it with a
            // truncated preview of the saved cookie, so saving without pasting
            // wrote that truncation back as the real cookie and broke
            // authentication.
            PasteableTextField(text: binding(for: account.slot),
                               placeholder: "Paste cookie here...")
                .frame(height: 50)
                .cornerRadius(4)

            HStack(spacing: 8) {
                Button("Save & Fetch") {
                    // Trimmed before the guard: a stray space or a trailing
                    // newline off the clipboard is not a cookie, and untrimmed
                    // it passed !isEmpty and overwrote a working one.
                    let pasted = (cookieDrafts[account.slot] ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !pasted.isEmpty else {
                        account.errorMessage = "Cookie field is empty!"
                        return
                    }
                    account.saveSessionCookie(pasted)
                    cookieDrafts[account.slot] = ""
                    account.fetchUsage()
                }
                .buttonStyle(.borderedProminent)

                if account.hasCookie {
                    Button("Clear") {
                        account.clearSessionCookie()
                        cookieDrafts[account.slot] = ""
                    }
                }
            }
        }
    }

    // MARK: - General

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("General") {
                Toggle(isOn: Binding(
                    get: { prefs.openAtLogin },
                    set: { newValue in
                        // Register first: on macOS 13+ the getter reports the
                        // real SMAppService state, so the redraw that the
                        // assignment triggers must see it already applied.
                        prefs.applyLoginItem(newValue)
                        prefs.openAtLogin = newValue
                    }
                )) {
                    label("Open at Login",
                          "Launch app automatically when you log in")
                }
                .toggleStyle(.checkbox)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Appearance")
                    Picker("Appearance", selection: $appearanceMode) {
                        Text("System").tag("system")
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: appearanceMode) { _ in
                        (NSApplication.shared.delegate as? AppDelegate)?.applyAppearancePreference()
                    }
                    Text("Match macOS, or keep the classic dark look")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            section("Notifications") {
                Toggle(isOn: Binding(
                    get: { prefs.usageNotificationsEnabled },
                    set: { prefs.usageNotificationsEnabled = $0 }
                )) {
                    label("Enable Usage Notifications",
                          "Get alerts at 25%, 50%, 75%, and 90% session usage")
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(
                    get: { prefs.statusNotificationsEnabled },
                    set: { prefs.statusNotificationsEnabled = $0 }
                )) {
                    label("Enable Status Notifications",
                          "Get alerts when tracked Claude services have an outage")
                }
                .toggleStyle(.checkbox)

                Button("Test Notification") {
                    prefs.sendTestNotification()
                }
            }

            section("Keyboard Shortcut") {
                Toggle(isOn: Binding(
                    get: { prefs.shortcutEnabled },
                    set: { newValue in
                        prefs.shortcutEnabled = newValue
                        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                            appDelegate.setShortcutEnabled(newValue)
                        }
                    }
                )) {
                    label("Enable Keyboard Shortcut (⌘U)",
                          "Toggle popup from anywhere. Disable if it conflicts with other apps.")
                }
                .toggleStyle(.checkbox)

                if prefs.shortcutEnabled && !prefs.isAccessibilityEnabled {
                    Button("Grant Accessibility Permission") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Accessibility permission may be needed for the shortcut to work in all apps")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("Status Alerts") {
                Text("Only tick the Claude services you use. Status issues with unticked services won't be shown or trigger alerts.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(statusManager.allComponents) { component in
                    Toggle(component.name, isOn: Binding(
                        get: { statusManager.isTracked(component.id) },
                        set: { _ in statusManager.toggleComponent(component.id) }
                    ))
                    .toggleStyle(.checkbox)
                }
            }

            // Off the popover, which now only carries usage, but kept: it is
            // the maintainer's donation link.
            Button(action: {
                NSWorkspace.shared.open(URL(string: "https://donate.stripe.com/3cIcN5b5H7Q8ay8bIDfIs02")!)
            }) {
                Text("☕ Buy Dev a Coffee")
                    .foregroundColor(.orange)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 10, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
        }
    }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
