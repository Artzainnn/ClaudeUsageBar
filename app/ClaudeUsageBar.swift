import SwiftUI
import AppKit
import Carbon
import WebKit

// Main entry point
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var usageManager: UsageManager!
    var eventMonitor: Any?
    var hotKeyRef: EventHotKeyRef?
    var isPopoverTransitioning: Bool = false

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

        // Create popover with dynamic sizing
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 300)
        popover.behavior = .transient
        popover.animates = false  // Disable animation for consistent positioning
        popover.contentViewController = NSHostingController(rootView: UsageView(usageManager: usageManager))

        // Fetch initial data
        usageManager.fetchUsage()

        // Set up timer to refresh every 5 minutes
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.usageManager.fetchUsage()
        }

        // Listen for chart style changes to reposition popover
        NotificationCenter.default.addObserver(self, selector: #selector(handleChartStyleChanged), name: NSNotification.Name("ChartStyleChanged"), object: nil)

        // Set up Cmd+U keyboard shortcut
        setupKeyboardShortcut()
    }

    @objc func handleChartStyleChanged() {
        // Recreate popover entirely to fix positioning after size change
        guard !isPopoverTransitioning else { return }

        if popover.isShown {
            isPopoverTransitioning = true
            closePopover()
            // Longer delay to ensure popover is fully dismissed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                // Recreate the popover with fresh state
                self.recreatePopover()
                self.openPopover()
            }
        }
    }

    func recreatePopover() {
        // Create a fresh popover to avoid stale positioning
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false  // Disable animation to ensure correct positioning
        updatePopoverSize()
    }

    func setupKeyboardShortcut() {
        // Check Accessibility permissions
        checkAccessibilityPermissions()

        // Register global hotkey using Carbon
        registerGlobalHotKey()
    }

    func checkAccessibilityPermissions() {
        // Check if app has Accessibility permissions
        let trusted = AXIsProcessTrusted()

        if !trusted {
            NSLog("⚠️ Accessibility permissions not granted")
            // Only show alert if user hasn't dismissed it before
            if !UserDefaults.standard.bool(forKey: "accessibility_alert_dismissed") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let alert = NSAlert()
                    alert.messageText = "Accessibility Permission Required"
                    alert.informativeText = "ClaudeUsageBar needs Accessibility permission to use the Cmd+U keyboard shortcut.\n\nPlease enable it in:\nSystem Settings → Privacy & Security → Accessibility"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Don't Show Again")

                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        // Open System Settings
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    } else {
                        // User chose to skip - remember this choice
                        UserDefaults.standard.set(true, forKey: "accessibility_alert_dismissed")
                    }
                }
            }
        } else {
            NSLog("✅ Accessibility permissions granted")
            // Clear the dismissed flag if permissions are now granted
            UserDefaults.standard.removeObject(forKey: "accessibility_alert_dismissed")
        }
    }

    func registerGlobalHotKey() {
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
        // Prevent rapid clicking from causing positioning issues
        guard !isPopoverTransitioning else { return }

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
            isPopoverTransitioning = true

            // Increment refresh trigger to force complete view redraw with current data
            usageManager.refreshTrigger += 1

            // Refresh the content view controller
            let hostingController = NSHostingController(rootView: UsageView(usageManager: usageManager))
            popover.contentViewController = hostingController

            // Force UI refresh
            usageManager.updatePercentages()

            // Adjust popover size dynamically based on chart style and account count
            updatePopoverSize()

            // Close any existing showing state first to ensure clean positioning
            if popover.isShown {
                popover.performClose(nil)
            }

            // Force the hosting controller's view to load before showing
            _ = hostingController.view

            // Show popover below the menu bar button
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Adjust popover position to be consistent across different sizes
            // The popover window needs to be positioned just below the menu bar
            if let popoverWindow = popover.contentViewController?.view.window,
               let screen = popoverWindow.screen ?? NSScreen.main {
                let menuBarHeight: CGFloat = 24
                let targetY = screen.frame.height - menuBarHeight - popoverWindow.frame.height
                var newFrame = popoverWindow.frame
                newFrame.origin.y = targetY
                popoverWindow.setFrame(newFrame, display: true)
            }

            // Clear transitioning flag after popover is shown
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.isPopoverTransitioning = false
            }

            // Add event monitor to detect clicks outside the popover
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if self?.popover.isShown == true {
                    self?.closePopover()
                }
            }
        }
    }

    func updatePopoverSize() {
        let width: CGFloat
        let baseHeight: CGFloat = 320

        switch usageManager.chartStyle {
        case .ultraCompact:
            width = 380
        case .stackedVertical:
            width = 340
        case .separateCards:
            width = usageManager.accounts.count > 2 ? 420 : 380
        }

        // Adjust height based on number of accounts (with larger icons now ~40px per account)
        let accountCount = max(usageManager.accounts.count, 1)
        let hasSonnet = usageManager.accounts.contains { $0.hasWeeklySonnet } || usageManager.hasWeeklySonnet
        let extraHeight = CGFloat(accountCount - 1) * 45 + (hasSonnet ? 50 : 0)

        popover.contentSize = NSSize(width: width, height: baseHeight + extraHeight)
    }

    func closePopover() {
        popover.performClose(nil)

        // Remove event monitor
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func updateStatusIcon(percentage: Int) {
        guard let button = statusItem.button else { return }

        // Determine color based on highest percentage
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

        // Set image and title - show all account percentages if multiple
        button.image = sparkIcon

        if let manager = usageManager, manager.accounts.count > 1 {
            // Show all account session percentages separated by /
            let percentages = manager.accounts.map { Int($0.sessionPercentage * 100) }
            button.title = " " + percentages.map { "\($0)%" }.joined(separator: "/")
        } else {
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

// MARK: - Multi-Account Data Model

struct ClaudeAccount: Identifiable, Codable {
    let id: UUID
    var name: String
    var sessionCookie: String
    var lastNotifiedThreshold: Int = 0
    var customColorHex: String?      // Custom color as hex string (e.g., "#FF5733")
    var iconURL: String?              // URL to custom icon image
    var iconData: Data?               // Cached icon image data (persisted to avoid file access prompts)

    // Transient state (not persisted)
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
    var iconImage: NSImage?           // Cached icon image (transient)

    // Custom Codable to exclude transient properties
    enum CodingKeys: String, CodingKey {
        case id, name, sessionCookie, lastNotifiedThreshold, customColorHex, iconURL, iconData
    }

    init(id: UUID = UUID(), name: String, sessionCookie: String, lastNotifiedThreshold: Int = 0, customColorHex: String? = nil, iconURL: String? = nil) {
        self.id = id
        self.name = name
        self.sessionCookie = sessionCookie
        self.lastNotifiedThreshold = lastNotifiedThreshold
        self.customColorHex = customColorHex
        self.iconURL = iconURL
    }

    // Get the display color for this account
    var displayColor: Color {
        if let hex = customColorHex {
            return Color(hex: hex)
        }
        return .blue // Default
    }

    var sessionPercentage: Double {
        sessionLimit > 0 ? Double(sessionUsage) / Double(sessionLimit) : 0
    }

    var weeklyPercentage: Double {
        weeklyLimit > 0 ? Double(weeklyUsage) / Double(weeklyLimit) : 0
    }

    var weeklySonnetPercentage: Double {
        weeklySonnetLimit > 0 ? Double(weeklySonnetUsage) / Double(weeklySonnetLimit) : 0
    }
}

enum ChartStyle: String, Codable, CaseIterable {
    case ultraCompact = "Ultra-compact rows"
    case stackedVertical = "Stacked per metric"
    case separateCards = "Separate cards"
}

enum ColorMode: String, Codable, CaseIterable {
    case byUsageLevel = "By usage level"
    case byAccount = "By account"
    case hybrid = "Hybrid"
}

// MARK: - UsageManager

class UsageManager: ObservableObject {
    // Multi-account support
    @Published var accounts: [ClaudeAccount] = []
    @Published var chartStyle: ChartStyle = .ultraCompact
    @Published var colorMode: ColorMode = .byUsageLevel
    @Published var refreshTrigger: Int = 0  // Increment to force view refresh

    // Legacy single-account properties (for backward compatibility during transition)
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
    @Published var notificationsEnabled: Bool = true
    @Published var openAtLogin: Bool = false
    @Published var hasWeeklySonnet: Bool = false
    @Published var hasFetchedData: Bool = false
    @Published var isAccessibilityEnabled: Bool = false
    @Published var showTimeRemaining: Bool = false  // Toggle between date/time vs "3h remaining"

    private var statusItem: NSStatusItem?
    private var sessionCookie: String = ""
    private weak var delegate: AppDelegate?
    private var lastNotifiedThreshold: Int = 0

    init(statusItem: NSStatusItem?, delegate: AppDelegate? = nil) {
        self.statusItem = statusItem
        self.delegate = delegate
        loadAccounts()
        loadSettings()
        checkAccessibilityStatus()
    }

    func checkAccessibilityStatus() {
        isAccessibilityEnabled = AXIsProcessTrusted()
    }

    // MARK: - Account Management

    func loadAccounts() {
        // Try to load accounts from new format
        if let data = UserDefaults.standard.data(forKey: "claude_accounts"),
           let savedAccounts = try? JSONDecoder().decode([ClaudeAccount].self, from: data) {
            accounts = savedAccounts
            NSLog("ClaudeUsage: Loaded \(accounts.count) accounts")
        } else {
            // Migration: check for legacy single-account cookie
            migrateFromSingleAccount()
        }

        // Load chart style and color mode
        if let styleRaw = UserDefaults.standard.string(forKey: "chart_style"),
           let style = ChartStyle(rawValue: styleRaw) {
            chartStyle = style
        }
        if let modeRaw = UserDefaults.standard.string(forKey: "color_mode"),
           let mode = ColorMode(rawValue: modeRaw) {
            colorMode = mode
        }
        showTimeRemaining = UserDefaults.standard.bool(forKey: "show_time_remaining")

        // Sync legacy properties from first account for backward compatibility
        syncLegacyProperties()

        // Load custom icons
        loadAllIcons()
    }

    func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: "claude_accounts")
        }
        UserDefaults.standard.set(chartStyle.rawValue, forKey: "chart_style")
        UserDefaults.standard.set(colorMode.rawValue, forKey: "color_mode")
        UserDefaults.standard.set(showTimeRemaining, forKey: "show_time_remaining")
        UserDefaults.standard.synchronize()
        NSLog("ClaudeUsage: Saved \(accounts.count) accounts")
    }

    func migrateFromSingleAccount() {
        if let savedCookie = UserDefaults.standard.string(forKey: "claude_session_cookie"),
           !savedCookie.isEmpty {
            NSLog("ClaudeUsage: Migrating from single account format")
            let lastThreshold = UserDefaults.standard.integer(forKey: "last_notified_threshold")
            let account = ClaudeAccount(name: "My Account", sessionCookie: savedCookie, lastNotifiedThreshold: lastThreshold)
            accounts = [account]
            saveAccounts()

            // Keep legacy cookie for backward compatibility but mark migration done
            sessionCookie = savedCookie
            lastNotifiedThreshold = lastThreshold
            NSLog("ClaudeUsage: Migration complete - created 'My Account'")
        }
    }

    func syncLegacyProperties() {
        // Sync legacy single-account properties from first account
        if let first = accounts.first {
            sessionCookie = first.sessionCookie
            sessionUsage = first.sessionUsage
            weeklyUsage = first.weeklyUsage
            weeklySonnetUsage = first.weeklySonnetUsage
            sessionResetsAt = first.sessionResetsAt
            weeklyResetsAt = first.weeklyResetsAt
            weeklySonnetResetsAt = first.weeklySonnetResetsAt
            hasWeeklySonnet = first.hasWeeklySonnet
            hasFetchedData = first.hasFetchedData
            lastNotifiedThreshold = first.lastNotifiedThreshold
        }
    }

    func addAccount(name: String, cookie: String) {
        guard accounts.count < 4 else {
            NSLog("ClaudeUsage: Maximum 4 accounts allowed")
            return
        }
        let account = ClaudeAccount(name: name, sessionCookie: cookie)
        accounts.append(account)
        saveAccounts()
        NSLog("ClaudeUsage: Added account '\(name)'")
    }

    func removeAccount(id: UUID) {
        accounts.removeAll { $0.id == id }
        saveAccounts()
        syncLegacyProperties()
        updateStatusBar()
        NSLog("ClaudeUsage: Removed account")
    }

    func updateAccount(id: UUID, name: String, cookie: String, colorHex: String? = nil, iconURL: String? = nil) {
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].name = name
            if !cookie.isEmpty {
                accounts[index].sessionCookie = cookie
            }
            if let colorHex = colorHex {
                accounts[index].customColorHex = colorHex
            }
            accounts[index].iconURL = iconURL
            // Load icon if path/URL provided
            if let urlString = iconURL, !urlString.isEmpty {
                loadIcon(for: index, from: urlString)
            } else {
                accounts[index].iconImage = nil
            }
            saveAccounts()
            syncLegacyProperties()
            NSLog("ClaudeUsage: Updated account '\(name)'")
        }
    }

    func loadIcon(for index: Int, from urlString: String) {
        // Support local file paths
        var imageData: Data?

        if urlString.hasPrefix("/") || urlString.hasPrefix("~") {
            // Local file path
            let expandedPath = NSString(string: urlString).expandingTildeInPath
            imageData = try? Data(contentsOf: URL(fileURLWithPath: expandedPath))
            if imageData == nil {
                NSLog("ClaudeUsage: Failed to load local icon from \(expandedPath)")
                return
            }
        } else if urlString.hasPrefix("file://") {
            // file:// URL
            guard let url = URL(string: urlString) else { return }
            imageData = try? Data(contentsOf: url)
            if imageData == nil {
                NSLog("ClaudeUsage: Failed to load icon from file URL \(url)")
                return
            }
        } else {
            // Remote URL - load asynchronously
            guard let url = URL(string: urlString) else { return }
            URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                guard let data = data, let img = NSImage(data: data) else {
                    NSLog("ClaudeUsage: Failed to load icon from \(url)")
                    return
                }
                DispatchQueue.main.async {
                    self?.setResizedIcon(img, for: index, cacheData: data)
                }
            }.resume()
            return
        }

        // For local files, set immediately and cache the data
        if let data = imageData, let img = NSImage(data: data) {
            setResizedIcon(img, for: index, cacheData: data)
        }
    }

    func setResizedIcon(_ image: NSImage, for index: Int, cacheData: Data? = nil) {
        guard index < accounts.count else { return }
        // Resize image to 32x32 for crisp display at various sizes
        let resized = NSImage(size: NSSize(width: 32, height: 32))
        resized.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32),
                  from: NSRect(origin: .zero, size: image.size),
                  operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        accounts[index].iconImage = resized

        // Cache the image data to avoid file access prompts on restart
        if let data = cacheData {
            accounts[index].iconData = data
            saveAccounts()
        }
        NSLog("ClaudeUsage: Loaded icon for account \(index)")
    }

    func loadAllIcons() {
        for (index, account) in accounts.enumerated() {
            // First try to restore from cached data (no file access needed)
            if let data = account.iconData, let img = NSImage(data: data) {
                setResizedIcon(img, for: index)
                NSLog("ClaudeUsage: Restored icon from cache for account \(index)")
            } else if let urlString = account.iconURL {
                // Fall back to loading from URL/path
                loadIcon(for: index, from: urlString)
            }
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
        lastNotifiedThreshold = UserDefaults.standard.integer(forKey: "last_notified_threshold")
    }

    func saveSettings() {
        UserDefaults.standard.set(notificationsEnabled, forKey: "notifications_enabled")
        UserDefaults.standard.set(openAtLogin, forKey: "open_at_login")
        UserDefaults.standard.synchronize()
    }

    // Legacy method - now works with first account
    func saveSessionCookie(_ cookie: String) {
        NSLog("ClaudeUsage: Saving cookie, length: \(cookie.count)")
        if accounts.isEmpty {
            addAccount(name: "My Account", cookie: cookie)
        } else {
            accounts[0].sessionCookie = cookie
            saveAccounts()
        }
        sessionCookie = cookie
        NSLog("ClaudeUsage: Cookie saved successfully")
    }

    // Legacy method - clears all accounts
    func clearSessionCookie() {
        NSLog("ClaudeUsage: Clearing all accounts")
        accounts.removeAll()
        sessionCookie = ""
        UserDefaults.standard.removeObject(forKey: "claude_accounts")
        UserDefaults.standard.removeObject(forKey: "claude_session_cookie")
        UserDefaults.standard.synchronize()

        // Reset all data
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
        UserDefaults.standard.set(0, forKey: "last_notified_threshold")

        // Update status bar to show 0%
        delegate?.updateStatusIcon(percentage: 0)

        NSLog("ClaudeUsage: All data cleared")
    }

    // MARK: - Multi-Account Fetching

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
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

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

    // Fetch usage for all accounts
    func fetchUsage() {
        guard !accounts.isEmpty else {
            // Legacy fallback for single cookie
            guard !sessionCookie.isEmpty else {
                DispatchQueue.main.async {
                    self.errorMessage = "No accounts configured"
                    self.updateStatusBar()
                }
                return
            }
            // Use legacy single-account fetch
            fetchUsageLegacy()
            return
        }

        isLoading = true
        errorMessage = nil

        // Fetch for each account by UUID (safe against concurrent modifications)
        for account in accounts {
            fetchUsageForAccount(id: account.id)
        }
    }

    // Helper to find account index by UUID (returns nil if account was removed)
    private func accountIndex(for id: UUID) -> Int? {
        accounts.firstIndex(where: { $0.id == id })
    }

    // Fetch usage for a specific account by index (legacy, for AddAccountInlineView)
    func fetchUsageForAccount(index: Int) {
        guard index < accounts.count else { return }
        fetchUsageForAccount(id: accounts[index].id)
    }

    // Fetch usage for a specific account by UUID (safe)
    func fetchUsageForAccount(id: UUID) {
        guard let index = accountIndex(for: id) else { return }

        let cookie = accounts[index].sessionCookie
        let accountId = id  // Capture UUID for async callbacks

        guard !cookie.isEmpty else {
            DispatchQueue.main.async {
                if let idx = self.accountIndex(for: accountId) {
                    self.accounts[idx].errorMessage = "No cookie set"
                    self.accounts[idx].isLoading = false
                }
            }
            return
        }

        DispatchQueue.main.async {
            if let idx = self.accountIndex(for: accountId) {
                self.accounts[idx].isLoading = true
                self.accounts[idx].errorMessage = nil
            }
        }

        fetchOrganizationId(cookie: cookie) { [weak self] orgId in
            guard let self = self, let orgId = orgId else {
                DispatchQueue.main.async {
                    if let idx = self?.accountIndex(for: accountId) {
                        self?.accounts[idx].errorMessage = "Could not get org ID"
                        self?.accounts[idx].isLoading = false
                    }
                    self?.checkAllAccountsLoaded()
                }
                return
            }
            self.fetchUsageWithOrgId(orgId, cookie: cookie, accountId: accountId)
        }
    }

    func fetchUsageWithOrgId(_ orgId: String, cookie: String, accountId: UUID) {
        let urlString = "https://claude.ai/api/organizations/\(orgId)/usage"

        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                if let idx = self.accountIndex(for: accountId) {
                    self.accounts[idx].errorMessage = "Invalid URL"
                    self.accounts[idx].isLoading = false
                }
                self.checkAllAccountsLoaded()
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        NSLog("🔍 Fetching for account \(accountId) from: \(urlString)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let idx = self.accountIndex(for: accountId) else {
                    // Account was removed during fetch, ignore result
                    self.checkAllAccountsLoaded()
                    return
                }

                self.accounts[idx].isLoading = false

                if let error = error {
                    NSLog("❌ Error for account \(accountId): \(error.localizedDescription)")
                    self.accounts[idx].errorMessage = "Network error"
                    self.checkAllAccountsLoaded()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.accounts[idx].errorMessage = "Invalid response"
                    self.checkAllAccountsLoaded()
                    return
                }

                NSLog("📡 Account \(accountId) status: \(httpResponse.statusCode)")

                if httpResponse.statusCode == 200, let data = data {
                    self.parseUsageDataForAccount(data, accountId: accountId)
                } else {
                    self.accounts[idx].errorMessage = "HTTP \(httpResponse.statusCode)"
                }

                self.checkAllAccountsLoaded()
            }
        }.resume()
    }

    func parseUsageDataForAccount(_ data: Data, accountId: UUID) {
        guard let idx = accountIndex(for: accountId) else { return }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                accounts[idx].errorMessage = "Invalid JSON"
                return
            }

            NSLog("📊 Parsing usage data for account \(accountId)...")

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Parse the actual claude.ai response format
            if let fiveHour = json["five_hour"] as? [String: Any] {
                if let sessionUtil = fiveHour["utilization"] as? Double {
                    accounts[idx].sessionUsage = Int(sessionUtil)
                    accounts[idx].sessionLimit = 100
                }
                if let resetsAtString = fiveHour["resets_at"] as? String,
                   let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                    accounts[idx].sessionResetsAt = resetsAt
                }
            }

            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let weeklyUtil = sevenDay["utilization"] as? Double {
                    accounts[idx].weeklyUsage = Int(weeklyUtil)
                    accounts[idx].weeklyLimit = 100
                }
                if let resetsAtString = sevenDay["resets_at"] as? String,
                   let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                    accounts[idx].weeklyResetsAt = resetsAt
                }
            }

            // Check for seven_day_sonnet (Pro plan feature)
            if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
                accounts[idx].hasWeeklySonnet = true
                if let sonnetUtil = sevenDaySonnet["utilization"] as? Double {
                    accounts[idx].weeklySonnetUsage = Int(sonnetUtil)
                    accounts[idx].weeklySonnetLimit = 100
                }
                if let resetsAtString = sevenDaySonnet["resets_at"] as? String,
                   let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                    accounts[idx].weeklySonnetResetsAt = resetsAt
                }
            } else {
                accounts[idx].hasWeeklySonnet = false
            }

            accounts[idx].hasFetchedData = true
            accounts[idx].errorMessage = nil

            NSLog("✅ Account \(accountId): Session \(accounts[idx].sessionUsage)%, Weekly \(accounts[idx].weeklyUsage)%")

            // Check notifications for this account
            checkNotificationThresholdsForAccount(id: accountId)

        } catch {
            NSLog("❌ Parse error for account \(accountId): \(error.localizedDescription)")
            accounts[idx].errorMessage = "Parse error"
        }
    }

    func checkAllAccountsLoaded() {
        let allLoaded = accounts.allSatisfy { !$0.isLoading }
        if allLoaded {
            isLoading = false
            lastUpdated = Date()
            syncLegacyProperties()
            updateStatusBar()
            updatePercentages()
            saveAccounts() // Persist notification thresholds
        }
    }

    // Legacy single-account fetch (for backward compatibility)
    func fetchUsageLegacy() {
        isLoading = true
        errorMessage = nil

        fetchOrganizationId(cookie: sessionCookie) { [weak self] orgId in
            guard let self = self, let orgId = orgId else {
                DispatchQueue.main.async {
                    self?.errorMessage = "Could not get org ID from cookie"
                    self?.isLoading = false
                }
                return
            }
            self.fetchUsageWithOrgIdLegacy(orgId)
        }
    }

    func fetchUsageWithOrgIdLegacy(_ orgId: String) {
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
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                if error != nil {
                    self?.errorMessage = "Network error"
                    self?.updateStatusBar()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.errorMessage = "Invalid response"
                    self?.updateStatusBar()
                    return
                }

                if httpResponse.statusCode == 200, let data = data {
                    self?.parseUsageDataLegacy(data)
                } else {
                    self?.errorMessage = "HTTP \(httpResponse.statusCode)"
                }

                self?.updateStatusBar()
            }
        }.resume()
    }

    func parseUsageDataLegacy(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Invalid JSON"
                return
            }

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            if let fiveHour = json["five_hour"] as? [String: Any] {
                if let sessionUtil = fiveHour["utilization"] as? Double {
                    sessionUsage = Int(sessionUtil)
                    sessionLimit = 100
                }
                if let resetsAtString = fiveHour["resets_at"] as? String,
                   let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                    sessionResetsAt = resetsAt
                }
            }

            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let weeklyUtil = sevenDay["utilization"] as? Double {
                    weeklyUsage = Int(weeklyUtil)
                    weeklyLimit = 100
                }
                if let resetsAtString = sevenDay["resets_at"] as? String,
                   let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                    weeklyResetsAt = resetsAt
                }
            }

            if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
                hasWeeklySonnet = true
                if let sonnetUtil = sevenDaySonnet["utilization"] as? Double {
                    weeklySonnetUsage = Int(sonnetUtil)
                    weeklySonnetLimit = 100
                }
                if let resetsAtString = sevenDaySonnet["resets_at"] as? String,
                   let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                    weeklySonnetResetsAt = resetsAt
                }
            } else {
                hasWeeklySonnet = false
            }

            lastUpdated = Date()
            errorMessage = nil
            hasFetchedData = true
            updatePercentages()
        } catch {
            errorMessage = "Parse error"
        }
    }

    // MARK: - Status Bar & Notifications

    func updateStatusBar() {
        // Use max session usage across all accounts for status bar
        let maxSessionPercent: Int
        if accounts.isEmpty {
            maxSessionPercent = Int((Double(sessionUsage) / Double(sessionLimit)) * 100)
        } else {
            maxSessionPercent = accounts.map { Int($0.sessionPercentage * 100) }.max() ?? 0
        }

        // Update the icon color based on highest usage
        delegate?.updateStatusIcon(percentage: maxSessionPercent)
    }

    func checkNotificationThresholdsForAccount(id: UUID) {
        guard notificationsEnabled else { return }
        guard let idx = accountIndex(for: id) else { return }

        let percentage = Int(accounts[idx].sessionPercentage * 100)
        let lastThreshold = accounts[idx].lastNotifiedThreshold
        let thresholds = [25, 50, 75, 90]

        for threshold in thresholds {
            if percentage >= threshold && lastThreshold < threshold {
                NSLog("📬 Sending notification for account '\(accounts[idx].name)' at \(threshold)%")
                sendNotificationForAccount(accountName: accounts[idx].name, percentage: percentage, threshold: threshold)
                accounts[idx].lastNotifiedThreshold = threshold
            }
        }

        // Reset if usage drops below current threshold
        if percentage < lastThreshold {
            let newThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            accounts[idx].lastNotifiedThreshold = newThreshold
        }
    }

    // Legacy notification check (for backward compatibility)
    func checkNotificationThresholds(percentage: Int) {
        NSLog("🔔 Checking notifications: percentage=\(percentage)%, enabled=\(notificationsEnabled), lastNotified=\(lastNotifiedThreshold)%")

        guard notificationsEnabled else { return }

        let thresholds = [25, 50, 75, 90]

        for threshold in thresholds {
            if percentage >= threshold && lastNotifiedThreshold < threshold {
                sendNotification(percentage: percentage, threshold: threshold)
                lastNotifiedThreshold = threshold
                UserDefaults.standard.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
                UserDefaults.standard.synchronize()
            }
        }

        if percentage < lastNotifiedThreshold {
            let newThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            lastNotifiedThreshold = newThreshold
            UserDefaults.standard.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
            UserDefaults.standard.synchronize()
        }
    }

    func sendNotificationForAccount(accountName: String, percentage: Int, threshold: Int) {
        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert - \(accountName)"
        notification.informativeText = "You've reached \(percentage)% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent notification for '\(accountName)' at \(threshold)% threshold")
    }

    func sendNotification(percentage: Int, threshold: Int) {
        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = "You've reached \(percentage)% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
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

    func updatePercentages() {
        sessionPercentage = sessionLimit > 0 ? Double(sessionUsage) / Double(sessionLimit) : 0
        weeklyPercentage = weeklyLimit > 0 ? Double(weeklyUsage) / Double(weeklyLimit) : 0
        weeklySonnetPercentage = weeklySonnetLimit > 0 ? Double(weeklySonnetUsage) / Double(weeklySonnetLimit) : 0
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

// MARK: - WebView Login

struct WebLoginView: NSViewRepresentable {
    let onCookieExtracted: (String) -> Void
    let onCookiesDetected: (String) -> Void
    @Binding var extractTrigger: Bool
    let detectedCookie: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        // Store reference in coordinator
        context.coordinator.webView = webView

        // Load Claude.ai login page
        if let url = URL(string: "https://claude.ai/login") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Check if extraction was triggered (user clicked Create Account)
        if extractTrigger && !detectedCookie.isEmpty {
            DispatchQueue.main.async {
                self.extractTrigger = false
                onCookieExtracted(detectedCookie)
            }
        }
    }

    func makeCoordinator() -> WebLoginCoordinator {
        WebLoginCoordinator(onCookiesDetected: onCookiesDetected)
    }
}

class WebLoginCoordinator: NSObject, WKNavigationDelegate {
    weak var webView: WKWebView?
    let onCookiesDetected: (String) -> Void
    private var cookieCheckTimer: Timer?
    private var hasDetectedCookies = false

    init(onCookiesDetected: @escaping (String) -> Void) {
        self.onCookiesDetected = onCookiesDetected
        super.init()
        // Start a timer to periodically check for cookies
        startCookieCheckTimer()
    }

    deinit {
        cookieCheckTimer?.invalidate()
    }

    func startCookieCheckTimer() {
        cookieCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkCookiesPeriodically()
        }
    }

    func checkCookiesPeriodically() {
        guard !hasDetectedCookies, let webView = webView else { return }

        // Check if we're on a logged-in page
        guard let url = webView.url else { return }
        let urlString = url.absoluteString

        let isOnClaudeAi = urlString.contains("claude.ai")
        let isOnAuthPage = urlString.contains("/login") || urlString.contains("/signup") || urlString.contains("/oauth")

        if isOnClaudeAi && !isOnAuthPage {
            checkCookies(from: webView)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let urlString = url.absoluteString

        NSLog("WebLogin: Navigation finished to \(urlString)")

        // Check if we've navigated to a page indicating successful login
        // User is logged in if they're on claude.ai but NOT on the login/signup pages
        let isOnClaudeAi = urlString.contains("claude.ai")
        let isOnAuthPage = urlString.contains("/login") || urlString.contains("/signup") || urlString.contains("/oauth")

        if isOnClaudeAi && !isOnAuthPage {
            NSLog("WebLogin: Detected logged-in state at \(urlString), checking cookies...")
            checkCookies(from: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("WebLogin: Navigation failed: \(error.localizedDescription)")
    }

    func checkCookies(from webView: WKWebView) {
        NSLog("WebLogin: Checking cookies...")

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }

            // Filter cookies for claude.ai domain
            let claudeCookies = cookies.filter { cookie in
                cookie.domain.contains("claude.ai")
            }

            NSLog("WebLogin: Found \(claudeCookies.count) claude.ai cookies")

            // Build cookie string in the format expected by the app
            var cookieParts: [String] = []
            var hasSessionKey = false
            var hasLastActiveOrg = false

            for cookie in claudeCookies {
                cookieParts.append("\(cookie.name)=\(cookie.value)")
                if cookie.name == "sessionKey" {
                    hasSessionKey = true
                }
                if cookie.name == "lastActiveOrg" {
                    hasLastActiveOrg = true
                }
                NSLog("WebLogin: Cookie - \(cookie.name)")
            }

            let cookieString = cookieParts.joined(separator: "; ")

            DispatchQueue.main.async {
                if hasSessionKey || hasLastActiveOrg {
                    NSLog("WebLogin: Valid cookies detected (sessionKey: \(hasSessionKey), lastActiveOrg: \(hasLastActiveOrg))")
                    self.hasDetectedCookies = true
                    self.cookieCheckTimer?.invalidate()
                    self.onCookiesDetected(cookieString)
                } else {
                    NSLog("WebLogin: Missing required cookies, waiting for login...")
                }
            }
        }
    }
}

struct WebLoginWindowView: View {
    let onCookieExtracted: (String) -> Void
    let onCancel: () -> Void
    @State private var isLoading = true
    @State private var extractTrigger = false
    @State private var detectedCookie = ""

    var cookiesReady: Bool {
        !detectedCookie.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Sign in to Claude")
                    .font(.headline)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .help("Cancel")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // WebView
            ZStack {
                WebLoginView(
                    onCookieExtracted: { cookie in
                        onCookieExtracted(cookie)
                    },
                    onCookiesDetected: { cookie in
                        detectedCookie = cookie
                    },
                    extractTrigger: $extractTrigger,
                    detectedCookie: detectedCookie
                )

                if isLoading {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onAppear {
                // Hide loading indicator after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    isLoading = false
                }
            }

            Divider()

            // Footer with create account button
            HStack {
                if cookiesReady {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Login successful")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                    Text("Waiting for login...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Create Account") {
                    extractTrigger = true
                }
                .buttonStyle(.borderedProminent)
                .tint(cookiesReady ? .accentColor : .gray)
                .controlSize(.small)
                .disabled(!cookiesReady)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 500, height: 650)
    }
}

// MARK: - Color Helpers

let defaultAccountColors: [Color] = [.blue, .purple, .teal, .orange]

// Color extension to parse hex strings
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 255) // Default to blue on parse failure
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }

    func toHex() -> String {
        guard let components = NSColor(self).usingColorSpace(.deviceRGB) else { return "#0000FF" }
        let r = Int(components.redComponent * 255)
        let g = Int(components.greenComponent * 255)
        let b = Int(components.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

func colorForAccount(index: Int, accounts: [ClaudeAccount]? = nil) -> Color {
    // Use custom color if available
    if let accounts = accounts, index < accounts.count, let customHex = accounts[index].customColorHex {
        return Color(hex: customHex)
    }
    return defaultAccountColors[index % defaultAccountColors.count]
}

func colorForUsage(percentage: Double) -> Color {
    if percentage < 0.7 {
        return .green
    } else if percentage < 0.9 {
        return .orange
    } else {
        return .red
    }
}

// MARK: - Chart Style Views

struct UltraCompactChartView: View {
    @ObservedObject var usageManager: UsageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Session row
            MetricRow(
                label: "Session",
                accounts: usageManager.accounts,
                getValue: { $0.sessionPercentage },
                getResetTime: { $0.sessionResetsAt },
                colorMode: usageManager.colorMode,
                includeDate: false,
                showRemaining: usageManager.showTimeRemaining
            )

            // Weekly row
            MetricRow(
                label: "Weekly",
                accounts: usageManager.accounts,
                getValue: { $0.weeklyPercentage },
                getResetTime: { $0.weeklyResetsAt },
                colorMode: usageManager.colorMode,
                includeDate: true,
                showRemaining: usageManager.showTimeRemaining
            )

            // Sonnet row (only if any account has it)
            if usageManager.accounts.contains(where: { $0.hasWeeklySonnet }) {
                MetricRow(
                    label: "Sonnet",
                    accounts: usageManager.accounts,
                    getValue: { $0.hasWeeklySonnet ? $0.weeklySonnetPercentage : nil },
                    getResetTime: { $0.weeklySonnetResetsAt },
                    colorMode: usageManager.colorMode,
                    includeDate: true,
                    showRemaining: usageManager.showTimeRemaining
                )
            }
        }
    }
}

struct MetricRow: View {
    let label: String
    let accounts: [ClaudeAccount]
    let getValue: (ClaudeAccount) -> Double?
    let getResetTime: (ClaudeAccount) -> Date?
    let colorMode: ColorMode
    let includeDate: Bool
    var showRemaining: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .frame(width: 55, alignment: .leading)

                // Side-by-side bars
                HStack(spacing: 4) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if let value = getValue(account) {
                            CompactBar(
                                percentage: value,
                                color: colorForBarMetric(percentage: value, index: index, colorMode: colorMode)
                            )
                        } else {
                            // N/A indicator
                            Text("n/a")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                // Percentages
                HStack(spacing: 4) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if let value = getValue(account) {
                            Text("\(Int(value * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 30)
                        }
                    }
                }
            }

            // Reset times for all accounts
            HStack(spacing: 8) {
                Text("Resets")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if let resetTime = getResetTime(account) {
                        Text(formatResetTimeCompact(resetTime, includeDate: includeDate, showRemaining: showRemaining))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if index < accounts.count - 1 {
                            Text("/")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    func colorForBarMetric(percentage: Double, index: Int, colorMode: ColorMode) -> Color {
        let accountColor = index < accounts.count ? accounts[index].displayColor : defaultAccountColors[index % defaultAccountColors.count]
        switch colorMode {
        case .byUsageLevel:
            return colorForUsage(percentage: percentage)
        case .byAccount:
            return accountColor
        case .hybrid:
            return percentage > 0.9 ? .red : accountColor
        }
    }
}

struct CompactBar: View {
    let percentage: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 8)
                    .cornerRadius(4)

                Rectangle()
                    .fill(color)
                    .frame(width: geometry.size.width * min(percentage, 1.0), height: 8)
                    .cornerRadius(4)
            }
        }
        .frame(height: 8)
    }
}

// Reusable colored progress bar (replaces ProgressView which doesn't tint reliably on macOS)
struct ColoredProgressBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 4)
                    .cornerRadius(2)

                Rectangle()
                    .fill(color)
                    .frame(width: geometry.size.width * min(CGFloat(value), 1.0), height: 4)
                    .cornerRadius(2)
            }
        }
        .frame(height: 4)
    }
}

struct StackedVerticalChartView: View {
    @ObservedObject var usageManager: UsageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Session section
            MetricSection(
                title: "Session (5 hour)",
                accounts: usageManager.accounts,
                getValue: { $0.sessionPercentage },
                getResetTime: { $0.sessionResetsAt },
                colorMode: usageManager.colorMode,
                includeDate: false,
                showRemaining: usageManager.showTimeRemaining
            )

            // Weekly section
            MetricSection(
                title: "Weekly (7 day)",
                accounts: usageManager.accounts,
                getValue: { $0.weeklyPercentage },
                getResetTime: { $0.weeklyResetsAt },
                colorMode: usageManager.colorMode,
                includeDate: true,
                showRemaining: usageManager.showTimeRemaining
            )

            // Sonnet section (only if any account has it)
            if usageManager.accounts.contains(where: { $0.hasWeeklySonnet }) {
                MetricSection(
                    title: "Weekly Sonnet",
                    accounts: usageManager.accounts,
                    getValue: { $0.hasWeeklySonnet ? $0.weeklySonnetPercentage : nil },
                    getResetTime: { $0.weeklySonnetResetsAt },
                    colorMode: usageManager.colorMode,
                    includeDate: true,
                    showRemaining: usageManager.showTimeRemaining
                )
            }
        }
    }
}

struct MetricSection: View {
    let title: String
    let accounts: [ClaudeAccount]
    let getValue: (ClaudeAccount) -> Double?
    let getResetTime: (ClaudeAccount) -> Date?
    let colorMode: ColorMode
    let includeDate: Bool
    var showRemaining: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                // Show reset times for all accounts
                HStack(spacing: 4) {
                    Text("Resets")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if let resetTime = getResetTime(account) {
                            Text(formatResetTimeCompact(resetTime, includeDate: includeDate, showRemaining: showRemaining))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if index < accounts.count - 1 {
                                Text("/")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if let value = getValue(account) {
                    HStack(spacing: 8) {
                        // Custom bar instead of ProgressView for reliable colors
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(height: 6)
                                    .cornerRadius(3)

                                Rectangle()
                                    .fill(colorForBarMetric(percentage: value, index: index, colorMode: colorMode))
                                    .frame(width: geometry.size.width * min(CGFloat(value), 1.0), height: 6)
                                    .cornerRadius(3)
                            }
                        }
                        .frame(height: 6)

                        Text("\(account.name) \(Int(value * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(minWidth: 80, alignment: .trailing)
                    }
                } else {
                    HStack {
                        Text("\(account.name)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("n/a")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    func colorForBarMetric(percentage: Double, index: Int, colorMode: ColorMode) -> Color {
        let accountColor = index < accounts.count ? accounts[index].displayColor : defaultAccountColors[index % defaultAccountColors.count]
        switch colorMode {
        case .byUsageLevel:
            return colorForUsage(percentage: percentage)
        case .byAccount:
            return accountColor
        case .hybrid:
            return percentage > 0.9 ? .red : accountColor
        }
    }
}

struct SeparateCardsView: View {
    @ObservedObject var usageManager: UsageManager

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(usageManager.accounts.enumerated()), id: \.element.id) { index, account in
                AccountCard(
                    account: account,
                    index: index,
                    colorMode: usageManager.colorMode,
                    showRemaining: usageManager.showTimeRemaining
                )
            }
        }
    }
}

struct AccountCard: View {
    let account: ClaudeAccount
    let index: Int
    let colorMode: ColorMode
    var showRemaining: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Show custom icon if available, otherwise colored circle
                if let iconImage = account.iconImage {
                    ZStack {
                        // Outer colored ring
                        Circle()
                            .fill(account.displayColor)
                            .frame(width: 28, height: 28)
                        // White background for transparency
                        Circle()
                            .fill(Color.white)
                            .frame(width: 22, height: 22)
                        Image(nsImage: iconImage)
                            .resizable()
                            .frame(width: 22, height: 22)
                            .clipShape(Circle())
                    }
                } else {
                    Circle()
                        .fill(account.displayColor)
                        .frame(width: 12, height: 12)
                }
                Text(account.name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }

            if let error = account.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
            } else if account.hasFetchedData {
                // Session
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ColoredProgressBar(value: account.sessionPercentage, color: cardBarColor(percentage: account.sessionPercentage))
                    HStack {
                        Text("\(Int(account.sessionPercentage * 100))%")
                            .font(.caption2)
                        Spacer()
                        if let resetTime = account.sessionResetsAt {
                            Text(formatResetTimeCompact(resetTime, includeDate: false, showRemaining: showRemaining))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Weekly
                VStack(alignment: .leading, spacing: 2) {
                    Text("Weekly")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ColoredProgressBar(value: account.weeklyPercentage, color: cardBarColor(percentage: account.weeklyPercentage))
                    HStack {
                        Text("\(Int(account.weeklyPercentage * 100))%")
                            .font(.caption2)
                        Spacer()
                        if let resetTime = account.weeklyResetsAt {
                            Text(formatResetTimeCompact(resetTime, includeDate: true, showRemaining: showRemaining))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Sonnet (if available)
                if account.hasWeeklySonnet {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sonnet")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        ColoredProgressBar(value: account.weeklySonnetPercentage, color: cardBarColor(percentage: account.weeklySonnetPercentage))
                        Text("\(Int(account.weeklySonnetPercentage * 100))%")
                            .font(.caption2)
                    }
                }
            } else if account.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Text("No data")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
        .frame(maxWidth: .infinity)
    }

    func cardBarColor(percentage: Double) -> Color {
        switch colorMode {
        case .byUsageLevel:
            return colorForUsage(percentage: percentage)
        case .byAccount:
            return account.displayColor
        case .hybrid:
            return percentage > 0.9 ? .red : account.displayColor
        }
    }
}

func formatResetTimeCompact(_ date: Date, includeDate: Bool, showRemaining: Bool = false) -> String {
    if showRemaining {
        let now = Date()
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 {
            return "now"
        }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 24 {
            let days = hours / 24
            return "in \(days)d \(hours % 24)h"
        } else if hours > 0 {
            return "in \(hours)h \(minutes)m"
        } else {
            return "in \(minutes)m"
        }
    } else {
        let formatter = DateFormatter()
        if includeDate {
            formatter.dateFormat = "d MMM 'at' h:mm a"
            return "on \(formatter.string(from: date))"
        } else {
            formatter.timeStyle = .short
            return "at \(formatter.string(from: date))"
        }
    }
}

// MARK: - Account Management Inline Views

struct AddAccountInlineView: View {
    @ObservedObject var usageManager: UsageManager
    @Binding var isPresented: Bool
    @State private var accountName: String = ""
    @State private var cookieInput: String = ""
    @State private var showInstructions: Bool = false
    @State private var showManualEntry: Bool = false
    @State private var showWebLogin: Bool = false
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add Account")
                    .font(.headline)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }

            TextField("Account Name (e.g., Personal, Work)", text: $accountName)
                .textFieldStyle(.roundedBorder)

            // Primary action: Login with Browser
            VStack(alignment: .leading, spacing: 8) {
                Button(action: { showWebLogin = true }) {
                    HStack {
                        Image(systemName: "globe")
                        Text("Login with Browser")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Sign in to Claude.ai directly - no manual steps needed")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Secondary option: Manual cookie entry
            VStack(alignment: .leading, spacing: 4) {
                Button(action: { showManualEntry.toggle() }) {
                    HStack {
                        Text("Paste Cookie Manually")
                            .font(.caption)
                        Spacer()
                        Image(systemName: showManualEntry ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)

                if showManualEntry {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Session Cookie")
                                .font(.caption)
                            Spacer()
                            Button(showInstructions ? "Hide Help" : "How to get cookie") {
                                showInstructions.toggle()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                        }

                        if showInstructions {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("1. Go to Settings > Usage on claude.ai")
                                Text("2. Press F12 (or Cmd+Option+I)")
                                Text("3. Go to Network tab")
                                Text("4. Refresh page, click 'usage' request")
                                Text("5. Find 'Cookie' in Request Headers")
                                Text("6. Copy full cookie value")
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(6)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                        }

                        PasteableTextField(text: $cookieInput, placeholder: "Paste cookie here...")
                            .frame(height: 50)

                        if let error = validationError {
                            Text(error)
                                .font(.caption2)
                                .foregroundColor(.red)
                        }

                        HStack {
                            Spacer()
                            Button("Add Account") {
                                addAccountWithCookie()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(cookieInput.isEmpty)
                        }
                    }
                    .padding(.top, 4)
                }
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
        .sheet(isPresented: $showWebLogin) {
            WebLoginWindowView(
                onCookieExtracted: { cookie in
                    showWebLogin = false
                    handleExtractedCookie(cookie)
                },
                onCancel: {
                    showWebLogin = false
                }
            )
        }
    }

    private func handleExtractedCookie(_ cookie: String) {
        // Validate: check for duplicate cookie
        if usageManager.accounts.contains(where: { $0.sessionCookie == cookie }) {
            validationError = "This account is already added"
            return
        }

        let name = accountName.isEmpty ? "Account \(usageManager.accounts.count + 1)" : accountName
        usageManager.addAccount(name: name, cookie: cookie)
        usageManager.fetchUsageForAccount(index: usageManager.accounts.count - 1)
        isPresented = false
    }

    private func addAccountWithCookie() {
        // Validate: check for duplicate cookie
        if usageManager.accounts.contains(where: { $0.sessionCookie == cookieInput }) {
            validationError = "This cookie is already added to another account"
            return
        }
        // Validate: basic cookie format check
        if !cookieInput.contains("sessionKey=") && !cookieInput.contains("lastActiveOrg=") {
            validationError = "Cookie doesn't appear to be valid (missing sessionKey or lastActiveOrg)"
            return
        }

        let name = accountName.isEmpty ? "Account \(usageManager.accounts.count + 1)" : accountName
        usageManager.addAccount(name: name, cookie: cookieInput)
        usageManager.fetchUsageForAccount(index: usageManager.accounts.count - 1)
        isPresented = false
    }
}

struct EditAccountInlineView: View {
    @ObservedObject var usageManager: UsageManager
    let accountId: UUID
    @Binding var isPresented: Bool
    @State private var accountName: String = ""
    @State private var cookieInput: String = ""
    @State private var selectedColor: Color = .blue
    @State private var iconURLInput: String = ""
    @State private var showDeleteConfirm: Bool = false

    let colorOptions: [(String, Color)] = [
        ("Blue", .blue), ("Purple", .purple), ("Teal", .teal), ("Orange", .orange),
        ("Red", .red), ("Green", .green), ("Pink", .pink), ("Yellow", .yellow)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Edit Account")
                    .font(.headline)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }

            TextField("Account Name", text: $accountName)
                .textFieldStyle(.roundedBorder)

            // Color picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Account Color")
                    .font(.caption)
                HStack(spacing: 6) {
                    ForEach(colorOptions, id: \.0) { name, color in
                        Circle()
                            .fill(color)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary, lineWidth: selectedColor.toHex() == color.toHex() ? 2 : 0)
                            )
                            .onTapGesture {
                                selectedColor = color
                            }
                    }
                }
            }

            // Icon URL
            VStack(alignment: .leading, spacing: 4) {
                Text("Icon URL (optional - e.g., GitHub avatar)")
                    .font(.caption)
                PasteableTextField(text: $iconURLInput, placeholder: "https://github.com/username.png")
                    .frame(height: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Session Cookie (leave empty to keep current)")
                    .font(.caption)
                PasteableTextField(text: $cookieInput, placeholder: "Paste new cookie to update...")
                    .frame(height: 50)
            }

            HStack {
                Button("Delete", role: .destructive) {
                    showDeleteConfirm = true
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    let colorHex = selectedColor.toHex()
                    let iconURL = iconURLInput.isEmpty ? nil : iconURLInput
                    usageManager.updateAccount(id: accountId, name: accountName, cookie: cookieInput, colorHex: colorHex, iconURL: iconURL)
                    if !cookieInput.isEmpty {
                        if let index = usageManager.accounts.firstIndex(where: { $0.id == accountId }) {
                            usageManager.fetchUsageForAccount(index: index)
                        }
                    }
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(accountName.isEmpty)
            }

            if showDeleteConfirm {
                VStack(spacing: 8) {
                    Text("Delete this account?")
                        .font(.caption)
                        .fontWeight(.semibold)
                    HStack {
                        Button("Cancel") {
                            showDeleteConfirm = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Delete") {
                            usageManager.removeAccount(id: accountId)
                            isPresented = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }
        }
        .onAppear {
            if let account = usageManager.accounts.first(where: { $0.id == accountId }) {
                accountName = account.name
                if let hex = account.customColorHex {
                    selectedColor = Color(hex: hex)
                }
                iconURLInput = account.iconURL ?? ""
            }
        }
    }
}

// MARK: - Main Usage View

struct UsageView: View {
    @ObservedObject var usageManager: UsageManager
    @State private var showingSettings: Bool = false
    @State private var showingAddAccount: Bool = false
    @State private var editingAccountId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Show Add Account form if active
            if showingAddAccount {
                AddAccountInlineView(usageManager: usageManager, isPresented: $showingAddAccount)
            } else if let editId = editingAccountId {
                EditAccountInlineView(usageManager: usageManager, accountId: editId, isPresented: Binding(
                    get: { editingAccountId != nil },
                    set: { if !$0 { editingAccountId = nil } }
                ))
            } else {
                // Normal view
                mainContentView
            }
        }
        .padding()
        .frame(width: popoverWidth)
        .id(usageManager.refreshTrigger)  // Force complete redraw when triggered
        .onAppear {
            usageManager.updatePercentages()
        }
    }

    var mainContentView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                if usageManager.accounts.count < 4 {
                    Button(action: { showingAddAccount = true }) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Add Account")
                }
            }
            .padding(.bottom, 4)

            if let error = usageManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.bottom, 8)
            }

            // Show welcome message or usage charts
            if usageManager.accounts.isEmpty {
                Text("Welcome! Click + to add your first Claude account.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                // Multi-account chart views
                switch usageManager.chartStyle {
                case .ultraCompact:
                    UltraCompactChartView(usageManager: usageManager)
                case .stackedVertical:
                    StackedVerticalChartView(usageManager: usageManager)
                case .separateCards:
                    SeparateCardsView(usageManager: usageManager)
                }

                // Account legend with edit/delete (always show so users can manage accounts)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(usageManager.accounts.enumerated()), id: \.element.id) { index, account in
                        HStack {
                            // Show custom icon if available, otherwise colored circle
                            if let iconImage = account.iconImage {
                                ZStack {
                                    // Outer colored ring
                                    Circle()
                                        .fill(account.displayColor)
                                        .frame(width: 36, height: 36)
                                    // White background for transparency
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 30, height: 30)
                                    Image(nsImage: iconImage)
                                        .resizable()
                                        .frame(width: 30, height: 30)
                                        .clipShape(Circle())
                                }
                            } else {
                                Circle()
                                    .fill(account.displayColor)
                                    .frame(width: 14, height: 14)
                            }
                            Text(account.name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()

                            Menu {
                                Button("Edit") {
                                    editingAccountId = account.id
                                }
                                Button("Remove", role: .destructive) {
                                    usageManager.removeAccount(id: account.id)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.caption)
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 20)
                        }
                    }
                }
                .padding(.top, 4)

                Divider()

                HStack {
                    Text("Updated: \(formatTime(usageManager.lastUpdated))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if usageManager.isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Button("Refresh All") {
                            usageManager.fetchUsage()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }

            // Settings Section
            Button(showingSettings ? "Hide Settings" : "Settings") {
                showingSettings.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingSettings {
                VStack(alignment: .leading, spacing: 12) {
                    // Chart Style picker (only show if multiple accounts)
                    if usageManager.accounts.count > 1 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Chart Style")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Picker("", selection: Binding(
                                get: { usageManager.chartStyle },
                                set: { newValue in
                                    usageManager.chartStyle = newValue
                                    usageManager.saveAccounts()
                                    // Notify AppDelegate to reposition popover
                                    NotificationCenter.default.post(name: NSNotification.Name("ChartStyleChanged"), object: nil)
                                }
                            )) {
                                ForEach(ChartStyle.allCases, id: \.self) { style in
                                    Text(style.rawValue).tag(style)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Color Mode")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Picker("", selection: Binding(
                                get: { usageManager.colorMode },
                                set: { newValue in
                                    usageManager.colorMode = newValue
                                    usageManager.saveAccounts()
                                }
                            )) {
                                ForEach(ColorMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }

                        Divider()
                    }

                    // Reset time format toggle
                    Toggle(isOn: Binding(
                        get: { usageManager.showTimeRemaining },
                        set: { newValue in
                            usageManager.showTimeRemaining = newValue
                            usageManager.saveAccounts()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Time Remaining")
                                .font(.caption)
                            Text("Show \"in 3h 15m\" instead of date/time")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

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
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keyboard Shortcut")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text("Toggle popup from anywhere")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if !usageManager.isAccessibilityEnabled {
                            Button("Enable Keyboard Shortcut") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Text("Grant Accessibility permission in System Settings\nto use Cmd+U shortcut")
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
    }

    var popoverWidth: CGFloat {
        switch usageManager.chartStyle {
        case .ultraCompact:
            return 380
        case .stackedVertical:
            return 340
        case .separateCards:
            return usageManager.accounts.count > 2 ? 420 : 380
        }
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

