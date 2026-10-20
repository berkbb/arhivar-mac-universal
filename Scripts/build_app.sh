#!/bin/bash
# Arhivar.app paketini derler ve hazırlar (varsayılan: evrensel arm64 + x86_64).
#
# Ortam değişkenleri:
#   SEVENZIP_DIR  Pakete eklenecek 7-Zip klasörü (varsayılan: Vendor/7-Zip)
#   CONFIG        debug | release (varsayılan: release)
#   ARCHS         Derlenecek mimariler (varsayılan: "arm64 x86_64"; yalnızca bu Mac için: ARCHS=native)
#   SIGN_IDENTITY İmza kimliği (varsayılan: "-", ad-hoc). Ör. "Developer ID Application: Ad (TAKIM)";
#                 ad-hoc dışındaki kimliklerde noter onayı için sertleştirilmiş çalışma zamanı ve zaman damgası eklenir.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEVENZIP_DIR="${SEVENZIP_DIR:-$ROOT/Vendor/7-Zip}"
CONFIG="${CONFIG:-release}"
ARCHS="${ARCHS:-arm64 x86_64}"
APP="$ROOT/build/Arhivar.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then SIGN_ARGS+=(--options runtime --timestamp); fi

BUILD_ARGS=(-c "$CONFIG" --package-path "$ROOT")
if [ "$ARCHS" != "native" ]; then
  for arch in $ARCHS; do BUILD_ARGS+=(--arch "$arch"); done
fi

echo "▸ Swift paketi derleniyor ($CONFIG, ${ARCHS})…"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
  echo "▸ Uygulama simgesi çiziliyor…"
  swift "$ROOT/Scripts/make_icon.swift" "$ROOT/Resources/AppIcon.icns"
fi
if [ ! -f "$ROOT/Resources/DocumentIcons/zip.icns" ]; then
  echo "▸ Belge simgeleri çiziliyor…"
  swift "$ROOT/Scripts/make_document_icons.swift" "$ROOT/Resources/DocumentIcons"
fi

echo "▸ Paket hazırlanıyor…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Arhivar" "$APP/Contents/MacOS/Arhivar"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
# Arhivar varsayılan uygulama olduğunda Finder'ın arşivlerde gösterdiği belge simgeleri (Info.plist: CFBundleTypeIconFile).
cp "$ROOT/Resources/DocumentIcons/"*.icns "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/"*.lproj "$APP/Contents/Resources/"
cp "$ROOT/Scripts/update-7zip.sh" "$APP/Contents/Resources/update-7zip.sh"
chmod 755 "$APP/Contents/Resources/update-7zip.sh"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Arhivar-License.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Third-Party-Notices.txt"

if [ -x "$SEVENZIP_DIR/7zz" ]; then
  echo "▸ 7-Zip motoru ekleniyor: $SEVENZIP_DIR/7zz"
  cp "$SEVENZIP_DIR/7zz" "$APP/Contents/MacOS/7zz"
  if [ -f "$SEVENZIP_DIR/License.txt" ]; then
    cp "$SEVENZIP_DIR/License.txt" "$APP/Contents/Resources/7-Zip-License.txt"
  fi
  if [ -d "$SEVENZIP_DIR/MANUAL" ]; then
    cp -R "$SEVENZIP_DIR/MANUAL" "$APP/Contents/Resources/Manual"
    find "$APP/Contents/Resources/Manual" -name .DS_Store -delete
  fi
  codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/7zz"
else
  echo "⚠ $SEVENZIP_DIR/7zz bulunamadı. Önce ./Scripts/update-7zip.sh install çalıştırın." >&2
  exit 1
fi

if [ -f "$BIN_DIR/ArhivarQuickLook" ]; then
  echo "▸ Quick Look eklentisi paketleniyor: ArhivarQuickLook.appex"
  QL_APPEX="$APP/Contents/PlugIns/ArhivarQuickLook.appex"
  mkdir -p "$QL_APPEX/Contents/MacOS" "$QL_APPEX/Contents/Resources"
  cp "$BIN_DIR/ArhivarQuickLook" "$QL_APPEX/Contents/MacOS/ArhivarQuickLook"
  cp "$ROOT/Support/QuickLook-Info.plist" "$QL_APPEX/Contents/Info.plist"
  codesign "${SIGN_ARGS[@]}" "$QL_APPEX"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then echo "▸ Ad-hoc imzalanıyor…"; else echo "▸ İmzalanıyor: $SIGN_IDENTITY"; fi
codesign "${SIGN_ARGS[@]}" "$APP"
echo "▸ Mimariler: $(lipo -archs "$APP/Contents/MacOS/Arhivar")"
echo "✓ Hazır: $APP"
