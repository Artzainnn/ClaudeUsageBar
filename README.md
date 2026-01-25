# ClaudeUsageBar

> Track your Claude.ai usage right from your Mac menu bar!

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-12.0+-blue.svg)](https://www.apple.com/macos/)

A lightweight, open-source macOS menu bar application that displays your Claude.ai session and weekly usage limits with real-time updates and notifications.

## 📥 Download

**[Download Latest Release](https://github.com/Artzainnn/claudeusagebar/releases)** (DMG Installer)

## 📦 Set Up (1mn)

Go to [claude.ai/settings/usage](https://claude.ai/settings/usage) from browser, open Developer Tools (Cmd+Option+I), go to the Network tab, refresh the page, click the "usage" request, and copy the full "Cookie" value from the Request Headers.

## ✨ Features

- 🟢 **Real-time usage tracking** - Monitor session (5-hour) and weekly (7-day) limits
- 🎨 **Color-coded menu bar icon** - Visual spark icon that changes color (green/yellow/red)
- 🔔 **Smart notifications** - Alerts at 25%, 50%, 75%, 90% usage thresholds
- ⌨️ **Keyboard shortcut** - Toggle popup with Cmd+U from anywhere
- ⚡ **Auto-refresh** - Updates every 5 minutes automatically
- 🔒 **Privacy-first** - All data stored locally on your Mac
- 📊 **Pro plan support** - Shows weekly Sonnet usage for Pro subscribers
- 🎯 **Menu bar only** - No Dock icon, stays out of your way

[See full feature list →](app/README.md)

## 🚀 Quick Start

1. **Download** `ClaudeUsageBar-Installer.dmg` from [Releases](https://github.com/Artzainnn/ClaudeUsageBar/releases)
2. **Open DMG** and drag ClaudeUsageBar to Applications folder
3. **Launch** ClaudeUsageBar from Applications
4. **Set cookie** from claude.ai (follow in-app instructions)
5. **Done!** Usage appears in menu bar

## 📸 Screenshots

**Menu Bar Display:**
```
⚡ 45%  (Green spark icon when usage < 70%)
```

**Popup Interface:**
- Session (5-hour) usage with progress bar
- Weekly (7-day) usage with progress bar
- Weekly Sonnet usage (Pro plan only)
- Settings for notifications and shortcuts

## 📁 Repository Structure

```
app/        - macOS menu bar application (Swift/SwiftUI)
website/    - Landing page (HTML/CSS)
```

## 🛠️ Build from Source

**Requirements:**
- macOS 12.0 (Monterey) or later
- Xcode Command Line Tools

**Build the app:**
```bash
cd app
chmod +x build.sh
./build.sh
```

**Create DMG installer:**
```bash
./create_dmg.sh
```

The built app will be in `app/build/ClaudeUsageBar.app`

## 🔧 Development

### Project Structure

- `app/ClaudeUsageBar.swift` - Main application code
- `app/build.sh` - Build script
- `app/create_dmg.sh` - DMG installer creation
- `website/index.html` - Landing page

### Key Technologies

- **SwiftUI** - Modern macOS UI framework
- **AppKit** - Menu bar integration
- **Carbon** - Global keyboard shortcuts
- **NSUserNotification** - System notifications (no permissions needed)

## 🤝 Contributing

Contributions are welcome! Here's how you can help:

- 🐛 Report bugs via [Issues](https://github.com/Artzainnn/claudeusagebar/issues)
- 💡 Suggest features or improvements
- 🔧 Submit pull requests
- 📖 Improve documentation
- 🌍 Translate the website

## 📄 License

MIT License - see [LICENSE](LICENSE) for details

## ⚠️ Disclaimer

This app uses Claude.ai's internal API endpoints which may change without notice. It is not affiliated with or endorsed by Anthropic. Use at your own risk.

## 🙏 Support

If you find this useful, consider:
- ⭐ Starring this repository
- 📢 Sharing with others who use Claude

## 🔗 Links

- **Website:** [claudeusagebar.com](https://claudeusagebar.com)
- **Issues:** [GitHub Issues](https://github.com/Artzainnn/claudeusagebar/issues)
- **Releases:** [GitHub Releases](https://github.com/Artzainnn/claudeusagebar/releases)

---

**Made with ❤️ for the Claude community**
