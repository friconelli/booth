#!/bin/zsh
# Compila Booth → dist/Booth.app. Uso: ./build.sh
# Usa ffmpeg/ffprobe di Homebrew (/opt/homebrew/bin) oppure quelli messi in Contents/Resources.
set -e; cd "$(dirname "$0")"
NAME="Booth"; EXE=booth; BUNDLE_ID=app.booth.Booth; VERSION=${VERSION:-0.2.0}
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk
A="dist/$NAME.app"; rm -rf "$A"; mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
swiftc -O -sdk $SDK -target arm64-apple-macos13.0 swift/*.swift -o "$A/Contents/MacOS/$EXE"
cat > "$A/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleName</key><string>$NAME</string><key>CFBundleDisplayName</key><string>$NAME</string><key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>$EXE</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>$VERSION</string><key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string><key>NSHighResolutionCapable</key><true/><key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Film</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string>
<key>CFBundleTypeExtensions</key><array><string>mp4</string><string>mkv</string><string>avi</string><string>m4v</string><string>mov</string></array></dict></array></dict></plist>
P
# ffmpeg e ffprobe con le loro librerie dentro l'app (BUNDLE_FFMPEG=0 per saltare e usare quelli di Homebrew)
[ "${BUNDLE_FFMPEG:-1}" = 1 ] && python3 tools/bundle_tools.py "$A/Contents/Resources"
[ -f icon/Booth.icns ] && cp icon/Booth.icns "$A/Contents/Resources/Booth.icns" && sed -i '' 's|<key>CFBundlePackageType</key>|<key>CFBundleIconFile</key><string>Booth</string><key>CFBundlePackageType</key>|' "$A/Contents/Info.plist"
codesign --force -s - -r='designated => identifier "'$BUNDLE_ID'"' "$A"
ln -sf "$NAME.app/Contents/MacOS/$EXE" dist/booth
codesign --verify --deep --strict "$A" || { echo "firma non valida"; exit 1; }
