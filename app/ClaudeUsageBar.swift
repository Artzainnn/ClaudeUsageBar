import SwiftUI
import AppKit
import WebKit
import Carbon
import Security

/// NSPanel with .nonactivatingPanel style mask doesn't accept key window status by
/// default, which breaks text input in embedded NSTextView (used by the manual
/// cookie paste flow). Override so clicks inside the panel can drive focus.
final class KeyAcceptingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// Main entry point
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popupPanel: NSPanel?
    var hostingView: NSHostingView<UsageView>?
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

        // Create floating panel (replaces NSPopover for a no-arrow rectangular look)
        buildPopupPanel()

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
        // Only check permissions and register hotkey if user has the shortcut enabled
        guard usageManager.shortcutEnabled else {
            NSLog("ℹ️ Shortcut disabled — skipping accessibility check")
            return
        }
        checkAccessibilityPermissions()
        registerGlobalHotKey()
    }

    func setShortcutEnabled(_ enabled: Bool) {
        if enabled {
            registerGlobalHotKey()
        } else {
            unregisterGlobalHotKey()
        }
    }

    func checkAccessibilityPermissions() {
        let trusted = AXIsProcessTrusted()

        guard !trusted else {
            NSLog("✅ Accessibility permissions granted")
            return
        }
        NSLog("⚠️ Accessibility permissions not granted")

        if UserDefaults.standard.bool(forKey: "accessibility_alert_dismissed") {
            NSLog("ℹ️ User previously dismissed accessibility alert — skipping")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "ClaudeUsageBar needs Accessibility permission to use the Cmd+U keyboard shortcut.\n\nPlease enable it in:\nSystem Settings → Privacy & Security → Accessibility"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Skip for Now")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"

            let response = alert.runModal()
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: "accessibility_alert_dismissed")
            }
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
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

    func buildPopupPanel() {
        let panel = KeyAcceptingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .utilityWindow

        let blur = NSVisualEffectView()
        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: UsageView(usageManager: usageManager))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: blur.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor)
        ])

        panel.contentView = blur
        self.popupPanel = panel
        self.hostingView = hosting
    }

    @objc func togglePopover() {
        if popupPanel?.isVisible == true {
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
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let panel = popupPanel,
              let hosting = hostingView else { return }

        // Defensive: never leave a stale global monitor attached.
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        usageManager.updatePercentages()

        // Resize panel to fit current SwiftUI content
        let target = hosting.fittingSize
        if target.width > 0 && target.height > 0 {
            panel.setContentSize(target)
        }

        // Position panel right under the status item button, centered horizontally
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
        let panelW = panel.frame.width
        let panelH = panel.frame.height
        var x = buttonFrameOnScreen.midX - panelW / 2
        var y = buttonFrameOnScreen.minY - panelH - 4
        if let visible = buttonWindow.screen?.visibleFrame {
            x = min(max(x, visible.minX + 4), visible.maxX - panelW - 4)
            y = max(y, visible.minY + 4)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    func closePopover() {
        popupPanel?.orderOut(nil)
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

enum CookieKeychain {
    private static let service = "com.claudeusagebar.cookie"
    private static let account = "claude_session"

    @discardableResult
    static func save(_ cookie: String) -> Bool {
        let data = Data(cookie.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Try update first, fall back to add
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound {
            NSLog("ClaudeUsage: Keychain update failed status=\(updateStatus)")
        }
        var addAttrs = baseQuery
        addAttrs[kSecValueData as String] = data
        addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        if addStatus != errSecSuccess {
            NSLog("ClaudeUsage: Keychain add failed status=\(addStatus)")
            return false
        }
        return true
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess {
            NSLog("ClaudeUsage: Keychain read failed status=\(status)")
            return nil
        }
        guard let data = result as? Data, let cookie = String(data: data, encoding: .utf8) else {
            return nil
        }
        return cookie
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("ClaudeUsage: Keychain delete failed status=\(status)")
        }
    }
}

class UsageManager: ObservableObject {
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
    @Published var shortcutEnabled: Bool = true
    @Published var sessionExpiresAt: Date?

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
        if let kc = CookieKeychain.read(), !kc.isEmpty {
            sessionCookie = kc
        } else if let legacy = UserDefaults.standard.string(forKey: "claude_session_cookie"), !legacy.isEmpty {
            // One-shot migration from legacy UserDefaults storage.
            NSLog("ClaudeUsage: Migrating cookie from UserDefaults to Keychain")
            sessionCookie = legacy
            if CookieKeychain.save(legacy) {
                UserDefaults.standard.removeObject(forKey: "claude_session_cookie")
                UserDefaults.standard.synchronize()
            }
        }
        if let ts = UserDefaults.standard.object(forKey: "claude_session_expires_at") as? Date {
            sessionExpiresAt = ts
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

    func saveSessionCookie(_ cookie: String, expiresAt: Date? = nil) {
        NSLog("ClaudeUsage: Saving cookie, length: \(cookie.count)")
        sessionCookie = cookie
        if CookieKeychain.save(cookie) {
            NSLog("ClaudeUsage: Cookie saved to Keychain")
        } else {
            NSLog("ClaudeUsage: Cookie save to Keychain FAILED")
        }
        sessionExpiresAt = expiresAt
        if let expiresAt = expiresAt {
            UserDefaults.standard.set(expiresAt, forKey: "claude_session_expires_at")
        } else {
            UserDefaults.standard.removeObject(forKey: "claude_session_expires_at")
        }
        UserDefaults.standard.synchronize()
    }

    func markSessionExpired() {
        sessionExpiresAt = Date()
        UserDefaults.standard.set(Date(), forKey: "claude_session_expires_at")
        UserDefaults.standard.synchronize()
    }

    func clearSessionCookie() {
        NSLog("ClaudeUsage: Clearing cookie")
        sessionCookie = ""
        sessionExpiresAt = nil
        CookieKeychain.delete()
        // Also wipe legacy UserDefaults entry in case migration didn't run.
        UserDefaults.standard.removeObject(forKey: "claude_session_cookie")
        UserDefaults.standard.removeObject(forKey: "claude_session_expires_at")
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

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            // Detect auth failure: claude.ai redirects unauthenticated requests to /login
            // (final URL ends up on /login) and serves an HTML page rather than JSON.
            let httpResponse = response as? HTTPURLResponse
            let finalPath = response?.url?.path.lowercased() ?? ""
            let contentType = (httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let authFailedByStatus = (httpResponse?.statusCode == 401 || httpResponse?.statusCode == 403)
            let authFailedByRedirect = finalPath.contains("/login")
            let authFailedByContentType = !contentType.contains("application/json") && !contentType.isEmpty

            if authFailedByStatus || authFailedByRedirect || authFailedByContentType {
                NSLog("⚠️ Session expired during bootstrap (status=\(httpResponse?.statusCode ?? -1) finalPath=\(finalPath) contentType=\(contentType))")
                DispatchQueue.main.async {
                    self?.errorMessage = "Session expired — please re-sign in"
                    self?.markSessionExpired()
                }
                completion(nil)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let bodyPreview = data.flatMap { String(data: $0.prefix(200), encoding: .utf8) } ?? "<no body>"
                NSLog("❌ Could not parse bootstrap JSON. status=\(httpResponse?.statusCode ?? -1) finalPath=\(finalPath) contentType=\(contentType) body=\(bodyPreview)")
                DispatchQueue.main.async {
                    self?.errorMessage = "Session expired — please re-sign in"
                    self?.markSessionExpired()
                }
                completion(nil)
                return
            }
            // JSON parsed but no account → treat as auth failure
            guard let account = json["account"] as? [String: Any],
                  let lastActiveOrgId = account["lastActiveOrgId"] as? String else {
                NSLog("⚠️ Bootstrap JSON missing account.lastActiveOrgId. keys=\(Array(json.keys)) body=\(String(data: data.prefix(300), encoding: .utf8) ?? "")")
                DispatchQueue.main.async {
                    self?.errorMessage = "Session expired — please re-sign in"
                    self?.markSessionExpired()
                }
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
                    // Preserve a more specific error (e.g. "Session expired") set by fetchOrganizationId.
                    if self?.errorMessage == nil {
                        self?.errorMessage = "Could not get org ID from cookie"
                    }
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

                NSLog("📡 Status: \(httpResponse.statusCode)")

                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    NSLog("📦 Response: \(responseString)")
                }

                let finalPath = response?.url?.path.lowercased() ?? ""
                let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                let authFailedByStatus = (httpResponse.statusCode == 401 || httpResponse.statusCode == 403)
                let authFailedByRedirect = finalPath.contains("/login")
                let authFailedByContentType = httpResponse.statusCode == 200 && !contentType.contains("application/json") && !contentType.isEmpty

                if httpResponse.statusCode == 200, !authFailedByRedirect, !authFailedByContentType, let data = data {
                    self?.parseUsageData(data)
                } else if authFailedByStatus || authFailedByRedirect || authFailedByContentType {
                    NSLog("⚠️ Session expired (status=\(httpResponse.statusCode) finalPath=\(finalPath) contentType=\(contentType))")
                    self?.errorMessage = "Session expired — please re-sign in"
                    self?.markSessionExpired()
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

            // Log what we found
            NSLog("✅ Parsed: Session \(sessionUsage)%, Weekly \(weeklyUsage)%\(hasWeeklySonnet ? ", Weekly Sonnet \(weeklySonnetUsage)%" : "")")

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

        // Update the icon color
        delegate?.updateStatusIcon(percentage: sessionPercent)

        // Check for notification thresholds
        checkNotificationThresholds(percentage: sessionPercent)
    }

    func checkNotificationThresholds(percentage: Int) {
        NSLog("🔔 Checking notifications: percentage=\(percentage)%, enabled=\(notificationsEnabled), lastNotified=\(lastNotifiedThreshold)%")

        guard notificationsEnabled else {
            NSLog("⚠️ Notifications disabled")
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

    func updatePercentages() {
        sessionPercentage = Double(sessionUsage) / Double(sessionLimit)
        weeklyPercentage = Double(weeklyUsage) / Double(weeklyLimit)
        weeklySonnetPercentage = Double(weeklySonnetUsage) / Double(weeklySonnetLimit)
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

final class ClaudeLoginWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static var current: ClaudeLoginWindowController?

    private let onCookieCaptured: (String, Date?) -> Void
    private var webView: WKWebView!
    private var statusLabel: NSTextField!
    private var pollTimer: Timer?
    private var hintTimer: Timer?
    private var captured = false

    init(onCookieCaptured: @escaping (String, Date?) -> Void) {
        self.onCookieCaptured = onCookieCaptured

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Claude"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 760))
        container.autoresizingMask = [.width, .height]

        let toolbarHeight: CGFloat = 44
        let toolbar = NSView(frame: NSRect(x: 0, y: 760 - toolbarHeight, width: 900, height: toolbarHeight))
        toolbar.autoresizingMask = [.width, .minYMargin]
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let status = NSTextField(labelWithString: "Sign in with email — enter your email, then the 6-digit code sent to you. Window will close automatically.")
        status.frame = NSRect(x: 16, y: 12, width: 640, height: 20)
        status.autoresizingMask = [.width]
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        toolbar.addSubview(status)
        self.statusLabel = status

        let captureButton = NSButton(title: "I'm signed in — capture now", target: self, action: #selector(captureNow))
        captureButton.bezelStyle = .rounded
        captureButton.controlSize = .small
        captureButton.frame = NSRect(x: 900 - 220, y: 8, width: 200, height: 28)
        captureButton.autoresizingMask = [.minXMargin]
        toolbar.addSubview(captureButton)

        container.addSubview(toolbar)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let neutralizeSSOSource = """
        (function() {
            try {
                var noop = function() {};
                var fakeId = {
                    initialize: noop, prompt: noop, cancel: noop,
                    disableAutoSelect: noop, renderButton: noop,
                    storeCredential: noop, revoke: noop
                };
                var fakeOAuth2 = { initTokenClient: function() { return { requestAccessToken: noop }; } };
                Object.defineProperty(window, 'google', {
                    value: { accounts: { id: fakeId, oauth2: fakeOAuth2 } },
                    writable: false, configurable: false
                });
                Object.defineProperty(window, 'AppleID', {
                    value: { auth: { init: noop, signIn: noop } },
                    writable: false, configurable: false
                });
            } catch (e) {}
        })();
        """
        let earlyScript = WKUserScript(source: neutralizeSSOSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)

        let hideSSOSource = """
        (function() {
            var TERMS = ['google', 'apple', 'microsoft', 'github', 'sso', 'single sign', 'continue with'];
            function shouldHide(el) {
                var text = (el.textContent || '').toLowerCase();
                var aria = (el.getAttribute && (el.getAttribute('aria-label') || '')).toLowerCase();
                for (var i = 0; i < TERMS.length; i++) {
                    if (text.indexOf(TERMS[i]) !== -1 || aria.indexOf(TERMS[i]) !== -1) {
                        if (text.indexOf('email') !== -1) continue;
                        return true;
                    }
                }
                return false;
            }
            function sweep() {
                var nodes = document.querySelectorAll('button, a[role="button"], a');
                for (var i = 0; i < nodes.length; i++) {
                    if (shouldHide(nodes[i])) {
                        nodes[i].style.display = 'none';
                        var p = nodes[i].parentElement;
                        if (p && p.children.length === 1) p.style.display = 'none';
                    }
                }
                document.querySelectorAll('div, span, p').forEach(function(el) {
                    var t = (el.textContent || '').trim().toLowerCase();
                    if (t === 'or' || t === '— or —' || t === 'or continue with') {
                        el.style.display = 'none';
                    }
                });
            }
            sweep();
            try {
                var obs = new MutationObserver(sweep);
                obs.observe(document.body, { childList: true, subtree: true });
            } catch (e) {}
            setInterval(sweep, 800);
        })();
        """
        let userScript = WKUserScript(source: hideSSOSource, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        let contentController = WKUserContentController()
        contentController.addUserScript(earlyScript)
        contentController.addUserScript(userScript)
        config.userContentController = contentController

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 760 - toolbarHeight),
            configuration: config
        )
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        container.addSubview(webView)
        self.webView = webView

        window.contentView = container

        if let url = URL(string: "https://claude.ai/login") {
            webView.load(URLRequest(url: url))
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.checkCookies(manual: false)
        }
        hintTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, !self.captured else { return }
                self.statusLabel.stringValue = "Still waiting — if you're stuck, close this window and try \"Set cookie manually\" instead."
                self.statusLabel.textColor = .systemOrange
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        pollTimer?.invalidate()
        hintTimer?.invalidate()
    }

    private func cleanup() {
        pollTimer?.invalidate()
        pollTimer = nil
        hintTimer?.invalidate()
        hintTimer = nil
        if ClaudeLoginWindowController.current === self {
            ClaudeLoginWindowController.current = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        cleanup()
    }

    @objc private func captureNow() {
        statusLabel.stringValue = "Capturing cookies…"
        checkCookies(manual: true)
    }

    private static let blockedAuthRules: [(host: String, pathPrefix: String?)] = [
        ("accounts.google.com", nil),
        ("apis.google.com", nil),
        ("oauth2.googleapis.com", nil),
        ("appleid.apple.com", nil),
        ("idmsa.apple.com", nil),
        ("accounts.apple.com", nil),
        ("login.microsoftonline.com", nil),
        ("login.live.com", nil),
        ("github.com", "/login")
    ]

    private func isBlockedAuthURL(_ url: URL?) -> Bool {
        guard let url = url, let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        for rule in Self.blockedAuthRules {
            let hostMatches = (host == rule.host) || host.hasSuffix("." + rule.host)
            guard hostMatches else { continue }
            if let prefix = rule.pathPrefix {
                if path.hasPrefix(prefix) { return true }
            } else {
                return true
            }
        }
        return false
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if isBlockedAuthURL(navigationAction.request.url) {
            NSLog("ClaudeUsage: Blocked SSO navigation to \(navigationAction.request.url?.absoluteString ?? "")")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if isBlockedAuthURL(navigationAction.request.url) {
            NSLog("ClaudeUsage: Blocked SSO popup to \(navigationAction.request.url?.absoluteString ?? "")")
            return nil
        }
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkCookies(manual: false)
    }

    private func checkCookies(manual: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !captured else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async {
                guard let self = self, !self.captured else { return }
                let claudeCookies = cookies.filter { $0.domain.contains("claude.ai") }
                let sessionCookie = claudeCookies.first { $0.name == "sessionKey" && !$0.value.isEmpty }

                guard let sessionCookie = sessionCookie else {
                    if manual {
                        self.statusLabel.stringValue = "No sessionKey cookie found yet — please complete sign in first."
                    }
                    return
                }

                let cookieString = claudeCookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")

                self.captured = true
                self.onCookieCaptured(cookieString, sessionCookie.expiresDate)
                self.window?.close() // triggers windowWillClose → cleanup()
            }
        }
    }
}

func presentClaudeLogin(onCookie: @escaping (String, Date?) -> Void) {
    if let existing = ClaudeLoginWindowController.current {
        NSApp.activate(ignoringOtherApps: true)
        existing.window?.makeKeyAndOrderFront(nil)
        return
    }
    let controller = ClaudeLoginWindowController(onCookieCaptured: onCookie)
    ClaudeLoginWindowController.current = controller
    NSApp.activate(ignoringOtherApps: true)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
}

struct UsageView: View {
    @ObservedObject var usageManager: UsageManager
    @State private var sessionCookieInput: String = ""
    @State private var showingCookieInput: Bool = false
    @State private var showingSettings: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Claude Usage")
                .font(.headline)
                .padding(.bottom, 4)

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
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if let expiry = usageManager.sessionExpiresAt,
               expiry.timeIntervalSinceNow < 7 * 24 * 3600 {
                let isExpired = expiry.timeIntervalSinceNow <= 0
                Text(isExpired
                     ? "⚠️ Session expired \(formatResetTime(expiry, includeDate: true)) — please re-sign in"
                     : "⚠️ Session expires \(formatResetTime(expiry, includeDate: true))")
                    .font(.caption2)
                    .foregroundColor(isExpired ? .red : .orange)
            }
            }

            if usageManager.hasFetchedData {
                Button(action: signInWithEmail) {
                    HStack(spacing: 4) {
                        Image(systemName: "envelope")
                        Text("Re-sign in")
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Button(action: signInWithEmail) {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope")
                        Text("Sign in with email")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button(showingCookieInput ? "Hide manual cookie setup" : "Set cookie manually") {
                showingCookieInput.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingCookieInput {
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
                            PasteableTextField(text: $sessionCookieInput, placeholder: "Paste cookie here...")
                                .frame(height: 60)
                                .cornerRadius(4)

                            HStack(spacing: 8) {
                                Button("Save Cookie & Fetch") {
                                    NSLog("ClaudeUsage: Save clicked, input length: \(sessionCookieInput.count)")
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
        .padding(16)
        .frame(width: 400)
        .onAppear {
            // Force refresh to ensure progress bars show colors
            usageManager.updatePercentages()
        }
    }

    func signInWithEmail() {
        presentClaudeLogin { cookieString, expiresAt in
            NSLog("ClaudeUsage: Auto-captured cookie, length: \(cookieString.count), expires: \(expiresAt?.description ?? "n/a")")
            usageManager.saveSessionCookie(cookieString, expiresAt: expiresAt)
            usageManager.errorMessage = "Signed in, fetching..."
            usageManager.fetchUsage()
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

}
