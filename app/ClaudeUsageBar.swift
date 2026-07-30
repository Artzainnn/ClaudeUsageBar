import SwiftUI
import AppKit
import WebKit
import Carbon
import ServiceManagement

// Main entry point
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var usageManager: UsageManager!
    var statusManager: StatusManager!
    let signInController = SignInWindowController()
    var eventMonitor: Any?
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The UI is designed for dark; force dark appearance regardless of the
        // system light/dark setting (light mode had poor contrast).
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Accessory apps have no menu bar, so Cmd+V/C/X/A don't route anywhere
        // by default. A main menu with an Edit submenu (never visible) is what
        // makes the standard edit shortcuts work in every window and webview.
        setupEditMenu()

        // NSUserNotification (deprecated but works without permissions for unsigned apps)
        NSLog("✅ App launched, notifications ready")

        // Create status bar item with variable length for compact display
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Create Claude logo as initial icon
            updateStatusIcon(percentage: 0)
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self

            // Force the button to be visible
            button.appearsDisabled = false
            button.isEnabled = true
        }

        // Initialize managers
        usageManager = UsageManager(statusItem: statusItem, delegate: self)
        statusManager = StatusManager()

        // Create popover
        popover = NSPopover()
        // Initial guess; SwiftUI's intrinsic size (capped at 600) will drive the actual size.
        popover.contentSize = NSSize(width: 360, height: 320)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsageView(
            usageManager: usageManager,
            statusManager: statusManager
        ))

        // Fetch initial data
        usageManager.fetchUsage()
        statusManager.fetch()

        // Usage + Anthropic status are time-sensitive — poll every 5 min.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.usageManager.fetchUsage()
            self.statusManager.fetch()
        }

        // Set up Cmd+U keyboard shortcut
        setupKeyboardShortcut()
    }

    func setupEditMenu() {
        let mainMenu = NSMenu()

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    func presentSignInWindow() {
        popover?.performClose(nil)
        signInController.present { [weak self] cookie in
            self?.usageManager.addAccount(cookie: cookie)
        }
    }

    func setupKeyboardShortcut() {
        // Carbon RegisterEventHotKey needs no Accessibility permission —
        // just register when enabled. (The old Accessibility check/alert was
        // unnecessary and re-prompted on every rebuild with ad-hoc signing.)
        if usageManager.shortcutEnabled {
            registerGlobalHotKey()
        }
    }

    func setShortcutEnabled(_ enabled: Bool) {
        if enabled {
            registerGlobalHotKey()
        } else {
            unregisterGlobalHotKey()
        }
    }

    func registerGlobalHotKey() {
        // Guard against double registration
        if hotKeyRef != nil { return }

        var hotKeyID = EventHotKeyID()
        // Use simple numeric ID instead of FourCharCode
        hotKeyID.signature = 0x436C5542 // 'ClUB' as hex
        hotKeyID.id = 1

        // Cmd+U key code
        let keyCode: UInt32 = 32 // 'U' key
        let modifiers: UInt32 = UInt32(cmdKey)

        // Create event spec for hotkey
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        // Install event handler
        var handler: EventHandlerRef?
        let callback: EventHandlerUPP = { (nextHandler, event, userData) -> OSStatus in
            // Get the AppDelegate instance
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()

            // Toggle popover
            DispatchQueue.main.async {
                appDelegate.togglePopover()
            }

            return noErr
        }

        // Install the handler
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPtr, &handler)

        // Register the hotkey
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status == noErr {
            NSLog("✅ Registered Cmd+U hotkey successfully")
        } else {
            NSLog("❌ Failed to register hotkey, status: \(status)")
        }
    }

    func unregisterGlobalHotKey() {
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
            hotKeyRef = nil
            NSLog("🗑️ Unregistered Cmd+U hotkey")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    @objc func handleClick() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right click - show menu
            let menu = NSMenu()
            let toggleItem = NSMenuItem(title: "Toggle Usage (⌘U)", action: #selector(togglePopover), keyEquivalent: "u")
            toggleItem.keyEquivalentModifierMask = .command
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit ClaudeUsageBar", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // Left click - toggle popover
            togglePopover()
        }
    }

    func openPopover() {
        if let button = statusItem.button {
            // Rebuild the content view on every open. The hosting controller is
            // otherwise reused, so the SwiftUI view's @State (Settings expanded,
            // last measured height) persists between opens. Reopening after
            // Settings was left open then restores that tall height, which is too
            // big to fit below the menu bar and renders cropped at the top. A
            // fresh view always starts compact, so the popover only grows
            // downward and never opens oversized. (Pre-existing upstream bug.)
            popover.contentViewController = NSHostingController(rootView: UsageView(
                usageManager: usageManager,
                statusManager: statusManager
            ))

            // Force UI refresh by updating percentages
            DispatchQueue.main.async {
                self.usageManager.updatePercentages()
            }

            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Re-anchor once, shortly after the content has measured its true
            // height. The popover shows at a provisional size then grows to fit;
            // because it grows from a fixed bottom edge, when the menu bar icon is
            // at the top screen edge that growth pushes the top off-screen and it
            // renders cropped. Re-showing here (from an idle timer, NOT from a
            // SwiftUI layout callback — that desyncs the window from the content)
            // lets AppKit reposition it correctly below the icon for the true size.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self, self.popover.isShown,
                      let b = self.statusItem.button else { return }
                self.popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            }

            // Add event monitor to detect clicks outside the popover
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if self?.popover.isShown == true {
                    self?.closePopover()
                }
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)

        // Remove event monitor
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // `percentage` drives the spark icon color (green/yellow/red). `title`, when
    // provided, overrides the default single-percentage text — used by the
    // "both" display mode to show session and weekly side by side.
    func updateStatusIcon(percentage: Int, title: String? = nil) {
        guard let button = statusItem.button else { return }

        // Determine color based on percentage
        let color: NSColor
        if percentage < 70 {
            color = NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0) // Green
        } else if percentage < 90 {
            color = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0) // Yellow
        } else {
            color = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0) // Red
        }

        // Create spark icon with color
        let sparkIcon = createSparkIcon(color: color)

        // Set image and title
        button.image = sparkIcon
        button.title = title ?? " \(percentage)%"
    }

    func createSparkIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)

        image.lockFocus()

        // SVG path: M8 1L9 6L13 3L10 7L15 8L10 9L13 13L9 10L8 15L7 10L3 13L6 9L1 8L6 7L3 3L7 6L8 1Z
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8, y: 1))
        path.line(to: NSPoint(x: 9, y: 6))
        path.line(to: NSPoint(x: 13, y: 3))
        path.line(to: NSPoint(x: 10, y: 7))
        path.line(to: NSPoint(x: 15, y: 8))
        path.line(to: NSPoint(x: 10, y: 9))
        path.line(to: NSPoint(x: 13, y: 13))
        path.line(to: NSPoint(x: 9, y: 10))
        path.line(to: NSPoint(x: 8, y: 15))
        path.line(to: NSPoint(x: 7, y: 10))
        path.line(to: NSPoint(x: 3, y: 13))
        path.line(to: NSPoint(x: 6, y: 9))
        path.line(to: NSPoint(x: 1, y: 8))
        path.line(to: NSPoint(x: 6, y: 7))
        path.line(to: NSPoint(x: 3, y: 3))
        path.line(to: NSPoint(x: 7, y: 6))
        path.close()

        color.setFill()
        path.fill()

        image.unlockFocus()
        image.isTemplate = false

        return image
    }
}

// NSColor extension for hex conversion
extension NSColor {
    var hexString: String {
        guard let rgbColor = self.usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        let r = Int(rgbColor.redComponent * 255)
        let g = Int(rgbColor.greenComponent * 255)
        let b = Int(rgbColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// Main entry point
@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// What the menu bar text shows. Icon color always follows the higher of the
// two percentages when both are visible (see updateStatusBar).
enum MenuBarDisplayMode: String, CaseIterable {
    case session   // 5-hour session usage only (default, original behavior)
    case weekly    // 7-day weekly usage only
    case both      // session first, weekly second

    var label: String {
        switch self {
        case .session: return "Session (5-hour)"
        case .weekly:  return "Weekly (7-day)"
        case .both:    return "Both (session · weekly)"
        }
    }
}

// A saved claude.ai login. `cookie` is the full Cookie header string; `orgId`
// is cached after the first bootstrap lookup so switching accounts is instant.
struct ClaudeAccount: Identifiable, Codable, Equatable {
    let id: String
    var label: String
    var cookie: String
    var orgId: String?
}

// Lightweight per-account numbers for the switcher menu (the active account
// gets the full detailed fetch; others only need the two headline percents).
struct AccountSummary: Equatable {
    var session: Int = 0
    var weekly: Int = 0
    var failed: Bool = false
}

class UsageManager: ObservableObject {
    @Published var sessionUsage: Int = 0
    @Published var sessionLimit: Int = 100
    @Published var weeklyUsage: Int = 0
    @Published var weeklyLimit: Int = 100
    @Published var weeklySonnetUsage: Int = 0
    @Published var weeklySonnetLimit: Int = 100
    @Published var weeklyFableUsage: Int = 0
    @Published var weeklyFableLimit: Int = 100
    // Extra usage spend (from /overage_spend_limit). Shown only when there's spend.
    @Published var extraSpentMinor: Int = 0
    @Published var extraLimitMinor: Int = 0
    @Published var extraResetsAt: Date?
    @Published var freeCreditsMinor: Int = 0   // remaining free/promo credits (/prepaid/credits)
    @Published var creditCurrency: String = "USD"
    @Published var hasCreditUsage: Bool = false
    @Published var sessionResetsAt: Date?
    @Published var weeklyResetsAt: Date?
    @Published var weeklySonnetResetsAt: Date?
    @Published var weeklyFableResetsAt: Date?
    @Published var lastUpdated: Date = Date()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var usageNotificationsEnabled: Bool = true
    @Published var statusNotificationsEnabled: Bool = true
    @Published var openAtLogin: Bool = false
    @Published var hasWeeklySonnet: Bool = false
    @Published var hasWeeklyFable: Bool = false
    @Published var hasFetchedData: Bool = false
    @Published var shortcutEnabled: Bool = true
    @Published var menuBarDisplayMode: MenuBarDisplayMode = .session
    @Published var accounts: [ClaudeAccount] = []
    @Published var activeAccountId: String?
    @Published var accountSummaries: [String: AccountSummary] = [:]

    private var statusItem: NSStatusItem?
    private weak var delegate: AppDelegate?
    private var lastNotifiedThreshold: Int = 0

    var activeAccount: ClaudeAccount? {
        accounts.first { $0.id == activeAccountId } ?? accounts.first
    }

    // Cookie of the active account — all existing fetch paths read this.
    private var sessionCookie: String {
        activeAccount?.cookie ?? ""
    }

    init(statusItem: NSStatusItem?, delegate: AppDelegate? = nil) {
        self.statusItem = statusItem
        self.delegate = delegate
        loadAccounts()
        loadSettings()
    }

    func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: "claude_accounts"),
           let saved = try? JSONDecoder().decode([ClaudeAccount].self, from: data) {
            accounts = saved
        }
        // Migrate the pre-multi-account single cookie into an account entry.
        if accounts.isEmpty,
           let legacy = UserDefaults.standard.string(forKey: "claude_session_cookie"),
           !legacy.isEmpty {
            accounts = [ClaudeAccount(id: UUID().uuidString, label: "Account 1", cookie: legacy, orgId: nil)]
            UserDefaults.standard.removeObject(forKey: "claude_session_cookie")
            persistAccounts()
        }
        activeAccountId = UserDefaults.standard.string(forKey: "active_account_id") ?? accounts.first?.id
        if accounts.first(where: { $0.id == activeAccountId }) == nil {
            activeAccountId = accounts.first?.id
        }
        // Accounts still carrying a placeholder label (migrated, or added
        // before bootstrap answered) get their email resolved in background.
        for account in accounts where account.label.hasPrefix("Account ") {
            resolveLabel(for: account.id)
        }
    }

    func persistAccounts() {
        if accounts.isEmpty {
            // An empty write is only ever legitimate from removeAccount.
            // Log a stack so any other path that lands here is caught.
            NSLog("⚠️ persistAccounts writing EMPTY account list\n\(Thread.callStackSymbols.joined(separator: "\n"))")
        }
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: "claude_accounts")
        }
        if let id = activeAccountId {
            UserDefaults.standard.set(id, forKey: "active_account_id")
        } else {
            UserDefaults.standard.removeObject(forKey: "active_account_id")
        }
    }

    // Add (or refresh) an account from a captured/pasted cookie string. The
    // label is resolved from bootstrap's email afterwards; if the email matches
    // an existing account this replaces that account's cookie instead of
    // creating a duplicate.
    func addAccount(cookie: String, label: String? = nil) {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Cookie field is empty!"
            return
        }
        let account = ClaudeAccount(
            id: UUID().uuidString,
            label: label ?? "Account \(accounts.count + 1)",
            cookie: trimmed,
            orgId: nil
        )
        accounts.append(account)
        activeAccountId = account.id
        persistAccounts()
        resetDisplayedData()
        fetchUsage()
        resolveLabel(for: account.id)
    }

    // Ask bootstrap for the account email to use as the display label, and
    // fold duplicate logins (same email) into one entry.
    func resolveLabel(for accountId: String) {
        guard let account = accounts.first(where: { $0.id == accountId }) else { return }
        guard let url = URL(string: "https://claude.ai/api/bootstrap") else { return }
        var request = URLRequest(url: url)
        request.setValue(account.cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let acct = json["account"] as? [String: Any] else { return }
            let email = acct["email_address"] as? String
            let orgId = acct["lastActiveOrgId"] as? String
            DispatchQueue.main.async {
                guard let self = self,
                      let idx = self.accounts.firstIndex(where: { $0.id == accountId }) else { return }
                if let email = email, !email.isEmpty {
                    // Same email already saved under another entry? Keep the
                    // old entry's position, adopt the new cookie, drop the dup.
                    if let dupIdx = self.accounts.firstIndex(where: { $0.label == email && $0.id != accountId }) {
                        self.accounts[dupIdx].cookie = self.accounts[idx].cookie
                        self.accounts[dupIdx].orgId = orgId ?? self.accounts[dupIdx].orgId
                        let dupId = self.accounts[dupIdx].id
                        self.accounts.remove(at: idx)
                        if self.activeAccountId == accountId { self.activeAccountId = dupId }
                    } else {
                        self.accounts[idx].label = email
                        self.accounts[idx].orgId = orgId ?? self.accounts[idx].orgId
                    }
                } else if let orgId = orgId {
                    self.accounts[idx].orgId = orgId
                }
                self.persistAccounts()
            }
        }.resume()
    }

    func switchAccount(to id: String) {
        guard id != activeAccountId, accounts.contains(where: { $0.id == id }) else { return }
        activeAccountId = id
        lastNotifiedThreshold = UserDefaults.standard.integer(forKey: "last_notified_threshold_\(id)")
        persistAccounts()
        resetDisplayedData()
        fetchUsage()
    }

    func removeAccount(id: String) {
        accounts.removeAll { $0.id == id }
        accountSummaries.removeValue(forKey: id)
        UserDefaults.standard.removeObject(forKey: "last_notified_threshold_\(id)")
        if activeAccountId == id {
            activeAccountId = accounts.first?.id
            resetDisplayedData()
            if activeAccountId != nil { fetchUsage() }
        }
        persistAccounts()
        if accounts.isEmpty {
            delegate?.updateStatusIcon(percentage: 0)
        }
    }

    func loadSettings() {
        // Migrate from legacy single notifications_enabled flag (pre-v1.1) to split flags
        let hasUsageKey  = UserDefaults.standard.object(forKey: "usage_notifications_enabled")  != nil
        let hasStatusKey = UserDefaults.standard.object(forKey: "status_notifications_enabled") != nil

        if !hasUsageKey || !hasStatusKey {
            let legacyHasKey = UserDefaults.standard.object(forKey: "notifications_enabled") != nil
            let legacyValue  = legacyHasKey ? UserDefaults.standard.bool(forKey: "notifications_enabled") : true
            if !hasUsageKey {
                usageNotificationsEnabled = legacyValue
                UserDefaults.standard.set(legacyValue, forKey: "usage_notifications_enabled")
            }
            if !hasStatusKey {
                statusNotificationsEnabled = legacyValue
                UserDefaults.standard.set(legacyValue, forKey: "status_notifications_enabled")
            }
        }
        if hasUsageKey {
            usageNotificationsEnabled = UserDefaults.standard.bool(forKey: "usage_notifications_enabled")
        }
        if hasStatusKey {
            statusNotificationsEnabled = UserDefaults.standard.bool(forKey: "status_notifications_enabled")
        }

        // Reflect the real system login-item state, not just a stored bool.
        if #available(macOS 13.0, *) {
            openAtLogin = (SMAppService.mainApp.status == .enabled)
        } else {
            openAtLogin = UserDefaults.standard.bool(forKey: "open_at_login")
        }
        lastNotifiedThreshold = activeAccountId.map {
            UserDefaults.standard.integer(forKey: "last_notified_threshold_\($0)")
        } ?? 0
        // Default shortcut to enabled if not previously set
        if UserDefaults.standard.object(forKey: "shortcut_enabled") == nil {
            shortcutEnabled = true
        } else {
            shortcutEnabled = UserDefaults.standard.bool(forKey: "shortcut_enabled")
        }
        // Menu bar display mode — default to session (original behavior)
        if let stored = UserDefaults.standard.string(forKey: "menu_bar_display_mode"),
           let mode = MenuBarDisplayMode(rawValue: stored) {
            menuBarDisplayMode = mode
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(usageNotificationsEnabled,  forKey: "usage_notifications_enabled")
        UserDefaults.standard.set(statusNotificationsEnabled, forKey: "status_notifications_enabled")
        UserDefaults.standard.set(openAtLogin, forKey: "open_at_login")
        UserDefaults.standard.set(shortcutEnabled, forKey: "shortcut_enabled")
        UserDefaults.standard.set(menuBarDisplayMode.rawValue, forKey: "menu_bar_display_mode")
        UserDefaults.standard.synchronize()
    }

    // Actually register/unregister the app as a macOS login item.
    func applyLoginItem(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            NSLog("🔑 Login item \(enabled ? "registered" : "unregistered")")
        } catch {
            NSLog("❌ Login item error: \(error.localizedDescription)")
        }
    }

    // Clear the displayed usage numbers (used when switching/removing accounts
    // so one account's bars never linger while another account's data loads).
    func resetDisplayedData() {
        sessionUsage = 0
        weeklyUsage = 0
        weeklySonnetUsage = 0
        weeklyFableUsage = 0
        sessionResetsAt = nil
        weeklyResetsAt = nil
        weeklySonnetResetsAt = nil
        weeklyFableResetsAt = nil
        extraSpentMinor = 0
        extraLimitMinor = 0
        extraResetsAt = nil
        freeCreditsMinor = 0
        hasCreditUsage = false
        hasFetchedData = false
        hasWeeklySonnet = false
        hasWeeklyFable = false
        errorMessage = nil
        lastNotifiedThreshold = activeAccountId.map {
            UserDefaults.standard.integer(forKey: "last_notified_threshold_\($0)")
        } ?? 0

        // Update status bar to show 0%
        delegate?.updateStatusIcon(percentage: 0)
    }

    func fetchOrganizationId(completion: @escaping (String?) -> Void) {
        guard let account = activeAccount else { completion(nil); return }
        resolveOrgId(for: account, completion: completion)
    }

    // Org ID for any account: cached value, then the lastActiveOrg cookie
    // value, then a bootstrap call (result cached back onto the account).
    func resolveOrgId(for account: ClaudeAccount, completion: @escaping (String?) -> Void) {
        if let cached = account.orgId, !cached.isEmpty {
            completion(cached)
            return
        }

        let cookieParts = account.cookie.components(separatedBy: ";")
        for part in cookieParts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("lastActiveOrg=") {
                let orgId = trimmed.replacingOccurrences(of: "lastActiveOrg=", with: "")
                NSLog("📋 Found org ID in cookie: \(orgId)")
                cacheOrgId(orgId, accountId: account.id)
                completion(orgId)
                return
            }
        }

        // If not in cookie, fetch from bootstrap
        guard let url = URL(string: "https://claude.ai/api/bootstrap") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(account.cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        NSLog("📡 Fetching bootstrap to get org ID...")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let acct = json["account"] as? [String: Any],
                  let lastActiveOrgId = acct["lastActiveOrgId"] as? String else {
                NSLog("❌ Could not parse org ID from bootstrap")
                completion(nil)
                return
            }
            NSLog("✅ Got org ID from bootstrap: \(lastActiveOrgId)")
            self?.cacheOrgId(lastActiveOrgId, accountId: account.id)
            completion(lastActiveOrgId)
        }.resume()
    }

    private func cacheOrgId(_ orgId: String, accountId: String) {
        DispatchQueue.main.async {
            if let idx = self.accounts.firstIndex(where: { $0.id == accountId }),
               self.accounts[idx].orgId != orgId {
                self.accounts[idx].orgId = orgId
                self.persistAccounts()
            }
        }
    }

    func fetchUsage() {
        guard !sessionCookie.isEmpty else {
            DispatchQueue.main.async {
                self.errorMessage = "No account signed in"
                self.updateStatusBar()
            }
            return
        }

        isLoading = true
        errorMessage = nil

        // Extract org ID from cookie
        fetchOrganizationId { [weak self] orgId in
            guard let self = self, let orgId = orgId else {
                DispatchQueue.main.async {
                    self?.errorMessage = "Could not get org ID from cookie"
                    self?.isLoading = false
                }
                return
            }

            self.fetchUsageWithOrgId(orgId)
            self.fetchExtraUsage(orgId)
            self.fetchFreeCredits(orgId)
        }

        // Headline percents for every saved account (drives the switcher menu).
        fetchAccountSummaries()
    }

    func fetchAccountSummaries() {
        for account in accounts {
            resolveOrgId(for: account) { [weak self] orgId in
                guard let orgId = orgId else {
                    DispatchQueue.main.async {
                        self?.accountSummaries[account.id] = AccountSummary(failed: true)
                    }
                    return
                }
                guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage") else { return }
                var request = URLRequest(url: url)
                request.setValue(account.cookie, forHTTPHeaderField: "Cookie")
                request.setValue("*/*", forHTTPHeaderField: "Accept")
                request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
                request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                URLSession.shared.dataTask(with: request) { data, response, _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                              let data = data,
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            self.accountSummaries[account.id] = AccountSummary(failed: true)
                            return
                        }
                        var summary = AccountSummary()
                        if let fiveHour = json["five_hour"] as? [String: Any],
                           let util = fiveHour["utilization"] as? Double {
                            summary.session = Int(util)
                        }
                        if let sevenDay = json["seven_day"] as? [String: Any],
                           let util = sevenDay["utilization"] as? Double {
                            summary.weekly = Int(util)
                        }
                        self.accountSummaries[account.id] = summary
                    }
                }.resume()
            }
        }
    }

    // Remaining free/promo credits (balance) from /prepaid/credits.
    func fetchFreeCredits(_ orgId: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/prepaid/credits") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                // `amount` is the current balance; fall back to summing remaining tranches.
                if let amount = json["amount"] as? Int {
                    self.freeCreditsMinor = amount
                } else {
                    var remaining = 0
                    for key in ["tranches", "promo_tranches"] {
                        if let arr = json[key] as? [[String: Any]] {
                            for t in arr { remaining += (t["remaining_amount_minor_units"] as? Int) ?? 0 }
                        }
                    }
                    self.freeCreditsMinor = remaining
                }
                if let cur = json["currency"] as? String { self.creditCurrency = cur }
                NSLog("🎁 Free credits left: \(self.freeCreditsMinor) \(self.creditCurrency)")
            }
        }.resume()
    }

    // Extra usage spend + monthly limit live on a separate endpoint (not /usage).
    func fetchExtraUsage(_ orgId: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/overage_spend_limit") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

                let spent = (json["used_credits"] as? Int) ?? 0
                let limit = (json["monthly_credit_limit"] as? Int) ?? 0
                self.extraSpentMinor = spent
                self.extraLimitMinor = limit
                self.creditCurrency = (json["currency"] as? String) ?? "USD"
                if let resetStr = json["disabled_until"] as? String {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    self.extraResetsAt = f.date(from: resetStr) ?? ISO8601DateFormatter().date(from: resetStr)
                }
                self.hasCreditUsage = spent > 0
                NSLog("💳 Extra usage: \(spent)/\(limit) \(self.creditCurrency)")
            }
        }.resume()
    }

    func fetchUsageWithOrgId(_ orgId: String) {
        let urlString = "https://claude.ai/api/organizations/\(orgId)/usage"

        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid URL"
                self.isLoading = false
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Use the full cookie string (user provides all cookies, not just sessionKey)
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        NSLog("🔍 Fetching from: \(urlString)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                if let error = error {
                    NSLog("❌ Error: \(error.localizedDescription)")
                    self?.errorMessage = "Network error"
                    self?.updateStatusBar()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.errorMessage = "Invalid response"
                    self?.updateStatusBar()
                    return
                }

                NSLog("📡 Status: \(httpResponse.statusCode)")

                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    NSLog("📦 Response: \(responseString)")
                }

                if httpResponse.statusCode == 200, let data = data {
                    self?.parseUsageData(data)
                } else {
                    self?.errorMessage = "HTTP \(httpResponse.statusCode)"
                }

                self?.updateStatusBar()
            }
        }.resume()
    }

    func parseUsageData(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Invalid JSON"
                return
            }

            NSLog("📊 Parsing usage data...")

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Parse the actual claude.ai response format
            if let fiveHour = json["five_hour"] as? [String: Any] {
                if let sessionUtil = fiveHour["utilization"] as? Double {
                    sessionUsage = Int(sessionUtil)
                    sessionLimit = 100
                }
                if let resetsAtString = fiveHour["resets_at"] as? String {
                    NSLog("🕐 Session resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        sessionResetsAt = resetsAt
                        NSLog("✅ Parsed session reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse session reset time")
                    }
                }
            }

            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let weeklyUtil = sevenDay["utilization"] as? Double {
                    weeklyUsage = Int(weeklyUtil)
                    weeklyLimit = 100
                }
                if let resetsAtString = sevenDay["resets_at"] as? String {
                    NSLog("🕐 Weekly resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        weeklyResetsAt = resetsAt
                        NSLog("✅ Parsed weekly reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly reset time")
                    }
                }
            }

            // Check for seven_day_sonnet (Pro plan feature)
            if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
                hasWeeklySonnet = true
                if let sonnetUtil = sevenDaySonnet["utilization"] as? Double {
                    weeklySonnetUsage = Int(sonnetUtil)
                    weeklySonnetLimit = 100
                }
                if let resetsAtString = sevenDaySonnet["resets_at"] as? String {
                    NSLog("🕐 Weekly Sonnet resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        weeklySonnetResetsAt = resetsAt
                        NSLog("✅ Parsed weekly Sonnet reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly Sonnet reset time")
                    }
                }
            } else {
                hasWeeklySonnet = false
            }

            // Fable is a new, separately-counted model. It isn't a top-level
            // key like seven_day_sonnet — it lives in the `limits` array as a
            // model-scoped weekly limit (scope.model.display_name == "Fable").
            // The bar is only surfaced in the UI when usage is above 1%.
            hasWeeklyFable = false
            if let limits = json["limits"] as? [[String: Any]] {
                let fableLimit = limits.first { entry in
                    let scope = entry["scope"] as? [String: Any]
                    let model = scope?["model"] as? [String: Any]
                    return (model?["display_name"] as? String) == "Fable"
                }
                if let fable = fableLimit {
                    hasWeeklyFable = true
                    // `percent` may decode as Int or Double depending on payload.
                    if let p = fable["percent"] as? Int {
                        weeklyFableUsage = p
                    } else if let p = fable["percent"] as? Double {
                        weeklyFableUsage = Int(p)
                    }
                    weeklyFableLimit = 100
                    if let resetsAtString = fable["resets_at"] as? String {
                        NSLog("🕐 Weekly Fable resets_at string: \(resetsAtString)")
                        if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                            weeklyFableResetsAt = resetsAt
                            NSLog("✅ Parsed weekly Fable reset time: \(resetsAt)")
                        } else {
                            NSLog("❌ Failed to parse weekly Fable reset time")
                        }
                    }
                }
            }

            // (Prepaid usage credits are fetched separately from /prepaid/credits.)

            // Log what we found
            NSLog("✅ Parsed: Session \(sessionUsage)%, Weekly \(weeklyUsage)%\(hasWeeklySonnet ? ", Weekly Sonnet \(weeklySonnetUsage)%" : "")\(hasWeeklyFable ? ", Weekly Fable \(weeklyFableUsage)%" : "")")

            lastUpdated = Date()
            errorMessage = nil
            hasFetchedData = true

            // Update percentage values for progress bars
            updatePercentages()
        } catch {
            NSLog("❌ Parse error: \(error.localizedDescription)")
            errorMessage = "Parse error"
        }
    }

    func updateStatusBar() {
        let sessionPercent = Int((Double(sessionUsage) / Double(sessionLimit)) * 100)
        let weeklyPercent  = Int((Double(weeklyUsage) / Double(weeklyLimit)) * 100)

        // Build the menu bar title and choose which percentage drives the icon color.
        let title: String
        let colorPercent: Int
        switch menuBarDisplayMode {
        case .session:
            title = " \(sessionPercent)%"
            colorPercent = sessionPercent
        case .weekly:
            title = " \(weeklyPercent)%"
            colorPercent = weeklyPercent
        case .both:
            // Session first, weekly second. Color follows whichever is higher.
            title = " \(sessionPercent)% · \(weeklyPercent)%"
            colorPercent = max(sessionPercent, weeklyPercent)
        }

        // Update the icon color and text
        delegate?.updateStatusIcon(percentage: colorPercent, title: title)

        // Notifications remain session-based (unchanged).
        checkNotificationThresholds(percentage: sessionPercent)
    }

    func checkNotificationThresholds(percentage: Int) {
        NSLog("🔔 Checking notifications: percentage=\(percentage)%, enabled=\(usageNotificationsEnabled), lastNotified=\(lastNotifiedThreshold)%")

        guard usageNotificationsEnabled else {
            NSLog("⚠️ Usage notifications disabled")
            return
        }

        let thresholds = [25, 50, 75, 90]

        // Threshold state is per-account so switching accounts doesn't
        // suppress (or re-fire) alerts that belong to a different login.
        let thresholdKey = "last_notified_threshold_\(activeAccountId ?? "default")"

        for threshold in thresholds {
            if percentage >= threshold && lastNotifiedThreshold < threshold {
                NSLog("📬 Sending notification for \(threshold)% threshold")
                sendNotification(percentage: percentage, threshold: threshold)
                lastNotifiedThreshold = threshold
                // Persist the threshold
                UserDefaults.standard.set(lastNotifiedThreshold, forKey: thresholdKey)
                UserDefaults.standard.synchronize()
            }
        }

        // Reset if usage drops below current threshold
        if percentage < lastNotifiedThreshold {
            let newThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            NSLog("🔄 Resetting notification threshold from \(lastNotifiedThreshold)% to \(newThreshold)%")
            lastNotifiedThreshold = newThreshold
            UserDefaults.standard.set(lastNotifiedThreshold, forKey: thresholdKey)
            UserDefaults.standard.synchronize()
        }
    }

    func sendNotification(percentage: Int, threshold: Int) {
        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = "You've reached \(percentage)% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent notification for \(threshold)% threshold")
    }

    func sendTestNotification() {
        NSLog("🔔 Test notification button clicked")

        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = "Test notification - You've reached 75% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Test notification sent successfully")
    }

    @Published var sessionPercentage: Double = 0.0
    @Published var weeklyPercentage: Double = 0.0
    @Published var weeklySonnetPercentage: Double = 0.0
    @Published var weeklyFablePercentage: Double = 0.0

    func updatePercentages() {
        sessionPercentage = Double(sessionUsage) / Double(sessionLimit)
        weeklyPercentage = Double(weeklyUsage) / Double(weeklyLimit)
        weeklySonnetPercentage = Double(weeklySonnetUsage) / Double(weeklySonnetLimit)
        weeklyFablePercentage = Double(weeklyFableUsage) / Double(weeklyFableLimit)
    }

    func requestSignIn() {
        delegate?.presentSignInWindow()
    }
}

// MARK: - Embedded claude.ai sign-in

// Opens a real WebKit window on claude.ai's login page and captures the
// session cookie automatically once login completes — no DevTools digging.
// Uses a throwaway non-persistent cookie store, so signing in to a second
// account never reuses (or disturbs) an earlier account's session.
class SignInWindowController: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var pollTimer: Timer?
    private var onCookieCaptured: ((String) -> Void)?
    private var captured = false

    func present(onCookieCaptured: @escaping (String) -> Void) {
        // Already open — just bring it forward.
        if let window = window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        self.onCookieCaptured = onCookieCaptured
        captured = false

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        // Safari UA: Google blocks OAuth in generic embedded webviews, and
        // Cloudflare is friendlier to a recognized browser.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

        // Email login: the emailed magic link, opened in the default browser,
        // shows a one-time code — which gets typed back into THIS window's
        // login form. The hint spells that out; the paste field remains as a
        // fallback for completing the link inside this window instead.
        let hint = NSTextField(wrappingLabelWithString:
            "Email login: click the emailed link in your browser, then type the code it shows into the form below. (Or paste the link here and press Return.)")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor

        let linkField = NSTextField()
        linkField.placeholderString = "Optional: paste the emailed sign-in link here and press Return"
        linkField.font = NSFont.systemFont(ofSize: 11)
        linkField.target = self
        linkField.action = #selector(openPastedLink(_:))

        let stack = NSStackView(views: [hint, linkField, webView])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 0, right: 8)
        webView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Sign in to Claude"
        window.contentView = stack
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        self.webView = webView
        self.window = window

        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // The login flow is an SPA — route changes don't always fire
        // navigation callbacks, so poll the cookie store as well.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkForSession()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkForSession()
    }

    @objc func openPastedLink(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "claude.ai" || host.hasSuffix(".claude.ai")
                || host == "anthropic.com" || host.hasSuffix(".anthropic.com") else {
            NSSound.beep()
            sender.placeholderString = "That doesn't look like a claude.ai link — paste the full URL from the email"
            sender.stringValue = ""
            return
        }
        webView?.load(URLRequest(url: url))
        sender.stringValue = ""
    }

    private func checkForSession() {
        guard !captured, let webView = webView else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self, !self.captured else { return }
            let claudeCookies = cookies.filter { $0.domain.hasSuffix("claude.ai") }
            guard claudeCookies.contains(where: { $0.name == "sessionKey" && !$0.value.isEmpty }) else { return }
            self.captured = true
            let cookieString = claudeCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            NSLog("🔐 Captured session cookie from sign-in window (\(claudeCookies.count) cookies)")
            DispatchQueue.main.async {
                self.onCookieCaptured?(cookieString)
                self.closeWindow()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        teardown()
    }

    private func closeWindow() {
        window?.delegate = nil
        window?.close()
        teardown()
    }

    private func teardown() {
        pollTimer?.invalidate()
        pollTimer = nil
        webView?.navigationDelegate = nil
        webView = nil
        window = nil
        onCookieCaptured = nil
    }
}

// MARK: - Anthropic Service Status

struct StatusIncident: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String           // investigating | identified | monitoring | resolved
    let latestUpdate: String
    let updatedAt: Date?
    let componentIds: [String]
}

struct AffectedComponent: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String           // degraded_performance | partial_outage | major_outage
}

struct StatusComponent: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String           // operational | degraded_performance | ...
}

private let defaultTrackedComponents: [StatusComponent] = [
    StatusComponent(id: "c-claude-ai",      name: "claude.ai",                          status: "operational"),
    StatusComponent(id: "c-claude-console", name: "Claude Console (platform.claude.com)", status: "operational"),
    StatusComponent(id: "c-claude-api",     name: "Claude API (api.anthropic.com)",     status: "operational"),
    StatusComponent(id: "c-claude-code",    name: "Claude Code",                         status: "operational"),
    StatusComponent(id: "c-claude-cowork",  name: "Claude Cowork",                       status: "operational"),
    StatusComponent(id: "c-claude-gov",     name: "Claude for Government",              status: "operational"),
]

private let defaultTrackedComponentIdSet: Set<String> = Set(
    defaultTrackedComponents.map { $0.id }.filter { $0 != "c-claude-gov" }
)

class StatusManager: ObservableObject {
    @Published var indicator: String = "none"        // none | minor | major | critical (raw, global)
    @Published var statusDescription: String = "All systems operational"
    @Published var incidents: [StatusIncident] = []
    @Published var affectedComponents: [AffectedComponent] = []
    @Published var allComponents: [StatusComponent] = defaultTrackedComponents
    @Published var selectedComponentIds: Set<String> = defaultTrackedComponentIdSet
    @Published var lastUpdated: Date?
    @Published var hasFetched: Bool = false

    // Canonical URL (status.anthropic.com 302-redirects here)
    private let endpoint = URL(string: "https://status.claude.com/api/v2/summary.json")!

    init() {
        if let saved = UserDefaults.standard.array(forKey: "tracked_component_ids") as? [String] {
            selectedComponentIds = Set(saved)
        }
        // Clean up legacy debug pref if present
        UserDefaults.standard.removeObject(forKey: "status_preview_mode")
    }

    func toggleComponent(_ id: String) {
        if selectedComponentIds.contains(id) {
            selectedComponentIds.remove(id)
        } else {
            selectedComponentIds.insert(id)
        }
        UserDefaults.standard.set(Array(selectedComponentIds), forKey: "tracked_component_ids")
    }

    func isTracked(_ id: String) -> Bool {
        selectedComponentIds.contains(id)
    }

    // MARK: - Filtered/effective views (respect tracked components)

    var filteredAffectedComponents: [AffectedComponent] {
        affectedComponents.filter { selectedComponentIds.contains($0.id) }
    }

    var filteredIncidents: [StatusIncident] {
        incidents.filter { incident in
            guard !incident.componentIds.isEmpty else { return true }
            return incident.componentIds.contains(where: { selectedComponentIds.contains($0) })
        }
    }

    var effectiveIndicator: String {
        let trackedComponents = allComponents.filter { selectedComponentIds.contains($0.id) }
        let max = trackedComponents.map { severity(for: $0.status) }.max() ?? 0
        switch max {
        case 0:  return "none"
        case 1:  return "minor"
        case 2:  return "major"
        default: return "critical"
        }
    }

    private func severity(for componentStatus: String) -> Int {
        switch componentStatus {
        case "operational":          return 0
        case "under_maintenance":    return 1
        case "degraded_performance": return 1
        case "partial_outage":       return 2
        case "major_outage":         return 3
        default:                     return 0
        }
    }

    func fetch() {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self, let data = data else { return }
            self.parse(data)
        }.resume()
    }

    private func parse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? [String: Any],
              let indicator = status["indicator"] as? String,
              let desc = status["description"] as? String else {
            return
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var parsedIncidents: [StatusIncident] = []
        if let raw = json["incidents"] as? [[String: Any]] {
            for inc in raw {
                guard let id = inc["id"] as? String,
                      let name = inc["name"] as? String,
                      let st = inc["status"] as? String else { continue }
                if st == "resolved" || st == "postmortem" { continue }
                let updates = inc["incident_updates"] as? [[String: Any]] ?? []
                let latest = (updates.first?["body"] as? String) ?? ""
                let dateStr = (updates.first?["created_at"] as? String) ?? (inc["updated_at"] as? String)
                let updatedAt = dateStr.flatMap { iso.date(from: $0) ?? isoNoFrac.date(from: $0) }
                let compIds = (inc["components"] as? [[String: Any]] ?? [])
                    .compactMap { $0["id"] as? String }
                parsedIncidents.append(StatusIncident(
                    id: id, name: name, status: st, latestUpdate: latest,
                    updatedAt: updatedAt,
                    componentIds: compIds
                ))
            }
        }

        var parsedAffected: [AffectedComponent] = []
        var parsedAll: [StatusComponent] = []
        if let raw = json["components"] as? [[String: Any]] {
            for c in raw {
                guard let id = c["id"] as? String,
                      let name = c["name"] as? String,
                      let st = c["status"] as? String else { continue }
                parsedAll.append(StatusComponent(id: id, name: name, status: st))
                if st != "operational" {
                    parsedAffected.append(AffectedComponent(id: id, name: name, status: st))
                }
            }
        }

        DispatchQueue.main.async {
            let isFirstFetch = !self.hasFetched

            self.indicator = indicator
            self.statusDescription = desc
            self.incidents = parsedIncidents
            self.affectedComponents = parsedAffected
            if !parsedAll.isEmpty {
                self.allComponents = parsedAll
                // First time we see real components: track all except Claude for Government by default
                if UserDefaults.standard.array(forKey: "tracked_component_ids") == nil {
                    let defaultIds = parsedAll
                        .filter { !$0.name.localizedCaseInsensitiveContains("Government") }
                        .map { $0.id }
                    self.selectedComponentIds = Set(defaultIds)
                    UserDefaults.standard.set(Array(self.selectedComponentIds),
                                              forKey: "tracked_component_ids")
                }
            }
            self.lastUpdated = Date()
            self.hasFetched = true

            // Notify on transitions of EFFECTIVE (filtered) indicator
            let effective = self.effectiveIndicator
            let previous = UserDefaults.standard.string(forKey: "last_effective_indicator")
            if !isFirstFetch, let previous = previous, previous != effective {
                self.notifyStatusChange(to: effective, description: desc)
            }
            UserDefaults.standard.set(effective, forKey: "last_effective_indicator")
        }
    }

    private func notifyStatusChange(to indicator: String, description: String) {
        guard UserDefaults.standard.bool(forKey: "status_notifications_enabled") else { return }

        let notification = NSUserNotification()
        if indicator == "none" {
            notification.title = "Claude is back online"
            notification.informativeText = "All systems operational"
        } else {
            notification.title = "Claude status: \(description)"
            notification.informativeText = "Visit status.anthropic.com for details"
        }
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent status-change notification: \(indicator)")
    }
}

// Custom NSTextField that properly handles paste
class CustomTextField: NSTextField {
    var onTextChange: ((String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            if (event.modifierFlags.contains(.command)) {
                switch event.charactersIgnoringModifiers {
                case "v":
                    if let string = NSPasteboard.general.string(forType: .string) {
                        self.stringValue = string
                        onTextChange?(string)
                        NSLog("ClaudeUsage: Pasted text length: \(string.count)")
                        return true
                    }
                case "a":
                    self.currentEditor()?.selectAll(nil)
                    return true
                case "c":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.stringValue, forType: .string)
                    return true
                case "x":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.stringValue, forType: .string)
                    self.stringValue = ""
                    onTextChange?("")
                    return true
                default:
                    break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?(self.stringValue)
    }
}

// Custom TextView that ensures keyboard commands work
class PasteableNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v": // Paste
                paste(nil)
                return true
            case "c": // Copy
                copy(nil)
                return true
            case "x": // Cut
                cut(nil)
                return true
            case "a": // Select All
                selectAll(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// Multi-line text field with proper paste support
struct PasteableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = PasteableNSTextView()

        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 11)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true

        // Enable wrapping
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PasteableNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PasteableTextField

        init(_ parent: PasteableTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// Custom progress bar. Replaces the native ProgressView, whose fill desaturates
// to gray while the popover window isn't key (the popover opens without focus),
// leaving the usage bars gray until clicked. A plain filled shape keeps its
// color regardless of window focus.
struct UsageBar: View {
    let value: Double   // 0.0 ... 1.0
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

struct UsageView: View {
    @ObservedObject var usageManager: UsageManager
    @ObservedObject var statusManager: StatusManager
    @State private var sessionCookieInput: String = ""
    @State private var showingCookieInput: Bool = false
    @State private var showingSettings: Bool = false
    @State private var showingStatusDetails: Bool = false
    @State private var measuredHeight: CGFloat = 250

    private let maxPopupHeight: CGFloat = 600

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .padding()
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        }
                    )
            }
            .frame(width: 360, height: min(max(measuredHeight, 100), maxPopupHeight))
            // Darken the translucent popover material so contrast stays consistent
            // no matter how light the content behind the popover is.
            .background(Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.62))
            .onPreferenceChange(ContentHeightKey.self) { value in
                guard value > 0 else { return }
                measuredHeight = value
            }
            .onAppear {
                usageManager.updatePercentages()
            }
            .onChange(of: showingSettings) { isOpen in
                if isOpen {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo("settings-anchor", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                if !usageManager.accounts.isEmpty {
                    accountMenu
                }
            }
            .padding(.bottom, 4)

            if let error = usageManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.bottom, 8)
            }

            // Only show usage if data has been fetched
            if !usageManager.hasFetchedData {
                VStack(alignment: .leading, spacing: 10) {
                    Text(usageManager.accounts.isEmpty
                         ? "👋 Welcome! Sign in to your Claude account to get started."
                         : "👋 Welcome! Fetching usage data…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if usageManager.accounts.isEmpty {
                        Button("Sign in to Claude…") {
                            usageManager.requestSignIn()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 8)
            }

            // Session Usage
            if usageManager.hasFetchedData {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Session (5 hour)")
                        .font(.subheadline)
                    Spacer()
                    if let resetTime = usageManager.sessionResetsAt {
                        Text("Resets \(formatResetTime(resetTime))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                UsageBar(value: usageManager.sessionPercentage,
                         color: colorForPercentage(usageManager.sessionPercentage))

                Text("\(Int(usageManager.sessionPercentage * 100))% used")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Weekly Usage
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Weekly (7 day)")
                        .font(.subheadline)
                    Spacer()
                    if let resetTime = usageManager.weeklyResetsAt {
                        Text("Resets \(formatResetTime(resetTime, includeDate: true))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                UsageBar(value: usageManager.weeklyPercentage,
                         color: colorForPercentage(usageManager.weeklyPercentage))

                Text("\(Int(usageManager.weeklyPercentage * 100))% used")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Weekly Sonnet Usage (only show if available)
            if usageManager.hasWeeklySonnet && usageManager.hasFetchedData {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Weekly Sonnet (7 day)")
                            .font(.subheadline)
                        Spacer()
                        if let resetTime = usageManager.weeklySonnetResetsAt {
                            Text("Resets \(formatResetTime(resetTime, includeDate: true))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    UsageBar(value: usageManager.weeklySonnetPercentage,
                             color: colorForPercentage(usageManager.weeklySonnetPercentage))

                    Text("\(Int(usageManager.weeklySonnetPercentage * 100))% used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Weekly Fable Usage — only surfaced once usage is above 1%
            // (new model, counted separately; hidden while idle to avoid clutter).
            if usageManager.hasWeeklyFable && usageManager.hasFetchedData && usageManager.weeklyFableUsage >= 1 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Weekly Fable (7 day)")
                            .font(.subheadline)
                        Spacer()
                        if let resetTime = usageManager.weeklyFableResetsAt {
                            Text("Resets \(formatResetTime(resetTime, includeDate: true))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    UsageBar(value: usageManager.weeklyFablePercentage,
                             color: colorForPercentage(usageManager.weeklyFablePercentage))

                    Text("\(Int(usageManager.weeklyFablePercentage * 100))% used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Usage credits (pay-as-you-go). Only shown once credits are actually
            // used; links out to manage credits on claude.ai.
            if usageManager.hasCreditUsage || usageManager.freeCreditsMinor > 0 {
                let spentMinor = usageManager.extraSpentMinor
                let limitMinor = usageManager.extraLimitMinor
                let pct = limitMinor > 0 ? Double(spentMinor) / Double(limitMinor) : 0
                let pctInt = Int((pct * 100).rounded())
                // Show the exact % up to the limit; once over, just say "over limit".
                let pctLabel = pctInt > 100 ? "over limit" : "\(pctInt)%"
                let fmt: (Int) -> String = { minor in
                    let v = Double(minor) / 100.0
                    return usageManager.creditCurrency == "USD"
                        ? String(format: "$%.2f", v)
                        : String(format: "%@ %.2f", usageManager.creditCurrency, v)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Extra usage")
                            .font(.subheadline)
                        Spacer()
                        Button(action: {
                            if let url = URL(string: "https://claude.ai/new#settings/usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            Text("Manage →")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.borderless)
                    }

                    // Reset date, shortened (e.g. "Resets Aug 1") so it fits inline.
                    let shortReset: String? = usageManager.extraResetsAt.map { d in
                        let f = DateFormatter(); f.dateFormat = "MMM d"
                        return "Resets \(f.string(from: d))"
                    }

                    // Spend vs monthly limit — only when there's actual spend.
                    if usageManager.hasCreditUsage {
                        if limitMinor > 0 {
                            UsageBar(value: min(pct, 1.0), color: colorForPercentage(pct))
                        }
                        HStack {
                            Text(limitMinor > 0
                                 ? "\(fmt(spentMinor)) of \(fmt(limitMinor)) · \(pctLabel)"
                                 : "\(fmt(spentMinor)) spent")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            if let r = shortReset {
                                Text(r)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if usageManager.freeCreditsMinor > 0 {
                        Text("\(fmt(usageManager.freeCreditsMinor)) free credits left")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .opacity(0.85)
                    }
                }
            }

            // Discreet reassurance line naming whichever of Fable / extra usage
            // is not being consumed (nothing shown when both are active).
            if usageManager.hasFetchedData {
                let fableActive = usageManager.hasWeeklyFable && usageManager.weeklyFableUsage >= 1
                let extraActive = usageManager.hasCreditUsage || usageManager.freeCreditsMinor > 0
                if !fableActive || !extraActive {
                    Text(
                        !fableActive && !extraActive ? "No Fable or extra usage"
                        : !extraActive ? "No extra usage"
                        : "No Fable usage"
                    )
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .opacity(0.6)
                }
            }
            }

            if statusManager.hasFetched {
                Divider()
            }

            // Anthropic service status (compact; expandable on issue)
            if statusManager.hasFetched {
                let effective = statusManager.effectiveIndicator
                let filteredIncidents = statusManager.filteredIncidents
                let filteredAffected = statusManager.filteredAffectedComponents
                let hasIssue = effective != "none"
                    && (!filteredIncidents.isEmpty || !filteredAffected.isEmpty)

                VStack(alignment: .leading, spacing: 8) {
                    // Compact header row
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(statusColor(for: effective))
                            .frame(width: 8, height: 8)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(effective == "none"
                                 ? "All Claude services operational"
                                 : statusManager.statusDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(statusContextLine(for: statusManager))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if hasIssue {
                            Button(action: { showingStatusDetails.toggle() }) {
                                HStack(spacing: 2) {
                                    Text(showingStatusDetails ? "Hide" : "Details")
                                    Image(systemName: showingStatusDetails ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 8))
                                }
                                .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    // Expanded panel
                    if hasIssue && showingStatusDetails {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(filteredIncidents) { incident in
                                VStack(alignment: .leading, spacing: 6) {
                                    // Title
                                    Text(incident.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .fixedSize(horizontal: false, vertical: true)

                                    // Status badge + updated time
                                    HStack(spacing: 8) {
                                        Text(incident.status.uppercased())
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(badgeColor(for: incident.status))
                                            .cornerRadius(3)
                                        if let updated = incident.updatedAt {
                                            Text("Updated \(relativeTime(updated))")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    // Body
                                    if !incident.latestUpdate.isEmpty {
                                        Text(incident.latestUpdate)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.top, 2)
                                    }
                                }
                            }

                            // Affected components (when no formal incident)
                            if filteredIncidents.isEmpty && !filteredAffected.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Affected services")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                    ForEach(filteredAffected) { c in
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(Color.orange)
                                                .frame(width: 5, height: 5)
                                            Text(c.name).font(.caption2)
                                            Spacer()
                                            Text(componentLabel(c.status))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }

                            Divider()

                            HStack {
                                if let lastCheck = statusManager.lastUpdated {
                                    Text("Checked \(relativeTime(lastCheck))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: {
                                    NSWorkspace.shared.open(URL(string: "https://status.claude.com")!)
                                }) {
                                    Text("Open status page →")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.10))
                        .cornerRadius(6)
                    }
                }
            }

            if usageManager.hasFetchedData {
            Divider()

            HStack {
                Text("Last updated: \(formatTime(usageManager.lastUpdated))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Refresh") {
                    usageManager.fetchUsage()
                    statusManager.fetch()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            }

            Button(showingCookieInput ? "Hide Manual Cookie" : "Add Account Manually (cookie)") {
                showingCookieInput.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingCookieInput {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Manual fallback — if the sign-in window doesn't work, paste a cookie from your browser:")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Go to Settings > Usage on claude.ai")
                        Text("2. Press F12 (or Cmd+Option+I)")
                        Text("3. Go to Network tab")
                        Text("4. Refresh page, click 'usage' request")
                        Text("5. Find 'Cookie' in Request Headers")
                        Text("6. Copy full cookie value\n   (starts with anthropic-device-id=...)")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paste full cookie string:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        VStack(spacing: 4) {
                            PasteableTextField(text: $sessionCookieInput, placeholder: "Paste cookie here...")
                                .frame(height: 60)
                                .cornerRadius(4)

                            HStack(spacing: 8) {
                                Button("Add Account & Fetch") {
                                    NSLog("ClaudeUsage: Add account clicked, input length: \(sessionCookieInput.count)")
                                    usageManager.addAccount(cookie: sessionCookieInput)
                                    if !sessionCookieInput.isEmpty {
                                        sessionCookieInput = ""
                                        showingCookieInput = false
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }

            // Settings Section
            Button(showingSettings ? "Hide Settings" : "Settings") {
                showingSettings.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingSettings {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Menu Bar Display")
                            .font(.caption)
                        Picker("", selection: Binding(
                            get: { usageManager.menuBarDisplayMode },
                            set: { newValue in
                                usageManager.menuBarDisplayMode = newValue
                                usageManager.saveSettings()
                                // Re-render the menu bar text/color immediately.
                                usageManager.updateStatusBar()
                            }
                        )) {
                            ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .font(.caption)
                        Text("Choose what the menu bar shows. In Both mode the\nicon color follows whichever usage is higher.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle(isOn: Binding(
                        get: { usageManager.openAtLogin },
                        set: { newValue in
                            usageManager.openAtLogin = newValue
                            usageManager.applyLoginItem(newValue)
                            usageManager.saveSettings()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open at Login")
                                .font(.caption)
                            Text("Launch app automatically when you log in")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { usageManager.usageNotificationsEnabled },
                            set: { newValue in
                                usageManager.usageNotificationsEnabled = newValue
                                usageManager.saveSettings()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Usage Notifications")
                                    .font(.caption)
                                Text("Get alerts at 25%, 50%, 75%,\nand 90% session usage")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)

                        Toggle(isOn: Binding(
                            get: { usageManager.statusNotificationsEnabled },
                            set: { newValue in
                                usageManager.statusNotificationsEnabled = newValue
                                usageManager.saveSettings()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Status Notifications")
                                    .font(.caption)
                                Text("Get alerts when tracked Claude services have an outage")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)

                        Button("Test Notification") {
                            usageManager.sendTestNotification()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { usageManager.shortcutEnabled },
                            set: { newValue in
                                usageManager.shortcutEnabled = newValue
                                usageManager.saveSettings()
                                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                                    appDelegate.setShortcutEnabled(newValue)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keyboard Shortcut (⌘U)")
                                    .font(.caption)
                                Text("Toggle popup from anywhere.\nDisable if it conflicts with other apps.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Status alerts: services to track")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("Only tick the Claude services you use. Status issues with unticked services won't be shown or trigger alerts.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(statusManager.allComponents) { component in
                            Toggle(isOn: Binding(
                                get: { statusManager.isTracked(component.id) },
                                set: { _ in statusManager.toggleComponent(component.id) }
                            )) {
                                Text(component.name)
                                    .font(.caption2)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }

                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

                // Anchor for scroll-to-bottom when Settings opens
                Color.clear
                    .frame(height: 1)
                    .id("settings-anchor")
            }
        }
    }

    func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func formatResetTime(_ date: Date, includeDate: Bool = false) -> String {
        let formatter = DateFormatter()

        if includeDate {
            // Format: "on 31 Jan 2026 at 7:59 AM"
            formatter.dateFormat = "d MMM yyyy 'at' h:mm a"
            return "on \(formatter.string(from: date))"
        } else {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "at \(formatter.string(from: date))"
        }
    }

    func colorForPercentage(_ percentage: Double) -> Color {
        if percentage < 0.7 {
            return .green
        } else if percentage < 0.9 {
            return .orange
        } else {
            return .red
        }
    }

    func statusColor(for indicator: String) -> Color {
        switch indicator {
        case "none":     return .green
        case "minor":    return .yellow
        case "major":    return .orange
        case "critical": return .red
        default:         return .gray
        }
    }

    func statusLabel(for indicator: String, description: String) -> String {
        if indicator == "none" {
            return "Claude: all systems operational"
        }
        return "Claude: \(description)"
    }

    func relativeTime(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 {
            let m = elapsed / 60
            return "\(m) min\(m == 1 ? "" : "s") ago"
        }
        if elapsed < 86_400 {
            let h = elapsed / 3600
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = elapsed / 86_400
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }

    func statusContextLine(for sm: StatusManager) -> String {
        let tracked = sm.allComponents.filter { sm.selectedComponentIds.contains($0.id) }
        let trackedNames = tracked.prefix(4).map { shortName($0.name) }.joined(separator: ", ")
        let extra = tracked.count > 4 ? " +\(tracked.count - 4)" : ""
        let trackedSummary = tracked.isEmpty ? "No services tracked" : "Tracks \(trackedNames)\(extra)"

        if sm.effectiveIndicator == "none" {
            if let lastCheck = sm.lastUpdated {
                return "\(trackedSummary) · checked \(relativeTime(lastCheck))"
            }
            return trackedSummary
        }
        let affected = sm.filteredAffectedComponents
        if !affected.isEmpty {
            let names = affected.prefix(3).map { shortName($0.name) }.joined(separator: ", ")
            let more = affected.count > 3 ? " +\(affected.count - 3)" : ""
            return "Affects: \(names)\(more)"
        }
        if let lastCheck = sm.lastUpdated {
            return "Checked \(relativeTime(lastCheck))"
        }
        return ""
    }

    func shortName(_ raw: String) -> String {
        if let paren = raw.range(of: " (") {
            return String(raw[..<paren.lowerBound])
        }
        return raw
    }

    // Compact account switcher in the header. Each entry shows the account's
    // headline percents so you can compare accounts without switching.
    var accountMenu: some View {
        Menu {
            ForEach(usageManager.accounts) { account in
                Button(action: { usageManager.switchAccount(to: account.id) }) {
                    Text((account.id == usageManager.activeAccount?.id ? "✓ " : "") + accountMenuLabel(account))
                }
            }
            Divider()
            Button("Add Account…") {
                usageManager.requestSignIn()
            }
            if let active = usageManager.activeAccount {
                Button("Remove \(active.label)") {
                    usageManager.removeAccount(id: active.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 11))
                Text(usageManager.activeAccount?.label ?? "Account")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(maxWidth: 170)
    }

    func accountMenuLabel(_ account: ClaudeAccount) -> String {
        if let summary = usageManager.accountSummaries[account.id] {
            if summary.failed {
                return "\(account.label) — session expired"
            }
            return "\(account.label) — S \(summary.session)% · W \(summary.weekly)%"
        }
        return account.label
    }

    func badgeColor(for status: String) -> Color {
        switch status {
        case "investigating": return Color.red.opacity(0.8)
        case "identified":    return Color.orange
        case "monitoring":    return Color.blue
        case "resolved":      return Color.green
        default:              return Color.gray
        }
    }

    func componentLabel(_ status: String) -> String {
        switch status {
        case "degraded_performance": return "degraded"
        case "partial_outage":       return "partial outage"
        case "major_outage":         return "major outage"
        case "under_maintenance":    return "maintenance"
        default:                     return status
        }
    }

}
