# CLAUDE.md

## Project Overview

ClaudeUsageBar is a macOS menu bar application that displays real-time Claude.ai usage metrics (session limits, weekly limits, Pro Sonnet usage). Built with Swift + SwiftUI, privacy-first (all data local via UserDefaults), no external dependencies.

## Repository Structure

```
app/                        # macOS application
  ClaudeUsageBar.swift      # Single-file app (~1138 lines): AppDelegate, UsageManager, UsageView
  Info.plist                # Bundle config (com.claude.usagebar, macOS 12.0+, LSUIElement)
  build.sh                  # Build script → universal binary (arm64 + x86_64)
  create_dmg.sh             # DMG installer creation
website/                    # Landing page & SEO blog (static HTML/CSS/JS)
  index.html                # Main landing page
  blog/                     # SEO blog posts (7 articles)
```

## Build & Run

```bash
cd app
chmod +x build.sh
./build.sh                  # Outputs: build/ClaudeUsageBar.app
```

Build requires macOS with `swiftc`. The script compiles for arm64 and x86_64, creates a universal binary with `lipo`, and code-signs.

## Architecture

**MVVM with ObservableObject pattern**, all in `ClaudeUsageBar.swift`:

- **AppDelegate** (L7-296): Status bar item, popover, global Cmd+U hotkey (Carbon), menu bar icon color coding (green <70%, yellow 70-90%, red >90%)
- **UsageManager** (L298-674): Data fetching from `claude.ai/api/organizations/{orgId}/usage`, cookie management, notification thresholds (25/50/75/90%), auto-refresh every 5 min
- **UsageView** (L809-1137): SwiftUI popover UI — progress bars, cookie input, settings panel
- **CustomTextField / PasteableTextField** (L677-807): NSViewRepresentable bridges for proper clipboard support in popover

## Key Technical Details

- Auth: Session cookie from claude.ai, org ID extracted from `lastActiveOrg` in cookie
- Storage: UserDefaults only (cookies, settings, notification state)
- Network: URLSession → `https://claude.ai/api/organizations/{orgId}/usage`
- Notifications: NSUserNotification at configurable thresholds
- App Transport Security: Allows anthropic.com domain (Info.plist)
- No Dock icon: LSUIElement = true

## Development Notes

- Single Swift file — all app logic lives in `ClaudeUsageBar.swift`
- No Xcode project — compiled directly with `swiftc` via build script
- No test suite currently
- Website is pure static HTML with inline CSS, no build step
- MIT licensed
