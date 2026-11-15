# ClaudeUsageBar

> Track your Claude.ai usage right from your Mac menu bar!

A lightweight macOS menu bar app that displays your Claude.ai session and weekly usage limits with real-time updates and notifications.

## ✨ Features

- 🟢 **Real-time Usage Tracking**: Monitor session (5-hour) and weekly (7-day) usage
- 🔑 **Automatic & Web Authentication**: Detects Claude Code credentials in the macOS Keychain or signs in via the built-in `"Sign in with Claude.ai"` (`WKWebView`) window
- 🎨 **Color-Coded Menu Bar Icon**: Visual indication of usage levels (green/yellow/red)
- 🔔 **Smart Notifications**: Alerts at 25%, 50%, 75%, and 90% usage thresholds
- ⚡ **Auto-Refresh**: Updates every 5 minutes automatically and when your Mac wakes
- ⌨️ **Keyboard Shortcut**: Toggle popup with Cmd+U from anywhere
- 🔒 **Privacy First**: Web cookies and credentials stay in your macOS Keychain
- 📊 **Pro Plan Support**: Shows weekly Sonnet usage for Pro subscribers
- 🎯 **Menu Bar Only**: No Dock icon, stays out of your way

## 🖼️ Screenshots

**Menu Bar Display:**
- Shows current session percentage with color-coded icon
- Example: `⚡ 45%` (green < 70%, yellow 70-90%, red > 90%)

**Popup Interface:**
- Session (5-hour) usage with progress bar and reset time
- Weekly (7-day) usage with progress bar and reset date
- Weekly Sonnet usage (Pro plan only)
- Account & Connection panel and settings

## 📋 Requirements

- macOS 12.0 (Monterey) or later
- Apple Silicon (M1/M2/M3) or Intel Mac
- Active Claude.ai or Claude Code account

## 🚀 Installation

### Option 1: DMG Installer (Recommended)

1. Download `ClaudeUsageBar-Installer.dmg` from [Releases](../../releases)
2. Double-click the DMG file
3. Drag ClaudeUsageBar to the Applications folder
4. Eject the DMG
5. Open ClaudeUsageBar from Applications

### Option 2: ZIP Archive

1. Download `ClaudeUsageBar.zip` from [Releases](../../releases)
2. Extract the ZIP file
3. Drag ClaudeUsageBar.app to Applications folder
4. Open ClaudeUsageBar from Applications

### Option 3: Build from Source

```bash
cd app
chmod +x build.sh
./build.sh
```

The built app will be in `build/ClaudeUsageBar.app`.

## 🔧 First-Time Setup

When you launch ClaudeUsageBar, choose any of the following connection methods:

### Option A: Automatic Claude Code Detection
If you have signed in with Claude Code (`claude` CLI), ClaudeUsageBar detects its macOS Keychain credentials automatically. Click **"Use Claude Code Auth"** (or keep **Automatic** selected in **Account & Connection**).

### Option B: Built-in Web Sign-In (Recommended for Claude.ai)
1. Click **"Sign in with Claude.ai"** in the popup (or under **Account & Connection**).
2. Sign in inside the `"Sign in to Claude"` window (`WKWebView`).
3. Once authenticated, the window closes automatically and stores your session cookie securely in the macOS Keychain.

### Option C: Manual Session Cookie (Advanced)
1. Go to **Settings > Usage** on claude.ai and open DevTools (`Cmd+Option+I`) → **Network** tab.
2. Refresh the page, click the `usage` request, and copy the **`Cookie`** value from Request Headers.
3. Open **Account & Connection** → **Advanced: Paste Cookie Manually**, paste the cookie, and click **"Save Cookie & Fetch"**.

## ⚙️ Settings

Access settings inside the popup:

### Account & Connection
- Switch source between **Automatic**, **Claude Code**, and **Claude.ai**
- Sign in, switch accounts, or disconnect your Claude.ai web session
- Expand **Advanced: Paste Cookie Manually** when needed

### Notifications
- Enable/disable usage alerts
- Get notifications at 25%, 50%, 75%, 90% thresholds
- Click "Test Notification" to verify it works

### Keyboard Shortcut (Cmd+U)
- Toggle popup from anywhere on your Mac
- Requires Accessibility permission
- Click "Grant Accessibility Permission" in Settings

### Launch at Login
- Start ClaudeUsageBar automatically when you log in

## 🔒 Privacy & Security

- ✅ **Keychain storage** - Web session cookies are stored securely in the macOS Keychain (`com.claude.usagebar`), not in plain preferences
- ✅ **No analytics or tracking** - Zero third-party services
- ✅ **Local-only credentials** - Never sent anywhere except `claude.ai` or `api.anthropic.com`
- ✅ **Open source** - Review `ClaudeUsageBar.swift` and `AuthSupport.swift` yourself

## 🎯 How It Works

1. Resolves your preferred connection source (`Automatic`, `Claude Code`, or `Claude.ai Web`)
2. Reads Claude Code OAuth credentials or your Keychain-stored web session cookie
3. Fetches live usage data from `api.anthropic.com` or `claude.ai`
4. Displays real-time usage in your menu bar and sends threshold alerts

## 🔨 Building & Distribution

### Build the App
```bash
./build.sh
```
You can override the signing certificate via `CODESIGN_IDENTITY="..." ./build.sh`.

### Create DMG Installer
```bash
./create_dmg.sh
```

### Clean Build
```bash
rm -rf build
./build.sh
```

## 🐛 Troubleshooting

### "No data yet" showing
- Sign in with **"Sign in with Claude.ai"** or click **"Use Claude Code Auth"**
- If pasting a cookie manually, verify you copied the full cookie string

### Session expired
- Click **"Sign in with Claude.ai"** to refresh your web session, or run `claude` in Terminal if using Claude Code
- Use **Disconnect Claude.ai** under **Account & Connection** to clear stored web cookies

### Notifications not working
- Click "Test Notification" in Settings
- Notifications work without permission prompts
- Check macOS Focus mode isn't blocking them

### Cmd+U shortcut not working
- Enable Keyboard Shortcut in Settings and grant Accessibility permission in System Settings
- Restart the app after granting permission

### Usage not updating
- App auto-refreshes every 5 minutes and on Mac wake
- Click **Refresh** in the popup to update manually

## 📦 Distribution Files

- **ClaudeUsageBar.swift** - Main application code
- **AuthSupport.swift** - Keychain storage, cookie normalization, ISO-8601 parsing, and `WKWebView` sign-in controller
- **ClaudeUsageBar-Installer.dmg** - Drag-to-install DMG
- **README.md** - This file
- **LICENSE** - MIT License

## 🤝 Contributing

This is a personal project, but feel free to:
- Report bugs via Issues
- Suggest features
- Submit pull requests
- Fork and customize for your needs

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details

## ⚠️ Disclaimer

This app uses claude.ai and Claude Code endpoints which may change without notice. It is not affiliated with or endorsed by Anthropic. Use at your own risk.

## 🙏 Acknowledgments

Built with:
- SwiftUI for the interface
- AppKit for menu bar integration
- WebKit for embedded sign-in
- Security for macOS Keychain storage
- Carbon for global keyboard shortcuts
- NSUserNotification for alerts

---

**Made with ❤️ for the Claude community**
