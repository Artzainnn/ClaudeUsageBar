#!/bin/bash

# Build script for ClaudeUsageBar

echo "Building ClaudeUsageBar..."

# Create fresh build directory (delete any stale build to avoid accumulated xattrs
# from prior signs, which can cause "resource fork / detritus" errors on codesign).
rm -rf build
mkdir -p build

# Create app bundle structure first
APP_NAME="ClaudeUsageBar.app"
APP_PATH="build/$APP_NAME"

mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy Info.plist
cp Info.plist "$APP_PATH/Contents/"

# Create icon if it doesn't exist
if [ ! -f "ClaudeUsageBar.icns" ]; then
    echo "Creating app icon..."
    ./make_app_icon.sh >/dev/null 2>&1
fi

# Copy icon to Resources
if [ -f "ClaudeUsageBar.icns" ]; then
    cp ClaudeUsageBar.icns "$APP_PATH/Contents/Resources/"
    # Update Info.plist to reference icon
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string ClaudeUsageBar" "$APP_PATH/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile ClaudeUsageBar" "$APP_PATH/Contents/Info.plist"
fi

# Compile the Swift app for arm64.
# Log.swift, AnthropicUsageFetcher.swift, UsageProvider.swift, and the
# Codex provider files are compiled alongside ClaudeUsageBar.swift; see the
# header comments in those files for why the SwiftPM library boundary is
# drawn where it is. AnthropicUsageStore stays app-only (needs UsageManager);
# the Codex files are also in the SwiftPM library for unit testing.
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    ClaudeUsageBar.swift \
    Log.swift \
    AnthropicUsageFetcher.swift \
    UsageProvider.swift \
    AnthropicUsageStore.swift \
    CodexUsageFetcher.swift \
    CodexUsageStore.swift \
    DeepSeekUsageFetcher.swift \
    DeepSeekUsageStore.swift \
    ZedUsageFetcher.swift \
    ZedUsageStore.swift \
    XAIUsageFetcher.swift \
    XAIUsageStore.swift \
    OpenAIUsageFetcher.swift \
    OpenAIUsageStore.swift \
    PerplexityUsageFetcher.swift \
    PerplexityUsageStore.swift \
    CopilotUsageFetcher.swift \
    CopilotUsageStore.swift \
    FileWatcher.swift \
    SQLiteReader.swift \
    TCCState.swift \
    ClaudeCodePricing.swift \
    ClaudeCodeUsageFetcher.swift \
    ClaudeCodeUsageStore.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    -target arm64-apple-macos12.0

# Compile for x86_64 (Intel)
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64" \
    ClaudeUsageBar.swift \
    Log.swift \
    AnthropicUsageFetcher.swift \
    UsageProvider.swift \
    AnthropicUsageStore.swift \
    CodexUsageFetcher.swift \
    CodexUsageStore.swift \
    DeepSeekUsageFetcher.swift \
    DeepSeekUsageStore.swift \
    ZedUsageFetcher.swift \
    ZedUsageStore.swift \
    XAIUsageFetcher.swift \
    XAIUsageStore.swift \
    OpenAIUsageFetcher.swift \
    OpenAIUsageStore.swift \
    PerplexityUsageFetcher.swift \
    PerplexityUsageStore.swift \
    CopilotUsageFetcher.swift \
    CopilotUsageStore.swift \
    FileWatcher.swift \
    SQLiteReader.swift \
    TCCState.swift \
    ClaudeCodePricing.swift \
    ClaudeCodeUsageFetcher.swift \
    ClaudeCodeUsageStore.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    -target x86_64-apple-macos12.0

# Create universal binary
lipo -create -output "$APP_PATH/Contents/MacOS/ClaudeUsageBar" \
    "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64"

# Clean up individual arch binaries
rm "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64"
rm "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64"

# Create PkgInfo file
echo -n "APPL????" > "$APP_PATH/Contents/PkgInfo"

# Set proper permissions first
chmod 755 "$APP_PATH/Contents/MacOS/ClaudeUsageBar"

# Clean any "detritus" that codesign rejects: extended attributes, ._files, .DS_Store
xattr -cr "$APP_PATH"
find "$APP_PATH" -name '._*' -delete 2>/dev/null
find "$APP_PATH" -name '.DS_Store' -delete 2>/dev/null
dot_clean "$APP_PATH" 2>/dev/null

# Sign with Developer ID certificate. NEVER silently fall back to ad-hoc — that
# fails notarization later. If real signing fails, error out loudly.
DEVELOPER_ID="Developer ID Application: Linkko Technology Pte Ltd (Q467HQ5432)"
if codesign --force --deep --options runtime --sign "$DEVELOPER_ID" "$APP_PATH"; then
    echo "✅ App signed with Developer ID"
    if codesign --verify --verbose=2 "$APP_PATH" 2>&1 | grep -q "valid on disk"; then
        echo "✅ Signature verified"
    else
        echo "❌ Signature verification failed — fix before shipping" >&2
        exit 1
    fi
else
    echo "❌ Developer ID signing failed. NOT falling back to ad-hoc (would break notarization)." >&2
    echo "   Fix the cause above (often: stale xattrs / ._files / cert not in keychain) and re-run." >&2
    exit 1
fi

echo "Build successful!"
echo "App bundle created at: $APP_PATH"
echo "Launching app..."
open "$APP_PATH"
