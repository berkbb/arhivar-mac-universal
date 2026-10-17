# Arhivar

macOS 26+ için 7-Zip (`7zz`) tabanlı, SwiftUI ve Liquid Glass ile yazılmış yerel arşiv yöneticisi. Evrensel (Apple Silicon + Intel) olarak derlenir; 7-Zip motoru paketin içinde gelir.

## Özellikler

- **Arşiv tarayıcı**
  - Klasör görünümü: çift tıkla klasöre girme, ⌘↑ ile üst klasöre çıkma, tıklanabilir yol çubuğu
  - Ağaç görünümü; ⌘1 ve ⌘2 ile geçiş
  - Sıralama, arama, Finder simgeleri, durum çubuğu, arşiv bilgisi
- **Hızlı Bakış:** boşluk tuşu
- **Finder'a sürükleme:** dosya ya da klasör bırakıldığı anda çıkarılır
- **Açma:** 7z, ZIP, RAR, TAR, GZ, XZ, ISO, DMG ve 7-Zip'in açabildiği diğer biçimler
- **Oluşturma:** 7z, ZIP, TAR, WIM, GZIP, BZIP2, XZ; sıkıştırma düzeyi, AES-256, dosya adı şifreleme, parçalara bölme
- **Düzenleme (7z, ZIP, TAR, WIM):** dosya ekleme (sürükle-bırak dahil), silme, yeniden adlandırma
- **Finder sağ tık menüsü:** Arhivar ile Buraya Çıkar / Aç / Sıkıştır
- **Diller:** Türkçe (varsayılan), English, Română
- **Görünüm:** Otomatik, Açık, Koyu
- **Pencereler:** Ayarlar ve Hakkında
- **7-Zip güncelleyici:** [github.com/ip7z/7zip](https://github.com/ip7z/7zip/releases) adresinden indirir, SHA-256 ile doğrular. Projedeki ve uygulamanın içindeki 7-Zip'i günceller.

## Hızlı başlangıç

Finder'da çift tıklayın:

- **`Paketle.command`**: testleri çalıştırır; evrensel `build/Arhivar.app` ile `dist/` altında `.dmg`, `.zip` ve SHA-256 dosyası üretir.
- **`7-Zip-Guncelle.command`**: `Vendor/7-Zip` klasörünü ve varsa `build/Arhivar.app` içindeki 7-Zip'i son sürüme günceller.

Terminalden aynı işler:

```bash
./Scripts/package.sh                  # test + evrensel .app + .dmg + .zip
./Scripts/package.sh --update-7zip    # önce 7-Zip'i güncelle, sonra paketle
./Scripts/build_app.sh                # yalnızca build/Arhivar.app
./Scripts/update-7zip.sh check        # yeni 7-Zip sürümü var mı?
./Scripts/update-7zip.sh install      # Vendor/7-Zip'i güncelle
./Scripts/update-7zip.sh install --app build/Arhivar.app
swift test                            # 42 test
```

Gereken: Xcode 26 veya üstü. Ayrıntılar için [DEVELOPMENT.md](DEVELOPMENT.md), sürüm notları için [CHANGELOG.md](CHANGELOG.md).

## Lisans

Arhivar'ın kodu MIT lisanslıdır ([LICENSE](LICENSE)). Paketteki 7-Zip, GNU LGPL ve unRAR kısıtlamasıyla dağıtılır ([THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)). Bu kısıtlama nedeniyle Arhivar RAR arşivlerini açabilir ama oluşturamaz.
