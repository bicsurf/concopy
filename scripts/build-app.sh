#!/bin/bash
set -e

APP_NAME="ConCopy"
BUNDLE_DIR="$APP_NAME.app"

echo "==> Compilazione per Apple Silicon (arm64)..."
swift build -c release --arch arm64
BUILD_DIR_ARM64=$(swift build --show-bin-path -c release --arch arm64)
BIN_ARM64="$BUILD_DIR_ARM64/ConCopyApp"
if [ ! -f "$BIN_ARM64" ]; then
    BIN_ARM64=$(find "$BUILD_DIR_ARM64" -maxdepth 1 -type f -perm +111 ! -name "*.swiftmodule" ! -name "*.build" ! -name "*.json" ! -name "*.a" ! -name "*.dylib" ! -name "*.swiftsourceinfo" ! -name "*.txt" | head -n 1)
fi

echo "==> Compilazione per Intel (x86_64)..."
swift build -c release --arch x86_64
BUILD_DIR_X86=$(swift build --show-bin-path -c release --arch x86_64)
BIN_X86="$BUILD_DIR_X86/ConCopyApp"
if [ ! -f "$BIN_X86" ]; then
    BIN_X86=$(find "$BUILD_DIR_X86" -maxdepth 1 -type f -perm +111 ! -name "*.swiftmodule" ! -name "*.build" ! -name "*.json" ! -name "*.a" ! -name "*.dylib" ! -name "*.swiftsourceinfo" ! -name "*.txt" | head -n 1)
fi

echo "==> Unione dei binari in un unico Universal Binary (arm64 + x86_64)..."
UNIVERSAL_BIN_DIR=".build/universal-release"
mkdir -p "$UNIVERSAL_BIN_DIR"
lipo -create -output "$UNIVERSAL_BIN_DIR/$APP_NAME" "$BIN_ARM64" "$BIN_X86"
chmod +x "$UNIVERSAL_BIN_DIR/$APP_NAME"

echo "==> Creazione della struttura del bundle macOS ($BUNDLE_DIR)..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

echo "==> Copia dell'eseguibile universale..."
cp "$UNIVERSAL_BIN_DIR/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"

echo "==> Copia dei bundle di risorse delle dipendenze..."
find "$BUILD_DIR_ARM64" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$BUNDLE_DIR/Contents/Resources/" \; 2>/dev/null || true
# Copia i bundle anche nella root del bundle app per soddisfare KeyboardShortcuts
find "$BUILD_DIR_ARM64" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$BUNDLE_DIR/" \; 2>/dev/null || true

echo "==> Generazione del file Info.plist..."
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
<string>1.0.0</string>
<key>CFBundleVersion</key>
<string>1</string>
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
codesign --force --deep --sign - "$BUNDLE_DIR"

echo "==> Fatto! Bundle .app universale generato correttamente."