import SwiftUI
import AppKit
import WebKit
import Carbon
import Combine

// Main entry point
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var usageManager: UsageManager!
    var eventMonitor: Any?
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Initialize usage manager
        usageManager = UsageManager(statusItem: statusItem, delegate: self)

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 520)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsageView(usageManager: usageManager))

        // Fetch initial data
        usageManager.fetchUsage()

        // Set up timer to refresh every 5 minutes
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.usageManager.fetchUsage()
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
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = "ClaudeUsageBar needs Accessibility permission to use the Cmd+U keyboard shortcut.\n\nPlease enable it in:\nSystem Settings → Privacy & Security → Accessibility"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Skip for Now")

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
            // Force UI refresh by updating percentages
            DispatchQueue.main.async {
                self.usageManager.updatePercentages()
            }

            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

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

    func updateStatusIcon(percentage: Int, account1Percent: Int? = nil, account2Percent: Int? = nil) {
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

        // Display format: "72% | 45%" for dual, "72%" for single
        switch (account1Percent, account2Percent) {
        case let (.some(a), .some(b)):
            button.title = " \(a)% | \(b)%"
        case let (.some(a), .none):
            button.title = " \(a)%"
        case let (.none, .some(b)):
            button.title = " \(b)%"
        case (.none, .none):
            button.title = " \(percentage)%"
        }
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

// MARK: - AccountData

class AccountData: ObservableObject, Identifiable {
    let id: Int  // 1 or 2

    @Published var sessionUsage: Int = 0
    @Published var sessionLimit: Int = 100
    @Published var weeklyUsage: Int = 0
    @Published var weeklyLimit: Int = 100
    @Published var weeklySonnetUsage: Int = 0
    @Published var weeklySonnetLimit: Int = 100
    @Published var sessionResetsAt: Date?
    @Published var weeklyResetsAt: Date?
    @Published var weeklySonnetResetsAt: Date?
    @Published var lastUpdated: Date = Date()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var hasWeeklySonnet: Bool = false
    @Published var hasFetchedData: Bool = false
    @Published var sessionPercentage: Double = 0.0
    @Published var weeklyPercentage: Double = 0.0
    @Published var weeklySonnetPercentage: Double = 0.0

    var sessionCookie: String = ""
    var lastNotifiedThreshold: Int = 0

    // Namespaced UserDefaults keys
    var cookieKey: String { "claude_session_cookie_\(id)" }
    var thresholdKey: String { "last_notified_threshold_\(id)" }

    // Auto-detect Pro/Free based on hasWeeklySonnet
    var accountLabel: String {
        hasWeeklySonnet ? "Pro" : "Free"
    }

    var isConfigured: Bool {
        !sessionCookie.isEmpty
    }

    init(id: Int) {
        self.id = id
    }

    func updatePercentages() {
        sessionPercentage = Double(sessionUsage) / Double(sessionLimit)
        weeklyPercentage = Double(weeklyUsage) / Double(weeklyLimit)
        weeklySonnetPercentage = Double(weeklySonnetUsage) / Double(weeklySonnetLimit)
    }

    func reset() {
        sessionUsage = 0
        weeklyUsage = 0
        weeklySonnetUsage = 0
        sessionResetsAt = nil
        weeklyResetsAt = nil
        weeklySonnetResetsAt = nil
        hasFetchedData = false
        hasWeeklySonnet = false
        errorMessage = nil
        lastNotifiedThreshold = 0
        updatePercentages()
    }
}

// MARK: - UsageManager

class UsageManager: ObservableObject {
    @Published var account1: AccountData = AccountData(id: 1)
    @Published var account2: AccountData = AccountData(id: 2)
    @Published var notificationsEnabled: Bool = true
    @Published var openAtLogin: Bool = false
    @Published var isAccessibilityEnabled: Bool = false
    @Published var shortcutEnabled: Bool = true

    private var statusItem: NSStatusItem?
    private weak var delegate: AppDelegate?
    private var cancellables = Set<AnyCancellable>()

    init(statusItem: NSStatusItem?, delegate: AppDelegate? = nil) {
        self.statusItem = statusItem
        self.delegate = delegate

        // Forward child objectWillChange to parent so SwiftUI observes nested changes
        account1.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        account2.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        loadSessionCookies()
        loadSettings()
        checkAccessibilityStatus()
    }

    func checkAccessibilityStatus() {
        isAccessibilityEnabled = AXIsProcessTrusted()
    }

    // MARK: Cookie Management

    func loadSessionCookies() {
        // Migration: old single-account key -> account 1
        if let oldCookie = UserDefaults.standard.string(forKey: "claude_session_cookie") {
            UserDefaults.standard.set(oldCookie, forKey: "claude_session_cookie_1")
            let oldThreshold = UserDefaults.standard.integer(forKey: "last_notified_threshold")
            UserDefaults.standard.set(oldThreshold, forKey: "last_notified_threshold_1")
            UserDefaults.standard.removeObject(forKey: "claude_session_cookie")
            UserDefaults.standard.removeObject(forKey: "last_notified_threshold")
            UserDefaults.standard.synchronize()
            NSLog("ClaudeUsage: Migrated single-account data to account 1")
        }

        // Load per-account cookies
        if let c1 = UserDefaults.standard.string(forKey: account1.cookieKey) {
            account1.sessionCookie = c1
        }
        if let c2 = UserDefaults.standard.string(forKey: account2.cookieKey) {
            account2.sessionCookie = c2
        }
        account1.lastNotifiedThreshold = UserDefaults.standard.integer(forKey: account1.thresholdKey)
        account2.lastNotifiedThreshold = UserDefaults.standard.integer(forKey: account2.thresholdKey)
    }

    func loadSettings() {
        notificationsEnabled = UserDefaults.standard.bool(forKey: "notifications_enabled")
        // Default to true if not set
        if !UserDefaults.standard.bool(forKey: "has_set_notifications") {
            notificationsEnabled = true
            UserDefaults.standard.set(true, forKey: "has_set_notifications")
        }
        openAtLogin = UserDefaults.standard.bool(forKey: "open_at_login")
        // Default shortcut to enabled if not previously set
        if UserDefaults.standard.object(forKey: "shortcut_enabled") == nil {
            shortcutEnabled = true
        } else {
            shortcutEnabled = UserDefaults.standard.bool(forKey: "shortcut_enabled")
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(notificationsEnabled, forKey: "notifications_enabled")
        UserDefaults.standard.set(openAtLogin, forKey: "open_at_login")
        UserDefaults.standard.set(shortcutEnabled, forKey: "shortcut_enabled")
        UserDefaults.standard.synchronize()
    }

    func saveSessionCookie(_ cookie: String, for account: AccountData) {
        NSLog("ClaudeUsage: Saving cookie for account \(account.id), length: \(cookie.count)")
        account.sessionCookie = cookie
        UserDefaults.standard.set(cookie, forKey: account.cookieKey)
        UserDefaults.standard.synchronize()
        NSLog("ClaudeUsage: Cookie saved successfully for account \(account.id)")
    }

    func clearSessionCookie(for account: AccountData) {
        NSLog("ClaudeUsage: Clearing cookie for account \(account.id)")
        account.sessionCookie = ""
        UserDefaults.standard.removeObject(forKey: account.cookieKey)
        account.reset()
        UserDefaults.standard.set(0, forKey: account.thresholdKey)
        UserDefaults.standard.synchronize()

        // Update status bar
        updateStatusBar()

        NSLog("ClaudeUsage: Cookie cleared, data reset for account \(account.id)")
    }

    // MARK: Network Fetching

    func fetchOrganizationId(cookie: String, completion: @escaping (String?) -> Void) {
        // Get org ID from the lastActiveOrg cookie value
        let cookieParts = cookie.components(separatedBy: ";")
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
        request.setValue("sessionKey=\(cookie)", forHTTPHeaderField: "Cookie")

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
        fetchUsageForAccount(account1)
        fetchUsageForAccount(account2)
    }

    func fetchUsageForAccount(_ account: AccountData) {
        guard account.isConfigured else {
            DispatchQueue.main.async {
                self.updateStatusBar()
            }
            return
        }

        account.isLoading = true
        account.errorMessage = nil

        // Extract org ID from cookie
        fetchOrganizationId(cookie: account.sessionCookie) { [weak self] orgId in
            guard let self = self, let orgId = orgId else {
                DispatchQueue.main.async {
                    account.errorMessage = "Could not get org ID from cookie"
                    account.isLoading = false
                }
                return
            }

            self.fetchUsageWithOrgId(orgId, for: account)
        }
    }

    func fetchUsageWithOrgId(_ orgId: String, for account: AccountData) {
        let urlString = "https://claude.ai/api/organizations/\(orgId)/usage"

        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                account.errorMessage = "Invalid URL"
                account.isLoading = false
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Use the full cookie string (user provides all cookies, not just sessionKey)
        request.setValue(account.sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        NSLog("🔍 Fetching from: \(urlString) for account \(account.id)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                account.isLoading = false

                if let error = error {
                    NSLog("❌ Error for account \(account.id): \(error.localizedDescription)")
                    account.errorMessage = "Network error"
                    self?.updateStatusBar()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    account.errorMessage = "Invalid response"
                    self?.updateStatusBar()
                    return
                }

                NSLog("📡 Account \(account.id) status: \(httpResponse.statusCode)")

                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    NSLog("📦 Account \(account.id) response: \(responseString)")
                }

                if httpResponse.statusCode == 200, let data = data {
                    self?.parseUsageData(data, for: account)
                } else {
                    account.errorMessage = "HTTP \(httpResponse.statusCode)"
                }

                self?.updateStatusBar()
            }
        }.resume()
    }

    func parseUsageData(_ data: Data, for account: AccountData) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                account.errorMessage = "Invalid JSON"
                return
            }

            NSLog("📊 Parsing usage data for account \(account.id)...")

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Parse the actual claude.ai response format
            if let fiveHour = json["five_hour"] as? [String: Any] {
                if let sessionUtil = fiveHour["utilization"] as? Double {
                    account.sessionUsage = Int(sessionUtil)
                    account.sessionLimit = 100
                }
                if let resetsAtString = fiveHour["resets_at"] as? String {
                    NSLog("🕐 Account \(account.id) session resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        account.sessionResetsAt = resetsAt
                        NSLog("✅ Parsed session reset time for account \(account.id): \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse session reset time for account \(account.id)")
                    }
                }
            }

            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let weeklyUtil = sevenDay["utilization"] as? Double {
                    account.weeklyUsage = Int(weeklyUtil)
                    account.weeklyLimit = 100
                }
                if let resetsAtString = sevenDay["resets_at"] as? String {
                    NSLog("🕐 Account \(account.id) weekly resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        account.weeklyResetsAt = resetsAt
                        NSLog("✅ Parsed weekly reset time for account \(account.id): \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly reset time for account \(account.id)")
                    }
                }
            }

            // Check for seven_day_sonnet (Pro plan feature)
            if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
                account.hasWeeklySonnet = true
                if let sonnetUtil = sevenDaySonnet["utilization"] as? Double {
                    account.weeklySonnetUsage = Int(sonnetUtil)
                    account.weeklySonnetLimit = 100
                }
                if let resetsAtString = sevenDaySonnet["resets_at"] as? String {
                    NSLog("🕐 Account \(account.id) weekly Sonnet resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        account.weeklySonnetResetsAt = resetsAt
                        NSLog("✅ Parsed weekly Sonnet reset time for account \(account.id): \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly Sonnet reset time for account \(account.id)")
                    }
                }
            } else {
                account.hasWeeklySonnet = false
            }

            // Log what we found
            NSLog("✅ Account \(account.id) parsed: Session \(account.sessionUsage)%, Weekly \(account.weeklyUsage)%\(account.hasWeeklySonnet ? ", Weekly Sonnet \(account.weeklySonnetUsage)%" : "")")

            account.lastUpdated = Date()
            account.errorMessage = nil
            account.hasFetchedData = true

            // Update percentage values for progress bars
            account.updatePercentages()

            // Check notification thresholds
            checkNotificationThresholds(for: account)
        } catch {
            NSLog("❌ Parse error for account \(account.id): \(error.localizedDescription)")
            account.errorMessage = "Parse error"
        }
    }

    // MARK: Status Bar

    func updateStatusBar() {
        let p1: Int? = account1.isConfigured && account1.hasFetchedData
            ? Int(account1.sessionPercentage * 100) : nil
        let p2: Int? = account2.isConfigured && account2.hasFetchedData
            ? Int(account2.sessionPercentage * 100) : nil

        let maxPercent: Int
        switch (p1, p2) {
        case let (.some(a), .some(b)): maxPercent = max(a, b)
        case let (.some(a), .none): maxPercent = a
        case let (.none, .some(b)): maxPercent = b
        case (.none, .none): maxPercent = 0
        }

        delegate?.updateStatusIcon(percentage: maxPercent, account1Percent: p1, account2Percent: p2)
    }

    // MARK: Notifications

    func checkNotificationThresholds(for account: AccountData) {
        let percentage = Int(account.sessionPercentage * 100)
        NSLog("🔔 Checking notifications for account \(account.id): percentage=\(percentage)%, enabled=\(notificationsEnabled), lastNotified=\(account.lastNotifiedThreshold)%")

        guard notificationsEnabled else {
            NSLog("⚠️ Notifications disabled")
            return
        }

        let thresholds = [25, 50, 75, 90]

        for threshold in thresholds {
            if percentage >= threshold && account.lastNotifiedThreshold < threshold {
                NSLog("📬 Sending notification for account \(account.id) at \(threshold)% threshold")
                sendNotification(percentage: percentage, threshold: threshold, account: account)
                account.lastNotifiedThreshold = threshold
                // Persist the threshold
                UserDefaults.standard.set(account.lastNotifiedThreshold, forKey: account.thresholdKey)
                UserDefaults.standard.synchronize()
            }
        }

        // Reset if usage drops below current threshold
        if percentage < account.lastNotifiedThreshold {
            let newThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            NSLog("🔄 Resetting notification threshold for account \(account.id) from \(account.lastNotifiedThreshold)% to \(newThreshold)%")
            account.lastNotifiedThreshold = newThreshold
            UserDefaults.standard.set(account.lastNotifiedThreshold, forKey: account.thresholdKey)
            UserDefaults.standard.synchronize()
        }
    }

    func sendNotification(percentage: Int, threshold: Int, account: AccountData) {
        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert (Account \(account.id) - \(account.accountLabel))"
        notification.informativeText = "You've reached \(percentage)% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent notification for account \(account.id) at \(threshold)% threshold")
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

    func updatePercentages() {
        account1.updatePercentages()
        account2.updatePercentages()
    }
}

// MARK: - Custom NSTextField that properly handles paste

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

// MARK: - Shared Helpers

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

// MARK: - AccountUsageView

struct AccountUsageView: View {
    @ObservedObject var account: AccountData

    var body: some View {
        if account.hasFetchedData {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Account \(account.id)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("(\(account.accountLabel))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Session Usage
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Session (5 hour)")
                            .font(.subheadline)
                        Spacer()
                        if let resetTime = account.sessionResetsAt {
                            Text("Resets \(formatResetTime(resetTime))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    ProgressView(value: account.sessionPercentage)
                        .tint(colorForPercentage(account.sessionPercentage))

                    Text("\(Int(account.sessionPercentage * 100))% used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Weekly Usage
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Weekly (7 day)")
                            .font(.subheadline)
                        Spacer()
                        if let resetTime = account.weeklyResetsAt {
                            Text("Resets \(formatResetTime(resetTime, includeDate: true))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    ProgressView(value: account.weeklyPercentage)
                        .tint(colorForPercentage(account.weeklyPercentage))

                    Text("\(Int(account.weeklyPercentage * 100))% used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Weekly Sonnet Usage (only show if available)
                if account.hasWeeklySonnet {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Weekly Sonnet (7 day)")
                                .font(.subheadline)
                            Spacer()
                            if let resetTime = account.weeklySonnetResetsAt {
                                Text("Resets \(formatResetTime(resetTime, includeDate: true))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        ProgressView(value: account.weeklySonnetPercentage)
                            .tint(colorForPercentage(account.weeklySonnetPercentage))

                        Text("\(Int(account.weeklySonnetPercentage * 100))% used")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - CookieInputSection

struct CookieInputSection: View {
    @Binding var cookieInput: String
    @ObservedObject var account: AccountData
    var usageManager: UsageManager
    @Binding var isShowing: Bool

    var body: some View {
        Button(isShowing ? "Hide Account \(account.id) Cookie" : "Set Account \(account.id) Cookie") {
            isShowing.toggle()
        }
        .buttonStyle(.borderless)
        .font(.caption)

        if isShowing {
            VStack(alignment: .leading, spacing: 8) {
                Text("How to get your session cookie:")
                    .font(.caption)
                    .fontWeight(.semibold)

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
                        PasteableTextField(text: $cookieInput, placeholder: "Paste cookie here...")
                            .frame(height: 60)
                            .cornerRadius(4)

                        HStack(spacing: 8) {
                            Button("Save Cookie & Fetch") {
                                NSLog("ClaudeUsage: Save clicked for account \(account.id), input length: \(cookieInput.count)")
                                if cookieInput.isEmpty {
                                    account.errorMessage = "Cookie field is empty!"
                                } else {
                                    usageManager.saveSessionCookie(cookieInput, for: account)
                                    usageManager.fetchUsageForAccount(account)
                                    account.errorMessage = "Cookie saved, fetching..."
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            if account.hasFetchedData {
                                Button("Clear Cookie") {
                                    cookieInput = ""
                                    usageManager.clearSessionCookie(for: account)
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
    }
}

// MARK: - UsageView

struct UsageView: View {
    @ObservedObject var usageManager: UsageManager
    @State private var cookieInput1: String = ""
    @State private var cookieInput2: String = ""
    @State private var showingCookieInput1: Bool = false
    @State private var showingCookieInput2: Bool = false
    @State private var showingSettings: Bool = false

    var maxLastUpdated: Date {
        let d1 = usageManager.account1.hasFetchedData ? usageManager.account1.lastUpdated : .distantPast
        let d2 = usageManager.account2.hasFetchedData ? usageManager.account2.lastUpdated : .distantPast
        return max(d1, d2)
    }

    var anyHasFetchedData: Bool {
        usageManager.account1.hasFetchedData || usageManager.account2.hasFetchedData
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Claude Usage")
                    .font(.headline)
                    .padding(.bottom, 4)

                // Error messages
                if let error1 = usageManager.account1.errorMessage, usageManager.account1.isConfigured {
                    Text("Account 1: \(error1)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if let error2 = usageManager.account2.errorMessage, usageManager.account2.isConfigured {
                    Text("Account 2: \(error2)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                // Welcome message
                if !anyHasFetchedData {
                    Text("👋 Welcome! Set your session cookie below to get started.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }

                // Account 1 usage
                AccountUsageView(account: usageManager.account1)

                // Account 2 usage
                if usageManager.account2.hasFetchedData {
                    Divider()
                    AccountUsageView(account: usageManager.account2)
                }

                // Last updated + Refresh
                if anyHasFetchedData {
                    Divider()

                    HStack {
                        Text("Last updated: \(formatTime(maxLastUpdated))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Refresh") {
                            usageManager.fetchUsage()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }

                // Cookie input sections
                CookieInputSection(
                    cookieInput: $cookieInput1,
                    account: usageManager.account1,
                    usageManager: usageManager,
                    isShowing: $showingCookieInput1
                )

                CookieInputSection(
                    cookieInput: $cookieInput2,
                    account: usageManager.account2,
                    usageManager: usageManager,
                    isShowing: $showingCookieInput2
                )

                // Support Section
                Button(action: {
                    NSWorkspace.shared.open(URL(string: "https://donate.stripe.com/3cIcN5b5H7Q8ay8bIDfIs02")!)
                }) {
                    HStack(spacing: 4) {
                        Text("☕")
                        Text("Buy Dev a Coffee")
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundColor(.orange)

                // Settings Section
                Button(showingSettings ? "Hide Settings" : "Settings") {
                    showingSettings.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)

                if showingSettings {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { usageManager.openAtLogin },
                            set: { newValue in
                                usageManager.openAtLogin = newValue
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
                                get: { usageManager.notificationsEnabled },
                                set: { newValue in
                                    usageManager.notificationsEnabled = newValue
                                    usageManager.saveSettings()
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Enable Notifications")
                                        .font(.caption)
                                    Text("Get alerts at 25%, 50%, 75%,\nand 90% session usage")
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

                            if usageManager.shortcutEnabled && !usageManager.isAccessibilityEnabled {
                                Button("Grant Accessibility Permission") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                Text("Accessibility permission may be needed\nfor the shortcut to work in all apps")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            .padding()
            .frame(width: 360)
        }
        .onAppear {
            // Load saved cookie previews when view appears
            if let savedCookie1 = UserDefaults.standard.string(forKey: "claude_session_cookie_1") {
                cookieInput1 = String(savedCookie1.prefix(20)) + "..."
            }
            if let savedCookie2 = UserDefaults.standard.string(forKey: "claude_session_cookie_2") {
                cookieInput2 = String(savedCookie2.prefix(20)) + "..."
            }
            // Force refresh to ensure progress bars show colors
            usageManager.updatePercentages()
        }
    }
}
