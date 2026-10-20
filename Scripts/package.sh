#!/bin/bash
# Arhivar'ı dağıtıma hazır paketler: evrensel .app, .dmg ve .zip (7-Zip motoru dahil).
#
# Kullanım: package.sh [--skip-tests] [--update-7zip]
#   --skip-tests   Testleri çalıştırmadan paketle
#   --update-7zip  Paketlemeden önce Vendor/7-Zip'i GitHub'daki son sürüme güncelle
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_TESTS=1
UPDATE_ENGINE=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) RUN_TESTS=0 ;;
    --update-7zip) UPDATE_ENGINE=1 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Bilinmeyen seçenek: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Support/Info.plist")"
DIST="$ROOT/dist"
APP="$ROOT/build/Arhivar.app"
NAME="Arhivar-$VERSION"

if [ "$UPDATE_ENGINE" = 1 ]; then
  echo "▸ 7-Zip güncelleniyor…"
  "$ROOT/Scripts/update-7zip.sh" install --dest "$ROOT/Vendor/7-Zip"
fi

if [ "$RUN_TESTS" = 1 ]; then
  echo "▸ Testler çalıştırılıyor…"
  swift test --package-path "$ROOT"
fi

"$ROOT/Scripts/build_app.sh"

# Paketin 7-Zip motorunu içerdiğini ve çalıştığını doğrula.
ENGINE="$APP/Contents/MacOS/7zz"
[ -x "$ENGINE" ] || { echo "HATA: Pakette 7zz yok." >&2; exit 1; }
ENGINE_VERSION="$(perl -e 'alarm shift; exec @ARGV' 10 "$ENGINE" </dev/null 2>/dev/null \
  | awk '/7-Zip/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+$/) { print $i; exit } }' || true)"
echo "▸ Paketteki 7-Zip: ${ENGINE_VERSION:-okunamadı} ($(lipo -archs "$ENGINE"))"
codesign --verify --deep --strict "$APP"

echo "▸ Dağıtım dosyaları hazırlanıyor…"
mkdir -p "$DIST"
rm -f "$DIST/$NAME.zip" "$DIST/$NAME.dmg" "$DIST/$NAME.dmg.sig" "$DIST/SHA256SUMS.txt" "$DIST/$NAME.sha256"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/arhivar-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
# ditto paket üst verisini ve genişletilmiş öznitelikleri (imza dahil) olduğu gibi korur.
ditto "$APP" "$STAGING/Arhivar.app"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/LICENSE" "$STAGING/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGING/THIRD_PARTY_NOTICES.txt"
hdiutil create -quiet -volname "Arhivar $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$DIST/$NAME.dmg"

DMG_PATH="$DIST/$NAME.dmg"
SIGNING_TOOL=(xcrun swift "$ROOT/Scripts/update_signing.swift")
APP_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :ArhivarUpdatePublicEDKey' "$ROOT/Support/Info.plist" 2>/dev/null || true)"

if [ -n "$APP_PUBLIC_KEY" ]; then
  KEYCHAIN_PUBLIC_KEY="$("${SIGNING_TOOL[@]}" public-key 2>/dev/null || true)"
  if [ "$APP_PUBLIC_KEY" = "$KEYCHAIN_PUBLIC_KEY" ]; then
    echo "▸ DMG imzalanıyor (Ed25519)…"
    "${SIGNING_TOOL[@]}" sign "$DMG_PATH" > "$DMG_PATH.sig"
    "${SIGNING_TOOL[@]}" verify "$DMG_PATH" "$(cat "$DMG_PATH.sig")" "$APP_PUBLIC_KEY"
    echo "✓ İmza doğrulandı ($DMG_PATH.sig)"
  else
    echo "UYARI: Keychain anahtarı ile Info.plist'teki ArhivarUpdatePublicEDKey uyuşmuyor; .sig üretilemedi." >&2
  fi
fi

echo "▸ SHA-256 özetleri oluşturuluyor…"
(cd "$DIST" && shasum -a 256 "$NAME.dmg" > SHA256SUMS.txt)
cp "$DIST/SHA256SUMS.txt" "$DIST/$NAME.sha256"

echo "✓ Paketler hazır:"
# ls | awk '{ print $9 }' boşluk içeren yolları keserdi; boyut ve yol ayrı ayrı yazılır.
READY_FILES=("$DIST/$NAME.dmg" "$DIST/SHA256SUMS.txt" "$DIST/$NAME.sha256")
if [ -f "$DMG_PATH.sig" ]; then
  READY_FILES+=("$DMG_PATH.sig")
fi
for file in "${READY_FILES[@]}"; do
  printf '   %s\t%s\n' "$(du -h "$file" | cut -f1)" "$file"
done
