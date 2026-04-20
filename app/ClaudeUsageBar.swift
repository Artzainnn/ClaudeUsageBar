import SwiftUI
import AppKit
import WebKit
import Carbon

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
            updateStatusIcon(percentages: [])
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
        popover.contentSize = NSSize(width: 320, height: 260)
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

    func updateStatusIcon(percentages: [Int]) {
        guard let button = statusItem.button else { return }

        // Determine color based on max percentage
        let maxPercentage = percentages.max() ?? 0
        let color: NSColor
        if maxPercentage < 70 {
            color = NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0) // Green
        } else if maxPercentage < 90 {
            color = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0) // Yellow
        } else {
            color = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0) // Red
        }

        // Create spark icon with color
        let sparkIcon = createSparkIcon(color: color)

        // Set image and title
        button.image = sparkIcon
        if percentages.isEmpty {
            button.title = " 0%"
        } else if percentages.count == 1 {
            button.title = " \(percentages[0])%"
        } else {
            button.title = " " + percentages.map { "\($0)%" }.joined(separator: " | ")
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

// MARK: - Subscription Model

struct Subscription: Identifiable, Codable {
    let id: UUID
    var name: String
    var cookie: String

    // Runtime usage data (not persisted — re-fetched on launch)
    var sessionUsage: Int = 0
    var sessionLimit: Int = 100
    var weeklyUsage: Int = 0
    var weeklyLimit: Int = 100
    var weeklySonnetUsage: Int = 0
    var weeklySonnetLimit: Int = 100
    var sessionResetsAt: Date?
    var weeklyResetsAt: Date?
    var weeklySonnetResetsAt: Date?
    var hasWeeklySonnet: Bool = false
    var hasFetchedData: Bool = false
    var isLoading: Bool = false
    var errorMessage: String?
    var lastUpdated: Date = Date()
    var lastNotifiedThreshold: Int = 0

    var sessionPercentage: Double {
        guard sessionLimit > 0 else { return 0 }
        return Double(sessionUsage) / Double(sessionLimit)
    }

    var weeklyPercentage: Double {
        guard weeklyLimit > 0 else { return 0 }
        return Double(weeklyUsage) / Double(weeklyLimit)
    }

    var weeklySonnetPercentage: Double {
        guard weeklySonnetLimit > 0 else { return 0 }
        return Double(weeklySonnetUsage) / Double(weeklySonnetLimit)
    }

    // Only persist id, name, cookie, lastNotifiedThreshold
    enum CodingKeys: String, CodingKey {
        case id, name, cookie, lastNotifiedThreshold
    }

    init(id: UUID = UUID(), name: String, cookie: String, lastNotifiedThreshold: Int = 0) {
        self.id = id
        self.name = name
        self.cookie = cookie
        self.lastNotifiedThreshold = lastNotifiedThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        cookie = try container.decode(String.self, forKey: .cookie)
        lastNotifiedThreshold = try container.decodeIfPresent(Int.self, forKey: .lastNotifiedThreshold) ?? 0
    }
}

// MARK: - Usage Manager

class UsageManager: ObservableObject {
    static let maxSubscriptions = 5

    @Published var subscriptions: [Subscription] = []
    @Published var notificationsEnabled: Bool = true
    @Published var openAtLogin: Bool = false
    @Published var isAccessibilityEnabled: Bool = false
    @Published var shortcutEnabled: Bool = true

    private var statusItem: NSStatusItem?
    private weak var delegate: AppDelegate?

    var hasFetchedData: Bool {
        subscriptions.contains(where: { $0.hasFetchedData })
    }

    var isLoading: Bool {
        subscriptions.contains(where: { $0.isLoading })
    }

    var lastUpdated: Date {
        subscriptions.compactMap({ $0.hasFetchedData ? $0.lastUpdated : nil }).max() ?? Date()
    }

    init(statusItem: NSStatusItem?, delegate: AppDelegate? = nil) {
        self.statusItem = statusItem
        self.delegate = delegate
        migrateFromSingleCookie()
        loadSubscriptions()
        loadSettings()
        checkAccessibilityStatus()
    }

    func checkAccessibilityStatus() {
        isAccessibilityEnabled = AXIsProcessTrusted()
    }

    // MARK: Migration

    private func migrateFromSingleCookie() {
        // Only run if old key exists AND new key does not
        guard let oldCookie = UserDefaults.standard.string(forKey: "claude_session_cookie"),
              !oldCookie.isEmpty,
              UserDefaults.standard.data(forKey: "claude_subscriptions") == nil else {
            return
        }

        let oldThreshold = UserDefaults.standard.integer(forKey: "last_notified_threshold")

        let migrated = Subscription(
            name: "My Subscription",
            cookie: oldCookie,
            lastNotifiedThreshold: oldThreshold
        )

        subscriptions = [migrated]
        saveSubscriptions()

        // Clean up old keys
        UserDefaults.standard.removeObject(forKey: "claude_session_cookie")
        UserDefaults.standard.removeObject(forKey: "last_notified_threshold")
        UserDefaults.standard.synchronize()

        NSLog("ClaudeUsage: Migrated single cookie to subscription '\(migrated.name)'")
    }

    // MARK: Persistence

    func loadSubscriptions() {
        if let data = UserDefaults.standard.data(forKey: "claude_subscriptions"),
           let decoded = try? JSONDecoder().decode([Subscription].self, from: data) {
            subscriptions = decoded
        }
    }

    func saveSubscriptions() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            UserDefaults.standard.set(data, forKey: "claude_subscriptions")
            UserDefaults.standard.synchronize()
        }
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

    // MARK: Subscription CRUD

    func addSubscription(name: String, cookie: String) {
        guard subscriptions.count < UsageManager.maxSubscriptions else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmedName.isEmpty ? "Subscription \(subscriptions.count + 1)" : trimmedName
        let sub = Subscription(name: finalName, cookie: cookie)
        subscriptions.append(sub)
        saveSubscriptions()
        fetchUsage(for: sub.id)
    }

    func removeSubscription(id: UUID) {
        subscriptions.removeAll(where: { $0.id == id })
        saveSubscriptions()
        updateStatusBar()
    }

    func updateSubscription(id: UUID, name: String? = nil, cookie: String? = nil) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        if let name = name {
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            if !trimmedName.isEmpty {
                subscriptions[idx].name = trimmedName
            }
        }
        if let cookie = cookie {
            subscriptions[idx].cookie = cookie
            subscriptions[idx].hasFetchedData = false
            subscriptions[idx].errorMessage = nil
        }
        saveSubscriptions()
    }

    // MARK: Fetching

    func fetchUsage() {
        guard !subscriptions.isEmpty else {
            updateStatusBar()
            return
        }
        for subscription in subscriptions {
            fetchUsage(for: subscription.id)
        }
    }

    func fetchUsage(for subscriptionId: UUID) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == subscriptionId }) else { return }
        guard !subscriptions[idx].cookie.isEmpty else {
            subscriptions[idx].errorMessage = "Session cookie not set"
            updateStatusBar()
            return
        }

        subscriptions[idx].isLoading = true
        subscriptions[idx].errorMessage = nil

        let cookie = subscriptions[idx].cookie

        fetchOrganizationId(cookie: cookie) { [weak self] orgId in
            guard let self = self else { return }
            guard let orgId = orgId else {
                DispatchQueue.main.async {
                    if let idx = self.subscriptions.firstIndex(where: { $0.id == subscriptionId }) {
                        self.subscriptions[idx].errorMessage = "Could not get org ID from cookie"
                        self.subscriptions[idx].isLoading = false
                    }
                }
                return
            }
            self.fetchUsageWithOrgId(orgId, cookie: cookie, subscriptionId: subscriptionId)
        }
    }

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

    func fetchUsageWithOrgId(_ orgId: String, cookie: String, subscriptionId: UUID) {
        let urlString = "https://claude.ai/api/organizations/\(orgId)/usage"

        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                if let idx = self.subscriptions.firstIndex(where: { $0.id == subscriptionId }) {
                    self.subscriptions[idx].errorMessage = "Invalid URL"
                    self.subscriptions[idx].isLoading = false
                }
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Use the full cookie string (user provides all cookies, not just sessionKey)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        NSLog("🔍 Fetching from: \(urlString)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let idx = self.subscriptions.firstIndex(where: { $0.id == subscriptionId }) else { return }

                self.subscriptions[idx].isLoading = false

                if let error = error {
                    NSLog("❌ Error: \(error.localizedDescription)")
                    self.subscriptions[idx].errorMessage = "Network error"
                    self.updateStatusBar()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.subscriptions[idx].errorMessage = "Invalid response"
                    self.updateStatusBar()
                    return
                }

                NSLog("📡 Status: \(httpResponse.statusCode)")

                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    NSLog("📦 Response: \(responseString)")
                }

                if httpResponse.statusCode == 200, let data = data {
                    self.parseUsageData(data, subscriptionId: subscriptionId)
                } else {
                    self.subscriptions[idx].errorMessage = "HTTP \(httpResponse.statusCode)"
                }

                self.updateStatusBar()
            }
        }.resume()
    }

    func parseUsageData(_ data: Data, subscriptionId: UUID) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == subscriptionId }) else { return }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                subscriptions[idx].errorMessage = "Invalid JSON"
                return
            }

            NSLog("📊 Parsing usage data for '\(subscriptions[idx].name)'...")

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Parse the actual claude.ai response format
            if let fiveHour = json["five_hour"] as? [String: Any] {
                if let sessionUtil = fiveHour["utilization"] as? Double {
                    subscriptions[idx].sessionUsage = Int(sessionUtil)
                    subscriptions[idx].sessionLimit = 100
                }
                if let resetsAtString = fiveHour["resets_at"] as? String {
                    NSLog("🕐 Session resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        subscriptions[idx].sessionResetsAt = resetsAt
                        NSLog("✅ Parsed session reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse session reset time")
                    }
                }
            }

            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let weeklyUtil = sevenDay["utilization"] as? Double {
                    subscriptions[idx].weeklyUsage = Int(weeklyUtil)
                    subscriptions[idx].weeklyLimit = 100
                }
                if let resetsAtString = sevenDay["resets_at"] as? String {
                    NSLog("🕐 Weekly resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        subscriptions[idx].weeklyResetsAt = resetsAt
                        NSLog("✅ Parsed weekly reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly reset time")
                    }
                }
            }

            // Check for seven_day_sonnet (Pro plan feature)
            if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
                subscriptions[idx].hasWeeklySonnet = true
                if let sonnetUtil = sevenDaySonnet["utilization"] as? Double {
                    subscriptions[idx].weeklySonnetUsage = Int(sonnetUtil)
                    subscriptions[idx].weeklySonnetLimit = 100
                }
                if let resetsAtString = sevenDaySonnet["resets_at"] as? String {
                    NSLog("🕐 Weekly Sonnet resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        subscriptions[idx].weeklySonnetResetsAt = resetsAt
                        NSLog("✅ Parsed weekly Sonnet reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly Sonnet reset time")
                    }
                }
            } else {
                subscriptions[idx].hasWeeklySonnet = false
            }

            // Log what we found
            NSLog("✅ Parsed [\(subscriptions[idx].name)]: Session \(subscriptions[idx].sessionUsage)%, Weekly \(subscriptions[idx].weeklyUsage)%\(subscriptions[idx].hasWeeklySonnet ? ", Weekly Sonnet \(subscriptions[idx].weeklySonnetUsage)%" : "")")

            subscriptions[idx].lastUpdated = Date()
            subscriptions[idx].errorMessage = nil
            subscriptions[idx].hasFetchedData = true
        } catch {
            NSLog("❌ Parse error: \(error.localizedDescription)")
            subscriptions[idx].errorMessage = "Parse error"
        }
    }

    // MARK: Status Bar

    func updateStatusBar() {
        let percentages = subscriptions
            .filter { $0.hasFetchedData }
            .map { Int($0.sessionPercentage * 100) }

        delegate?.updateStatusIcon(percentages: percentages)

        // Check notification thresholds for each subscription
        for idx in subscriptions.indices {
            checkNotificationThresholds(subscriptionIndex: idx)
        }
    }

    // MARK: Notifications

    func checkNotificationThresholds(subscriptionIndex idx: Int) {
        guard idx < subscriptions.count else { return }
        let percentage = Int(subscriptions[idx].sessionPercentage * 100)

        NSLog("🔔 Checking notifications for '\(subscriptions[idx].name)': percentage=\(percentage)%, enabled=\(notificationsEnabled), lastNotified=\(subscriptions[idx].lastNotifiedThreshold)%")

        guard notificationsEnabled else {
            return
        }

        let thresholds = [25, 50, 75, 90]

        for threshold in thresholds {
            if percentage >= threshold && subscriptions[idx].lastNotifiedThreshold < threshold {
                NSLog("📬 Sending notification for '\(subscriptions[idx].name)' at \(threshold)% threshold")
                sendNotification(subscriptionName: subscriptions[idx].name, percentage: percentage, threshold: threshold)
                subscriptions[idx].lastNotifiedThreshold = threshold
                saveSubscriptions()
            }
        }

        // Reset if usage drops below current threshold
        if percentage < subscriptions[idx].lastNotifiedThreshold {
            let newThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            NSLog("🔄 Resetting notification threshold for '\(subscriptions[idx].name)' from \(subscriptions[idx].lastNotifiedThreshold)% to \(newThreshold)%")
            subscriptions[idx].lastNotifiedThreshold = newThreshold
            saveSubscriptions()
        }
    }

    func sendNotification(subscriptionName: String, percentage: Int, threshold: Int) {
        let notification = NSUserNotification()
        if subscriptions.count > 1 {
            notification.title = "Claude Usage Alert (\(subscriptionName))"
        } else {
            notification.title = "Claude Usage Alert"
        }
        notification.informativeText = "You've reached \(percentage)% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent notification for \(threshold)% threshold")
    }

    func sendTestNotification() {
        NSLog("🔔 Test notification button clicked")

        let notification = NSUserNotification()
        if subscriptions.count > 1, let first = subscriptions.first {
            notification.title = "Claude Usage Alert (\(first.name))"
        } else {
            notification.title = "Claude Usage Alert"
        }
        notification.informativeText = "Test notification - You've reached 75% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Test notification sent successfully")
    }
}

// MARK: - Custom Text Fields

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

// MARK: - Reusable UI Components

struct UsageBarView: View {
    let label: String
    let percentage: Double
    let resetTime: Date?
    let includeDate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                if let resetTime = resetTime {
                    Text("Resets \(formatResetTime(resetTime, includeDate: includeDate))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ProgressView(value: percentage)
                .tint(colorForPercentage(percentage))

            Text("\(Int(percentage * 100))% used")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    func formatResetTime(_ date: Date, includeDate: Bool = false) -> String {
        let formatter = DateFormatter()
        if includeDate {
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
}

struct SubscriptionUsageView: View {
    let subscription: Subscription

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageBarView(
                label: "Session (5 hour)",
                percentage: subscription.sessionPercentage,
                resetTime: subscription.sessionResetsAt,
                includeDate: false
            )

            UsageBarView(
                label: "Weekly (7 day)",
                percentage: subscription.weeklyPercentage,
                resetTime: subscription.weeklyResetsAt,
                includeDate: true
            )

            if subscription.hasWeeklySonnet {
                UsageBarView(
                    label: "Weekly Sonnet (7 day)",
                    percentage: subscription.weeklySonnetPercentage,
                    resetTime: subscription.weeklySonnetResetsAt,
                    includeDate: true
                )
            }

            if let error = subscription.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }
}

// MARK: - Manage Subscriptions View

struct ManageSubscriptionsView: View {
    @ObservedObject var usageManager: UsageManager
    @State private var editingId: UUID?
    @State private var editName: String = ""
    @State private var editCookie: String = ""
    @State private var newName: String = ""
    @State private var newCookie: String = ""
    @State private var showingAddForm: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Existing subscriptions
            ForEach(usageManager.subscriptions) { sub in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(colorForPercentage(sub.sessionPercentage))
                            .frame(width: 6, height: 6)
                        Text(sub.name)
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                        if editingId != sub.id {
                            Button(action: {
                                editingId = sub.id
                                editName = sub.name
                                editCookie = sub.cookie
                            }) {
                                Image(systemName: "pencil")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)

                            if usageManager.subscriptions.count > 1 {
                                Button(action: {
                                    usageManager.removeSubscription(id: sub.id)
                                }) {
                                    Image(systemName: "trash")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                                .foregroundColor(.red)
                            }
                        }
                    }

                    // Inline edit form
                    if editingId == sub.id {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Name", text: $editName)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)

                            Text("Cookie:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            PasteableTextField(text: $editCookie, placeholder: "Paste cookie here...")
                                .frame(height: 50)
                                .cornerRadius(4)

                            HStack(spacing: 8) {
                                Button("Save") {
                                    usageManager.updateSubscription(id: sub.id, name: editName, cookie: editCookie)
                                    if editCookie != sub.cookie {
                                        usageManager.fetchUsage(for: sub.id)
                                    }
                                    editingId = nil
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                Button("Cancel") {
                                    editingId = nil
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(6)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(4)
                    }
                }

                if sub.id != usageManager.subscriptions.last?.id {
                    Divider()
                }
            }

            // Add new subscription
            if usageManager.subscriptions.count < UsageManager.maxSubscriptions {
                Divider()

                if showingAddForm {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add Subscription")
                            .font(.caption)
                            .fontWeight(.semibold)

                        TextField("Name (e.g. Work, Personal)", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)

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

                        Text("Paste full cookie string:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        PasteableTextField(text: $newCookie, placeholder: "Paste cookie here...")
                            .frame(height: 60)
                            .cornerRadius(4)

                        HStack(spacing: 8) {
                            Button("Save & Fetch") {
                                if !newCookie.isEmpty {
                                    usageManager.addSubscription(name: newName, cookie: newCookie)
                                    newName = ""
                                    newCookie = ""
                                    showingAddForm = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Cancel") {
                                newName = ""
                                newCookie = ""
                                showingAddForm = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } else {
                    Button(action: { showingAddForm = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                                .font(.caption)
                            Text("Add Subscription")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
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
}

// MARK: - Main Usage View

struct UsageView: View {
    @ObservedObject var usageManager: UsageManager
    @State private var showingSubscriptions: Bool = false
    @State private var showingSettings: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Claude Usage")
                .font(.headline)
                .padding(.bottom, 4)

            // Empty state
            if usageManager.subscriptions.isEmpty {
                Text("Welcome! Add a subscription below to get started.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
            // Single subscription — same look as original
            else if usageManager.subscriptions.count == 1 {
                let sub = usageManager.subscriptions[0]
                if !sub.hasFetchedData && sub.errorMessage == nil && !sub.isLoading {
                    Text("Welcome! Set your session cookie below to get started.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                } else if sub.hasFetchedData {
                    SubscriptionUsageView(subscription: sub)
                } else if let error = sub.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.bottom, 8)
                }
                if sub.isLoading {
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            // Multiple subscriptions — collapsible sections
            else {
                ForEach(usageManager.subscriptions) { sub in
                    DisclosureGroup {
                        if sub.hasFetchedData {
                            SubscriptionUsageView(subscription: sub)
                                .padding(.top, 4)
                        } else if sub.isLoading {
                            Text("Loading...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if let error = sub.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    } label: {
                        HStack {
                            Text(sub.name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                            if sub.hasFetchedData {
                                Text("\(Int(sub.sessionPercentage * 100))%")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(colorForPercentage(sub.sessionPercentage))
                            } else if sub.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }

            // Last updated + refresh
            if usageManager.hasFetchedData {
                Divider()

                HStack {
                    Text("Last updated: \(formatTime(usageManager.lastUpdated))")
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

            // Manage Subscriptions
            Button(showingSubscriptions ? "Hide Subscriptions" : "Manage Subscriptions") {
                showingSubscriptions.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingSubscriptions {
                ManageSubscriptionsView(usageManager: usageManager)
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
            }

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

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
}
