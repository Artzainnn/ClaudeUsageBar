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

# Compile the Swift app for arm64
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_arm64" \
    ClaudeUsageBar.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework WebKit \
    -target arm64-apple-macos12.0

# Compile for x86_64 (Intel)
swiftc -parse-as-library -o "$APP_PATH/Contents/MacOS/ClaudeUsageBar_x86_64" \
    ClaudeUsageBar.swift \
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

# Sign the app.
#
# For DISTRIBUTION you must sign with a "Developer ID Application" certificate so
# the app can be notarized. Set DEVELOPER_ID to that identity (or export it in
# your environment) to use it. Ad-hoc fallback is disabled in that case.
#
# For LOCAL DEV (e.g. a fork with no Apple certificate) we fall back to ad-hoc
# signing, which is enough to run the app on this machine but CANNOT be notarized.
DEVELOPER_ID="${DEVELOPER_ID:-}"

if [ -n "$DEVELOPER_ID" ]; then
    # Explicit Developer ID requested — never silently fall back to ad-hoc.
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
else
    # No Developer ID configured — ad-hoc sign for local use only.
    echo "⚠️  No DEVELOPER_ID set — ad-hoc signing (local use only, cannot be notarized/distributed)."
    echo "   For distribution: export DEVELOPER_ID=\"Developer ID Application: Your Name (TEAMID)\" and re-run."
    if codesign --force --deep --sign - "$APP_PATH"; then
        echo "✅ App ad-hoc signed"
    else
        echo "❌ Ad-hoc signing failed (often: stale xattrs / ._files). Fix the cause above and re-run." >&2
        exit 1
    fi
fi

echo "Build successful!"
echo "App bundle created at: $APP_PATH"
echo "Launching app..."
open "$APP_PATH"
