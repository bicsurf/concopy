#!/bin/bash
set -e

APP_NAME="ConCopy"
BUNDLE_DIR="$APP_NAME.app"

RAW_VERSION="${VERSION:-${GITHUB_REF_NAME:-$(git describe --tags --abbrev=0 2>/dev/null || git tag --sort=-v:refname 2>/dev/null | head -n 1 || echo "1.0.0")}}"
RAW_VERSION="${RAW_VERSION#[vV]}"
export VERSION="${RAW_VERSION:-1.0.0}"

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

echo "==> Generazione Info.plist con versione: $VERSION"
cat << EOF > "$BUNDLE_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.conoscenti.concopy</string>
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

echo "==> Applicazione della firma ad-hoc..."
chmod -R u+w "$BUNDLE_DIR"
codesign --force --deep --sign - "$BUNDLE_DIR"

echo "==> Fatto! Bundle .app universale generato correttamente."