#!/bin/bash

APP_NAME="ClaudeUsageBar"
DMG_NAME="${APP_NAME}-Installer"
VERSION="1.1"

# Create a temporary directory for DMG contents
TMP_DIR="dmg_temp"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

# Copy the app
cp -R "build/${APP_NAME}.app" "$TMP_DIR/"

# Strip all extended attributes (including quarantine)
xattr -cr "$TMP_DIR/${APP_NAME}.app"

# Create symbolic link to Applications folder
ln -s /Applications "$TMP_DIR/Applications"

# Create a background image (optional - we'll use text instead)
mkdir -p "$TMP_DIR/.background"

# Set custom icon positions and window size using AppleScript
cat > /tmp/dmg_setup.applescript << 'APPLESCRIPT'
tell application "Finder"
    tell disk "DISK_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 600, 400}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set position of item "APP_NAME.app" of container window to {150, 150}
        set position of item "Applications" of container window to {350, 150}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

# Create temporary DMG
hdiutil create -volname "${APP_NAME}" -srcfolder "$TMP_DIR" -ov -format UDRW temp.dmg

# Mount it
MOUNT_DIR=$(hdiutil attach -readwrite -noverify temp.dmg | grep Volumes | awk '{print $3}')

# Run AppleScript to set up the window (replace placeholders)
sed "s/DISK_NAME/${APP_NAME}/g; s/APP_NAME/${APP_NAME}/g" /tmp/dmg_setup.applescript > /tmp/dmg_setup_final.applescript
osascript /tmp/dmg_setup_final.applescript 2>/dev/null || echo "Note: DMG layout customization skipped"

# Unmount
hdiutil detach "$MOUNT_DIR" -force

# Convert to compressed final DMG
rm -f "${DMG_NAME}.dmg"
hdiutil convert temp.dmg -format UDZO -o "${DMG_NAME}.dmg"

# Clean up
rm -f temp.dmg
rm -rf "$TMP_DIR"
rm -f /tmp/dmg_setup*.applescript

echo "✅ DMG created: ${DMG_NAME}.dmg"

# ---------- Sign + Notarize + Staple ----------
DEVELOPER_ID="Developer ID Application: Linkko Technology Pte Ltd (Q467HQ5432)"
NOTARY_PROFILE="claudeusagebar-notary"

# Sign the DMG itself (the .app inside was already signed in build.sh)
echo ""
echo "🔏 Signing DMG with Developer ID..."
if codesign --force --sign "$DEVELOPER_ID" "${DMG_NAME}.dmg" 2>/dev/null; then
    echo "✅ DMG signed"
else
    echo "⚠️  DMG signing failed (continuing — Gatekeeper may reject)"
fi

# Notarize
echo ""
echo "📤 Submitting to Apple notary service (this can take 5–15 min)..."
if xcrun notarytool submit "${DMG_NAME}.dmg" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1; then
    echo "📎 Stapling notarization ticket to DMG..."
    if xcrun stapler staple "${DMG_NAME}.dmg"; then
        echo "✅ Notarized and stapled — ready to ship"
    else
        echo "⚠️  Stapling failed (DMG is notarized but ticket not embedded — users need to be online for first launch)"
    fi
else
    echo ""
    echo "⚠️  Notarization skipped or failed."
    echo ""
    echo "If this is your first time, run this once to set up credentials:"
    echo ""
    echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
    echo "    --apple-id \"<your-apple-id-email>\" \\"
    echo "    --team-id \"Q467HQ5432\" \\"
    echo "    --password \"<app-specific-password from appleid.apple.com>\""
    echo ""
    echo "Then re-run this script. The DMG is signed but unnotarized — Gatekeeper will warn users."
fi

echo ""
echo "Users can now:"
echo "1. Download ${DMG_NAME}.dmg"
echo "2. Double-click to mount"
echo "3. Drag ${APP_NAME}.app to Applications folder"
echo "4. Eject the DMG"
echo "5. Open ${APP_NAME} from Applications!"
