import SwiftUI
import AppKit
import Carbon
import Combine
import ServiceManagement

// Secondary text: system gray in dark; darker in light, where the vibrant
// ~50% gray over the white popover backing reads as washed out.
extension Color {
    static let secondaryText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .secondaryLabelColor
            : NSColor(white: 0.24, alpha: 1.0) // opaque: vibrancy washes out alpha grays
    })
}

// Deterministic usage bar: the native linear ProgressView ignores .tint() in
// light (aqua) and vibrant rendering and falls back to accent blue.
struct UsageBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

// Main entry point
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keyed by account slot, so a click can name the account it came from and
    /// so an account losing its cookie takes its own item away with it.
    var statusItems: [Int: NSStatusItem] = [:]
    var popover: NSPopover!
    var store: AccountsStore!
    var statusManager: StatusManager!
    var updateManager: UpdateManager!
    var eventMonitor: Any?
    var hotKeyRef: EventHotKeyRef?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSUserNotification (deprecated but works without permissions for unsigned apps)
        NSLog("✅ App launched, notifications ready")

        // Initialize managers
        store = AccountsStore()
        statusManager = StatusManager()
        updateManager = UpdateManager()

        // One subscription covers both things that move the menu bar — a new
        // reading and a cookie saved or cleared — because AccountsStore
        // forwards every account's objectWillChange, and writing any @Published
        // on an account (sessionUsage included) is what emits it.
        //
        // The hop is not a stylistic main-thread bounce, it is what makes this
        // correct: objectWillChange fires in willSet, *before* the new value is
        // stored, and nothing between here and there re-dispatches. Read
        // synchronously, syncStatusItems would see the state as it was before
        // the change — a freshly pasted cookie would leave store.configured
        // still holding one account, so no second icon and no badges until some
        // later, unrelated emission happened to paper over it.
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncStatusItems() }
            .store(in: &cancellables)

        syncStatusItems()

        // Create popover
        popover = NSPopover()
        // Initial guess; SwiftUI's intrinsic size (capped at 600) will drive the actual size.
        popover.contentSize = NSSize(width: 360, height: 320)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsageView(
            store: store,
            statusManager: statusManager,
            updateManager: updateManager
        ))

        // Appearance preference: "system" (default) tracks the macOS light/dark
        // setting; "dark"/"light" force one (dark was hard-forced in v1.3.2 and
        // users complained about losing light mode). Applied after the popover
        // exists so both NSApp and the popover get styled.
        applyAppearancePreference()

        // Re-apply when macOS flips light/dark, so a forced mode that matches
        // the system switches back to the native (inherited) rendering.
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            // The defaults key can lag the notification; re-resolve a tick later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.applyAppearancePreference()
            }
        }

        // Fetch initial data
        store.refreshAll()
        statusManager.fetch()
        updateManager.fetch()

        // Usage + Anthropic status are time-sensitive — poll every 5 min.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.store.refreshAll()
            self.statusManager.fetch()
        }

        // App updates are infrequent (new release at most weekly) — poll every 3 hours.
        Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in
            self.updateManager.fetch()
        }

        // Set up Cmd+U keyboard shortcut
        setupKeyboardShortcut()
    }

    func applyAppearancePreference() {
        let mode = UserDefaults.standard.string(forKey: "appearance_mode") ?? "system"
        let systemIsDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let isDark: Bool
        switch mode {
        case "dark":  isDark = true
        case "light": isDark = false
        default:      isDark = systemIsDark
        }
        // Always set an explicit, resolved appearance ("System" resolves to the
        // current macOS setting) so every mode uses the same rendering path:
        // inherited "vibrant" rendering drops ProgressView tints (bars turn
        // accent-blue) and shades colors slightly differently, which made
        // System and Dark look different. Set on the popover too — it doesn't
        // reliably restyle from NSApp.appearance alone once created.
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        popover?.appearance = appearance
    }

    func setupKeyboardShortcut() {
        // Check Accessibility permissions
        checkAccessibilityPermissions()

        // Only register if user has the shortcut enabled
        if store.accounts[0].shortcutEnabled {
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

    /// The ⌘U hotkey and the right-click menu both reach the popover through
    /// here, and neither of them knows which icon to anchor to.
    @objc func togglePopover() {
        togglePopover(anchoredTo: nil)
    }

    func togglePopover(anchoredTo slot: Int?) {
        if popover.isShown {
            closePopover()
        } else {
            openPopover(anchoredTo: slot)
        }
    }

    @objc func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        // Identity, not equality: which of the buttons we own sent this.
        guard let slot = statusItems.first(where: { $0.value.button === sender })?.key else { return }

        if event.type == .rightMouseUp {
            // Right click - show menu
            let menu = NSMenu()
            // Spelled out because togglePopover(anchoredTo:) now shares the
            // name; #selector resolves by name before it filters by @objc.
            let toggleItem = NSMenuItem(title: "Toggle Usage (⌘U)",
                                        action: #selector(AppDelegate.togglePopover as (AppDelegate) -> () -> Void),
                                        keyEquivalent: "u")
            toggleItem.keyEquivalentModifierMask = .command
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit ClaudeUsageBar", action: #selector(quitApp), keyEquivalent: "q"))
            // Attached and detached on the item that was clicked: left over on
            // the wrong one, a later left click would drop the menu instead of
            // opening the popover.
            statusItems[slot]?.menu = menu
            statusItems[slot]?.button?.performClick(nil)
            statusItems[slot]?.menu = nil
        } else {
            // Left click - toggle popover
            togglePopover(anchoredTo: slot)
        }
    }

    func openPopover(anchoredTo slot: Int?) {
        // ⌘U has no clicked icon to anchor to, so it falls back to the first
        // one. With no items at all there is nothing to anchor to and nothing
        // the user could have been looking at, so this is a no-op, not a crash.
        guard let anchorSlot = slot ?? statusItems.keys.sorted().first,
              let button = statusItems[anchorSlot]?.button else { return }

        // Force UI refresh by updating percentages
        DispatchQueue.main.async {
            self.store.accounts.forEach { $0.updatePercentages() }
        }

        // Pin the content size before showing. NSPopover is positioned from the
        // size it has at show() time, but an NSHostingController only reports
        // its real height after a layout pass — so the popover was placed for
        // the 320pt guess above, then grew to its true height afterwards. An
        // NSWindow grows upward from its origin, so that growth pushed the top
        // off the screen: measured at 1277 on an 1169pt display, clipping the
        // title and the first usage bar.
        if let contentView = popover.contentViewController?.view {
            contentView.layoutSubtreeIfNeeded()
            let fitting = contentView.fittingSize
            if fitting.height > 1 {
                popover.contentSize = NSSize(width: popover.contentSize.width, height: fitting.height)
            }
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Add event monitor to detect clicks outside the popover
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if self?.popover.isShown == true {
                self?.closePopover()
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

    func updateIcon(for account: UsageManager) {
        guard let button = statusItems[account.slot]?.button else { return }
        button.image = menuBarIcon(percentage: account.sessionUsage,
                                   badge: store.showsBadges ? account.slot : nil)
        button.title = " \(account.sessionUsage)%"
    }

    func syncStatusItems() {
        // With no cookie yet there is nothing configured, but the app must not
        // vanish from the menu bar — slot 1 stands in until a cookie arrives.
        // It is the only icon on screen, so it gets no badge: a lone "1" would
        // number a list of one.
        let visible = store.configured.isEmpty ? [store.accounts[0]] : store.configured
        let wanted = Set(visible.map { $0.slot })

        for (slot, item) in statusItems where !wanted.contains(slot) {
            NSStatusBar.system.removeStatusItem(item)
            statusItems[slot] = nil
        }

        for account in visible where statusItems[account.slot] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // Without an autosaveName macOS forgets where the user dragged each
            // icon, and two items would shuffle position on every launch.
            item.autosaveName = "cub-account-\(account.slot)"
            if let button = item.button {
                button.action = #selector(handleClick(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.target = self

                // Force the button to be visible
                button.appearsDisabled = false
                button.isEnabled = true
            }
            statusItems[account.slot] = item
        }

        // The badge appears only with two accounts, so adding or removing one
        // has to restyle the other as well.
        for account in visible { updateIcon(for: account) }
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

// Custom TextView that ensures keyboard commands work
class PasteableNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit dispatches performKeyEquivalent DOWN THE VIEW HIERARCHY, not to
        // the first responder. With one of these in the popover that was
        // harmless — the only instance was also the focused one. With one per
        // account, the first in subview order claimed every Cmd+V and returned
        // true, so the paste landed in account 1's field no matter which field
        // the user had clicked. Acting only when focused restores the mapping.
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
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

struct UsageView: View {
    @ObservedObject var store: AccountsStore
    @ObservedObject var statusManager: StatusManager
    @ObservedObject var updateManager: UpdateManager
    @State private var cookieDrafts: [Int: String] = [:]
    @State private var showingCookieInput: Bool = false
    @State private var showingSettings: Bool = false
    @State private var showingStatusDetails: Bool = false
    @State private var measuredHeight: CGFloat = 250
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance_mode") private var appearanceMode: String = "system"

    private let maxPopupHeight: CGFloat = 600

    /// The pasted-but-not-yet-saved cookie, keyed by slot so one account's
    /// draft can never be written onto the other's key.
    private func binding(for slot: Int) -> Binding<String> {
        Binding(get: { cookieDrafts[slot] ?? "" }, set: { cookieDrafts[slot] = $0 })
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
            // Dark: light scrim over the native material — between fully native
            // (too transparent) and the v1.3.2 0.62 scrim (read as "too dark").
            // TEST VALUE on ClaudeUsageBar only; CodexUsageBar stays fully native.
            // Light: near-opaque backing, or a dark desktop bleeds through as
            // murky blue-gray when forced.
            .background(
                colorScheme == .dark
                    ? Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.3)
                    : Color.white.opacity(0.85)
            )
            .onPreferenceChange(ContentHeightKey.self) { value in
                guard value > 0 else { return }
                measuredHeight = value
            }
            .onAppear {
                store.accounts.forEach { $0.updatePercentages() }
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
                                .foregroundColor(Color.secondaryText)
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
                            .foregroundColor(Color.secondaryText)
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
                                .foregroundColor(Color.secondaryText)
                        }
                        .buttonStyle(.borderless)
                    }
                    Text(update.title)
                        .font(.caption)
                    Text(update.body)
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
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

            // Only show usage if data has been fetched
            if store.configured.isEmpty {
                Text("👋 Welcome! Set your session cookie below to get started.")
                    .font(.subheadline)
                    .foregroundColor(Color.secondaryText)
                    .padding(.vertical, 8)
            }

            ForEach(Array(store.configured.enumerated()), id: \.element.slot) { index, account in
                if index > 0 { Divider() }
                AccountUsageSection(manager: account,
                                    badge: store.showsBadges ? account.slot : nil)
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
                                .foregroundColor(Color.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(statusContextLine(for: statusManager))
                                .font(.system(size: 10))
                                .foregroundColor(Color.secondaryText)
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
                                                .foregroundColor(Color.secondaryText)
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
                                        .foregroundColor(Color.secondaryText)
                                    ForEach(filteredAffected) { c in
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(Color.orange)
                                                .frame(width: 5, height: 5)
                                            Text(c.name).font(.caption2)
                                            Spacer()
                                            Text(componentLabel(c.status))
                                                .font(.caption2)
                                                .foregroundColor(Color.secondaryText)
                                        }
                                    }
                                }
                            }

                            Divider()

                            HStack {
                                if let lastCheck = statusManager.lastUpdated {
                                    Text("Checked \(relativeTime(lastCheck))")
                                        .font(.caption2)
                                        .foregroundColor(Color.secondaryText)
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

            // Gated on `configured`, not on `hasFetchedData`: Refresh is the way
            // out of a failed fetch, so it has to stay reachable exactly when the
            // fetch did not work. Only the label to its left is conditional.
            if !store.configured.isEmpty {
                Divider()
                HStack {
                    if store.configured.contains(where: { $0.isLoading }) {
                        Text("Fetching…")
                            .font(.caption)
                            .foregroundColor(Color.secondaryText)
                    } else if let latest = store.configured
                        .filter({ $0.hasFetchedData })
                        .map({ $0.lastUpdated }).max() {
                        // Only accounts that actually parsed a payload count.
                        // lastUpdated is seeded to Date() at init and moved only on
                        // a successful parse, so an expired cookie or an offline
                        // machine used to render the launch time as though a fetch
                        // had just succeeded — and drift further from the truth the
                        // longer the app stayed open.
                        Text("Last updated: \(formatTime(latest))")
                            .font(.caption)
                            .foregroundColor(Color.secondaryText)
                    }
                    Spacer()
                    Button("Refresh") {
                        store.refreshAll()
                        statusManager.fetch()
                        updateManager.fetch()
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
                    .foregroundColor(Color.secondaryText)

                    ForEach(store.accounts, id: \.slot) { account in
                        VStack(alignment: .leading, spacing: 4) {
                            // displayName, not "Account \(slot)": once the user names
                            // an account, the popover section header says "Work" and
                            // this said "Account 2" — one account labelled two ways
                            // on one screen. Unnamed it still reads "Account N".
                            Text(account.displayName)
                                .font(.caption)
                                .fontWeight(.semibold)

                            TextField("Name (optional)", text: Binding(
                                get: { account.name },
                                set: { account.name = $0; account.saveSettings() }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)

                            if account.hasCookie {
                                Text("Cookie saved ••••\(account.cookieSuffix)")
                                    .font(.caption2)
                                    .foregroundColor(Color.secondaryText)
                                // Two cookies are indistinguishable by eye, so the
                                // address is the only way to tell which claude.ai
                                // account a slot actually holds.
                                if !account.email.isEmpty {
                                    Text(account.email)
                                        .font(.caption2)
                                        .foregroundColor(Color.secondaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }

                            // An account with no cookie renders no section in the
                            // popover, so the error the buttons below can raise
                            // would otherwise have nowhere to appear.
                            if !account.hasCookie, let error = account.errorMessage {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }

                            // The paste field always starts EMPTY. Pre-1.4 seeded it
                            // with a truncated preview of the saved cookie, so saving
                            // without pasting wrote that truncation back as the real
                            // cookie and broke authentication.
                            PasteableTextField(text: binding(for: account.slot),
                                               placeholder: "Paste cookie here...")
                                .frame(height: 50)
                                .cornerRadius(4)

                            HStack(spacing: 8) {
                                Button("Save & Fetch") {
                                    // Trimmed before the guard: a stray space or a
                                    // trailing newline off the clipboard is not a
                                    // cookie, and untrimmed it passed !isEmpty and
                                    // overwrote a working one.
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
                                .controlSize(.small)

                                if account.hasCookie {
                                    Button("Clear") {
                                        account.clearSessionCookie()
                                        cookieDrafts[account.slot] = ""
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.vertical, 4)
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
                    // App-wide preferences. They live on slot 1 only because a
                    // UsageManager is where the UserDefaults handle is; both
                    // accounts read the same keys, so there is no second copy
                    // to keep in step.
                    Toggle(isOn: Binding(
                        get: { store.accounts[0].openAtLogin },
                        set: { newValue in
                            // Register first: on macOS 13+ the getter reports the
                            // real SMAppService state, so the redraw that the
                            // assignment triggers must see it already applied.
                            store.accounts[0].applyLoginItem(newValue)
                            store.accounts[0].openAtLogin = newValue
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open at Login")
                                .font(.caption)
                            Text("Launch app automatically when you log in")
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                        }
                    }
                    .toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { store.accounts[0].usageNotificationsEnabled },
                            set: { newValue in
                                store.accounts[0].usageNotificationsEnabled = newValue
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Usage Notifications")
                                    .font(.caption)
                                Text("Get alerts at 25%, 50%, 75%,\nand 90% session usage")
                                    .font(.caption2)
                                    .foregroundColor(Color.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)

                        Toggle(isOn: Binding(
                            get: { store.accounts[0].statusNotificationsEnabled },
                            set: { newValue in
                                store.accounts[0].statusNotificationsEnabled = newValue
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Status Notifications")
                                    .font(.caption)
                                Text("Get alerts when tracked Claude services have an outage")
                                    .font(.caption2)
                                    .foregroundColor(Color.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)

                        Button("Test Notification") {
                            store.accounts[0].sendTestNotification()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { store.accounts[0].shortcutEnabled },
                            set: { newValue in
                                store.accounts[0].shortcutEnabled = newValue
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
                                    .foregroundColor(Color.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)

                        if store.accounts[0].shortcutEnabled && !store.accounts[0].isAccessibilityEnabled {
                            Button("Grant Accessibility Permission") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Text("Accessibility permission may be needed\nfor the shortcut to work in all apps")
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
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
                            .foregroundColor(Color.secondaryText)
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

                    Divider()

                    // Appearance sits last on purpose: opening Settings auto-scrolls
                    // to the anchor below, so this lands in view.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Appearance")
                            .font(.caption)
                        Picker("Appearance", selection: $appearanceMode) {
                            Text("System").tag("system")
                            Text("Dark").tag("dark")
                            Text("Light").tag("light")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: appearanceMode) { _ in
                            (NSApplication.shared.delegate as? AppDelegate)?.applyAppearancePreference()
                        }
                        Text("Match macOS, or keep the classic dark look")
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
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

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
