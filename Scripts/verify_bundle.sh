#!/bin/bash
# Derlenmiş Arhivar.app paketinin içeriğini denetler: 7-Zip motoru, Quick Look eklentisi, eklentinin dil
# dosyaları (kum havuzunda yalnızca kendi paketini okuyabilir), libarchive bağlantısı ve imza.
#
# Kullanım: verify_bundle.sh [Arhivar.app]   (varsayılan: build/Arhivar.app)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Arhivar.app}"
APPEX="$APP/Contents/PlugIns/ArhivarQuickLook.appex"
FAILURES=0

fail() { echo "✘ $1" >&2; FAILURES=$((FAILURES + 1)); }
check_file() { [ -f "$1" ] || fail "Eksik: ${1#"$APP/"}"; }

[ -d "$APP" ] || { echo "✘ Paket bulunamadı: $APP" >&2; exit 1; }

[ -x "$APP/Contents/MacOS/Arhivar" ] || fail "Eksik ya da çalıştırılamaz: Contents/MacOS/Arhivar"
[ -x "$APP/Contents/MacOS/7zz" ] || fail "Eksik ya da çalıştırılamaz: Contents/MacOS/7zz"
[ -x "$APPEX/Contents/MacOS/ArhivarQuickLook" ] || fail "Eksik ya da çalıştırılamaz: Quick Look eklentisi"
check_file "$APPEX/Contents/Info.plist"

for LPROJ in "$ROOT/Resources/"*.lproj; do
  LANG_DIR="$(basename "$LPROJ")"
  for FILE in "$LPROJ"/*.strings; do
    check_file "$APP/Contents/Resources/$LANG_DIR/$(basename "$FILE")"
  done
  check_file "$APPEX/Contents/Resources/$LANG_DIR/Localizable.strings"
  QL_STRINGS="$APPEX/Contents/Resources/$LANG_DIR/InfoPlist.strings"
  check_file "$QL_STRINGS"
  # Eklentiye yanlışlıkla uygulamanın InfoPlist.strings'i kopyalanırsa eklentinin adı "Arhivar" görünür.
  if [ -f "$QL_STRINGS" ]; then
    QL_NAME="$(plutil -extract CFBundleDisplayName raw -o - "$QL_STRINGS" 2>/dev/null || true)"
    APP_NAME="$(plutil -extract CFBundleDisplayName raw -o - "$APP/Contents/Resources/$LANG_DIR/InfoPlist.strings" 2>/dev/null || true)"
    [ -n "$QL_NAME" ] && [ "$QL_NAME" != "$APP_NAME" ] || fail "$LANG_DIR: eklentinin adı uygulamanınkiyle aynı ya da boş (\"$QL_NAME\")"
  fi
done

if [ -x "$APPEX/Contents/MacOS/ArhivarQuickLook" ]; then
  otool -L "$APPEX/Contents/MacOS/ArhivarQuickLook" | grep -q "/usr/lib/libarchive" \
    || fail "Quick Look eklentisi libarchive'e bağlı değil (kum havuzunda 7zz başlatılamaz)"
fi

codesign --verify --deep --strict "$APP" 2>/dev/null || fail "İmza doğrulanamadı"

if [ "$FAILURES" -gt 0 ]; then
  echo "✘ Paket denetimi başarısız: $FAILURES sorun." >&2
  exit 1
fi
echo "✓ Paket denetimi geçti: $APP"
