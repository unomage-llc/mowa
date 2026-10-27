#!/bin/bash
# Builds the installer DMG: Mowa.app + an Applications shortcut in a styled
# Finder window (background with a drag arrow, big icons, no toolbar).
#
#   bash scripts/make-dmg.sh build/Mowa.app build/release/Mowa-1.0.1.dmg "Mowa 1.0.1"
#
# The window layout is applied by Finder via AppleScript, so it runs on a Mac with
# a logged-in session (the first run asks Terminal for permission to control
# Finder: allow it). If Finder can't be scripted, the DMG is still built, just
# without the styling. Background art: scripts/make-dmg-background.py.
set -euo pipefail

APP="${1:?app}"; DMG="${2:?dmg}"; VOLNAME="${3:-Mowa}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BG_DIR="$ROOT/Support/dmg"
APP_NAME="$(basename "$APP")"

# Must match scripts/make-dmg-background.py
WIN_W=660; WIN_H=420; ICON=128
APP_X=170; APPS_X=490; ICON_Y=190

WORK="$(mktemp -d)"
RW="$WORK/rw.dmg"
cleanup() {
  [ -n "${MNT:-}" ] && hdiutil detach "$MNT" -quiet -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Detach a leftover volume with the same name from an earlier interrupted run.
if [ -d "/Volumes/$VOLNAME" ]; then hdiutil detach "/Volumes/$VOLNAME" -force -quiet || true; fi

SIZE_MB=$(( $(du -sm "$APP" | cut -f1) + 40 ))
hdiutil create -size "${SIZE_MB}m" -fs HFS+ -volname "$VOLNAME" -ov "$RW" >/dev/null
MNT="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
[ -d "$MNT" ] || { echo "error: could not mount $RW"; exit 1; }

ditto "$APP" "$MNT/$APP_NAME"
ln -s /Applications "$MNT/Applications"

STYLED=0
if [ -f "$BG_DIR/background.png" ]; then
  mkdir "$MNT/.background"
  if [ -f "$BG_DIR/background@2x.png" ]; then
    # Retina-aware background: one TIFF holding both resolutions.
    tiffutil -cathidpicheck "$BG_DIR/background.png" "$BG_DIR/background@2x.png" -out "$MNT/.background/background.tiff" >/dev/null 2>&1 \
      || cp "$BG_DIR/background.png" "$MNT/.background/background.tiff"
  else
    cp "$BG_DIR/background.png" "$MNT/.background/background.tiff"
  fi

  # Volume icon = app icon.
  if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
    cp "$APP/Contents/Resources/AppIcon.icns" "$MNT/.VolumeIcon.icns"
    SetFile -a C "$MNT" 2>/dev/null || true
  fi

  DISK="$(basename "$MNT")"
  if osascript <<OSA
tell application "Finder"
  tell disk "$DISK"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $ICON
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$APP_NAME" of container window to {$APP_X, $ICON_Y}
    set position of item "Applications" of container window to {$APPS_X, $ICON_Y}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
  then
    STYLED=1
  else
    echo "warn: Finder styling failed (allow Terminal to control Finder in System Settings → Privacy & Security → Automation); building a plain DMG"
  fi
fi

# Let Finder flush .DS_Store, then make the volume read-only + compressed.
sync; sleep 2
chmod -Rf go-w "$MNT" 2>/dev/null || true
hdiutil detach "$MNT" -quiet || { sleep 3; hdiutil detach "$MNT" -force -quiet; }
MNT=""
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
echo "ok: dmg $( [ $STYLED = 1 ] && echo styled || echo plain ) → $DMG"
