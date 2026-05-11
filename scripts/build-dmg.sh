#!/usr/bin/env bash
#
# Build a distributable AppleTVRemote DMG with a drag-to-Applications layout.
#
# Defaults to UNSIGNED + ad-hoc signing — no Apple Developer Program account
# required. End users will see Gatekeeper's "cannot be opened because Apple
# cannot check it for malicious software" dialog on first launch and must
# right-click → Open once (or `xattr -dr com.apple.quarantine /path`).
#
# Usage:
#   scripts/build-dmg.sh                                  # ad-hoc + no notarization
#   SIGN_IDENTITY="Developer ID Application: …" …        # real identity
#   NOTARIZE_PROFILE=appletv-remote-notarization …       # opt-in notarization
#
# Env vars (all optional):
#   SIGN_IDENTITY      Codesign identity. Default "-" (ad-hoc).
#   NOTARIZE_PROFILE   notarytool keychain profile. Default "" (skip).
#                      Only honored when SIGN_IDENTITY is a real Dev ID.
#   VERSION            Version string in the DMG filename. Default: yyyy.mm.dd.
#
# Requires: swift, hdiutil, codesign, osascript.

set -euo pipefail

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-}"
VERSION="${VERSION:-$(date +%Y.%m.%d)}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
STAGING="$DIST_DIR/staging"
APP_DST="$DIST_DIR/AppleTVRemote.app"
DMG_NAME="AppleTVRemote-$VERSION"
DMG_TMP="$DIST_DIR/$DMG_NAME-tmp.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME.dmg"
VOLUME_NAME="AppleTVRemote"
MOUNT_DIR="/Volumes/$VOLUME_NAME"
BUNDLE_ID="com.adhir.AppleTVRemote"

mkdir -p "$DIST_DIR"

echo "==> Configuration"
echo "    Sign identity:    ${SIGN_IDENTITY/-/'-' (ad-hoc)}"
echo "    Notarize profile: ${NOTARIZE_PROFILE:-<disabled>}"
echo "    Version:          $VERSION"
echo "    DMG output:       $DMG_PATH"
echo

# ── Build via SPM (xcodeproj is a thin SPM wrapper that doesn't produce
#                    a real .app; we wrap manually) ──
echo "==> Building (swift build -c release)..."
(cd "$REPO_ROOT" && swift build -c release 2>&1 | tail -3)

BIN_SRC="$REPO_ROOT/.build/release/AppleTVRemote"
BUNDLE_SRC="$REPO_ROOT/.build/release/AppleTVRemote_AppleTVRemote.bundle"
ATV_SRC="$REPO_ROOT/.build/release/atv"
INFOPLIST_SRC="$REPO_ROOT/Sources/AppleTVRemote/Resources/Info.plist"
ENTITLEMENTS="$REPO_ROOT/AppleTVRemote.entitlements"

[[ -x "$BIN_SRC" ]]        || { echo "ERROR: $BIN_SRC missing" >&2; exit 1; }
[[ -d "$BUNDLE_SRC" ]]     || { echo "ERROR: $BUNDLE_SRC missing" >&2; exit 1; }
[[ -x "$ATV_SRC" ]]        || { echo "ERROR: $ATV_SRC missing" >&2; exit 1; }
[[ -f "$INFOPLIST_SRC" ]]  || { echo "ERROR: $INFOPLIST_SRC missing" >&2; exit 1; }

# ── Assemble the .app bundle ──
echo "==> Assembling .app bundle..."
rm -rf "$APP_DST"
mkdir -p "$APP_DST/Contents/MacOS" "$APP_DST/Contents/Resources"

cp    "$BIN_SRC"     "$APP_DST/Contents/MacOS/AppleTVRemote"
cp -R "$BUNDLE_SRC"  "$APP_DST/Contents/Resources/"

# Substitute Info.plist build-setting placeholders.
sed -e 's/\$(EXECUTABLE_NAME)/AppleTVRemote/g' \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
    -e 's/\$(PRODUCT_NAME)/AppleTVRemote/g' \
    -e 's/\$(DEVELOPMENT_LANGUAGE)/en/g' \
    "$INFOPLIST_SRC" > "$APP_DST/Contents/Info.plist"

# Mark as a UIElement (no Dock icon — menu-bar-only).
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" \
    "$APP_DST/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :LSUIElement true" \
    "$APP_DST/Contents/Info.plist"

# ── Sign ──
echo "==> Signing .app + atv ($SIGN_IDENTITY)..."
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_DST"
    codesign --force --sign - "$ATV_SRC"
else
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$APP_DST"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$ATV_SRC"
fi

# ── Stage DMG contents ──
echo "==> Staging DMG contents..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_DST"                      "$STAGING/AppleTVRemote.app"
cp    "$ATV_SRC"                      "$STAGING/atv"
cp    "$REPO_ROOT/scripts/install.sh" "$STAGING/install.sh"
cp    "$REPO_ROOT/scripts/README.txt" "$STAGING/README.txt"
chmod +x "$STAGING/install.sh"
ln -sf /Applications "$STAGING/Applications"

# ── Build writable DMG → mount → set icon positions → convert ──
echo "==> Creating writable DMG..."
[[ -d "$MOUNT_DIR" ]] && hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
rm -f "$DMG_TMP" "$DMG_PATH"

STAGE_KB=$(du -sk "$STAGING" | awk '{print $1}')
SIZE_MB=$(( STAGE_KB / 1024 + STAGE_KB / 5120 + 20 ))

hdiutil create -size "${SIZE_MB}m" \
    -fs HFS+ \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDRW \
    "$DMG_TMP" >/dev/null

echo "==> Mounting + applying drag-to-Applications layout..."
hdiutil attach "$DMG_TMP" -readwrite -noverify -noautoopen >/dev/null
sleep 1

osascript <<EOS
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 760, 480}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 12
    -- Top row: the drag target.
    set position of item "AppleTVRemote.app"  of container window to {130, 130}
    set position of item "Applications"       of container window to {410, 130}
    -- Bottom row: CLI + install helper + readme.
    set position of item "atv"                of container window to {110, 280}
    set position of item "install.sh"         of container window to {270, 280}
    set position of item "README.txt"         of container window to {430, 280}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
EOS

sync
hdiutil detach "$MOUNT_DIR" >/dev/null

echo "==> Converting to compressed read-only DMG..."
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$DMG_TMP"
rm -rf "$STAGING"

# ── Sign DMG / Notarize (Developer-ID-only) ──
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    echo "==> Signing DMG..."
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

if [[ -n "$NOTARIZE_PROFILE" ]]; then
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        echo "!! Skipping notarization — needs a real Developer ID identity."
    else
        echo "==> Submitting for notarization (5–15 min)..."
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$NOTARIZE_PROFILE" \
            --wait
        echo "==> Stapling notarization ticket..."
        xcrun stapler staple "$DMG_PATH"
    fi
fi

# ── Verify ──
echo
echo "==> Verification"
codesign --verify --verbose=1 "$APP_DST" 2>&1 | sed 's/^/    /' || true

echo
echo "✓ Built: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo "  Drag AppleTVRemote.app onto the Applications shortcut to install."
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  cat <<'EOT'

  Note: ad-hoc signed build. End users will see a Gatekeeper warning the
  first time they open the app:
    "AppleTVRemote can't be opened because Apple cannot check it for
     malicious software."
  Workaround: right-click → Open (once), or
    xattr -dr com.apple.quarantine /Applications/AppleTVRemote.app
EOT
fi
