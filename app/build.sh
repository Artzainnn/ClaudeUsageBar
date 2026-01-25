#!/bin/bash

# Build script for ClaudeUsageBar

echo "Building ClaudeUsageBar..."

# Create build directory
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

# Clean extended attributes before signing
xattr -cr "$APP_PATH"

# Sign with Developer ID certificate
DEVELOPER_ID="Developer ID Application: Linkko Technology Pte Ltd (Q467HQ5432)"
if codesign --force --deep --options runtime --sign "$DEVELOPER_ID" "$APP_PATH" 2>/dev/null; then
    echo "✅ App signed with Developer ID"
else
    echo "⚠️  Falling back to ad-hoc signature"
    codesign --force --deep --sign - "$APP_PATH"
fi

echo "Build successful!"
echo "App bundle created at: $APP_PATH"
echo "Launching app..."
open "$APP_PATH"
