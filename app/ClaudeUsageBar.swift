import SwiftUI
import AppKit
import Carbon
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

/// Compact choice control with the accent-blue selection of the app's prominent
/// buttons. Native segmented pickers only tint while their window is key, which
/// the popover never is, so they read as flat gray.
struct ChoicePills: View {
    @Binding var selection: String
    let options: [(label: String, tag: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.tag) { option in
                let selected = selection == option.tag
                Button(action: { selection = option.tag }) {
                    Text(option.label)
                        .font(.caption)
                        .fontWeight(selected ? .semibold : .regular)
                        .foregroundColor(selected ? .white : Color.secondaryText)
                        .frame(minWidth: 64)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.15)))
        .fixedSize()
    }
}

/// A banked limit reset the user can trigger (Claude grant or Codex reset credit).
struct ResetGrant: Equatable {
    let title: String
    let count: Int
    let expiresAt: Date?
}

/// Banked resets as a plain line: count on the left, expiry aligned right.
struct ResetRow: View {
    let title: String
    let detail: String?
    let help: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let detail = detail {
                Text(detail)
            }
        }
        .font(.caption)
        .foregroundColor(Color.secondaryText)
        .help(help)
    }
}

// Where usage "should" sit right now, given how far into the reset window we
// are. Built by the view layer from a Pace; the two fields travel together so a
// tick can never be drawn without the tooltip explaining it.
struct PaceMarker {
    let expected: Double   // 0...1
    let tooltip: String
}

// Deterministic usage bar: the native linear ProgressView ignores .tint() in
// light (aqua) and vibrant rendering and falls back to accent blue.
struct UsageBar: View {
    let value: Double
    let color: Color
    var pace: PaceMarker? = nil
    var height: CGFloat = 6

    @State private var isHovering = false

    private let tickWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                // Pace tick. Neutral rather than coloured so it stays legible over
                // both the saturated fill and the faint track, in either
                // appearance, without competing with the green/orange/red.
                if let pace = pace {
                    Rectangle()
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: tickWidth)
                        .offset(x: max(0, min(1, pace.expected)) * geo.size.width - tickWidth / 2)
                }
            }
            // Trims a tick near either end against the rounded cap instead of
            // letting it poke out past the bar.
            .clipShape(Capsule())
            // Drawn after the clip so the bubble isn't trimmed to the capsule, and
            // anchored to the bar's leading edge rather than centred on the tick:
            // the popup is only 360pt wide, so a bubble that tracks the tick runs
            // off the right-hand side.
            .overlay(alignment: .topLeading) {
                if let pace = pace, isHovering {
                    PaceTooltip(text: pace.tooltip)
                        .offset(y: -24)
                }
            }
        }
        .frame(height: height)
        // Hover, not .help(): the popover is never the key window (nothing calls
        // NSApp.activate) and AppKit tooltips don't fire in an inactive one — the
        // same reason PasteableNSTextView implements Cmd-V by hand. Tracked on the
        // whole bar, since a 1.5pt tick is nothing to aim at.
        .onHover { isHovering = $0 }
    }
}

// Tooltip bubble for the pace marker.
//
// Solid backing rather than a material: over the popover's own translucent
// backing a material reads as muddy. Sized to its text, which is safe because
// the string is bounded — at its longest, "On pace: 100% by now · 6d 23h in"
// still sits comfortably inside the bar.
struct PaceTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundColor(Color.primary)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .allowsHitTesting(false)
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

        // Initialize managers
        usageManager = UsageManager(statusItem: statusItem, delegate: self)
        statusManager = StatusManager()
        updateManager = UpdateManager()

        // Create popover with dynamic sizing
        popover = NSPopover()
        // Initial guess; SwiftUI's intrinsic size (capped at 600) will drive the actual size.
        popover.contentSize = NSSize(width: 380, height: 320)
        popover.behavior = .transient
        popover.animates = false  // Disable animation for consistent positioning
        popover.contentViewController = NSHostingController(rootView: makeUsageView())

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

        // Listen for chart style changes to reposition popover
        NotificationCenter.default.addObserver(self, selector: #selector(handleChartStyleChanged), name: NSNotification.Name("ChartStyleChanged"), object: nil)

        // Set up Cmd+U keyboard shortcut
        setupKeyboardShortcut()
    }

    func makeUsageView() -> UsageView {
        UsageView(
            usageManager: usageManager,
            statusManager: statusManager,
            updateManager: updateManager
        )
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
        popover.appearance = NSApp.appearance
        updatePopoverSize()
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
            let hostingController = NSHostingController(rootView: makeUsageView())
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
        // Width depends on chart style and account count; height is driven by
        // UsageView's measured content (capped at 600), so keep the current one.
        let width = UsageView.popoverWidth(chartStyle: usageManager.chartStyle,
                                           accountCount: usageManager.accounts.count)
        popover.contentSize = NSSize(width: width, height: popover.contentSize.height)
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
    var weeklyFableUsage: Int = 0
    var weeklyFableLimit: Int = 100
    var weeklyFableResetsAt: Date?
    var hasWeeklyFable: Bool = false
    // Extra usage spend (from /overage_spend_limit). Shown only when there's spend.
    var extraSpentMinor: Int = 0
    var extraLimitMinor: Int = 0
    var extraResetsAt: Date?
    var freeCreditsMinor: Int = 0     // remaining free/promo credits (/prepaid/credits)
    var creditCurrency: String = "USD"
    var hasCreditUsage: Bool = false
    // Banked usage-limit resets the user can trigger on claude.ai (read-only here).
    var limitResetGrants: [ResetGrant] = []
    // Dollar allowance claude.ai calls `iguana_necktie`; limit 0 when absent.
    var sessionCreditsUsed: Double = 0
    var sessionCreditsLimit: Double = 0
    var sessionCreditsResetsAt: Date?
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

    var weeklyFablePercentage: Double {
        weeklyFableLimit > 0 ? Double(weeklyFableUsage) / Double(weeklyFableLimit) : 0
    }

    // Fable is only surfaced once usage is above 1% (hidden while idle).
    var showsWeeklyFable: Bool {
        hasWeeklyFable && hasFetchedData && weeklyFableUsage >= 1
    }

    var limitResetsLeft: Int {
        limitResetGrants.reduce(0) { $0 + $1.count }
    }

    var hasSessionCredits: Bool {
        sessionCreditsLimit > 0 && sessionCreditsUsed >= 0.01
    }

    var hasExtraUsage: Bool {
        hasCreditUsage || freeCreditsMinor > 0
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
    @Published var weeklyFableUsage: Int = 0
    @Published var weeklyFableLimit: Int = 100
    // Extra usage spend (from /overage_spend_limit). Shown only when there's spend.
    @Published var extraSpentMinor: Int = 0
    @Published var extraLimitMinor: Int = 0
    @Published var extraResetsAt: Date?
    @Published var freeCreditsMinor: Int = 0   // remaining free/promo credits (/prepaid/credits)
    // Banked usage-limit resets the user can trigger on claude.ai (e.g. the Opus 5.5
    // launch grant). Read-only here: using one is a POST on /reset_rate_limits.
    @Published var limitResetsLeft: Int = 0
    @Published var limitResetGrants: [ResetGrant] = []
    @Published var creditCurrency: String = "USD"
    @Published var hasCreditUsage: Bool = false
    // Dollar allowance claude.ai calls `iguana_necktie` (e.g. $250, renews monthly).
    // nil when the account doesn't have it: the row is hidden entirely.
    @Published var sessionCreditsUsed: Double = 0
    @Published var sessionCreditsLimit: Double = 0
    @Published var sessionCreditsResetsAt: Date?
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
    @Published var paceMarkerEnabled: Bool = false

    // Reset times as "in 3h 15m" vs a date/time (Settings > Reset times).
    var showTimeRemaining: Bool {
        (UserDefaults.standard.string(forKey: "reset_time_style") ?? "countdown") == "countdown"
    }

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
        // Carry the old "Show Time Remaining" toggle over to Settings > Reset times.
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "reset_time_style") == nil,
           defaults.object(forKey: "show_time_remaining") != nil {
            defaults.set(defaults.bool(forKey: "show_time_remaining") ? "countdown" : "date",
                         forKey: "reset_time_style")
        }

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
            weeklyFableUsage = first.weeklyFableUsage
            weeklyFableResetsAt = first.weeklyFableResetsAt
            hasWeeklyFable = first.hasWeeklyFable
            extraSpentMinor = first.extraSpentMinor
            extraLimitMinor = first.extraLimitMinor
            extraResetsAt = first.extraResetsAt
            freeCreditsMinor = first.freeCreditsMinor
            creditCurrency = first.creditCurrency
            hasCreditUsage = first.hasCreditUsage
            limitResetGrants = first.limitResetGrants
            limitResetsLeft = first.limitResetsLeft
            sessionCreditsUsed = first.sessionCreditsUsed
            sessionCreditsLimit = first.sessionCreditsLimit
            sessionCreditsResetsAt = first.sessionCreditsResetsAt
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
        // Off unless switched on: an upgrade shouldn't change how the bars look
        // without being asked. bool(forKey:) already returns false when unset.
        paceMarkerEnabled = UserDefaults.standard.bool(forKey: "pace_marker_enabled")
    }

    func saveSettings() {
        UserDefaults.standard.set(usageNotificationsEnabled,  forKey: "usage_notifications_enabled")
        UserDefaults.standard.set(statusNotificationsEnabled, forKey: "status_notifications_enabled")
        UserDefaults.standard.set(openAtLogin, forKey: "open_at_login")
        UserDefaults.standard.set(shortcutEnabled, forKey: "shortcut_enabled")
        UserDefaults.standard.set(paceMarkerEnabled, forKey: "pace_marker_enabled")
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
        weeklyFableUsage = 0
        sessionResetsAt = nil
        weeklyResetsAt = nil
        weeklySonnetResetsAt = nil
        weeklyFableResetsAt = nil
        extraSpentMinor = 0
        extraLimitMinor = 0
        extraResetsAt = nil
        freeCreditsMinor = 0
        limitResetsLeft = 0
        limitResetGrants = []
        sessionCreditsLimit = 0
        sessionCreditsUsed = 0
        sessionCreditsResetsAt = nil
        hasCreditUsage = false
        hasFetchedData = false
        hasWeeklySonnet = false
        hasWeeklyFable = false
        errorMessage = nil
        lastNotifiedThreshold = 0
        UserDefaults.standard.set(0, forKey: "last_notified_threshold")

        // Update status bar to show 0%
        delegate?.updateStatusIcon(percentage: 0)

        NSLog("ClaudeUsage: All data cleared")
    }

    // MARK: - Multi-Account Fetching

    /// GET request against claude.ai carrying the headers its web client sends.
    static func claudeRequest(_ url: URL, cookie: String) -> URLRequest {
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
        return request
    }

    static func parseISODate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
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
            self.fetchExtrasForAccount(orgId: orgId, cookie: cookie, accountId: accountId)
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

        let request = Self.claudeRequest(url, cookie: cookie)

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

    /// Fills `account` from a claude.ai `/usage` response.
    static func applyUsageJSON(_ json: [String: Any], to account: inout ClaudeAccount) {
        if let fiveHour = json["five_hour"] as? [String: Any] {
            if let sessionUtil = fiveHour["utilization"] as? Double {
                account.sessionUsage = Int(sessionUtil)
                account.sessionLimit = 100
            }
            if let resetsAt = parseISODate(fiveHour["resets_at"]) {
                account.sessionResetsAt = resetsAt
            }
        }

        if let credits = json["iguana_necktie"] as? [String: Any],
           let limit = (credits["limit_dollars"] as? NSNumber)?.doubleValue, limit > 0 {
            account.sessionCreditsLimit = limit
            account.sessionCreditsUsed = (credits["used_dollars"] as? NSNumber)?.doubleValue ?? 0
            account.sessionCreditsResetsAt = parseISODate(credits["resets_at"])
        } else {
            account.sessionCreditsLimit = 0
            account.sessionCreditsUsed = 0
            account.sessionCreditsResetsAt = nil
        }

        if let sevenDay = json["seven_day"] as? [String: Any] {
            if let weeklyUtil = sevenDay["utilization"] as? Double {
                account.weeklyUsage = Int(weeklyUtil)
                account.weeklyLimit = 100
            }
            if let resetsAt = parseISODate(sevenDay["resets_at"]) {
                account.weeklyResetsAt = resetsAt
            }
        }

        // Check for seven_day_sonnet (Pro plan feature)
        if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
            account.hasWeeklySonnet = true
            if let sonnetUtil = sevenDaySonnet["utilization"] as? Double {
                account.weeklySonnetUsage = Int(sonnetUtil)
                account.weeklySonnetLimit = 100
            }
            if let resetsAt = parseISODate(sevenDaySonnet["resets_at"]) {
                account.weeklySonnetResetsAt = resetsAt
            }
        } else {
            account.hasWeeklySonnet = false
        }

        // Fable is a new, separately-counted model. It isn't a top-level
        // key like seven_day_sonnet — it lives in the `limits` array as a
        // model-scoped weekly limit (scope.model.display_name == "Fable").
        // The bar is only surfaced in the UI when usage is above 1%.
        account.hasWeeklyFable = false
        if let limits = json["limits"] as? [[String: Any]] {
            let fableLimit = limits.first { entry in
                let scope = entry["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                return (model?["display_name"] as? String) == "Fable"
            }
            if let fable = fableLimit {
                account.hasWeeklyFable = true
                // `percent` may decode as Int or Double depending on payload.
                if let p = fable["percent"] as? Int {
                    account.weeklyFableUsage = p
                } else if let p = fable["percent"] as? Double {
                    account.weeklyFableUsage = Int(p)
                }
                account.weeklyFableLimit = 100
                if let resetsAt = parseISODate(fable["resets_at"]) {
                    account.weeklyFableResetsAt = resetsAt
                }
            }
        }
    }

    func parseUsageDataForAccount(_ data: Data, accountId: UUID) {
        guard let idx = accountIndex(for: accountId) else { return }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            NSLog("❌ Parse error for account \(accountId)")
            accounts[idx].errorMessage = "Invalid JSON"
            return
        }

        NSLog("📊 Parsing usage data for account \(accountId)...")

        Self.applyUsageJSON(json, to: &accounts[idx])
        accounts[idx].hasFetchedData = true
        accounts[idx].errorMessage = nil

        let a = accounts[idx]
        NSLog("✅ Account \(accountId): Session \(a.sessionUsage)%, Weekly \(a.weeklyUsage)%\(a.hasWeeklySonnet ? ", Weekly Sonnet \(a.weeklySonnetUsage)%" : "")\(a.hasWeeklyFable ? ", Weekly Fable \(a.weeklyFableUsage)%" : "")")

        // Check notifications for this account
        checkNotificationThresholdsForAccount(id: accountId)
    }

    // MARK: - Extra usage, free credits and limit resets (per account)

    // Each lives on its own endpoint; failures are silent (the rows just stay hidden).
    func fetchExtrasForAccount(orgId: String, cookie: String, accountId: UUID) {
        let base = "https://claude.ai/api/organizations/\(orgId)"
        // Extra usage spend + monthly limit live on a separate endpoint (not /usage).
        fetchAccountJSON("\(base)/overage_spend_limit", cookie: cookie, accountId: accountId) { account, json in
            Self.applyExtraUsageJSON(json, to: &account)
            NSLog("💳 Extra usage: \(account.extraSpentMinor)/\(account.extraLimitMinor) \(account.creditCurrency)")
        }
        // Remaining free/promo credits (balance).
        fetchAccountJSON("\(base)/prepaid/credits", cookie: cookie, accountId: accountId) { account, json in
            Self.applyFreeCreditsJSON(json, to: &account)
            NSLog("🎁 Free credits left: \(account.freeCreditsMinor) \(account.creditCurrency)")
        }
        // Usage-limit resets the account can still use. claude.ai's Settings > Usage reads
        // the same `cedar_ember` object from /usage with `cedar_ember=1`; we only GET it.
        fetchAccountJSON("\(base)/usage?cedar_ember=1&skip_spend=1", cookie: cookie, accountId: accountId) { account, json in
            account.limitResetGrants = Self.parseLimitResets(json["cedar_ember"])
            NSLog("🔄 Limit resets available: \(account.limitResetsLeft)")
        }
    }

    private func fetchAccountJSON(_ urlString: String, cookie: String, accountId: UUID,
                                  apply: @escaping (inout ClaudeAccount, [String: Any]) -> Void) {
        guard let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: Self.claudeRequest(url, cookie: cookie)) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self = self,
                      let idx = self.accountIndex(for: accountId),
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                apply(&self.accounts[idx], json)
                if idx == 0 { self.syncLegacyProperties() }
            }
        }.resume()
    }

    static func applyExtraUsageJSON(_ json: [String: Any], to account: inout ClaudeAccount) {
        let spent = (json["used_credits"] as? Int) ?? 0
        account.extraSpentMinor = spent
        account.extraLimitMinor = (json["monthly_credit_limit"] as? Int) ?? 0
        account.creditCurrency = (json["currency"] as? String) ?? "USD"
        if let resetsAt = parseISODate(json["disabled_until"]) {
            account.extraResetsAt = resetsAt
        }
        account.hasCreditUsage = spent > 0
    }

    static func applyFreeCreditsJSON(_ json: [String: Any], to account: inout ClaudeAccount) {
        // `amount` is the current balance; fall back to summing remaining tranches.
        if let amount = json["amount"] as? Int {
            account.freeCreditsMinor = amount
        } else {
            var remaining = 0
            for key in ["tranches", "promo_tranches"] {
                if let arr = json[key] as? [[String: Any]] {
                    for t in arr { remaining += (t["remaining_amount_minor_units"] as? Int) ?? 0 }
                }
            }
            account.freeCreditsMinor = remaining
        }
        if let cur = json["currency"] as? String { account.creditCurrency = cur }
    }

    /// Grants with resets still usable (not paused, inside their window).
    static func parseLimitResets(_ raw: Any?, now: Date = Date()) -> [ResetGrant] {
        guard let obj = raw as? [String: Any],
              (obj["eligible"] as? Bool) == true,
              let grants = obj["grants"] as? [[String: Any]] else { return [] }
        var out: [ResetGrant] = []
        for g in grants {
            let left = (g["resets_left"] as? Int) ?? 0
            guard left > 0, (g["paused"] as? Bool) != true,
                  let end = parseISODate(g["ends_at"]), end > now else { continue }
            if let start = parseISODate(g["starts_at"]), start > now { continue }
            out.append(ResetGrant(title: (g["label"] as? String) ?? "Usage-limit reset", count: left, expiresAt: end))
        }
        return out
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

        let request = Self.claudeRequest(url, cookie: sessionCookie)

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
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            errorMessage = "Invalid JSON"
            return
        }

        var parsed = ClaudeAccount(name: "", sessionCookie: sessionCookie)
        Self.applyUsageJSON(json, to: &parsed)
        sessionUsage = parsed.sessionUsage
        sessionResetsAt = parsed.sessionResetsAt
        weeklyUsage = parsed.weeklyUsage
        weeklyResetsAt = parsed.weeklyResetsAt
        hasWeeklySonnet = parsed.hasWeeklySonnet
        weeklySonnetUsage = parsed.weeklySonnetUsage
        weeklySonnetResetsAt = parsed.weeklySonnetResetsAt
        hasWeeklyFable = parsed.hasWeeklyFable
        weeklyFableUsage = parsed.weeklyFableUsage
        weeklyFableResetsAt = parsed.weeklyFableResetsAt
        sessionCreditsUsed = parsed.sessionCreditsUsed
        sessionCreditsLimit = parsed.sessionCreditsLimit
        sessionCreditsResetsAt = parsed.sessionCreditsResetsAt

        lastUpdated = Date()
        errorMessage = nil
        hasFetchedData = true
        updatePercentages()
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
        guard usageNotificationsEnabled else { return }
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
        NSLog("🔔 Checking notifications: percentage=\(percentage)%, enabled=\(usageNotificationsEnabled), lastNotified=\(lastNotifiedThreshold)%")

        guard usageNotificationsEnabled else {
            NSLog("⚠️ Usage notifications disabled")
            return
        }

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
    @Published var weeklyFablePercentage: Double = 0.0

    func updatePercentages() {
        sessionPercentage = sessionLimit > 0 ? Double(sessionUsage) / Double(sessionLimit) : 0
        weeklyPercentage = weeklyLimit > 0 ? Double(weeklyUsage) / Double(weeklyLimit) : 0
        weeklySonnetPercentage = weeklySonnetLimit > 0 ? Double(weeklySonnetUsage) / Double(weeklySonnetLimit) : 0
        weeklyFablePercentage = weeklyFableLimit > 0 ? Double(weeklyFableUsage) / Double(weeklyFableLimit) : 0
    }
}

// MARK: - Pace

// Fixed window lengths per limit type. Flat seconds, not calendar units:
// resets_at is an absolute server timestamp, so subtracting 7*24h stays correct
// across a DST boundary where a calendar "7 days" would land an hour off.
enum PaceWindow {
    static let session: TimeInterval = 5 * 3600
    static let weekly: TimeInterval = 7 * 24 * 3600
}

struct Pace {
    let expected: Double      // 0...1 — where the fill "should" be by now
    let elapsed: TimeInterval

    // The API reports only resets_at, never the window start — but since the
    // window length is fixed by limit type, the start is derived exactly rather
    // than estimated.
    //
    // Fails whenever there's nothing honest to draw: no data yet, the reset is
    // already due (stale fetch — a marker pinned at 100% would assert something
    // false), or the clock sits before the window even opened.
    init?(resetsAt: Date?, window: TimeInterval, now: Date = Date()) {
        guard let resetsAt = resetsAt, window > 0, now < resetsAt else { return nil }
        let elapsed = now.timeIntervalSince(resetsAt.addingTimeInterval(-window))
        guard elapsed >= 0 else { return nil }
        self.expected = min(1, max(0, elapsed / window))
        self.elapsed = elapsed
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
                // First-seen times decide which banner wins when both are live.
                let d = UserDefaults.standard
                let now = Date().timeIntervalSince1970
                if let update = updatePayload, self.isNewer(remote: update.version, than: self.currentVersion),
                   d.string(forKey: "update_seen_version") != update.version {
                    d.set(update.version, forKey: "update_seen_version")
                    d.set(now, forKey: "update_seen_at")
                }
                if let ann = announcementPayload, d.string(forKey: "message_seen_id") != ann.id {
                    d.set(ann.id, forKey: "message_seen_id")
                    d.set(now, forKey: "message_seen_at")
                }

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

    enum Banner { case none, message, update }

    /// When a message card and an update banner are both live, the popover shows the
    /// one published last (first seen most recently), so a newer update or message
    /// replaces an older card even if it was never closed. Ties go to the update.
    static func pickBanner(hasMessage: Bool, hasUpdate: Bool,
                           messageSeenAt: Double, updateSeenAt: Double) -> Banner {
        switch (hasMessage, hasUpdate) {
        case (false, false): return .none
        case (true, false): return .message
        case (false, true): return .update
        case (true, true): return updateSeenAt >= messageSeenAt ? .update : .message
        }
    }

    var visibleBanner: Banner {
        let d = UserDefaults.standard
        return Self.pickBanner(hasMessage: announcement != nil,
                               hasUpdate: available != nil && !isCurrentDismissed,
                               messageSeenAt: d.double(forKey: "message_seen_at"),
                               updateSeenAt: d.double(forKey: "update_seen_at"))
    }

    func dismissCurrent() {
        // Dismiss the banner on screen; the other one, if any, shows next.
        if visibleBanner == .message, let id = announcement?.id {
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

// MARK: - Pace Marker

// nil whenever no honest marker can be drawn: the setting is off, or the
// window data can't support one (see Pace.init).
//
// The row label already names the window ("Weekly (7 day)"), so the tooltip
// doesn't repeat it — a longer string overflows the popup.
func paceMarker(enabled: Bool, resetsAt: Date?, window: TimeInterval?, now: Date = Date()) -> PaceMarker? {
    guard enabled, let window = window,
          let pace = Pace(resetsAt: resetsAt, window: window, now: now) else { return nil }
    let percent = Int((pace.expected * 100).rounded())
    return PaceMarker(
        expected: pace.expected,
        tooltip: "On pace: \(percent)% by now · \(formatElapsed(pace.elapsed)) in"
    )
}

func formatElapsed(_ interval: TimeInterval) -> String {
    let totalMinutes = max(0, Int(interval / 60))
    let days = totalMinutes / 1440
    let hours = (totalMinutes % 1440) / 60
    let minutes = totalMinutes % 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

// MARK: - Chart Style Views

/// Shared display options for the chart views.
struct ChartOptions {
    let colorMode: ColorMode
    let showRemaining: Bool
    let paceEnabled: Bool
    let now: Date

    init(usageManager: UsageManager, now: Date) {
        self.colorMode = usageManager.colorMode
        self.showRemaining = usageManager.showTimeRemaining
        self.paceEnabled = usageManager.paceMarkerEnabled
        self.now = now
    }

    func barColor(percentage: Double, accountColor: Color) -> Color {
        switch colorMode {
        case .byUsageLevel:
            return colorForUsage(percentage: percentage)
        case .byAccount:
            return accountColor
        case .hybrid:
            return percentage > 0.9 ? .red : accountColor
        }
    }

    func pace(resetsAt: Date?, window: TimeInterval?) -> PaceMarker? {
        paceMarker(enabled: paceEnabled, resetsAt: resetsAt, window: window, now: now)
    }

    func resetText(_ date: Date, includeDate: Bool) -> String {
        formatResetTimeCompact(date, includeDate: includeDate, showRemaining: showRemaining, now: now)
    }
}

/// One usage metric (session, weekly, per-model weekly) as rendered by the charts.
struct UsageMetric {
    let label: String
    let title: String
    let includeDate: Bool
    let paceWindow: TimeInterval?
    let getValue: (ClaudeAccount) -> Double?
    let getResetTime: (ClaudeAccount) -> Date?

    /// Metrics to show for these accounts: per-model rows only when an account has them.
    static func metrics(for accounts: [ClaudeAccount]) -> [UsageMetric] {
        var out: [UsageMetric] = [
            UsageMetric(label: "Session", title: "Session (5 hour)", includeDate: false,
                        paceWindow: PaceWindow.session,
                        getValue: { $0.sessionPercentage }, getResetTime: { $0.sessionResetsAt }),
            UsageMetric(label: "Weekly", title: "Weekly (7 day)", includeDate: true,
                        paceWindow: PaceWindow.weekly,
                        getValue: { $0.weeklyPercentage }, getResetTime: { $0.weeklyResetsAt }),
        ]
        if accounts.contains(where: { $0.hasWeeklySonnet }) {
            out.append(UsageMetric(label: "Sonnet", title: "Weekly Sonnet", includeDate: true,
                                   paceWindow: PaceWindow.weekly,
                                   getValue: { $0.hasWeeklySonnet ? $0.weeklySonnetPercentage : nil },
                                   getResetTime: { $0.weeklySonnetResetsAt }))
        }
        // Fable is only surfaced once usage is above 1%.
        if accounts.contains(where: { $0.showsWeeklyFable }) {
            out.append(UsageMetric(label: "Fable", title: "Weekly Fable", includeDate: true,
                                   paceWindow: PaceWindow.weekly,
                                   getValue: { $0.hasWeeklyFable ? $0.weeklyFablePercentage : nil },
                                   getResetTime: { $0.weeklyFableResetsAt }))
        }
        return out
    }
}

struct UltraCompactChartView: View {
    @ObservedObject var usageManager: UsageManager
    let options: ChartOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(UsageMetric.metrics(for: usageManager.accounts), id: \.label) { metric in
                MetricRow(metric: metric, accounts: usageManager.accounts, options: options)
            }
        }
    }
}

struct MetricRow: View {
    let metric: UsageMetric
    let accounts: [ClaudeAccount]
    let options: ChartOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metric.label)
                    .font(.subheadline)
                    .frame(width: 55, alignment: .leading)

                // Side-by-side bars
                HStack(spacing: 4) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if let value = metric.getValue(account) {
                            CompactBar(
                                percentage: value,
                                color: options.barColor(percentage: value, accountColor: accountColor(index)),
                                pace: options.pace(resetsAt: metric.getResetTime(account), window: metric.paceWindow)
                            )
                        } else {
                            // N/A indicator
                            Text("n/a")
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                // Percentages
                HStack(spacing: 4) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if let value = metric.getValue(account) {
                            Text("\(Int(value * 100))%")
                                .font(.caption)
                                .foregroundColor(Color.secondaryText)
                                .frame(width: 30)
                        }
                    }
                }
            }

            // Reset times for all accounts
            HStack(spacing: 8) {
                Text("Resets")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
                ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                    if let resetTime = metric.getResetTime(account) {
                        Text(options.resetText(resetTime, includeDate: metric.includeDate))
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                        if index < accounts.count - 1 {
                            Text("/")
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                        }
                    }
                }
            }
        }
    }

    func accountColor(_ index: Int) -> Color {
        index < accounts.count ? accounts[index].displayColor : defaultAccountColors[index % defaultAccountColors.count]
    }
}

struct CompactBar: View {
    let percentage: Double
    let color: Color
    var pace: PaceMarker? = nil

    var body: some View {
        UsageBar(value: percentage, color: color, pace: pace, height: 8)
    }
}

// Reusable colored progress bar (replaces ProgressView which doesn't tint reliably on macOS)
struct ColoredProgressBar: View {
    let value: Double
    let color: Color
    var pace: PaceMarker? = nil

    var body: some View {
        UsageBar(value: value, color: color, pace: pace, height: 4)
    }
}

struct StackedVerticalChartView: View {
    @ObservedObject var usageManager: UsageManager
    let options: ChartOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(UsageMetric.metrics(for: usageManager.accounts), id: \.label) { metric in
                MetricSection(metric: metric, accounts: usageManager.accounts, options: options)
            }
        }
    }
}

struct MetricSection: View {
    let metric: UsageMetric
    let accounts: [ClaudeAccount]
    let options: ChartOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(metric.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                // Show reset times for all accounts
                HStack(spacing: 4) {
                    Text("Resets")
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if let resetTime = metric.getResetTime(account) {
                            Text(options.resetText(resetTime, includeDate: metric.includeDate))
                                .font(.caption)
                                .foregroundColor(Color.secondaryText)
                            if index < accounts.count - 1 {
                                Text("/")
                                    .font(.caption)
                                    .foregroundColor(Color.secondaryText)
                            }
                        }
                    }
                }
            }

            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                if let value = metric.getValue(account) {
                    HStack(spacing: 8) {
                        UsageBar(
                            value: value,
                            color: options.barColor(percentage: value, accountColor: accountColor(index)),
                            pace: options.pace(resetsAt: metric.getResetTime(account), window: metric.paceWindow)
                        )

                        Text("\(account.name) \(Int(value * 100))%")
                            .font(.caption)
                            .foregroundColor(Color.secondaryText)
                            .frame(minWidth: 80, alignment: .trailing)
                    }
                } else {
                    HStack {
                        Text("\(account.name)")
                            .font(.caption)
                            .foregroundColor(Color.secondaryText)
                        Spacer()
                        Text("n/a")
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                    }
                }
            }
        }
    }

    func accountColor(_ index: Int) -> Color {
        index < accounts.count ? accounts[index].displayColor : defaultAccountColors[index % defaultAccountColors.count]
    }
}

struct SeparateCardsView: View {
    @ObservedObject var usageManager: UsageManager
    let options: ChartOptions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(usageManager.accounts.enumerated()), id: \.element.id) { index, account in
                AccountCard(account: account, index: index, options: options)
            }
        }
    }
}

struct AccountCard: View {
    let account: ClaudeAccount
    let index: Int
    let options: ChartOptions

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
                ForEach(UsageMetric.metrics(for: [account]), id: \.label) { metric in
                    if let value = metric.getValue(account) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(metric.label)
                                .font(.caption2)
                                .foregroundColor(Color.secondaryText)
                            ColoredProgressBar(
                                value: value,
                                color: options.barColor(percentage: value, accountColor: account.displayColor),
                                pace: options.pace(resetsAt: metric.getResetTime(account), window: metric.paceWindow)
                            )
                            HStack {
                                Text("\(Int(value * 100))%")
                                    .font(.caption2)
                                Spacer()
                                if let resetTime = metric.getResetTime(account) {
                                    Text(options.resetText(resetTime, includeDate: metric.includeDate))
                                        .font(.caption2)
                                        .foregroundColor(Color.secondaryText)
                                }
                            }
                        }
                    }
                }
            } else if account.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Text("No data")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
        .frame(maxWidth: .infinity)
    }
}

func formatResetTimeCompact(_ date: Date, includeDate: Bool, showRemaining: Bool = false, now: Date = Date()) -> String {
    if showRemaining {
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 {
            return "now"
        }
        return "in \(UsageView.countdown(to: date, from: now))"
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

// MARK: - Extra Usage, Credits and Limit Resets (per account)

struct AccountExtrasView: View {
    let account: ClaudeAccount
    let showName: Bool
    let resetTimeStyle: String
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showName && (account.hasSessionCredits || account.hasExtraUsage || account.limitResetsLeft > 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(account.displayColor)
                        .frame(width: 8, height: 8)
                    Text(account.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
            }

            // Claude session credits: shown from the first cent used; hidden while
            // untouched or when the account has no allowance.
            if account.hasSessionCredits {
                let used = account.sessionCreditsUsed
                let limit = account.sessionCreditsLimit
                let left = max(0, limit - used)
                let money: (Double) -> String = { v in
                    v == v.rounded() ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Claude session credits")
                            .font(.subheadline)
                        Spacer()
                        if let resetTime = account.sessionCreditsResetsAt {
                            Text(resetText(resetTime)).help(resetHelp(resetTime))
                                .font(.caption)
                                .foregroundColor(Color.secondaryText)
                        }
                    }

                    UsageBar(value: used / limit, color: colorForUsage(percentage: used / limit))

                    Text("\(money(left)) of \(money(limit)) left")
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                }
            }

            // Usage credits (pay-as-you-go). Only shown once credits are actually
            // used; links out to manage credits on claude.ai.
            if account.hasExtraUsage {
                let spentMinor = account.extraSpentMinor
                let limitMinor = account.extraLimitMinor
                let pct = limitMinor > 0 ? Double(spentMinor) / Double(limitMinor) : 0
                let pctInt = Int((pct * 100).rounded())
                // Show the exact % up to the limit; once over, just say "over limit".
                let pctLabel = pctInt > 100 ? "over limit" : "\(pctInt)%"
                let currency = account.creditCurrency
                let fmt: (Int) -> String = { minor in
                    let v = Double(minor) / 100.0
                    return currency == "USD"
                        ? String(format: "$%.2f", v)
                        : String(format: "%@ %.2f", currency, v)
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
                    let shortReset: String? = account.extraResetsAt.map { d in
                        let f = DateFormatter(); f.dateFormat = "MMM d"
                        return "Resets \(f.string(from: d))"
                    }

                    // Spend vs monthly limit — only when there's actual spend.
                    if account.hasCreditUsage {
                        if limitMinor > 0 {
                            UsageBar(value: min(pct, 1.0),
                                     color: colorForUsage(percentage: pct))
                        }
                        HStack {
                            Text(limitMinor > 0
                                 ? "\(fmt(spentMinor)) of \(fmt(limitMinor)) · \(pctLabel)"
                                 : "\(fmt(spentMinor)) spent")
                                .font(.caption)
                                .foregroundColor(Color.secondaryText)
                            Spacer()
                            if let r = shortReset {
                                Text(r)
                                    .font(.caption)
                                    .foregroundColor(Color.secondaryText)
                            }
                        }
                    }

                    if account.freeCreditsMinor > 0 {
                        Text("\(fmt(account.freeCreditsMinor)) free credits left")
                            .font(.caption2)
                            .foregroundColor(Color.secondaryText)
                            .opacity(0.85)
                    }
                }
            }

            // Discreet info line: available limit resets when there are any, else
            // "No extra usage" when none is being consumed.
            if account.limitResetsLeft > 0 {
                resetRow(account.limitResetGrants)
            } else if !account.hasExtraUsage {
                Text(showName ? "\(account.name): no extra usage" : "No extra usage")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
                    .opacity(0.6)
            }
        }
    }

    private func timeLeft(_ date: Date) -> String {
        date <= now ? "now" : "in \(UsageView.countdown(to: date, from: now))"
    }

    /// Reset label, as time left or as a date per Settings > Reset times.
    func resetText(_ date: Date, includeDate: Bool = true) -> String {
        resetTimeStyle == "date" ? "Resets \(formatResetTime(date, includeDate: includeDate))" : "Resets \(timeLeft(date))"
    }

    /// The other format, on hover.
    func resetHelp(_ date: Date, includeDate: Bool = true) -> String {
        resetTimeStyle == "date" ? "Resets \(timeLeft(date))" : "Resets \(formatResetTime(date, includeDate: includeDate))"
    }

    /// Right side of the reset chip: "Expires in 6d 4h" or "Until Oct 22". With several
    /// resets expiring on different days, the soonest one is what matters ("Next ...").
    func resetsExpiryText(_ grants: [ResetGrant]) -> String? {
        let ends = grants.compactMap { $0.expiresAt }
        guard let first = ends.min() else { return nil }
        let next = Set(ends).count > 1 ? "Next " : ""
        if resetTimeStyle == "date" {
            // Last usable instant: an end at local midnight would read as the next day.
            let f = DateFormatter(); f.dateFormat = "MMM d"
            let day = f.string(from: first.addingTimeInterval(-1))
            return next.isEmpty ? "Until \(day)" : "Next until \(day)"
        }
        return next.isEmpty ? "Expires \(timeLeft(first))" : "Next expires \(timeLeft(first))"
    }

    func resetRow(_ grants: [ResetGrant]) -> some View {
        let n = grants.reduce(0) { $0 + $1.count }
        return ResetRow(title: "\(n) limit reset\(n == 1 ? "" : "s") available",
                         detail: resetsExpiryText(grants),
                         help: resetsHelp(grants))
    }

    func resetsHelp(_ grants: [ResetGrant]) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
        return grants.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }.map { g in
            let count = g.count > 1 ? " (x\(g.count))" : ""
            let when = g.expiresAt.map { "expires \(f.string(from: $0))" } ?? "no expiry"
            return "\(g.title)\(count): \(when)"
        }.joined(separator: "\n")
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
}

// MARK: - Account Management Inline Views

struct AddAccountInlineView: View {
    @ObservedObject var usageManager: UsageManager
    @Binding var isPresented: Bool
    @State private var accountName: String = ""
    @State private var cookieInput: String = ""
    @State private var showInstructions: Bool = false
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add Account")
                    .font(.headline)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color.secondaryText)
                }
                .buttonStyle(.borderless)
            }

            TextField("Account Name (e.g., Personal, Work)", text: $accountName)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
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
                    .foregroundColor(Color.secondaryText)
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
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Add Account") {
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
                .buttonStyle(.borderedProminent)
                .disabled(cookieInput.isEmpty)
            }
        }
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
                        .foregroundColor(Color.secondaryText)
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
    @ObservedObject var statusManager: StatusManager
    @ObservedObject var updateManager: UpdateManager
    @State private var showingSettings: Bool = false
    @State private var showingAddAccount: Bool = false
    @State private var editingAccountId: UUID?
    @State private var showingStatusDetails: Bool = false
    @State private var measuredHeight: CGFloat = 250
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance_mode") private var appearanceMode: String = "system"
    @AppStorage("reset_time_style") private var resetTimeStyle: String = "countdown"
    @State private var now = Date()
    private let minuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

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
            .frame(width: popoverWidth, height: min(max(measuredHeight, 100), maxPopupHeight))
            // Dark: light scrim over the native material. Light: near-opaque
            // backing, or a dark desktop bleeds through as murky blue-gray when forced.
            .background(
                colorScheme == .dark
                    ? Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.3)
                    : Color.white.opacity(0.85)
            )
            .onPreferenceChange(ContentHeightKey.self) { value in
                guard value > 0 else { return }
                measuredHeight = value
            }
            .onReceive(minuteTicker) { now = $0 }
            .onAppear {
                now = Date()
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
        .id(usageManager.refreshTrigger)  // Force complete redraw when triggered
    }

    var content: some View {
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
    }

    var chartOptions: ChartOptions {
        ChartOptions(usageManager: usageManager, now: now)
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

            // Free-form message banner (author-controlled). Takes priority over
            // the version-update banner when both are present.
            if updateManager.visibleBanner == .message, let ann = updateManager.announcement {
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

            // App update banner (version-based). Shares the slot with the message
            // card; the more recently published of the two is shown.
            if updateManager.visibleBanner == .update, let update = updateManager.available {
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

            if let error = usageManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.bottom, 8)
            }

            // Show welcome message or usage charts
            if usageManager.accounts.isEmpty {
                Text("👋 Welcome! Click + to add your first Claude account.")
                    .font(.subheadline)
                    .foregroundColor(Color.secondaryText)
                    .padding(.vertical, 8)
            } else {
                // Multi-account chart views
                switch usageManager.chartStyle {
                case .ultraCompact:
                    UltraCompactChartView(usageManager: usageManager, options: chartOptions)
                case .stackedVertical:
                    StackedVerticalChartView(usageManager: usageManager, options: chartOptions)
                case .separateCards:
                    SeparateCardsView(usageManager: usageManager, options: chartOptions)
                }

                // Extra usage, session credits and limit resets, per account
                ForEach(usageManager.accounts.filter { $0.hasFetchedData }) { account in
                    AccountExtrasView(account: account,
                                      showName: usageManager.accounts.count > 1,
                                      resetTimeStyle: resetTimeStyle,
                                      now: now)
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
            }

            if statusManager.hasFetched {
                Divider()
                statusSection
            }

            if !usageManager.accounts.isEmpty {
                Divider()

                HStack {
                    Text("Updated: \(formatTime(usageManager.lastUpdated))")
                        .font(.caption)
                        .foregroundColor(Color.secondaryText)
                    Spacer()
                    if usageManager.isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Button("Refresh All") {
                            usageManager.fetchUsage()
                            statusManager.fetch()
                            updateManager.fetch()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
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
                settingsSection

                // Anchor for scroll-to-bottom when Settings opens
                Color.clear
                    .frame(height: 1)
                    .id("settings-anchor")
            }
        }
    }

    // Anthropic service status (compact; expandable on issue)
    var statusSection: some View {
        let effective = statusManager.effectiveIndicator
        let filteredIncidents = statusManager.filteredIncidents
        let filteredAffected = statusManager.filteredAffectedComponents
        let hasIssue = effective != "none"
            && (!filteredIncidents.isEmpty || !filteredAffected.isEmpty)

        return VStack(alignment: .leading, spacing: 8) {
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

    var settingsSection: some View {
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
                        .foregroundColor(Color.secondaryText)
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
                            .foregroundColor(Color.secondaryText)
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
                            .foregroundColor(Color.secondaryText)
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

            VStack(alignment: .leading, spacing: 4) {
                Text("Reset times")
                    .font(.caption)
                ChoicePills(selection: $resetTimeStyle,
                            options: [("Time left", "countdown"), ("Date", "date")])
                Text("Show reset times as time left or as a date")
                    .font(.caption2)
                    .foregroundColor(Color.secondaryText)
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
                            .foregroundColor(Color.secondaryText)
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

            Toggle(isOn: Binding(
                get: { usageManager.paceMarkerEnabled },
                set: { newValue in
                    usageManager.paceMarkerEnabled = newValue
                    usageManager.saveSettings()
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Pace Marker")
                        .font(.caption)
                    Text("Mark where usage should be by now, based on how far into the reset window you are")
                        .font(.caption2)
                        .foregroundColor(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            Divider()

            // Appearance sits last on purpose: opening Settings auto-scrolls
            // to the anchor below, so this lands in view.
            VStack(alignment: .leading, spacing: 4) {
                Text("Appearance")
                    .font(.caption)
                ChoicePills(selection: $appearanceMode,
                            options: [("System", "system"), ("Dark", "dark"), ("Light", "light")])
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
    }

    var popoverWidth: CGFloat {
        Self.popoverWidth(chartStyle: usageManager.chartStyle, accountCount: usageManager.accounts.count)
    }

    static func popoverWidth(chartStyle: ChartStyle, accountCount: Int) -> CGFloat {
        switch chartStyle {
        case .ultraCompact:
            return 380
        case .stackedVertical:
            return 360
        case .separateCards:
            return accountCount > 2 ? 420 : 380
        }
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "5d 23h", "3h 12m" or "12m"; minutes round up so it never reads "0m" early.
    static func countdown(to date: Date, from now: Date) -> String {
        let mins = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
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
