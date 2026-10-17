# Changelog

Bu dosya [Keep a Changelog](https://keepachangelog.com/tr/1.1.0/) biçimini ve
[Semantic Versioning](https://semver.org/lang/tr/) kurallarını izler.

## [1.0.0] — 2026-10-17

İlk sürüm.

### Eklenenler

- **Arşiv tarayıcı**
  - 7-Zip File Manager gibi **klasör görünümü**: çift tık ya da Return ile klasöre girme, ⌘↑ ile üst klasöre çıkma, tıklanabilir yol çubuğu
  - Açılır **ağaç görünümü**; iki görünüm arasında ⌘1 / ⌘2 ile geçiş
  - Sıralanabilir sütunlar (Ad, Boyut, Sıkıştırılmış, Değiştirilme, Yöntem), Finder simgeleri, şifreli öğelerde kilit işareti
  - Tüm alt klasörlerde arama, durum çubuğu, arşiv bilgisi paneli
- **Hızlı Bakış:** boşluk tuşu ya da ⌘Y ile seçili dosyanın önizlemesi
- **Finder'a sürükleme:** listeden sürüklenen dosya ya da klasör bırakıldığı anda çıkarılır
- **Çıkarma:** tümünü ya da seçilenleri çıkarma; konum seçimi, arşiv adıyla alt klasör, var olan dosyalar için davranış seçimi
- **Arşiv oluşturma:** 7z, ZIP, TAR, WIM, GZIP, BZIP2, XZ; sıkıştırma düzeyi, AES-256, dosya adı şifreleme (7z), parçalara bölme
- **Arşiv düzenleme (7z, ZIP, TAR, WIM):** açık klasöre dosya ekleme (araç çubuğu, menü ya da sürükle-bırak), silme (⌘⌫), yeniden adlandırma; şifreli arşivlerde parola ve ad şifrelemesi korunur
- **Finder sağ tık servisleri:** "Arhivar ile Buraya Çıkar", "Arhivar ile Aç", "Arhivar ile Sıkıştır"
- Parola sorma ve yeniden deneme, ilerleme göstergesi ve iptal, işlem sonrası bildirim
- **Diller:** Türkçe (varsayılan), English, Română; uygulama içinden anında değişir
- **Görünüm:** Otomatik, Açık, Koyu
- **Ayarlar** penceresi (Genel, Sıkıştırma, Gelişmiş) ve **Hakkında** penceresi
- **7-Zip güncelleyici** (`Scripts/update-7zip.sh`, `7-Zip-Guncelle.command`, uygulama içi):
  - github.com/ip7z/7zip adresinden son sürümü denetler, SHA-256 ile doğrular
  - Projedeki `Vendor/7-Zip` klasörünü ve/veya uygulama paketinin içindeki 7zz'yi günceller, paketi yeniden imzalar
- **Paketleme** (`Scripts/package.sh`, `Paketle.command`): testler, evrensel (arm64 + x86_64) `.app`, `.dmg`, `.zip` ve SHA-256 dosyası; 7-Zip paketin içindedir
- 7-Zip 26.04 `Vendor/7-Zip` altında projeye dahil
- MIT lisansı ve üçüncü taraf bildirimleri (7-Zip: GNU LGPL + unRAR kısıtlaması)
