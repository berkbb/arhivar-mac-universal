#!/bin/bash
# Sürüm öncesi gerçek uygulama stres turu: büyük arşiv, iptal, parolalı arşivler ve Finder Hızlı Bakış.
#
# Klavye kullanmaz: Arhivar erişilebilirlik (AX) ile sürülür, Hızlı Bakış qlmanage ile açılır. Bu yüzden başka bir
# uygulamada yazarken çalıştırmak güvenlidir; yine de Arhivar başta bir kez öne getirilir (pencere ekranda olmalı).
#
# Gereken izin: betiği çalıştıran uygulama (Terminal, Claude…) Sistem Ayarları › Gizlilik ve Güvenlik ›
# Aygıt Denetimi ve Veri Erişimi (Erişilebilirlik) listesinde açık olmalı.
#
# Kullanım: stress-test.sh [--app PATH] [--files N] [--skip-quicklook] [--skip-app]
#   --app PATH        Sınanacak uygulama (varsayılan: /Applications/Arhivar.app)
#   --files N         Büyük arşivdeki dosya sayısı (varsayılan: 20000; 200'ün katı)
#   --skip-quicklook  Finder Hızlı Bakış turunu atla
#   --skip-app        Uygulama turunu (çıkarma, iptal, parola) atla
#
# Arhivar'ın üç ayarı (çıkarma klasörü, alt klasör yok, Finder'da gösterme) tur süresince geçici olarak değişir ve
# betik nasıl biterse bitsin eski değerlerine döner.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Arhivar.app"
FILES=20000
RUN_QL=1
RUN_APP=1
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift ;;
    --files) FILES="$2"; shift ;;
    --skip-quicklook) RUN_QL=0 ;;
    --skip-app) RUN_APP=0 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Bilinmeyen seçenek: $1" >&2; exit 2 ;;
  esac
  shift
done

BUNDLE=net.babadogan.arhivar
ENGINE="$ROOT/Vendor/7-Zip/7zz"
[ -x "$ENGINE" ] || { echo "HATA: $ENGINE yok (./Scripts/update-7zip.sh install)" >&2; exit 2; }
[ -d "$APP" ] || { echo "HATA: $APP yok" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/arhivar-stress.XXXXXX")"
PROBE="$WORK/stressprobe"
FAILED=0
pass() { echo "  ✔ $1"; }
fail() { echo "  ✘ $1"; FAILED=$((FAILED + 1)); }
crash_reports() { ls "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -ciE "^Arhivar" || true; }

# Ayarları yedekle; çıkışta (hata ya da Ctrl-C dahil) geri yükle. Hiç ayarlanmamış olanlar yeniden silinir.
SETTINGS=(extractLocation customExtractFolder subfolderMode revealAfterOperation)
SAVED_VALUES=(); SAVED_TYPES=()
for key in "${SETTINGS[@]}"; do
  SAVED_TYPES+=("$(defaults read-type "$BUNDLE" "$key" 2>/dev/null | awk '{print $NF}')")
  SAVED_VALUES+=("$(defaults read "$BUNDLE" "$key" 2>/dev/null)")
done
restore() {
  for i in "${!SETTINGS[@]}"; do
    key="${SETTINGS[$i]}"
    case "${SAVED_TYPES[$i]}" in
      "") defaults delete "$BUNDLE" "$key" >/dev/null 2>&1 ;;
      boolean) defaults write "$BUNDLE" "$key" -bool "$([ "${SAVED_VALUES[$i]}" = 1 ] && echo true || echo false)" ;;
      integer) defaults write "$BUNDLE" "$key" -int "${SAVED_VALUES[$i]}" ;;
      *) defaults write "$BUNDLE" "$key" -string "${SAVED_VALUES[$i]}" ;;
    esac
  done
  rm -rf "$WORK"
}
trap restore EXIT

echo "▸ Yardımcı derleniyor…"
swiftc -O "$ROOT/Scripts/StressProbe.swift" -o "$PROBE" 2>&1 | grep -v "^$" | grep -v warning >&2 || true
[ -x "$PROBE" ] || { echo "HATA: yardımcı derlenemedi" >&2; exit 2; }

# Arayüz metinleri uygulamanın dil ayarına göre (varsayılan Türkçe) uygulamanın kendi tablolarından okunur.
LANGUAGE="$(defaults read "$BUNDLE" language 2>/dev/null || echo tr)"
if [ "$LANGUAGE" = system ]; then
  LANGUAGE="$(defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | tr -d ' ",' | cut -c1-2)"
  case "$LANGUAGE" in tr|en|ro) ;; *) LANGUAGE=en ;; esac
fi
label() { plutil -extract "$1" raw -o - "$APP/Contents/Resources/$LANGUAGE.lproj/Localizable.strings"; }
MENU_ARCHIVE="$(label menuArchive)"
MENU_EXTRACT_ALL="$(label menuExtractAll)"
CANCELLING="$(label progressCancelling)"
MENU_CLOSE="$(label menuCloseArchive)"
MENU_NEW="$(label menuNewArchive)"
BUTTON_CANCEL="$(label buttonCancel)"

echo "▸ Örnek arşivler hazırlanıyor ($WORK)…"
FX="$WORK/fixtures"; mkdir -p "$FX/src" "$FX/kucuk"
"$PROBE" mkfiles "$FX/src" $((FILES / 200)) 200 >/dev/null
(cd "$FX/src" && "$ENGINE" a -bso0 -bsp0 -mx=1 "$FX/buyuk.zip" . >/dev/null)
cp "$FX/buyuk.zip" "$FX/indirilmis.zip"
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;" "$FX/indirilmis.zip"
printf 'gizli içerik\n' > "$FX/kucuk/not.txt"; printf 'ikinci\n' > "$FX/kucuk/b.txt"
(
  cd "$FX/kucuk" || exit 1
  /usr/bin/zip -q -P Gizli-123 "$FX/zipcrypto.zip" not.txt b.txt
  printf 'Gizli-123\n' | "$ENGINE" a -bso0 -tzip -p -mem=AES256 "$FX/aes.zip" not.txt b.txt >/dev/null
  printf 'Gizli-123\n' | "$ENGINE" a -bso0 -p "$FX/icerik-sifreli.7z" not.txt b.txt >/dev/null
  printf 'Gizli-123\n' | "$ENGINE" a -bso0 -p -mhe=on "$FX/baslik-sifreli.7z" not.txt b.txt >/dev/null
  /usr/bin/zip -q "$FX/normal.zip" not.txt b.txt
)
echo "bu bir arşiv değil" > "$FX/sahte.7z"
head -c 4000 "$FX/buyuk.zip" > "$FX/yarim.zip"
pass "$FILES dosyalık arşiv ve 8 küçük arşiv hazır"

CRASHES_BEFORE="$(crash_reports)"

if [ "$RUN_QL" = 1 ]; then
  echo "▸ Finder Hızlı Bakış (qlmanage)…"
  qlmanage -r >/dev/null 2>&1
  for f in zipcrypto.zip aes.zip icerik-sifreli.7z baslik-sifreli.7z normal.zip sahte.7z yarim.zip buyuk.zip; do
    (qlmanage -p "$FX/$f" >/dev/null 2>&1 &)
    sleep 4
    pid="$(pgrep -f "ArhivarQuickLook.appex/Contents/MacOS" | head -1)"
    pkill qlmanage
    if [ -n "$pid" ]; then pass "Hızlı Bakış: $f (eklenti çalıştı)"; else fail "Hızlı Bakış: $f (eklenti başlamadı)"; fi
    sleep 1
  done
fi

if [ "$RUN_APP" = 1 ]; then
  echo "▸ Uygulama: çıkarma, iptal ve parola…"
  OUT="$WORK/cikti"; mkdir -p "$OUT"
  defaults write "$BUNDLE" extractLocation custom
  defaults write "$BUNDLE" customExtractFolder "$OUT"
  defaults write "$BUNDLE" subfolderMode never
  defaults write "$BUNDLE" revealAfterOperation -bool false
  osascript -e 'tell application id "net.babadogan.arhivar" to quit' >/dev/null 2>&1; sleep 2; pkill -x Arhivar; sleep 1

  open_archive() {
    open -a "$APP" "$1"
    "$PROBE" wait arhivar.browser present 60 >/dev/null || return 1
    "$PROBE" wait arhivar.progress absent 120 >/dev/null
  }

  # macOS yalnızca o anki masaüstündeki pencereleri erişilebilirliğe açar. Arhivar başka bir masaüstündeyse ya da
  # tam ekran bir uygulamanın arkasındaysa sonraki adımlar boşuna düşerdi: önce pencerenin görünmesi beklenir.
  open -a "$APP"
  visible=0
  for _ in $(seq 1 30); do
    [ "$("$PROBE" windows 2>/dev/null || echo 0)" -ge 1 ] && { visible=1; break; }
    sleep 0.5
  done
  if [ "$visible" = 0 ]; then
    fail "Arhivar penceresi ekranda değil (başka bir masaüstünde ya da tam ekran bir uygulamanın arkasında mı?). Uygulama turu atlandı; pencereyi bu masaüstüne getirip yeniden çalıştırın."
    RUN_APP_STEPS=0
  else
    RUN_APP_STEPS=1
  fi

  # 1. İndirilmiş (karantinalı) büyük arşivi çıkar: arayüz donmamalı, dosyalar ve karantina işareti tam olmalı.
  if [ "$RUN_APP_STEPS" = 0 ]; then
    :
  elif open_archive "$FX/indirilmis.zip"; then
    "$PROBE" menu "$MENU_ARCHIVE" "$MENU_EXTRACT_ALL" >/dev/null
    "$PROBE" latency 600 > "$WORK/latency" &
    LATENCY_PID=$!
    "$PROBE" wait arhivar.progress present 10 >/dev/null
    "$PROBE" wait arhivar.progress absent 600 >/dev/null
    kill $LATENCY_PID 2>/dev/null; wait $LATENCY_PID 2>/dev/null
    count="$(find "$OUT" -type f | wc -l | tr -d ' ')"
    sample="$(find "$OUT" -type f | head -1)"
    [ "$count" = "$FILES" ] && pass "Çıkarma: $count dosya" || fail "Çıkarma: $count/$FILES dosya"
    xattr -p com.apple.quarantine "$sample" >/dev/null 2>&1 && pass "Karantina işareti aktarıldı" || fail "Karantina işareti yok"
  else
    fail "Arşiv açılamadı: indirilmis.zip"
  fi

  if [ "$RUN_APP_STEPS" = 1 ]; then
    # 2. İptal: "İptal ediliyor…" hemen görünmeli, hedefe hiçbir şey yazılmamalı, arayüz donmamalı.
    rm -rf "$OUT"; mkdir -p "$OUT"
    "$PROBE" menu "$MENU_ARCHIVE" "$MENU_EXTRACT_ALL" >/dev/null
    "$PROBE" wait arhivar.progress present 10 >/dev/null
    sleep 2
    "$PROBE" latency 30 > "$WORK/latency-cancel" &
    LATENCY_PID=$!
    "$PROBE" press arhivar.progress.cancel
    sleep 0.5
    title="$("$PROBE" text arhivar.progress)"
    [ "$title" = "$CANCELLING" ] && pass "İptal: \"$CANCELLING\" hemen gösterildi" || fail "İptal: başlık \"$title\""
    "$PROBE" wait arhivar.progress absent 60 >/dev/null && pass "İptal: pencere kapandı" || fail "İptal: pencere kapanmadı"
    kill $LATENCY_PID 2>/dev/null; wait $LATENCY_PID 2>/dev/null
    [ -z "$(find "$OUT" -type f | head -1)" ] && pass "İptal: hedefe hiçbir şey yazılmadı" || fail "İptal: hedefe dosya yazıldı"
    # İptal bir hata değildir: uyarı çıkmamalı (çıkarsa sonraki parola sayfalarını da engeller).
    unexpected="$("$PROBE" alert)"
    [ -z "$unexpected" ] && pass "İptal: uyarı gösterilmedi" || fail "İptal sonrası beklenmeyen uyarı: $unexpected"

    # 3. Parolalı arşivler: dosya adları parola sorulmadan gösterilmemeli.
    for f in aes.zip zipcrypto.zip icerik-sifreli.7z baslik-sifreli.7z; do
      open -a "$APP" "$FX/$f"
      if "$PROBE" wait arhivar.password present 15 >/dev/null; then
        pass "Parola soruldu: $f"
        "$PROBE" press arhivar.password.cancel
        "$PROBE" wait arhivar.password absent 5 >/dev/null
      else
        fail "Parola sorulmadı: $f"
      fi
    done

    # Arayüz yanıtı: eşik 1500 ms (bir an takılma kabul, donma değil).
    for file in latency latency-cancel; do
      worst="$(tail -1 "$WORK/$file" 2>/dev/null)"; worst="${worst:-?}"
      if [ "$worst" != "?" ] && [ "$worst" -lt 1500 ]; then pass "Arayüz yanıtı ($file): en kötü $worst ms"; else fail "Arayüz dondu ($file): en kötü $worst ms"; fi
    done
  fi
fi

if [ "$RUN_APP" = 1 ] && [ "${RUN_APP_STEPS:-0}" = 1 ]; then
  # 4. VoiceOver: görünen her denetimin okunacak bir adı olmalı (simgeden türetilen ya da boş ad olmamalı).
  audit() { if result="$("$PROBE" audit "$1")"; then pass "VoiceOver: $result"; else fail "VoiceOver: $result"; fi; }
  open_archive "$FX/normal.zip" && audit "arşiv görünümü"
  "$PROBE" menu "*" "$MENU_NEW" >/dev/null && sleep 1.5 && audit "yeni arşiv sayfası" && "$PROBE" pressname "$BUTTON_CANCEL" && sleep 1
  open -a "$APP" "$FX/aes.zip"
  "$PROBE" wait arhivar.password present 15 >/dev/null && audit "parola sayfası" && "$PROBE" press arhivar.password.cancel && sleep 1
  "$PROBE" menu "*" "$MENU_CLOSE" >/dev/null && sleep 1.5 && audit "karşılama"

  unexpected="$("$PROBE" alert)"
  [ -z "$unexpected" ] && pass "Tur sonunda açık uyarı yok" || fail "Tur sonunda açık uyarı: $unexpected"
fi

CRASHES_AFTER="$(crash_reports)"
[ "$CRASHES_AFTER" = "$CRASHES_BEFORE" ] && pass "Yeni çökme raporu yok" || fail "Yeni çökme raporu: $((CRASHES_AFTER - CRASHES_BEFORE))"

echo
if [ "$FAILED" -eq 0 ]; then echo "✓ Stres turu geçti"; else echo "✘ Stres turu: $FAILED sorun"; fi
exit $((FAILED > 0))
