#!/bin/bash
# Buduje CrateSort.app z ikoną i instaluje w folderze Aplikacje.
# Wymaga Xcode lub Command Line Tools (xcode-select --install).
#   ./build-app.sh            → zbuduj i zainstaluj w /Applications
#   ./build-app.sh --no-install → tylko zbuduj CrateSort.app tutaj
set -e
cd "$(dirname "$0")"
INSTALL=1
[ "$1" = "--no-install" ] && INSTALL=0

echo "▶ Kompiluję (release)…"
swift build -c release

APP="CrateSort.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CrateSort "$APP/Contents/MacOS/CrateSort"

echo "▶ Ikona…"
if command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
    SET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$SET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d Resources/AppIcon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns" || cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CrateSort</string>
    <key>CFBundleDisplayName</key><string>CrateSort</string>
    <key>CFBundleIdentifier</key><string>pl.cratesort.app</string>
    <key>CFBundleExecutable</key><string>CrateSort</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundleDevelopmentRegion</key><string>pl</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>CrateSort — katalog muzyki dla DJ-a</string>
    <key>NSRemovableVolumesUsageDescription</key><string>CrateSort skanuje muzykę na pendrive'ach i dyskach zewnętrznych.</string>
    <key>NSDesktopFolderUsageDescription</key><string>CrateSort skanuje muzykę w wybranych folderach.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>CrateSort skanuje muzykę w wybranych folderach.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>CrateSort skanuje muzykę w wybranych folderach.</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "✅ Zbudowano: $(pwd)/$APP"

if [ $INSTALL -eq 1 ]; then
    # zamknij działającą wersję, żeby można ją było podmienić
    osascript -e 'tell application "CrateSort" to quit' >/dev/null 2>&1 || true
    sleep 1
    DEST="/Applications"
    if [ ! -w "$DEST" ]; then
        DEST="$HOME/Applications"
        mkdir -p "$DEST"
    fi
    rm -rf "$DEST/CrateSort.app"
    ditto "$APP" "$DEST/CrateSort.app"
    # odśwież ikonę w Finderze, Docku i Launchpadzie
    touch "$DEST/CrateSort.app"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/CrateSort.app" >/dev/null 2>&1 || true
    echo "✅ Zainstalowano: $DEST/CrateSort.app"
    echo "   Uruchom z Launchpada, Spotlighta (⌘Spacja → CrateSort) albo: open \"$DEST/CrateSort.app\""
fi
