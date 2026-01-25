#!/bin/bash

APP_NAME="ClaudeUsageBar"
DMG_NAME="${APP_NAME}-Installer"
VERSION="1.0"

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
echo ""
echo "Users can now:"
echo "1. Download ${DMG_NAME}.dmg"
echo "2. Double-click to mount"
echo "3. Drag ${APP_NAME}.app to Applications folder"
echo "4. Eject the DMG"
echo "5. Open ${APP_NAME} from Applications!"
