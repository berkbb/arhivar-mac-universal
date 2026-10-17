# Changelog

Bu dosya [Keep a Changelog](https://keepachangelog.com/tr/1.1.0/) biçimini ve
[Semantic Versioning](https://semver.org/lang/tr/) kurallarını izler.

## [Yayımlanmadı]

## [1.0.1] — 2026-10-17

### Güvenlik

- Parolalar 7zz'ye komut satırı yerine stdin üzerinden veriliyor; işlem sürerken `ps` ile okunamıyor.
- Çıkarma önce hedefle aynı diskteki bir hazırlık klasörüne yapılıyor ve başarılı olursa taşınıyor. İptal, CRC hatası ya da dolu disk durumunda hedef hiç değişmiyor; "üzerine yaz" seçiliyken bile mevcut dosyalar korunuyor.
- Çıkarma, Hızlı Bakış ve Finder'a sürüklemeden önce boş disk alanı denetleniyor.
- 7zz her işlemde `sandbox-exec` ile yalıtılmış çalışıyor: ağ kapalı, yalnızca işlemin hedef klasörüne yazabiliyor, arşiv okurken `~/.ssh` ya da Anahtar Zinciri gibi kişisel klasörleri okuyamıyor. Ayarlar › Gelişmiş bölümünden kapatılabilir; varsayılan açık.

### Düzeltilenler

- Uygulama kapalıyken Finder sağ tık menüsünden "Arhivar ile Buraya Çıkar" ya da "Arhivar ile Aç" seçilince "7-Zip bulunamadı" hatası veriyordu. Artık motor bulunana kadar bekleniyor.
- Doğru parola verildiğinde şifreli arşivdeki başka bir hata (ör. CRC) yanlışlıkla "parola yanlış" olarak gösterilebiliyordu.

### Değişenler

- İşlem göstergesi, işleme göre canlandırılan bir simgeyle "Açılıyor…" ve "Arşiv okunuyor…" durumlarını gösteriyor. Hareketi Azalt açıksa simge durağan kalıyor.

## [1.0.0] — 2026-10-17

İlk sürüm. macOS 26 (Tahoe) ve üstü; Apple Silicon ve Intel (evrensel).

### Eklenenler

- **Arşiv tarayıcı**
  - 7-Zip File Manager gibi **klasör görünümü**: çift tık ya da Return ile klasöre girme, ⌘↑ ile üst klasöre çıkma, tıklanabilir yol çubuğu
  - Açılır **ağaç görünümü**; iki görünüm arasında ⌘1 / ⌘2 ile geçiş
  - Sıralanabilir sütunlar (Ad, Boyut, Sıkıştırılmış, Değiştirilme, Yöntem), Finder simgeleri, şifreli öğelerde kilit işareti
  - Tüm alt klasörlerde arama, durum çubuğu, arşiv bilgisi paneli
  - Büyük arşivlerde hızlı listeleme (200 bin girdi yaklaşık 1,3 saniye)
- **Hızlı Bakış:** boşluk tuşu ya da ⌘Y ile seçili dosyanın önizlemesi
- **Finder'a sürükleme:** listeden sürüklenen dosya ya da klasör bırakıldığı anda çıkarılır
- **Açma:** 7z, ZIP, RAR, TAR, `.tar.gz`, `.tar.xz`, `.tar.bz2`, ISO, DMG ve 7-Zip'in açabildiği diğer biçimler
- **Çıkarma:** tümünü ya da seçilenleri çıkarma; konum seçimi, arşiv adıyla alt klasör, var olan dosyalar için davranış seçimi
- **Arşiv oluşturma:** 7z, ZIP, TAR, WIM, GZIP, BZIP2, XZ; sıkıştırma düzeyi, AES-256, dosya adı şifreleme (7z), parçalara bölme
- **Arşiv düzenleme (7z, ZIP, TAR, WIM):** açık klasöre dosya ekleme (araç çubuğu, menü ya da sürükle-bırak), silme (⌘⌫), yeniden adlandırma; şifreli arşivlerde parola ve ad şifrelemesi korunur
- **Finder sağ tık servisleri:** "Arhivar ile Buraya Çıkar" (birden çok arşiv sırayla, parola gerekirse sorarak), "Arhivar ile Aç", "Arhivar ile Sıkıştır"
- Parola sorma ve yeniden deneme, ilerleme göstergesi ve iptal, işlem sonrası bildirim
- **Diller:** Türkçe (varsayılan), English, Română; uygulama içinden anında değişir
- **Görünüm:** Otomatik, Açık, Koyu
- **Ayarlar** penceresi (Genel, Sıkıştırma, Gelişmiş) ve **Hakkında** penceresi (lisanslar, kılavuz, GitHub deposu)
- **Arhivar güncelleme denetimi:** GitHub Releases'te yeni sürüm varsa indirme bağlantısı sunar (menü, Ayarlar › Gelişmiş, isteğe bağlı açılış denetimi)
- **7-Zip güncelleyici** (`Scripts/update-7zip.sh`, `7-Zip-Guncelle.command`, uygulama içi):
  - github.com/ip7z/7zip adresinden son sürümü denetler, SHA-256 ile doğrular
  - Projedeki `Vendor/7-Zip` klasörünü ve/veya uygulama paketinin içindeki 7zz'yi günceller, paketi yeniden imzalar
  - Kurulan sürümü `Vendor/7-Zip/SOURCE.txt` dosyasına yazar (sürüm, adres, SHA-256)
- **Paketleme ve yayımlama** (yerel; GitHub Actions kullanılmaz):
  - `Scripts/package.sh` / `Paketle.command`: testler, evrensel `.app`, `.dmg`, `.zip` ve SHA-256 dosyası; 7-Zip paketin içindedir
  - `Scripts/release.sh` / `Yayimla.command`: paketler, `v<sürüm>` etiketini oluşturur, GitHub Releases'e yükler
  - `Scripts/set-version.sh`: sürümün tek kaynağı `Support/Info.plist`
- 7-Zip 26.04 `Vendor/7-Zip` altında projeye dahil
- 74 test: çekirdek, uygulama modeli ve gerçek 7zz ile entegrasyon
- README'de kurulum ve ilk açılış (ad-hoc imza) talimatı
- MIT lisansı ve üçüncü taraf bildirimleri (7-Zip: GNU LGPL + unRAR kısıtlaması)

### Güvenlik

- İnternetten inmiş bir arşivden çıkarılan dosyalar, arşivin karantina (Gatekeeper) işaretini taşır. "Kullanıcı onayladı" biti aktarılmaz. Bu, Çıkar, Buraya Çıkar, Hızlı Bakış, çift tıkla açma ve Finder'a sürükleme için geçerlidir.
- Çalıştırılabilir ya da sistemi değiştirebilen dosyalar (`.command`, `.pkg`, `.mobileconfig`, uzantısız Unix programları…) açılmadan önce onay istenir.
- Gerçek uzantıyı gizleyebilen görünmez ya da yön değiştiren karakterler (ör. U+202E) listede `⟦U+202E⟧` olarak ve uyarı simgesiyle gösterilir.
- Önizleme ve sürükleme dosyaları arşiv başına `0700` izinli bir klasörde tutulur. Bu klasör arşiv kapanınca, başka arşive geçince ve uygulamadan çıkınca silinir; önceki çalıştırmalardan kalanlar açılışta temizlenir.
- Arşiv yollarındaki `../` gibi kaçışlar geçici klasörün dışına çıkamaz. Seçili öğe adları joker karakter olarak yorumlanmaz.
- Uygulama, GitHub'a bağlanmadan önce ilk açılışta izin ister; açılış denetimi varsayılan olarak kapalıdır.
