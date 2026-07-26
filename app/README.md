# ClaudeUsageBar

> Track your Claude.ai usage right from your Mac menu bar!

A lightweight macOS menu bar app that displays your Claude.ai session and weekly usage limits with real-time updates and notifications.

## ✨ Features

- 🟢 **Real-time Usage Tracking**: Monitor session (5-hour) and weekly (7-day) usage
- ⏱️ **Live Reset Pacing**: See time remaining in the popup and menu bar, plus whether usage is under, on, or over pace
- 🎨 **Color-Coded Menu Bar Icon**: Visual indication of usage levels (green/yellow/red)
- 🔔 **Smart Notifications**: Alerts at 25%, 50%, 75%, and 90% usage thresholds
- ⚡ **Auto-Refresh**: Updates every 5 minutes automatically
- ⌨️ **Keyboard Shortcut**: Toggle popup with Cmd+U from anywhere
- 🔒 **Privacy First**: All data stored locally on your Mac
- 📊 **Pro Plan Support**: Shows weekly Sonnet usage for Pro subscribers
- 🎯 **Menu Bar Only**: No Dock icon, stays out of your way

## 🖼️ Screenshots

**Menu Bar Display:**
- Shows current session percentage with color-coded emoji
- Example: `🟢 45%` (green < 70%, yellow 70-90%, red > 90%)

**Popup Interface:**
- Session (5-hour) usage with a live countdown and elapsed-time marker
- Weekly (7-day) usage with a live countdown and elapsed-time marker
- Weekly Sonnet usage (Pro plan only)
- Settings for notifications and keyboard shortcuts

## 📋 Requirements

- macOS 12.0 (Monterey) or later
- Apple Silicon (M1/M2/M3) or Intel Mac
- Active Claude.ai account (Free or Pro)

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

When you first launch ClaudeUsageBar, you'll see a welcome message. Follow these steps:

### Getting Your Session Cookie

1. Go to **Settings > Usage** on claude.ai
2. Press **F12** (or Cmd+Option+I on Mac)
3. Go to **Network** tab in DevTools
4. Refresh the page, click the "usage" request
5. Find **'Cookie'** in Request Headers
6. Copy the **full cookie value** (starts with `anthropic-device-id=...`)

### Adding Cookie to App

1. Click **"Set Session Cookie"** in the app
2. Paste your cookie (Cmd+V works!)
3. Click **"Save Cookie & Fetch"**
4. Your usage will appear immediately! 🎉

## ⚙️ Settings

Access settings by clicking the gear icon in the popup:

### Notifications
- Enable/disable usage alerts
- Get notifications at 25%, 50%, 75%, 90% thresholds
- Click "Test Notification" to verify it works

### Keyboard Shortcut (Cmd+U)
- Toggle popup from anywhere on your Mac
- Requires Accessibility permission
- Click "Enable Keyboard Shortcut" to grant permission

### Launch at Login
- Start ClaudeUsageBar automatically when you log in

## 🔒 Privacy & Security

- ✅ **All data stays on your Mac** - stored in UserDefaults only
- ✅ **No analytics or tracking** - zero external services
- ✅ **Session cookies stored locally** - never sent anywhere except claude.ai
- ✅ **No hardcoded credentials** - org ID extracted dynamically from your cookie
- ✅ **Open source** - review the code yourself

## 🎯 How It Works

1. Uses your session cookie to authenticate with claude.ai API
2. Fetches usage data from the same endpoints the website uses
3. Extracts org ID dynamically from your cookie
4. Displays real-time usage in your menu bar
5. Sends notifications when you hit usage thresholds

## 🔨 Building & Distribution

### Build the App
```bash
./build.sh
```

### Run Pace Logic Tests
```bash
swiftc -parse-as-library ResetPace.swift ResetPaceTests.swift -o /tmp/claudeusagebar-reset-pace-tests
/tmp/claudeusagebar-reset-pace-tests
```

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
- Make sure you've pasted your session cookie
- Click "Save Cookie & Fetch"
- Verify you copied the full cookie string

### Cookie expired
- Session cookies expire periodically
- Get a new cookie from claude.ai
- Click "Clear Cookie" then re-add it

### Notifications not working
- Click "Test Notification" in Settings
- Notifications work without permission prompts
- Check macOS Focus mode isn't blocking them

### Cmd+U shortcut not working
- Click "Enable Keyboard Shortcut" in Settings
- Grant Accessibility permission in System Settings
- Restart the app after granting permission

### Usage not updating
- App auto-refreshes every 5 minutes
- Click the refresh button to update manually
- If cookie expired, get a new one

## 📦 Distribution Files

- **ClaudeUsageBar-Installer.dmg** - Drag-to-install DMG (1.6 MB)
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

This app uses claude.ai's internal API endpoints which may change without notice. It is not affiliated with or endorsed by Anthropic. Use at your own risk.

## 🙏 Acknowledgments

Built with:
- SwiftUI for the interface
- AppKit for menu bar integration
- Carbon for global keyboard shortcuts
- NSUserNotification for alerts

---

**Made with ❤️ for the Claude community**
