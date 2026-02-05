# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ClaudeUsageBar is a native macOS menu bar application that tracks Claude.ai usage in real-time. Built with Swift/SwiftUI, it displays session (5-hour) and weekly (7-day) usage limits with color-coded indicators and notifications.

## Development Commands

### Building the Application

```bash
# Build universal binary (Apple Silicon + Intel)
cd app
chmod +x build.sh
./build.sh

# Clean build
rm -rf app/build
cd app && ./build.sh

# Create DMG installer for distribution
cd app
./create_dmg.sh
```

### Icon Generation

```bash
# Regenerate app icon from PNG source
cd app
./make_app_icon.sh
```

### Development Workflow

- **Main source**: `app/ClaudeUsageBar.swift` (single 2815-line file)
- **Build output**: `app/build/ClaudeUsageBar.app`
- **Distribution**: `app/build/ClaudeUsageBar-Installer.dmg`

## Architecture Overview

### Monolithic Swift Structure

The entire application is contained in `ClaudeUsageBar.swift` with clear MARK sections:

- **AppDelegate (Lines 7-360)**: Menu bar management, global shortcuts, lifecycle
- **UsageManager (Lines 463+)**: ObservableObject handling API calls, data persistence, multi-account support
- **ClaudeAccount (Lines 389-447)**: Account data model with Codable JSON serialization
- **SwiftUI Views**: Complete UI hierarchy including charts, cards, and settings
- **WebKit Integration**: Embedded login with cookie auto-extraction

### Key Technologies

- **SwiftUI**: Modern UI framework for all interface components
- **AppKit**: Menu bar integration via NSStatusItem and NSPopover
- **WebKit**: Embedded web views for authentication
- **Carbon**: Global keyboard shortcuts (Cmd+U)
- **NSUserNotification**: System notifications without permission requirements

### Multi-Account Architecture

- Maximum 4 accounts supported
- UUID-based account identification
- Independent fetch lifecycle per account
- Automatic migration from legacy single-account format
- JSON persistence to UserDefaults with key `"claude_accounts"`

### Data Persistence

All data stored locally in UserDefaults:
- Account data: JSON-encoded array under `"claude_accounts"`
- Settings: Individual keys (`chart_style`, `color_mode`, `notifications_enabled`, etc.)
- Legacy compatibility: Single account data under `"claude_session_cookie"`

### API Integration

- Endpoint: `https://claude.ai/api/organizations/{orgId}/usage`
- Dynamic organization ID extraction from cookies
- Response structure: `{ "five_hour": {...}, "seven_day": {...}, "seven_day_sonnet": {...} }`
- Cookie-based authentication with automatic expiration handling

## Code Organization Patterns

### View Architecture

Three chart visualization modes:
1. **Ultra-Compact**: Single row per account with all metrics
2. **Stacked Vertical**: Metrics stacked per account
3. **Separate Cards**: Individual card layout per account

### Color Coding System

- **By Usage Level**: Green <70%, Yellow 70-90%, Red >90%
- **By Account**: Each account gets distinct color
- **Hybrid**: Account colors with red override at >90%

### Notification System

- Threshold-based: 25%, 50%, 75%, 90%
- Per-account tracking to prevent duplicate notifications
- Uses deprecated NSUserNotification for no-permission operation

## Development Considerations

### Security Patterns

- HTTPOnly cookies only (no localStorage access)
- HTTPS-only communication (App Transport Security enabled)
- Local-only storage, no external analytics
- Dynamic credential extraction (no hardcoded values)

### Privacy-First Design

- All usage data stored locally in UserDefaults
- Session cookies never sent anywhere except claude.ai
- No tracking, analytics, or external services
- Open source for community verification

### macOS Integration

- **Menu bar only**: LSUIElement=true (no Dock icon)
- **Global shortcuts**: Carbon-based Cmd+U hotkey with Accessibility permissions
- **Multi-monitor support**: Proper popover positioning
- **Keyboard navigation**: Full accessibility support

### Build Configuration

- **Universal binary**: arm64 + x86_64 via lipo
- **Minimum target**: macOS 12.0 (Monterey)
- **Code signing**: Developer ID with ad-hoc fallback
- **Frameworks**: SwiftUI, AppKit, WebKit, Carbon, Foundation

## Testing and Quality

- No automated testing infrastructure currently in place
- Manual testing workflow through build and launch
- Error handling via NSLog (no structured logging framework)
- Memory safety through Swift's built-in protections

## Recent Feature Evolution

### Latest Improvements (Current Branch: feature/webview-login)

- **Embedded WebView login**: Auto-extract cookies without manual DevTools
- **Multi-monitor positioning**: Improved popover placement
- **Enhanced UI layouts**: Better visual hierarchy and spacing

### Multi-Account Support (commit d48378f)

- Migration from single to multi-account architecture
- Account-specific colors and icons
- Independent refresh cycles per account
- Maximum 4 accounts with UUID-based management

## File Structure Notes

- **Single-file app**: All logic in `ClaudeUsageBar.swift` for deployment simplicity
- **Separate website**: `website/` directory contains landing page (HTML/CSS)
- **Build artifacts**: All outputs in `app/build/` (gitignored)
- **Distribution ready**: Scripts handle DMG creation and code signing

## Working with This Codebase

- Always test builds on both Apple Silicon and Intel Macs when possible
- Verify code signing works with your Developer ID or use ad-hoc signing
- Monitor cookie extraction logic when working with authentication features
- Consider UI impact on different screen sizes and orientations when modifying SwiftUI views
- Test notification thresholds to ensure no duplicate alerts
- Verify keyboard shortcut functionality requires Accessibility permissions on macOS