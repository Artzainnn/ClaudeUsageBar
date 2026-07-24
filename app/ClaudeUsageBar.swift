import SwiftUI
import AppKit
import WebKit
import Carbon
import ServiceManagement

extension Notification.Name {
    /// Posted when the popover opens; the usage view scrolls back to the top.
    static let cubScrollToTop = Notification.Name("cubScrollToTop")
}

/// Minimal localization that follows the macOS language: German UI when the
/// user's preferred language is German, English otherwise. Service names and
/// technical tokens stay in English on purpose.
enum Loc {
    static let isGerman: Bool =
        (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("de")

    /// Pick the German or English variant.
    static func s(_ en: String, _ de: String) -> String { isGerman ? de : en }
}

/// Build metadata for the discreet footer in the popup, so it is obvious at a
/// glance which build (type + time) is currently running.
enum BuildInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
    static var configuration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }
    /// Modification date of the executable, formatted "dd.MM.yyyy HH:mm".
    static var buildDate: String {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return "?" }
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm"
        f.locale = Locale(identifier: "de_DE")
        return f.string(from: date)
    }
}

// Main entry point
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var usageManager: UsageManager!
    var statusManager: StatusManager!
    var updateManager: UpdateManager!
    var eventMonitor: Any?
    var hotKeyRef: EventHotKeyRef?
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Follow the system light/dark setting instead of forcing dark. The
        // popup uses system materials and semantic colors so both modes read well.

        // NSUserNotification (deprecated but works without permissions for unsigned apps)
        NSLog("✅ App launched, notifications ready")

        // Create status bar item with variable length for compact display
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Create Claude logo as initial icon
            updateStatusIcon(sessionPercent: 0, weeklyPercent: 0)
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
        updateManager = UpdateManager()

        // Create popover
        popover = NSPopover()
        // Initial guess; the real height is pushed in from UsageView via
        // onHeightChange as soon as SwiftUI measures its content, so NSPopover
        // always knows the true size and positions the window correctly.
        popover.contentSize = NSSize(width: 360, height: 320)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsageView(
            usageManager: usageManager,
            statusManager: statusManager,
            updateManager: updateManager,
            onHeightChange: { [weak self] height in
                self?.setPopoverHeight(height)
            }
        ))

        // Fetch initial data
        usageManager.fetchUsage()
        statusManager.fetch()
        updateManager.fetch()

        // Usage + Anthropic status are time-sensitive — poll every 5 min.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.usageManager.fetchUsage()
            self.statusManager.fetch()
        }

        // App updates are infrequent (new release at most weekly) — poll every 3 hours.
        Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in
            self.updateManager.fetch()
        }

        // Set up Cmd+U keyboard shortcut
        setupKeyboardShortcut()
    }

    func setupKeyboardShortcut() {
        // Check Accessibility permissions
        checkAccessibilityPermissions()

        // Only register if user has the shortcut enabled
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

    func checkAccessibilityPermissions() {
        // Check if app has Accessibility permissions
        let trusted = AXIsProcessTrusted()

        if !trusted {
            NSLog("⚠️ Accessibility permissions not granted")
            // Show alert to guide user
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let alert = NSAlert()
                alert.messageText = Loc.s("Accessibility Permission Required", "Bedienungshilfen-Freigabe erforderlich")
                alert.informativeText = Loc.s("ClaudeUsageBar needs Accessibility permission to use the Cmd+U keyboard shortcut.\n\nPlease enable it in:\nSystem Settings → Privacy & Security → Accessibility", "ClaudeUsageBar benötigt die Bedienungshilfen-Freigabe für das Tastenkürzel Cmd+U.\n\nBitte aktiviere sie unter:\nSystemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen")
                alert.alertStyle = .informational
                alert.addButton(withTitle: Loc.s("Open System Settings", "Systemeinstellungen öffnen"))
                alert.addButton(withTitle: Loc.s("Skip for Now", "Vorerst überspringen"))

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    // Open System Settings
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        } else {
            NSLog("✅ Accessibility permissions granted")
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

    /// Update the popover's content height to match the SwiftUI content, bounded
    /// by the visible screen height so the window always fits and stays anchored
    /// under the menu bar instead of being pushed off the top of the screen.
    func setPopoverHeight(_ height: CGFloat) {
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 40
        let clamped = max(200, min(height, maxHeight))
        guard abs(popover.contentSize.height - clamped) > 0.5 else { return }
        popover.contentSize = NSSize(width: 360, height: clamped)
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
            let toggleItem = NSMenuItem(title: Loc.s("Toggle Usage (⌘U)", "Nutzung anzeigen (⌘U)"), action: #selector(togglePopover), keyEquivalent: "u")
            toggleItem.keyEquivalentModifierMask = .command
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: Loc.s("Quit ClaudeUsageBar", "ClaudeUsageBar beenden"), action: #selector(quitApp), keyEquivalent: "q"))
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
            // Force UI refresh by updating percentages
            DispatchQueue.main.async {
                self.usageManager.updatePercentages()
            }

            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Always reset the scroll position to the top when opening, so the
            // most important rows (session + weekly) are never hidden above the fold.
            NotificationCenter.default.post(name: .cubScrollToTop, object: nil)

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

    /// Opens the settings window with the tab bar. The popover is closed so the
    /// window can come to the front; the window is created on first open and
    /// reused afterwards.
    func openSettingsWindow() {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(
            usageManager: usageManager,
            statusManager: statusManager
        ))
        let window = NSWindow(contentViewController: hosting)
        window.title = Loc.s("Settings", "Einstellungen")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func updateStatusIcon(sessionPercent: Int, weeklyPercent: Int) {
        guard let button = statusItem.button else { return }

        // The weekly (7-day) limit is the binding constraint, so the spark
        // icon color reflects the weekly usage level.
        let color: NSColor
        if weeklyPercent < 70 {
            color = NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0) // Green
        } else if weeklyPercent < 90 {
            color = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0) // Yellow
        } else {
            color = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0) // Red
        }

        // Create spark icon with color
        let sparkIcon = createSparkIcon(color: color)

        // Set image and title: show both session and weekly at a glance.
        button.image = sparkIcon
        button.title = " S\(sessionPercent)% · W\(weeklyPercent)%"
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
    @Published var isAccessibilityEnabled: Bool = false
    @Published var shortcutEnabled: Bool = true

    private var statusItem: NSStatusItem?
    private var sessionCookie: String = ""
    private weak var delegate: AppDelegate?
    private var lastNotifiedThreshold: Int = 0

    init(statusItem: NSStatusItem?, delegate: AppDelegate? = nil) {
        self.statusItem = statusItem
        self.delegate = delegate
        loadSessionCookie()
        loadSettings()
        checkAccessibilityStatus()
    }

    func checkAccessibilityStatus() {
        isAccessibilityEnabled = AXIsProcessTrusted()
    }

    func loadSessionCookie() {
        if let savedCookie = UserDefaults.standard.string(forKey: "claude_session_cookie") {
            sessionCookie = savedCookie
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
        lastNotifiedThreshold = UserDefaults.standard.integer(forKey: "last_notified_threshold")
        // Default shortcut to enabled if not previously set
        if UserDefaults.standard.object(forKey: "shortcut_enabled") == nil {
            shortcutEnabled = true
        } else {
            shortcutEnabled = UserDefaults.standard.bool(forKey: "shortcut_enabled")
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(usageNotificationsEnabled,  forKey: "usage_notifications_enabled")
        UserDefaults.standard.set(statusNotificationsEnabled, forKey: "status_notifications_enabled")
        UserDefaults.standard.set(openAtLogin, forKey: "open_at_login")
        UserDefaults.standard.set(shortcutEnabled, forKey: "shortcut_enabled")
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

    func saveSessionCookie(_ cookie: String) {
        NSLog("ClaudeUsage: Saving cookie, length: \(cookie.count)")
        sessionCookie = cookie
        UserDefaults.standard.set(cookie, forKey: "claude_session_cookie")
        UserDefaults.standard.synchronize()
        NSLog("ClaudeUsage: Cookie saved successfully")
    }

    func clearSessionCookie() {
        NSLog("ClaudeUsage: Clearing cookie")
        sessionCookie = ""
        UserDefaults.standard.removeObject(forKey: "claude_session_cookie")
        UserDefaults.standard.synchronize()

        // Reset all data
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
        lastNotifiedThreshold = 0
        UserDefaults.standard.set(0, forKey: "last_notified_threshold")

        // Update status bar to show 0%
        delegate?.updateStatusIcon(sessionPercent: 0, weeklyPercent: 0)

        NSLog("ClaudeUsage: Cookie cleared, data reset")
    }

    func fetchOrganizationId(completion: @escaping (String?) -> Void) {
        // Get org ID from the lastActiveOrg cookie value
        let cookieParts = sessionCookie.components(separatedBy: ";")
        for part in cookieParts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("lastActiveOrg=") {
                let orgId = trimmed.replacingOccurrences(of: "lastActiveOrg=", with: "")
                NSLog("📋 Found org ID in cookie: \(orgId)")
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
        request.setValue("sessionKey=\(sessionCookie)", forHTTPHeaderField: "Cookie")

        NSLog("📡 Fetching bootstrap to get org ID...")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["account"] as? [String: Any],
                  let lastActiveOrgId = account["lastActiveOrgId"] as? String else {
                NSLog("❌ Could not parse org ID from bootstrap")
                completion(nil)
                return
            }
            NSLog("✅ Got org ID from bootstrap: \(lastActiveOrgId)")
            completion(lastActiveOrgId)
        }.resume()
    }

    func fetchUsage() {
        guard !sessionCookie.isEmpty else {
            DispatchQueue.main.async {
                self.errorMessage = "Session cookie not set"
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
        let weeklyPercent = weeklyLimit > 0
            ? Int((Double(weeklyUsage) / Double(weeklyLimit)) * 100)
            : 0

        // Update the icon color and title (session + weekly)
        delegate?.updateStatusIcon(sessionPercent: sessionPercent, weeklyPercent: weeklyPercent)

        // Check for notification thresholds
        checkNotificationThresholds(percentage: sessionPercent)
    }

    func checkNotificationThresholds(percentage: Int) {
        NSLog("🔔 Checking notifications: percentage=\(percentage)%, enabled=\(usageNotificationsEnabled), lastNotified=\(lastNotifiedThreshold)%")

        guard usageNotificationsEnabled else {
            NSLog("⚠️ Usage notifications disabled")
            return
        }

        let thresholds = [25, 50, 75, 90]

        for threshold in thresholds {
            if percentage >= threshold && lastNotifiedThreshold < threshold {
                NSLog("📬 Sending notification for \(threshold)% threshold")
                sendNotification(percentage: percentage, threshold: threshold)
                lastNotifiedThreshold = threshold
                // Persist the threshold
                UserDefaults.standard.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
                UserDefaults.standard.synchronize()
            }
        }

        // Reset if usage drops below current threshold
        if percentage < lastNotifiedThreshold {
            let newThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            NSLog("🔄 Resetting notification threshold from \(lastNotifiedThreshold)% to \(newThreshold)%")
            lastNotifiedThreshold = newThreshold
            UserDefaults.standard.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
            UserDefaults.standard.synchronize()
        }
    }

    func sendNotification(percentage: Int, threshold: Int) {
        let notification = NSUserNotification()
        notification.title = Loc.s("Claude Usage Alert", "Claude-Nutzungshinweis")
        notification.informativeText = Loc.s("You've reached \(percentage)% of your 5-hour session limit", "Du hast \(percentage) % deines 5-Stunden-Sitzungslimits erreicht")
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent notification for \(threshold)% threshold")
    }

    func sendTestNotification() {
        NSLog("🔔 Test notification button clicked")

        let notification = NSUserNotification()
        notification.title = Loc.s("Claude Usage Alert", "Claude-Nutzungshinweis")
        notification.informativeText = Loc.s("Test notification - You've reached 75% of your 5-hour session limit", "Testbenachrichtigung – Du hast 75 % deines 5-Stunden-Sitzungslimits erreicht")
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
    @Published var statusDescription: String = Loc.s("All systems operational", "Alle Systeme betriebsbereit")
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
            notification.title = Loc.s("Claude is back online", "Claude ist wieder online")
            notification.informativeText = Loc.s("All systems operational", "Alle Systeme betriebsbereit")
        } else {
            notification.title = Loc.s("Claude status: \(description)", "Claude-Status: \(description)")
            notification.informativeText = Loc.s("Visit status.anthropic.com for details", "Details unter status.anthropic.com")
        }
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent status-change notification: \(indicator)")
    }
}

// MARK: - App Updates

struct BannerButton: Equatable {
    let label: String
    let url: URL?         // optional — opens this URL (validated)
    let action: String?   // "dismiss" closes the banner; nil = no extra side effect
    let style: String?    // "primary" | "secondary" | nil
}

struct AvailableUpdate: Equatable {
    let version: String
    let title: String
    let body: String
    let buttons: [BannerButton]
}

// Free-form message channel, decoupled from the app version. Driven by the
// `message` object in latest.json and keyed on `id` (not version), so any
// message can be sent at any time without shipping a new build. Every field is
// author-controlled — including the notification title, which is NOT possible
// on the legacy version-based channel.
struct Announcement: Equatable {
    let id: String
    let heading: String?          // optional small top line on the card (nil = none)
    let title: String
    let body: String
    let buttons: [BannerButton]
    let notify: Bool              // false = show the in-app card only, no OS notification
    let notifTitle: String        // fully custom notification title
    let notifBody: String         // fully custom notification body
}

class UpdateManager: ObservableObject {
    @Published var available: AvailableUpdate?
    @Published var announcement: Announcement?

    // Served directly from the repo via GitHub — free, unlimited, no Vercel meter.
    // Same file as website/latest.json so existing v1.1 users on Vercel see the same JSON.
    private let endpoint = URL(string: "https://raw.githubusercontent.com/Artzainnn/ClaudeUsageBar/main/website/latest.json")!

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private static let allowedHostSuffixes = [
        "github.com",
        "claudeusagebar.com"
    ]

    static func isSafeURL(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return allowedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    private static func parseButtons(from json: [String: Any]) -> [BannerButton] {
        // Explicit `buttons` array (new schema, supports any combination)
        if let raw = json["buttons"] as? [[String: Any]] {
            return raw.compactMap { dict -> BannerButton? in
                guard let label = dict["label"] as? String, !label.isEmpty else { return nil }
                let urlStr = dict["url"] as? String
                let url = urlStr.flatMap { URL(string: $0) }
                if let url = url, !isSafeURL(url) { return nil }   // reject unsafe URLs
                return BannerButton(
                    label: label,
                    url: url,
                    action: dict["action"] as? String,
                    style: dict["style"] as? String
                )
            }
        }
        // Back-compat: legacy `download_url` builds the default 2-button layout
        if let urlStr = json["download_url"] as? String,
           let url = URL(string: urlStr),
           isSafeURL(url) {
            return [
                BannerButton(label: "Download", url: url, action: nil, style: "primary"),
                BannerButton(label: "Later",    url: nil, action: "dismiss", style: nil)
            ]
        }
        return []
    }

    func fetch() {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("⚠️ Update fetch failed or invalid payload")
                return
            }

            // ---- Legacy version-update channel (for real releases; also what
            //      pre-1.3.1 apps rely on). Optional — absent fields = no update.
            let updatePayload: AvailableUpdate? = {
                guard let version = json["version"] as? String,
                      let title = json["title"] as? String,
                      let body = json["description"] as? String else { return nil }
                return AvailableUpdate(version: version, title: title, body: body,
                                       buttons: Self.parseButtons(from: json))
            }()

            // ---- Free-form message channel (`message` object, keyed on `id`).
            //      Every field author-controlled, including the notification title.
            let announcementPayload: Announcement? = {
                guard let msg = json["message"] as? [String: Any],
                      let id = msg["id"] as? String, !id.isEmpty else { return nil }
                let title = msg["title"] as? String ?? ""
                let body  = msg["body"]  as? String ?? ""
                let notif = msg["notification"] as? [String: Any]
                return Announcement(
                    id: id,
                    heading: msg["heading"] as? String,
                    title: title,
                    body: body,
                    buttons: Self.parseButtons(from: msg),
                    notify: (msg["notify"] as? Bool) ?? true,
                    notifTitle: (notif?["title"] as? String) ?? (title.isEmpty ? "ClaudeUsageBar" : title),
                    notifBody:  (notif?["body"]  as? String) ?? body
                )
            }()

            DispatchQueue.main.async {
                // Version-update channel
                if let update = updatePayload, self.isNewer(remote: update.version, than: self.currentVersion) {
                    if self.available != update {
                        self.available = update
                        NSLog("⬆️ Update available: \(update.version)")
                    }
                    let lastNotified = UserDefaults.standard.string(forKey: "last_notified_update_version")
                    if lastNotified != update.version {
                        let n = NSUserNotification()
                        n.title = "ClaudeUsageBar \(update.version) is available"
                        n.informativeText = update.title
                        n.soundName = NSUserNotificationDefaultSoundName
                        NSUserNotificationCenter.default.deliver(n)
                        UserDefaults.standard.set(update.version, forKey: "last_notified_update_version")
                        NSLog("📬 Sent update notification for \(update.version)")
                    }
                } else {
                    self.available = nil
                }

                // Message channel — notify once per `id`. On the very first run
                // that supports messages, seed the current id WITHOUT notifying so
                // updating from an older version doesn't re-ping the live message.
                if let ann = announcementPayload {
                    let dismissed = UserDefaults.standard.string(forKey: "dismissed_message_id")
                    self.announcement = (dismissed == ann.id) ? nil : ann

                    let lastShown = UserDefaults.standard.string(forKey: "last_shown_message_id")
                    if lastShown == nil {
                        UserDefaults.standard.set(ann.id, forKey: "last_shown_message_id")   // seed, no notif
                    } else if lastShown != ann.id {
                        if ann.notify {
                            let n = NSUserNotification()
                            n.title = ann.notifTitle
                            n.informativeText = ann.notifBody
                            n.soundName = NSUserNotificationDefaultSoundName
                            NSUserNotificationCenter.default.deliver(n)
                            NSLog("📬 Sent message notification for id \(ann.id)")
                        }
                        UserDefaults.standard.set(ann.id, forKey: "last_shown_message_id")
                    }
                } else {
                    self.announcement = nil
                }
            }
        }.resume()
    }

    func dismissCurrent() {
        // Announcement takes priority in the UI, so dismiss it first if present.
        if let id = announcement?.id {
            UserDefaults.standard.set(id, forKey: "dismissed_message_id")
            announcement = nil
            return
        }
        if let v = available?.version {
            UserDefaults.standard.set(v, forKey: "dismissed_update_version")
        }
        available = nil
    }

    var isCurrentDismissed: Bool {
        guard let v = available?.version else { return false }
        return UserDefaults.standard.string(forKey: "dismissed_update_version") == v
    }

    private func isNewer(remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let c = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, c.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
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

// MARK: - Settings Window

/// Dedicated settings window with a tab bar (instead of inline in the popover).
/// Hosted by the AppDelegate in an NSWindow and opened via the gear button in
/// the popover.
struct SettingsView: View {
    @ObservedObject var usageManager: UsageManager
    @ObservedObject var statusManager: StatusManager

    private let contentWidth: CGFloat = 460

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(Loc.s("General", "Allgemein"), systemImage: "gearshape") }

            notificationsTab
                .tabItem { Label(Loc.s("Notifications", "Hinweise"), systemImage: "bell") }

            servicesTab
                .tabItem { Label(Loc.s("Services", "Dienste"), systemImage: "waveform.path.ecg") }

            shortcutTab
                .tabItem { Label(Loc.s("Shortcut", "Kürzel"), systemImage: "keyboard") }
        }
        .frame(width: contentWidth, height: 380)
    }

    /// Shared shape for all settings toggles: a title plus a gray subtitle,
    /// rendered as either a checkbox or a switch.
    @ViewBuilder
    private func labeledToggle(_ title: String, _ subtitle: String,
                               useSwitch: Bool = false,
                               isOn: Binding<Bool>) -> some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if useSwitch {
            Toggle(isOn: isOn) { label }.toggleStyle(.switch)
        } else {
            Toggle(isOn: isOn) { label }.toggleStyle(.checkbox)
        }
    }

    // General: launch at login
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledToggle(
                Loc.s("Open at Login", "Bei Anmeldung öffnen"),
                Loc.s("Launch app automatically when you log in", "App beim Anmelden automatisch starten"),
                isOn: Binding(
                    get: { usageManager.openAtLogin },
                    set: { newValue in
                        usageManager.openAtLogin = newValue
                        usageManager.applyLoginItem(newValue)
                        usageManager.saveSettings()
                    }
                )
            )
            Spacer()
        }
        .padding(20)
        .frame(width: contentWidth, alignment: .leading)
    }

    // Notifications: usage and status alerts
    private var notificationsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeledToggle(
                Loc.s("Enable Usage Notifications", "Nutzungs-Benachrichtigungen aktivieren"),
                Loc.s("Get alerts at 25%, 50%, 75%, and 90% session usage", "Hinweise bei 25 %, 50 %, 75 % und 90 % Sitzungs-Nutzung"),
                isOn: Binding(
                    get: { usageManager.usageNotificationsEnabled },
                    set: { newValue in
                        usageManager.usageNotificationsEnabled = newValue
                        usageManager.saveSettings()
                    }
                )
            )

            labeledToggle(
                Loc.s("Enable Status Notifications", "Status-Benachrichtigungen aktivieren"),
                Loc.s("Get alerts when tracked Claude services have an outage", "Hinweise, wenn beobachtete Claude-Dienste eine Störung haben"),
                isOn: Binding(
                    get: { usageManager.statusNotificationsEnabled },
                    set: { newValue in
                        usageManager.statusNotificationsEnabled = newValue
                        usageManager.saveSettings()
                    }
                )
            )

            Button(Loc.s("Test Notification", "Test-Benachrichtigung")) {
                usageManager.sendTestNotification()
            }
            .controlSize(.small)

            Spacer()
        }
        .padding(20)
        .frame(width: contentWidth, alignment: .leading)
    }

    // Services: which Claude status components are tracked
    private var servicesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Loc.s("Status alerts: services to track", "Status-Warnungen: zu beobachtende Dienste"))
                .fontWeight(.semibold)
            Text(Loc.s("Only tick the Claude services you use. Status issues with unticked services won't be shown or trigger alerts.", "Nur die von dir genutzten Claude-Dienste ankreuzen. Störungen nicht angekreuzter Dienste werden nicht angezeigt und lösen keine Warnung aus."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(statusManager.allComponents) { component in
                        Toggle(isOn: Binding(
                            get: { statusManager.isTracked(component.id) },
                            set: { _ in statusManager.toggleComponent(component.id) }
                        )) {
                            Text(component.name)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: contentWidth, alignment: .leading)
    }

    // Shortcut: global Cmd+U and the Accessibility permission
    private var shortcutTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledToggle(
                Loc.s("Keyboard Shortcut (⌘U)", "Tastenkürzel (⌘U)"),
                Loc.s("Toggle popup from anywhere. Disable if it conflicts with other apps.", "Popup von überall öffnen. Deaktivieren, falls es mit anderen Apps kollidiert."),
                useSwitch: true,
                isOn: Binding(
                    get: { usageManager.shortcutEnabled },
                    set: { newValue in
                        usageManager.shortcutEnabled = newValue
                        usageManager.saveSettings()
                        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                            appDelegate.setShortcutEnabled(newValue)
                        }
                    }
                )
            )

            if usageManager.shortcutEnabled && !usageManager.isAccessibilityEnabled {
                Button(Loc.s("Grant Accessibility Permission", "Bedienungshilfen-Freigabe erteilen")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Text(Loc.s("Accessibility permission may be needed for the shortcut to work in all apps", "Für das Kürzel in allen Apps kann eine Bedienungshilfen-Freigabe nötig sein"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: contentWidth, alignment: .leading)
    }
}

struct UsageView: View {
    @ObservedObject var usageManager: UsageManager
    @ObservedObject var statusManager: StatusManager
    @ObservedObject var updateManager: UpdateManager
    /// Reports the desired popover height (content height, capped to the screen)
    /// so the AppDelegate can keep NSPopover's contentSize in sync.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @State private var sessionCookieInput: String = ""
    @State private var showingCookieInput: Bool = false
    @State private var showingStatusDetails: Bool = false
    @State private var measuredHeight: CGFloat = 250

    // Let the popup grow to fit its content, bounded only by the visible screen
    // height (minus a margin for the menu bar and a bottom gap). This shows the
    // whole popup without scrolling on normal displays, so the top (session +
    // weekly) is always visible; only very short screens fall back to scrolling.
    private var maxPopupHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 700
        return max(300, screenHeight - 48)
    }

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
            // Use the NSPopover's native, appearance-aware material so the popup
            // matches the system light/dark setting instead of a fixed dark tint.
            .onPreferenceChange(ContentHeightKey.self) { value in
                guard value > 0 else { return }
                let clamped = min(max(value, 100), maxPopupHeight)
                measuredHeight = clamped
                // Keep NSPopover's contentSize in sync with the real content
                // height, otherwise the popover is mis-sized and pushed off-screen.
                onHeightChange(clamped)
            }
            .onReceive(NotificationCenter.default.publisher(for: .cubScrollToTop)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.none) {
                        proxy.scrollTo("cub-top", anchor: .top)
                    }
                }
            }
            .onAppear {
                if let savedCookie = UserDefaults.standard.string(forKey: "claude_session_cookie") {
                    sessionCookieInput = String(savedCookie.prefix(20)) + "..."
                }
                usageManager.updatePercentages()
            }
        }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Invisible top anchor used to reset scroll position on open.
            Color.clear.frame(height: 0).id("cub-top")

            Text(Loc.s("Claude Usage", "Claude Nutzung"))
                .font(.headline)
                .padding(.bottom, 4)

            // Free-form message banner (author-controlled). Takes priority over
            // the version-update banner when both are present.
            if let ann = updateManager.announcement {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if let heading = ann.heading, !heading.isEmpty {
                            Text(heading)
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        Spacer()
                        Button(action: { updateManager.dismissCurrent() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    if !ann.title.isEmpty {
                        Text(ann.title)
                            .font(.caption)
                    }
                    if !ann.body.isEmpty {
                        Text(ann.body)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !ann.buttons.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(ann.buttons.indices, id: \.self) { i in
                                bannerButton(ann.buttons[i])
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(6)
            }

            // App update banner (version-based). Hidden while a message banner shows.
            if updateManager.announcement == nil,
               let update = updateManager.available, !updateManager.isCurrentDismissed {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("⬆️")
                        Text(Loc.s("Version \(update.version) available", "Version \(update.version) verfügbar"))
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: { updateManager.dismissCurrent() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    Text(update.title)
                        .font(.caption)
                    Text(update.body)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !update.buttons.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(update.buttons.indices, id: \.self) { i in
                                bannerButton(update.buttons[i])
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(6)
            }

            if let error = usageManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.bottom, 8)
            }

            // Only show usage if data has been fetched
            if !usageManager.hasFetchedData {
                Text(Loc.s("👋 Welcome! Set your session cookie below to get started.", "👋 Willkommen! Hinterlege unten deinen Session-Cookie, um zu starten."))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }

            // Session Usage
            if usageManager.hasFetchedData {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Loc.s("Session (5 hour)", "Sitzung (5 Std.)"))
                        .font(.subheadline)
                    Spacer()
                    if let resetTime = usageManager.sessionResetsAt {
                        Text(Loc.s("Resets ", "Zurücksetzung ") + formatResetTime(resetTime))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                ProgressView(value: usageManager.sessionPercentage)
                    .tint(colorForPercentage(usageManager.sessionPercentage))

                Text("\(Int(usageManager.sessionPercentage * 100))% " + Loc.s("used", "genutzt"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Weekly Usage
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Loc.s("Weekly (7 day)", "Woche (7 Tage)"))
                        .font(.subheadline)
                    Spacer()
                    if let resetTime = usageManager.weeklyResetsAt {
                        Text(Loc.s("Resets ", "Zurücksetzung ") + formatResetTime(resetTime, includeDate: true))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                ProgressView(value: usageManager.weeklyPercentage)
                    .tint(colorForPercentage(usageManager.weeklyPercentage))

                Text("\(Int(usageManager.weeklyPercentage * 100))% " + Loc.s("used", "genutzt"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Weekly Sonnet Usage (only show if available)
            if usageManager.hasWeeklySonnet && usageManager.hasFetchedData {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(Loc.s("Weekly Sonnet (7 day)", "Woche Sonnet (7 Tage)"))
                            .font(.subheadline)
                        Spacer()
                        if let resetTime = usageManager.weeklySonnetResetsAt {
                            Text(Loc.s("Resets ", "Zurücksetzung ") + formatResetTime(resetTime, includeDate: true))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    ProgressView(value: usageManager.weeklySonnetPercentage)
                        .tint(colorForPercentage(usageManager.weeklySonnetPercentage))

                    Text("\(Int(usageManager.weeklySonnetPercentage * 100))% " + Loc.s("used", "genutzt"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Weekly Fable Usage — only surfaced once usage is above 1%
            // (new model, counted separately; hidden while idle to avoid clutter).
            if usageManager.hasWeeklyFable && usageManager.hasFetchedData && usageManager.weeklyFableUsage >= 1 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(Loc.s("Weekly Fable (7 day)", "Woche Fable (7 Tage)"))
                            .font(.subheadline)
                        Spacer()
                        if let resetTime = usageManager.weeklyFableResetsAt {
                            Text(Loc.s("Resets ", "Zurücksetzung ") + formatResetTime(resetTime, includeDate: true))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    ProgressView(value: usageManager.weeklyFablePercentage)
                        .tint(colorForPercentage(usageManager.weeklyFablePercentage))

                    Text("\(Int(usageManager.weeklyFablePercentage * 100))% " + Loc.s("used", "genutzt"))
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
                let pctLabel = pctInt > 100 ? Loc.s("over limit", "über Limit") : "\(pctInt)%"
                let fmt: (Int) -> String = { minor in
                    let v = Double(minor) / 100.0
                    return usageManager.creditCurrency == "USD"
                        ? String(format: "$%.2f", v)
                        : String(format: "%@ %.2f", usageManager.creditCurrency, v)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(Loc.s("Extra usage", "Extra-Nutzung"))
                            .font(.subheadline)
                        Spacer()
                        Button(action: {
                            if let url = URL(string: "https://claude.ai/new#settings/usage") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            Text(Loc.s("Manage →", "Verwalten →"))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.borderless)
                    }

                    // Reset date, shortened (e.g. "Resets Aug 1") so it fits inline.
                    let shortReset: String? = usageManager.extraResetsAt.map { d in
                        let f = DateFormatter(); f.locale = Locale.current
                        f.dateFormat = Loc.isGerman ? "d. MMM" : "MMM d"
                        return Loc.s("Resets ", "Reset ") + f.string(from: d)
                    }

                    // Spend vs monthly limit — only when there's actual spend.
                    if usageManager.hasCreditUsage {
                        if limitMinor > 0 {
                            ProgressView(value: min(pct, 1.0))
                                .tint(colorForPercentage(pct))
                        }
                        HStack {
                            Text(limitMinor > 0
                                 ? "\(fmt(spentMinor)) " + Loc.s("of", "von") + " \(fmt(limitMinor)) · \(pctLabel)"
                                 : "\(fmt(spentMinor)) " + Loc.s("spent", "ausgegeben"))
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
                        Text("\(fmt(usageManager.freeCreditsMinor)) " + Loc.s("free credits left", "Gratis-Guthaben übrig"))
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
                        !fableActive && !extraActive ? Loc.s("No Fable or extra usage", "Keine Fable- oder Extra-Nutzung")
                        : !extraActive ? Loc.s("No extra usage", "Keine Extra-Nutzung")
                        : Loc.s("No Fable usage", "Keine Fable-Nutzung")
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
                                 ? Loc.s("All Claude services operational", "Alle Claude-Dienste betriebsbereit")
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
                                    Text(showingStatusDetails ? Loc.s("Hide", "Zu") : Loc.s("Details", "Details"))
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
                                            Text(Loc.s("Updated ", "Aktualisiert ") + relativeTime(updated))
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
                                    Text(Loc.s("Affected services", "Betroffene Dienste"))
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
                                    Text(Loc.s("Checked ", "Geprüft ") + relativeTime(lastCheck))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: {
                                    NSWorkspace.shared.open(URL(string: "https://status.claude.com")!)
                                }) {
                                    Text(Loc.s("Open status page →", "Statusseite öffnen →"))
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
                Text(Loc.s("Last updated: ", "Zuletzt aktualisiert: ") + formatTime(usageManager.lastUpdated))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(Loc.s("Refresh", "Aktualisieren")) {
                    usageManager.fetchUsage()
                    statusManager.fetch()
                    updateManager.fetch()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            }

            Button(showingCookieInput ? Loc.s("Hide Cookie", "Cookie ausblenden") : Loc.s("Set Session Cookie", "Session-Cookie setzen")) {
                showingCookieInput.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingCookieInput {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(Loc.s("How to get your session cookie:", "So bekommst du deinen Session-Cookie:"))
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.open(URL(string: "https://github.com/Artzainnn/ClaudeUsageBar/blob/main/setup-guide.png")!)
                        }) {
                            Text(Loc.s("View tutorial →", "Anleitung ansehen →"))
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.borderless)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(Loc.s("1. Go to Settings > Usage on claude.ai", "1. Auf claude.ai zu Einstellungen > Nutzung gehen"))
                        Text(Loc.s("2. Press F12 (or Cmd+Option+I)", "2. F12 drücken (oder Cmd+Option+I)"))
                        Text(Loc.s("3. Go to Network tab", "3. Zum Tab „Netzwerk“ wechseln"))
                        Text(Loc.s("4. Refresh page, click 'usage' request", "4. Seite neu laden, „usage“-Anfrage anklicken"))
                        Text(Loc.s("5. Find 'Cookie' in Request Headers", "5. „Cookie“ in den Request-Headern finden"))
                        Text(Loc.s("6. Copy full cookie value\n   (starts with anthropic-device-id=...)", "6. Vollständigen Cookie-Wert kopieren\n   (beginnt mit anthropic-device-id=...)"))
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(Loc.s("Paste full cookie string:", "Vollständigen Cookie einfügen:"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        VStack(spacing: 4) {
                            PasteableTextField(text: $sessionCookieInput, placeholder: Loc.s("Paste cookie here...", "Cookie hier einfügen…"))
                                .frame(height: 60)
                                .cornerRadius(4)

                            HStack(spacing: 8) {
                                Button(Loc.s("Save Cookie & Fetch", "Cookie speichern & laden")) {
                                    NSLog("ClaudeUsage: Save clicked, input length: \(sessionCookieInput.count)")
                                    if sessionCookieInput.isEmpty {
                                        usageManager.errorMessage = Loc.s("Cookie field is empty!", "Cookie-Feld ist leer!")
                                    } else {
                                        usageManager.saveSessionCookie(sessionCookieInput)
                                        usageManager.fetchUsage()
                                        usageManager.errorMessage = Loc.s("Cookie saved, fetching...", "Cookie gespeichert, lade…")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                if usageManager.hasFetchedData {
                                    Button(Loc.s("Clear Cookie", "Cookie löschen")) {
                                        sessionCookieInput = ""
                                        usageManager.clearSessionCookie()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }

            // Support section: donation button for the developer.
            coffeeButton(url: "https://donate.stripe.com/3cIcN5b5H7Q8ay8bIDfIs02",
                         "Buy Dev a Coffee",
                         "Dem Entwickler einen Kaffee spendieren")

            // Footer: settings (gear) on the left, quit on the right. The app is
            // a menu-bar accessory with no app menu, so Cmd+Q has nothing to bind
            // to — hence an explicit quit button here.
            HStack {
                Button(action: {
                    if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                        appDelegate.openSettingsWindow()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                        Text(Loc.s("Settings", "Einstellungen"))
                    }
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(action: {
                    if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                        appDelegate.quitApp()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text(Loc.s("Quit", "Beenden"))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
            }
            .font(.caption)

            // Discreet build-info footer: name/version/build/type on the left,
            // build date + time on the right. Shows at a glance which build runs.
            HStack {
                Text("ClaudeUsageBar \(BuildInfo.version) (\(BuildInfo.buildNumber)) · \(BuildInfo.configuration)")
                Spacer()
                Text(BuildInfo.buildDate)
            }
            .font(.caption2)
            .foregroundStyle(.quaternary)
        }
    }

    // A single donation (coffee) button, labeled bilingually.
    private func coffeeButton(url: String, _ en: String, _ de: String) -> some View {
        Button(action: {
            NSWorkspace.shared.open(URL(string: url)!)
        }) {
            HStack(spacing: 4) {
                Text("☕")
                Text(Loc.s(en, de))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundColor(.orange)
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
        formatter.locale = Locale.current

        if includeDate {
            if Loc.isGerman {
                // "am 31. Jan. 2026 um 07:59"
                formatter.dateFormat = "d. MMM yyyy 'um' HH:mm"
                return "am \(formatter.string(from: date))"
            }
            // "on 31 Jan 2026 at 7:59 AM"
            formatter.dateFormat = "d MMM yyyy 'at' h:mm a"
            return "on \(formatter.string(from: date))"
        } else {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return Loc.s("at", "um") + " \(formatter.string(from: date))"
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
            return Loc.s("Claude: all systems operational", "Claude: alle Systeme betriebsbereit")
        }
        return "Claude: \(description)"
    }

    func relativeTime(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 { return Loc.s("just now", "gerade eben") }
        if elapsed < 3600 {
            let m = elapsed / 60
            return Loc.isGerman ? "vor \(m) Min." : "\(m) min\(m == 1 ? "" : "s") ago"
        }
        if elapsed < 86_400 {
            let h = elapsed / 3600
            return Loc.isGerman ? "vor \(h) Std." : "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = elapsed / 86_400
        return Loc.isGerman ? "vor \(d) \(d == 1 ? "Tag" : "Tagen")" : "\(d) day\(d == 1 ? "" : "s") ago"
    }

    func statusContextLine(for sm: StatusManager) -> String {
        let tracked = sm.allComponents.filter { sm.selectedComponentIds.contains($0.id) }
        let trackedNames = tracked.prefix(4).map { shortName($0.name) }.joined(separator: ", ")
        let extra = tracked.count > 4 ? " +\(tracked.count - 4)" : ""
        let trackedSummary = tracked.isEmpty
            ? Loc.s("No services tracked", "Keine Dienste beobachtet")
            : Loc.s("Tracks ", "Beobachtet ") + "\(trackedNames)\(extra)"

        if sm.effectiveIndicator == "none" {
            if let lastCheck = sm.lastUpdated {
                return "\(trackedSummary) · " + Loc.s("checked ", "geprüft ") + relativeTime(lastCheck)
            }
            return trackedSummary
        }
        let affected = sm.filteredAffectedComponents
        if !affected.isEmpty {
            let names = affected.prefix(3).map { shortName($0.name) }.joined(separator: ", ")
            let more = affected.count > 3 ? " +\(affected.count - 3)" : ""
            return Loc.s("Affects: ", "Betroffen: ") + "\(names)\(more)"
        }
        if let lastCheck = sm.lastUpdated {
            return Loc.s("Checked ", "Geprüft ") + relativeTime(lastCheck)
        }
        return ""
    }

    func shortName(_ raw: String) -> String {
        if let paren = raw.range(of: " (") {
            return String(raw[..<paren.lowerBound])
        }
        return raw
    }

    @ViewBuilder
    func bannerButton(_ btn: BannerButton) -> some View {
        let tap = {
            if let url = btn.url {
                NSWorkspace.shared.open(url)
            }
            if btn.action == "dismiss" {
                updateManager.dismissCurrent()
            }
        }
        if btn.style == "primary" {
            Button(btn.label, action: tap)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(btn.label, action: tap)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
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
        case "degraded_performance": return Loc.s("degraded", "eingeschränkt")
        case "partial_outage":       return Loc.s("partial outage", "Teilausfall")
        case "major_outage":         return Loc.s("major outage", "größerer Ausfall")
        case "under_maintenance":    return Loc.s("maintenance", "Wartung")
        default:                     return status
        }
    }

}
