#!/bin/bash
set -e

APP_NAME="ConCopy"
BUNDLE_DIR="$APP_NAME.app"

RAW_VERSION="${VERSION:-${GITHUB_REF_NAME:-$(git describe --tags --abbrev=0 2>/dev/null || git tag --sort=-v:refname 2>/dev/null | head -n 1 || echo "1.2.0")}}"
RAW_VERSION="${RAW_VERSION#[vV]}"
export VERSION="${RAW_VERSION:-1.2.0}"

# Allineamento automatico versione in Casks/concopy.rb
if [ -f "Casks/concopy.rb" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' -E "s/version \"[^\"]+\"/version \"${VERSION}\"/" Casks/concopy.rb
    else
        sed -i -E "s/version \"[^\"]+\"/version \"${VERSION}\"/" Casks/concopy.rb
    fi
    echo "==> Casks/concopy.rb: version allineata a ${VERSION}"
fi

echo "==> Compilazione Universal Binary nativa (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64
BUILD_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
BIN_PATH="$BUILD_DIR/ConCopyApp"

if [ ! -f "$BIN_PATH" ]; then
    BIN_PATH=$(find "$BUILD_DIR" -maxdepth 1 -type f -perm +111 ! -name "*.swiftmodule" ! -name "*.build" ! -name "*.json" ! -name "*.a" ! -name "*.dylib" ! -name "*.swiftsourceinfo" ! -name "*.txt" | head -n 1)
fi

echo "==> Creazione della struttura del bundle macOS ($BUNDLE_DIR)..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

echo "==> Copia dell'eseguibile universale..."
cp "$BIN_PATH" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"

echo "==> Copia dei bundle di risorse delle dipendenze in Contents/Resources..."
find "$BUILD_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$BUNDLE_DIR/Contents/Resources/" \; 2>/dev/null || true

# Generazione e compilazione di AppIcon.icns
echo "==> Generazione e packaging di AppIcon.icns..."
ICON_SOURCE=""
if [ -f "assets/AppIcon.png" ]; then
    ICON_SOURCE="assets/AppIcon.png"
elif [ -f "assets/AppIcon.jpg" ]; then
    ICON_SOURCE="assets/AppIcon.jpg"
else
    echo "==> assets/AppIcon.png non trovato. Generazione tramite scripts/generate-icon.swift..."
    swift scripts/generate-icon.swift
    ICON_SOURCE="assets/AppIcon.png"
fi

if [ -f "$ICON_SOURCE" ]; then
    ICONSET_DIR="build/AppIcon.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    sips -s format png -z 16 16     "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
    sips -s format png -z 32 32     "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
    sips -s format png -z 32 32     "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
    sips -s format png -z 64 64     "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
    sips -s format png -z 128 128   "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
    sips -s format png -z 256 256   "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -s format png -z 256 256   "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
    sips -s format png -z 512 512   "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -s format png -z 512 512   "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
    sips -s format png -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

    iconutil -c icns "$ICONSET_DIR" -o "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET_DIR"
    echo "==> AppIcon.icns inserito con successo in $BUNDLE_DIR/Contents/Resources/"
fi

if [ -f "assets/AppIcon.png" ]; then
    cp "assets/AppIcon.png" "$BUNDLE_DIR/Contents/Resources/AppIcon.png"
fi

# Copia opzionale di MenuBarIcon se presente in assets
if [ -f "assets/MenuBarIcon.png" ]; then
    cp "assets/MenuBarIcon.png" "$BUNDLE_DIR/Contents/Resources/"
fi
if [ -f "assets/MenuBarIcon.pdf" ]; then
    cp "assets/MenuBarIcon.pdf" "$BUNDLE_DIR/Contents/Resources/"
fi

echo "==> Generazione Info.plist con versione: $VERSION"
cat << EOF > "$BUNDLE_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.bicsurf.concopy</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

touch "$BUNDLE_DIR"

echo "==> Applicazione della firma ad-hoc..."
chmod -R u+w "$BUNDLE_DIR"
codesign --force --deep --sign - "$BUNDLE_DIR"

echo "==> Fatto! Bundle .app universale generato correttamente."
