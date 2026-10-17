#!/bin/bash
# 7-Zip motorunu (7zz) resmi GitHub sürümlerinden (ip7z/7zip) denetler ve kurar.
#
# Kullanım:
#   update-7zip.sh check   [hedefler] [--current SÜRÜM]
#   update-7zip.sh install [hedefler] [--current SÜRÜM] [--force] [--no-verify]
#
# Hedefler (birden fazla verilebilir):
#   --dest DIR   7zz, lisans ve kılavuzu bir klasöre kurar (ör. Vendor/7-Zip)
#   --app PATH   Bir Arhivar.app paketinin içindeki 7zz'yi günceller ve paketi yeniden imzalar
# Hedef verilmezse: betik bir .app içinden çalışıyorsa o uygulama, projeden çalışıyorsa
# projenin Vendor/7-Zip klasörü güncellenir.
#
# Makine tarafından okunacak sonuçlar stdout'a KEY=value satırları olarak,
# insan için mesajlar stderr'e yazılır. Arhivar arayüzü de bu betiği çalıştırır.
set -euo pipefail

REPO="ip7z/7zip"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/"
FALLBACK_DIR="$HOME/Library/Application Support/Arhivar/engine"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CURRENT=""
FORCE=0
VERIFY=1
TARGET_KINDS=()
TARGET_PATHS=()
# Hedef yedek klasöre çevrildiyse, oradaki 7zz henüz yokken sürümü okunacak özgün (paketteki) 7zz.
TARGET_ORIGINALS=()

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2
}

log() { echo "$*" >&2; }
fail() { log "HATA: $*"; echo "STATUS=error"; echo "ERROR=$*"; exit 1; }
add_target() { TARGET_KINDS+=("$1"); TARGET_PATHS+=("$2"); TARGET_ORIGINALS+=(""); }

COMMAND="${1:-}"
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) [ $# -ge 2 ] || fail "--dest bir klasör bekliyor"; add_target dir "$2"; shift 2 ;;
    --app) [ $# -ge 2 ] || fail "--app bir .app yolu bekliyor"; add_target app "$2"; shift 2 ;;
    --current) [ $# -ge 2 ] || fail "--current bir sürüm bekliyor"; CURRENT="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --no-verify) VERIFY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Bilinmeyen seçenek: $1" ;;
  esac
done
case "$COMMAND" in
  check|install) ;;
  -h|--help|"") usage; exit 0 ;;
  *) fail "Bilinmeyen komut: $COMMAND (check veya install)" ;;
esac

# --- Varsayılan hedef ------------------------------------------------------
if [ ${#TARGET_KINDS[@]} -eq 0 ]; then
  if [ -n "${ARHIVAR_ENGINE_DIR:-}" ]; then
    add_target dir "$ARHIVAR_ENGINE_DIR"
  elif [[ "$SCRIPT_DIR" == *.app/Contents/Resources ]]; then
    add_target app "${SCRIPT_DIR%/Contents/Resources}"
  else
    add_target dir "$(cd "$SCRIPT_DIR/.." && pwd)/Vendor/7-Zip"
  fi
fi

# Yazılamayan bir uygulama paketi (ör. yönetici izniyle kurulmuş) yerine kullanıcı klasörüne kur.
for i in "${!TARGET_KINDS[@]}"; do
  if [ "${TARGET_KINDS[$i]}" = app ]; then
    APP_PATH="${TARGET_PATHS[$i]}"
    [ -d "$APP_PATH/Contents" ] || fail "Uygulama paketi bulunamadı: $APP_PATH"
    if [ ! -w "$APP_PATH/Contents/MacOS" ]; then
      log "Uyarı: $APP_PATH yazılamıyor; 7zz $FALLBACK_DIR klasörüne kurulacak."
      TARGET_KINDS[$i]=dir
      TARGET_PATHS[$i]="$FALLBACK_DIR"
      TARGET_ORIGINALS[$i]="$APP_PATH/Contents/MacOS/7zz"
    fi
  fi
done

target_binary() {
  if [ "$1" = app ]; then echo "$2/Contents/MacOS/7zz"; else echo "$2/7zz"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/arhivar-update.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Bir programı en fazla N saniye çalıştırır (macOS'ta timeout komutu yok).
run_with_timeout() {
  local seconds="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
}

# "7-Zip (z) 26.04 (arm64) : ..." satırından sürümü çıkarır.
engine_version() {
  local binary="$1"
  [ -x "$binary" ] || return 0
  run_with_timeout 10 "$binary" 2>/dev/null </dev/null \
    | awk '/7-Zip/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+$/) { print $i; exit } }' || true
}

# "26.04" -> 2604; karşılaştırma için.
version_number() {
  awk -F. '{ printf "%d%02d\n", $1, $2 }' <<<"$1"
}

# --- Son sürüm bilgisini al -------------------------------------------------
log "Son sürüm denetleniyor: github.com/$REPO"
curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 \
  -H "Accept: application/vnd.github+json" "$API_URL" -o "$WORK/release.json" \
  || fail "GitHub'a ulaşılamadı"

# JSON'u macOS'un yerleşik JavaScript motoruyla ayrıştır (ek bağımlılık yok).
RELEASE_INFO="$(osascript -l JavaScript -e '
function run(argv) {
  var text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js;
  var release = JSON.parse(text);
  var asset = (release.assets || []).filter(function (a) { return /^7z[0-9]+-mac\.tar\.xz$/.test(a.name); })[0];
  if (!asset) { return "TAG=" + release.tag_name; }
  return ["TAG=" + release.tag_name, "ASSET=" + asset.name, "URL=" + asset.browser_download_url,
          "DIGEST=" + (asset.digest || "")].join("\n");
}' "$WORK/release.json")" || fail "Sürüm bilgisi okunamadı"

TAG="$(sed -n 's/^TAG=//p' <<<"$RELEASE_INFO")"
ASSET="$(sed -n 's/^ASSET=//p' <<<"$RELEASE_INFO")"
URL="$(sed -n 's/^URL=//p' <<<"$RELEASE_INFO")"
DIGEST="$(sed -n 's/^DIGEST=//p' <<<"$RELEASE_INFO")"

[[ "$TAG" =~ ^[0-9]+\.[0-9]+$ ]] || fail "Beklenmeyen sürüm etiketi: $TAG"
[ -n "$ASSET" ] || fail "Bu sürümde macOS paketi yok ($TAG)"
[[ "$URL" == "$DOWNLOAD_PREFIX"* ]] || fail "Beklenmeyen indirme adresi: $URL"

# Kurulu sürüm: hedeflerin en eskisi (biri eksikse güncelleme gerekir).
# Yedek klasöre çevrilen hedefte henüz 7zz yoksa uygulamanın kendi 7zz'si geçerlidir; "yok" sayılmaz.
if [ -z "$CURRENT" ]; then
  LOWEST=""
  for i in "${!TARGET_KINDS[@]}"; do
    BINARY="$(target_binary "${TARGET_KINDS[$i]}" "${TARGET_PATHS[$i]}")"
    if [ ! -x "$BINARY" ] && [ -n "${TARGET_ORIGINALS[$i]}" ]; then BINARY="${TARGET_ORIGINALS[$i]}"; fi
    VERSION="$(engine_version "$BINARY")"
    if [ -z "$VERSION" ]; then LOWEST=""; break; fi
    if [ -z "$LOWEST" ] || [ "$(version_number "$VERSION")" -lt "$(version_number "$LOWEST")" ]; then
      LOWEST="$VERSION"
    fi
  done
  CURRENT="$LOWEST"
fi

echo "LATEST=$TAG"
echo "CURRENT=${CURRENT:-none}"
echo "SOURCE=https://github.com/$REPO/releases/tag/$TAG"
for i in "${!TARGET_KINDS[@]}"; do echo "TARGET=${TARGET_KINDS[$i]}:${TARGET_PATHS[$i]}"; done

UPDATE_AVAILABLE=1
if [ -n "$CURRENT" ] && [ "$(version_number "$CURRENT")" -ge "$(version_number "$TAG")" ]; then
  UPDATE_AVAILABLE=0
fi

if [ "$COMMAND" = "check" ]; then
  if [ "$UPDATE_AVAILABLE" = 1 ]; then
    log "Yeni sürüm var: $TAG (kurulu: ${CURRENT:-yok})"
    echo "STATUS=update-available"
  else
    log "7-Zip güncel: $CURRENT"
    echo "STATUS=up-to-date"
  fi
  exit 0
fi

# --- İndirme ve doğrulama -------------------------------------------------
if [ "$UPDATE_AVAILABLE" = 0 ] && [ "$FORCE" = 0 ]; then
  log "7-Zip zaten güncel ($CURRENT). Yeniden kurmak için --force kullanın."
  echo "STATUS=up-to-date"
  exit 0
fi

log "İndiriliyor: $ASSET"
curl -fL --proto '=https' --tlsv1.2 --max-time 600 --progress-bar "$URL" -o "$WORK/$ASSET" \
  || fail "İndirme başarısız"

if [ "$VERIFY" = 1 ]; then
  [[ "$DIGEST" == sha256:* ]] || fail "GitHub SHA-256 özeti vermedi; doğrulamasız kurmak için --no-verify kullanın"
  EXPECTED="${DIGEST#sha256:}"
  ACTUAL="$(shasum -a 256 "$WORK/$ASSET" | awk '{ print $1 }')"
  [ "$EXPECTED" = "$ACTUAL" ] || fail "SHA-256 eşleşmedi (beklenen $EXPECTED, gelen $ACTUAL)"
  log "SHA-256 doğrulandı."
else
  log "UYARI: SHA-256 doğrulaması atlandı."
  ACTUAL="$(shasum -a 256 "$WORK/$ASSET" | awk '{ print $1 }')"
fi

PAYLOAD="$WORK/extract"
mkdir -p "$PAYLOAD"
tar -xJf "$WORK/$ASSET" -C "$PAYLOAD" || fail "Paket açılamadı"
[ -f "$PAYLOAD/7zz" ] || fail "Paket içinde 7zz bulunamadı"
file "$PAYLOAD/7zz" | grep -q "Mach-O" || fail "7zz geçerli bir macOS programı değil"
chmod 755 "$PAYLOAD/7zz"

NEW_VERSION="$(engine_version "$PAYLOAD/7zz")"
[ "$NEW_VERSION" = "$TAG" ] || fail "İndirilen 7zz sürümü beklenenle uyuşmuyor (${NEW_VERSION:-okunamadı})"

# --- Kurulum ----------------------------------------------------------------

# Dosyayı önce geçici adla kopyalayıp tek adımda yerine taşır; yarım kurulum kalmaz.
replace_file() {
  cp "$1" "$2.new"
  mv -f "$2.new" "$2"
}

replace_dir() {
  rm -rf "$2.new"
  cp -R "$1" "$2.new"
  rm -rf "$2"
  mv "$2.new" "$2"
}

install_to_dir() {
  local dest="$1"
  mkdir -p "$dest"
  replace_file "$PAYLOAD/7zz" "$dest/7zz"
  for doc in License.txt History.txt readme.txt; do
    if [ -f "$PAYLOAD/$doc" ]; then cp "$PAYLOAD/$doc" "$dest/$doc"; fi
  done
  if [ -d "$PAYLOAD/MANUAL" ]; then replace_dir "$PAYLOAD/MANUAL" "$dest/MANUAL"; fi
  # Hangi 7-Zip sürümünün kurulduğunu kayıt altına al (yeniden üretilebilir sürümler için).
  printf 'version=%s\nasset=%s\nurl=%s\nsha256=%s\n' "$TAG" "$ASSET" "$URL" "$ACTUAL" > "$dest/SOURCE.txt"
}

install_to_app() {
  local app="$1"
  replace_file "$PAYLOAD/7zz" "$app/Contents/MacOS/7zz"
  if [ -f "$PAYLOAD/License.txt" ]; then cp "$PAYLOAD/License.txt" "$app/Contents/Resources/7-Zip-License.txt"; fi
  if [ -d "$PAYLOAD/MANUAL" ]; then replace_dir "$PAYLOAD/MANUAL" "$app/Contents/Resources/Manual"; fi
  # İçerik değiştiği için paketin imzasını yenile (ad-hoc).
  if command -v codesign >/dev/null; then
    codesign --force --sign - "$app/Contents/MacOS/7zz" >/dev/null 2>&1 || log "Uyarı: 7zz imzalanamadı."
    codesign --force --sign - "$app" >/dev/null 2>&1 || log "Uyarı: $app yeniden imzalanamadı."
  fi
}

for i in "${!TARGET_KINDS[@]}"; do
  KIND="${TARGET_KINDS[$i]}"
  TARGET="${TARGET_PATHS[$i]}"
  if [ "$KIND" = app ]; then install_to_app "$TARGET"; else install_to_dir "$TARGET"; fi
  INSTALLED="$(target_binary "$KIND" "$TARGET")"
  log "7-Zip $TAG kuruldu: $INSTALLED"
  echo "INSTALLED=$INSTALLED"
done

echo "STATUS=installed"
