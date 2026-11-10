#!/bin/bash
set -e

APP_NAME="ConCopy"
VERSION="1.0.0"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
BUNDLE_DIR="$APP_NAME.app"
TEMP_DMG_DIR="dmg_temp"

echo "==> Compilazione e generazione del bundle .app..."
./scripts/build-app.sh

echo "==> Preparazione della cartella temporanea per il DMG..."
rm -rf "$TEMP_DMG_DIR"
mkdir -p "$TEMP_DMG_DIR"

# Copia il bundle dell'applicazione
cp -R "$BUNDLE_DIR" "$TEMP_DMG_DIR/"

# Crea il collegamento simbolico alla cartella Applicazioni di macOS
ln -s /Applications "$TEMP_DMG_DIR/Applications"

echo "==> Creazione del file DMG compresso ($DMG_NAME)..."
rm -f "$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$TEMP_DMG_DIR" -ov -format UDZO "$DMG_NAME"

# Pulizia dei file temporanei
rm -rf "$TEMP_DMG_DIR"

echo "==> Fatto! File DMG creato con successo nella root del progetto: $DMG_NAME"