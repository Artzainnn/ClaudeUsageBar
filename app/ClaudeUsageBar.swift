import SwiftUI
import AppKit
import WebKit
import Carbon
import Combine

// The categorical logger (enum Log, enum LogValue) lives in Log.swift so
// the SwiftPM library target can compile it without also compiling this
// file's @main entry point. Both files are compiled together by
// app/build.sh into the final .app bundle.

// Main entry point
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var usageManager: UsageManager!
    var statusManager: StatusManager!
    var updateManager: UpdateManager!

    // PR 2c: multi-provider registry. Anthropic is the only provider today;
    // subsequent PRs register additional stores (Codex, DeepSeek, Zed, ...)
    // via `providers.append(...)`. The existing UsageManager continues to
    // drive Anthropic tiles — providers[0] is a thin wrapper around it.
    var providers: [ProviderBox] = []
    // PR 3-UI: the ObservableObject SwiftUI watches for generic provider
    // tiles. Holds the same ProviderBox instances as `providers`.
    var providersModel: ProvidersModel!
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

        // Initialize managers
        usageManager = UsageManager(statusItem: statusItem, delegate: self)
        // Wrap the manager in a UsageProvider so additional providers can
        // register alongside it without disturbing the Anthropic path.
        providers.append(ProviderBox(AnthropicUsageStore(manager: usageManager)))
        // PR 3-UI: register the Codex provider. It is opt-in (feature flag
        // features.codex.enabled defaults false), so registering it here is
        // inert for existing users — it contributes no tiles until enabled.
        providers.append(ProviderBox(CodexUsageStore()))
        // PR 4-UI: register DeepSeek. Also opt-in (features.deepseek.enabled
        // defaults false) and additionally requires a pasted API key, so it
        // is doubly inert until the user both enables and configures it.
        providers.append(ProviderBox(DeepSeekUsageStore()))
        // PR 5-UI: register Zed. Opt-in (features.zed.enabled defaults false);
        // it reads Zed's own Keychain login on first fetch (one-time macOS
        // prompt), so it is inert until enabled and the prompt is allowed.
        providers.append(ProviderBox(ZedUsageStore()))
        // PR 6-UI: register xAI. Opt-in; requires a pasted inference key, with
        // an optional gated management key for balance/history. Inert until
        // enabled and configured.
        providers.append(ProviderBox(XAIUsageStore()))
        // PR 7-UI: register OpenAI Platform. Opt-in; requires a pasted Admin
        // key (sk-admin-). Inert until enabled and configured.
        providers.append(ProviderBox(OpenAIUsageStore()))
        // Model SwiftUI observes for the generic (non-Anthropic) provider
        // tiles. Anthropic continues to render through usageManager directly.
        providersModel = ProvidersModel(providers: providers)
        statusManager = StatusManager()
        updateManager = UpdateManager()

        // Create popover
        popover = NSPopover()
        // Initial guess; SwiftUI's intrinsic size (capped at 600) will drive the actual size.
        popover.contentSize = NSSize(width: 360, height: 320)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsageView(
            usageManager: usageManager,
            statusManager: statusManager,
            updateManager: updateManager,
            providersModel: providersModel
        ))

        // Fetch initial data
        usageManager.fetchUsage()
        statusManager.fetch()
        updateManager.fetch()
        // Fetch any enabled non-Anthropic providers (Codex, etc.) on launch.
        providersModel.fetchEnabled()

        // Non-Anthropic providers poll on their own cadence. Codex documents
        // 60s while active; a single 60s timer drives every enabled provider.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            self.providersModel.fetchEnabled()
        }

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
            // Refresh enabled non-Anthropic providers (Codex, etc.) so their
            // tiles are current when the popover appears.
            providersModel?.fetchEnabled()

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

    func updateStatusIcon(percentage: Int) {
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
        button.title = " \(percentage)%"
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

        openAtLogin = UserDefaults.standard.bool(forKey: "open_at_login")
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

    func saveSessionCookie(_ cookie: String) {
        Log.info("ClaudeUsage: saving cookie", .count(cookie.count))
        sessionCookie = cookie
        UserDefaults.standard.set(cookie, forKey: "claude_session_cookie")
        UserDefaults.standard.synchronize()
        Log.info("ClaudeUsage: cookie saved successfully")
    }

    func clearSessionCookie() {
        Log.info("ClaudeUsage: clearing cookie")
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
        hasFetchedData = false
        hasWeeklySonnet = false
        hasWeeklyFable = false
        errorMessage = nil
        lastNotifiedThreshold = 0
        UserDefaults.standard.set(0, forKey: "last_notified_threshold")

        // Update status bar to show 0%
        delegate?.updateStatusIcon(percentage: 0)

        Log.info("ClaudeUsage: cookie cleared, data reset")
    }

    func fetchOrganizationId(completion: @escaping (String?) -> Void) {
        // PR 2b: parsing lives in AnthropicUsageFetcher. UsageManager keeps
        // ownership of the network call (which needs to be in the manager
        // for delegate/main-actor reasons) but delegates the string
        // parsing.
        if let orgId = AnthropicUsageFetcher.orgId(fromCookieString: sessionCookie) {
            Log.info("Found org ID in cookie", .identifier(orgId))
            completion(orgId)
            return
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
        }
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

                Log.info("Usage API response", .count(httpResponse.statusCode))

                // Response body is intentionally NOT logged. It contains the
                // full usage JSON tied to the user's cookie and would land in
                // unified log. Diagnostics for debugging live parse issues
                // must go through the DEBUG-only path.
                #if DEBUG
                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    Log.debug("Usage API body (DEBUG only): \(responseString)")
                }
                #endif

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
        // PR 2b: parsing extracted into AnthropicUsageFetcher (Sendable
        // value type, no side effects). UsageManager only applies the
        // resulting snapshot to observable state. Behaviour is identical
        // to the pre-refactor code; every branch is locked in by fixture
        // tests in Tests/TestRunner.
        do {
            let snap = try AnthropicUsageFetcher.parse(data)
            sessionUsage = snap.sessionUsage
            sessionLimit = 100
            sessionResetsAt = snap.sessionResetsAt

            weeklyUsage = snap.weeklyUsage
            weeklyLimit = 100
            weeklyResetsAt = snap.weeklyResetsAt

            hasWeeklySonnet = snap.hasWeeklySonnet
            weeklySonnetUsage = snap.weeklySonnetUsage
            weeklySonnetLimit = 100
            weeklySonnetResetsAt = snap.weeklySonnetResetsAt

            hasWeeklyFable = snap.hasWeeklyFable
            weeklyFableUsage = snap.weeklyFableUsage
            weeklyFableLimit = 100
            weeklyFableResetsAt = snap.weeklyFableResetsAt

            Log.info("Parsed usage",
                     .public("session"), .count(sessionUsage),
                     .public("weekly"), .count(weeklyUsage))

            lastUpdated = Date()
            errorMessage = nil
            hasFetchedData = true
            updatePercentages()
        } catch AnthropicUsageParseError.invalidJSON {
            errorMessage = "Invalid JSON"
        } catch {
            Log.info("Parse error", .public(error.localizedDescription))
            errorMessage = "Parse error"
        }
    }

    func updateStatusBar() {
        let sessionPercent = Int((Double(sessionUsage) / Double(sessionLimit)) * 100)

        // Update the icon color
        delegate?.updateStatusIcon(percentage: sessionPercent)

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

// PR 3-UI: the single ObservableObject SwiftUI watches for the generic
// (non-Anthropic) provider tiles. SwiftUI cannot observe a bare
// `[ProviderBox]`; it needs one ObservableObject to subscribe to. This model
// holds the boxes and re-broadcasts each box's objectWillChange, so any
// provider state change redraws the popover. Anthropic is intentionally
// excluded from `genericProviders` — it renders through usageManager as
// before; this model only drives the additional providers.
//
// @MainActor because it reads and drives @MainActor providers (ProviderBox,
// the stores). Every call site (AppDelegate lifecycle, timers on the main
// runloop, the SwiftUI popover) is already on the main actor, so this adds
// no friction. AppDelegate is annotated @MainActor to match, which AppKit
// already guarantees at runtime.
@MainActor
final class ProvidersModel: ObservableObject {
    let providers: [ProviderBox]
    private var cancellables: [AnyCancellable] = []

    init(providers: [ProviderBox]) {
        self.providers = providers
        for box in providers {
            box.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    /// Providers rendered through the generic path — everything except
    /// Anthropic, which keeps its bespoke rendering in UsageView.content.
    /// `nonisolated` because `providers` is an immutable `let` and `id` is a
    /// nonisolated stored property on ProviderBox — no main-actor state is
    /// touched, so AppDelegate's timer/lifecycle closures can call it.
    nonisolated var genericProviders: [ProviderBox] {
        providers.filter { $0.id != "anthropic" }
    }

    /// The subset of generic providers the user has enabled via Settings.
    /// Reads each provider's `isEnabled` through the `any UsageProvider`
    /// existential, whose protocol is not @MainActor (the stores add it with
    /// @preconcurrency), so this stays nonisolated.
    nonisolated var enabledGenericProviders: [ProviderBox] {
        genericProviders.filter { $0.provider.isEnabled }
    }

    /// Fetch every enabled non-Anthropic provider. Called on launch, on the
    /// 60s timer, when the popover opens, and from the Refresh button — all
    /// on the main thread in practice. `nonisolated` so those synchronous
    /// call sites do not need per-site actor hops.
    nonisolated func fetchEnabled() {
        for box in enabledGenericProviders {
            box.provider.fetch()
        }
    }

    /// Force the popover to re-evaluate which provider sections are visible.
    /// A Settings toggle writes the feature flag straight to UserDefaults,
    /// which does not itself fire objectWillChange; the toggle calls this so
    /// a section appears or disappears immediately on both transitions
    /// (enabling a provider also fetches; disabling it has no other signal).
    func providersChanged() {
        objectWillChange.send()
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct UsageView: View {
    @ObservedObject var usageManager: UsageManager
    @ObservedObject var statusManager: StatusManager
    @ObservedObject var updateManager: UpdateManager
    // PR 3-UI: drives the generic (non-Anthropic) provider tiles.
    @ObservedObject var providersModel: ProvidersModel
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
            .onPreferenceChange(ContentHeightKey.self) { value in
                guard value > 0 else { return }
                measuredHeight = value
            }
            .onAppear {
                if let savedCookie = UserDefaults.standard.string(forKey: "claude_session_cookie") {
                    sessionCookieInput = String(savedCookie.prefix(20)) + "..."
                }
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
            Text("Claude Usage")
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
                        Text("Version \(update.version) available")
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
                Text("👋 Welcome! Set your session cookie below to get started.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
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

                ProgressView(value: usageManager.sessionPercentage)
                    .tint(colorForPercentage(usageManager.sessionPercentage))

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

                ProgressView(value: usageManager.weeklyPercentage)
                    .tint(colorForPercentage(usageManager.weeklyPercentage))

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

                    ProgressView(value: usageManager.weeklySonnetPercentage)
                        .tint(colorForPercentage(usageManager.weeklySonnetPercentage))

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

                    ProgressView(value: usageManager.weeklyFablePercentage)
                        .tint(colorForPercentage(usageManager.weeklyFablePercentage))

                    Text("\(Int(usageManager.weeklyFablePercentage * 100))% used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            }

            // PR 3-UI: generic (non-Anthropic) provider tiles. Each enabled
            // provider contributes a section; Anthropic is rendered above via
            // usageManager and is excluded here. Renders nothing when no such
            // provider is enabled, so existing users see no change.
            ForEach(providersModel.enabledGenericProviders) { box in
                Divider()
                ProviderSectionView(box: box)
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
                    updateManager.fetch()
                    providersModel.fetchEnabled()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            }

            Button(showingCookieInput ? "Hide Cookie" : "Set Session Cookie") {
                showingCookieInput.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingCookieInput {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("How to get your session cookie:")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.open(URL(string: "https://github.com/Artzainnn/ClaudeUsageBar/blob/main/setup-guide.png")!)
                        }) {
                            Text("View tutorial →")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.borderless)
                    }

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
                                Button("Save Cookie & Fetch") {
                                    Log.info("ClaudeUsage: save clicked", .count(sessionCookieInput.count))
                                    if sessionCookieInput.isEmpty {
                                        usageManager.errorMessage = "Cookie field is empty!"
                                    } else {
                                        usageManager.saveSessionCookie(sessionCookieInput)
                                        usageManager.fetchUsage()
                                        usageManager.errorMessage = "Cookie saved, fetching..."
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                if usageManager.hasFetchedData {
                                    Button("Clear Cookie") {
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

                    // PR 3-UI: per-provider opt-in toggles. Each non-Anthropic
                    // provider is off by default; enabling one writes its
                    // featureFlagKey and triggers an immediate fetch.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Providers")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("Track additional AI services. Each is opt-in; enable only the ones you use.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(providersModel.genericProviders) { box in
                            ProviderToggleRow(box: box) { enabled in
                                // Re-evaluate section visibility on both
                                // transitions; fetch immediately on enable.
                                if enabled { box.provider.fetch() }
                                providersModel.providersChanged()
                            }
                        }
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
        case "degraded_performance": return "degraded"
        case "partial_outage":       return "partial outage"
        case "major_outage":         return "major outage"
        case "under_maintenance":    return "maintenance"
        default:                     return status
        }
    }

}

// MARK: - Generic provider rendering (PR 3-UI)

/// Renders one non-Anthropic provider: a section header (display name +
/// optional error / last-updated) followed by one UsageTileView per tile.
/// Observes the box so provider state changes redraw this section.
struct ProviderSectionView: View {
    @ObservedObject var box: ProviderBox

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(box.provider.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if let updated = box.provider.lastUpdated {
                    Text("Updated \(shortTime(updated))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if let error = box.provider.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            ForEach(box.provider.tiles) { tile in
                UsageTileView(tile: tile)
            }
        }
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}

/// Renders a single UsageTile by switching on its Kind. This is the generic
/// renderer every future provider reuses — adding a provider needs no new UI
/// as long as it emits one of these kinds.
struct UsageTileView: View {
    let tile: UsageTile

    var body: some View {
        switch tile.kind {
        case let .bar(fraction, resetsAt, badge):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tile.title)
                        .font(.caption)
                    if let badge = badge, !badge.isEmpty {
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(3)
                    }
                    Spacer()
                    if let resetsAt = resetsAt {
                        Text("Resets \(resetLabel(resetsAt))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                ProgressView(value: fraction)
                    .tint(color(for: fraction))
                Text("\(Int((fraction * 100).rounded()))% used")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

        case let .balance(remainingMinorUnits, currency, plan, resetsAt):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(tile.title)
                        .font(.caption)
                    Spacer()
                    Text(formatBalance(remainingMinorUnits, currency: currency))
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                if let plan = plan, !plan.isEmpty {
                    Text(plan)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let resetsAt = resetsAt {
                    Text("Resets \(resetLabel(resetsAt))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

        case let .counter(used, limit, resetsAt):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(tile.title)
                        .font(.caption)
                    Spacer()
                    if let limit = limit {
                        Text("\(used) / \(limit)")
                            .font(.caption)
                            .fontWeight(.semibold)
                    } else {
                        Text("\(used)")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                }
                if let resetsAt = resetsAt {
                    Text("Resets \(resetLabel(resetsAt))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

        case let .text(status, subtitle):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(tile.title)
                        .font(.caption)
                    Spacer()
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case let .needsAccess(path, guidance):
            VStack(alignment: .leading, spacing: 4) {
                Text(tile.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(guidance)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
        }
    }

    private func color(for fraction: Double) -> Color {
        if fraction < 0.7 { return .green }
        if fraction < 0.9 { return .orange }
        return .red
    }

    private func resetLabel(_ date: Date) -> String {
        let f = DateFormatter()
        // Include the date when the reset is more than ~a day out (weekly
        // windows); otherwise just the time (5-hour windows).
        if date.timeIntervalSinceNow > 86_400 {
            f.dateFormat = "d MMM 'at' h:mm a"
            return "on \(f.string(from: date))"
        }
        f.timeStyle = .short
        f.dateStyle = .none
        return "at \(f.string(from: date))"
    }

    private func formatBalance(_ minorUnits: Int, currency: String) -> String {
        let major = Double(minorUnits) / 100.0
        return String(format: "%@ %.2f", currency, major)
    }
}

/// One opt-in checkbox for a non-Anthropic provider in Settings. Reads and
/// writes the provider's featureFlagKey directly in UserDefaults; on enable
/// it fires `onEnable` so the provider fetches immediately rather than
/// waiting for the next timer tick. Below the toggle it shows provider-
/// specific help and, where relevant, a private-API disclosure line.
struct ProviderToggleRow: View {
    @ObservedObject var box: ProviderBox
    /// Called after the flag is written, with the new value, on every
    /// toggle (both enable and disable).
    let onChange: (Bool) -> Void

    @State private var enabled: Bool = false
    // Local buffer for a pasted secret (PasteKeyProvider). Never pre-filled
    // with the stored secret — we only ever write, never read it back out.
    @State private var keyInput: String = ""
    @State private var hasStoredKey: Bool = false
    // Secondary (gated, higher-privilege) key state — xAI's management key.
    @State private var secondaryInput: String = ""
    @State private var hasStoredSecondaryKey: Bool = false

    /// The provider as a PasteKeyProvider, when it is configured by pasting a
    /// secret; nil otherwise.
    private var pasteKeyProvider: PasteKeyProvider? {
        box.provider as? PasteKeyProvider
    }

    /// The provider as a SecondaryKeyProvider, when it accepts an optional
    /// second (gated) key; nil otherwise.
    private var secondaryKeyProvider: SecondaryKeyProvider? {
        box.provider as? SecondaryKeyProvider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { newValue in
                    enabled = newValue
                    UserDefaults.standard.set(newValue, forKey: box.provider.featureFlagKey)
                    onChange(newValue)
                }
            )) {
                Text(box.provider.displayName)
                    .font(.caption)
            }
            .toggleStyle(.checkbox)

            if let help = ProviderCopy.help(for: box.id) {
                Text(help)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let disclosure = ProviderCopy.disclosure(for: box.id) {
                Text(disclosure)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Key-entry affordance for paste-a-secret providers, shown only
            // when the provider is enabled. Uses a SecureField so the pasted
            // value is masked on screen; the stored secret is never read back
            // into the field.
            if enabled, let keyProvider = pasteKeyProvider {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        SecureField(keyProvider.keyPlaceholder, text: $keyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption2)
                        Button("Save") {
                            keyProvider.saveKey(keyInput)
                            keyInput = ""
                            hasStoredKey = keyProvider.hasKey
                            onChange(true)  // trigger a fetch now that a key exists
                        }
                        .controlSize(.small)
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if hasStoredKey {
                            Button("Clear") {
                                keyProvider.saveKey("")  // empty clears
                                hasStoredKey = keyProvider.hasKey
                                onChange(false)
                            }
                            .controlSize(.small)
                        }
                    }
                    Text(hasStoredKey ? "Key saved in Keychain." : "No key saved yet.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    // Secondary (gated, higher-privilege) key. Shown only once
                    // the primary key is stored, and only for providers that
                    // accept one (xAI's management key). Carries an explicit
                    // warning before the field.
                    if hasStoredKey, let secondary = secondaryKeyProvider {
                        Divider()
                        Text(secondary.secondaryKeyLabel)
                            .font(.caption2)
                            .fontWeight(.semibold)
                        Text(secondary.secondaryKeyWarning)
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            SecureField(secondary.secondaryKeyPlaceholder, text: $secondaryInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption2)
                            Button("Save") {
                                secondary.saveSecondaryKey(secondaryInput)
                                secondaryInput = ""
                                hasStoredSecondaryKey = secondary.hasSecondaryKey
                                onChange(true)
                            }
                            .controlSize(.small)
                            .disabled(secondaryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if hasStoredSecondaryKey {
                                Button("Clear") {
                                    secondary.saveSecondaryKey("")
                                    hasStoredSecondaryKey = secondary.hasSecondaryKey
                                    onChange(true)
                                }
                                .controlSize(.small)
                            }
                        }
                        Text(hasStoredSecondaryKey ? "Management key saved in Keychain." : "No management key saved.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .onAppear {
            enabled = UserDefaults.standard.bool(forKey: box.provider.featureFlagKey)
            hasStoredKey = pasteKeyProvider?.hasKey ?? false
            hasStoredSecondaryKey = secondaryKeyProvider?.hasSecondaryKey ?? false
        }
    }
}

