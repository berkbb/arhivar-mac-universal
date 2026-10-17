# Geliştirme

## Gereksinimler

- macOS 26 veya üstü
- Xcode 26 veya üstü (Swift 6.2+). Evrensel derleme için tam Xcode gerekir; Command Line Tools yetmez.

## Klasör yapısı

```
Arhivar/
├── Package.swift
├── Sources/
│   ├── ArhivarCore/          Arayüzden bağımsız, test edilen mantık
│   │   ├── CommandRunner.swift     Süreç çalıştırma, ilerleme, zaman aşımı, iptal, hata sınıflandırma
│   │   ├── ArchiveOptions.swift    Biçimler, düzeyler, 7zz argümanları (l, t, x, a)
│   │   ├── ArchiveEditing.swift    Düzenleme komutları (a, d, rn), AddPlan, ItemExtractor, sürükleme, gezinme yardımcıları
│   │   ├── ArchiveListing.swift    `7zz l -slt` ayrıştırıcı ve istatistikler
│   │   ├── ArchiveTree.swift       Düz listeden klasör ağacı, sıralama, arama
│   │   ├── Engine.swift            7zz bulma ve sürüm seçimi, güncelleyici sarmalayıcısı, ad yardımcıları
│   │   └── Localization.swift      AppLanguage, StringTable, LKey (tüm metin anahtarları)
│   └── Arhivar/              SwiftUI uygulaması (varsayılan yalıtım: MainActor)
│       ├── ArhivarApp.swift        Sahneler, menü komutları, AppDelegate
│       ├── AppModel.swift          Uygulama durumu ve tüm 7zz işlemleri
│       ├── AppSettings.swift       UserDefaults tercihleri, görünüm, yerelleştirme ve biçimlendirme
│       ├── FinderServices.swift    Finder sağ tık servisleri
│       └── Views/                  Görünümler
├── Resources/                {tr,en,ro}.lproj/Localizable.strings, ServicesMenu.strings, AppIcon.icns
├── Support/Info.plist        Paket bilgisi, belge türleri, NSServices
├── Scripts/                  build_app.sh, package.sh, update-7zip.sh, make_icon.swift
├── Vendor/7-Zip/             Pakete eklenen 7zz, lisansı ve kılavuzu
├── Tests/ArhivarCoreTests/   Çekirdek birim ve entegrasyon testleri
├── Tests/ArhivarAppTests/    Uygulama modeli (AppModel) akış testleri
├── Paketle.command           Çift tıkla paketleme
├── Yayimla.command           Çift tıkla GitHub Releases'e yayımlama
└── 7-Zip-Guncelle.command    Çift tıkla 7-Zip güncelleme
```

## Mimari

- Arhivar 7-Zip'e bağlanmaz. Değiştirilmemiş `7zz` programını ayrı bir süreç olarak çalıştırır (LGPL uyumu için de bu yol seçildi).
- Tüm 7zz argümanları `SevenZipCommand` tarafından üretilir ve test edilir. Dosya adları her zaman `--` ayracından sonra gelir. Seçili öğelerle çalışırken `-spd` verilir, böylece adlardaki `*` ve `?` joker karakter sayılmaz.
- `CommandRunner`:
  - stdin'i boş bırakır: parola istenirse 7zz takılmaz, hata verir ve bu hata `wrongPassword` olarak sınıflandırılır.
  - `-bsp1` çıktısındaki yüzdeleri okuyup ilerleme olarak bildirir.
  - Görev iptal edilince süreci sonlandırır.
- Arşiv listesi `ListingParser` ile okunur. `ArchiveTree`, arşivde açıkça bulunmayan ara klasörleri de oluşturur.
- **Düzenleme:**
  - `7zz rn` ve `7zz d` klasör yolunu önek olarak eşleştirir. Bu yüzden tek komut, açık klasör kaydı olmasa bile alt öğelerin hepsini kapsar (testlerle doğrulandı).
  - Alt klasöre ekleme: `AddPlan` dosyaları geçici bir klasörde hedef yol yapısına kopyalar (APFS'de anlık) ve 7zz'yi orada göreli yollarla çalıştırır.
- **Karantina:** `Quarantine.propagate` arşivin `com.apple.quarantine` değerini, çıkarmanın başladığı andan sonra yazılmış (ctime) öğelere uygular. "Kullanıcı onayladı" biti (0x40) temizlenir. 7zz bunu kendisi yapmaz.
- **Açma güvenliği:** `OpenSafety.executableKind` riskli türleri ve çalıştırma bitini, `hasDeceptiveCharacters` görünmez ve yön değiştiren karakterleri bulur.
- **Geçici dosyalar:** `$TMPDIR/Arhivar/session-<UUID>` (0700) arşiv başına tutulur ve arşiv kapanınca silinir. `ItemExtractor.sweepStale` açılışta 6 saatten eski klasörleri temizler.
- **Liste ayrıştırma:** satırlar bayt düzeyinde bölünür, blok alanları `Substring` olarak tutulur ve tarih `ListingParser.parseTimestamp` ile okunur (DateFormatter kullanılmaz). Yaz saati geçişlerinde sonuç DateFormatter ile aynıdır; bunu testler denetler.
- **Parolalar:** hiçbir zaman argüman olarak verilmez. `SevenZipCommand.passwordInput` parolayı 7zz'nin stdin'ine yazar; `l`, `t`, `x`, `d` ve `rn` parolayı kendileri sorar, `a` için çıplak `-p` verilir. Parola bilinmiyorsa stdin boştur ve 7zz `Break signaled` ile durur; bu "parola gerekli" olarak sınıflandırılır.
- **Hazırlık klasörüyle çıkarma:** `StagedExtraction` hedefle aynı birimde bir klasör açar (`itemReplacementDirectory`; olmazsa gizli `.arhivar-staging-*`). 7zz oraya çıkarır, ardından üzerine yazma kuralı Swift'te uygulanarak hedefe taşınır. Hedefteki sembolik bağlantıların içine yazılmaz.
- **Disk alanı:** `DiskSpace` / `InsufficientSpaceError`, seçimin açılmış boyutunu `volumeAvailableCapacityForImportantUsage` değerinden 1 GB pay düşülmüş alanla karşılaştırır.
- **Sandbox:** `SandboxProfile.forOperation` her işlem için SBPL kuralları üretir ve `CommandRunner` 7zz'yi `/usr/bin/sandbox-exec -p … -D W0=…` ile başlatır. Yollar `realpath(3)` ile çözülür, çünkü `URL.resolvingSymlinksInPath()` `/private` önekini siler ve kural eşleşmez. Kişisel klasör yasağı yalnızca arşiv okunurken (liste, test, çıkarma, silme, yeniden adlandırma) uygulanır; oluşturma ve eklemede kullanıcı kaynakları seçtiği için uygulanmaz.
- **Soğuk açılış:** Finder servisleri ve "Birlikte Aç" uygulama açılırken hemen gelebilir. `perform` motor henüz denetlenmediyse "Açılıyor…" gösterip `ensureEngine()` sonucunu bekler.
- **Motor seçimi:** Ayarlarda özel bir 7zz seçildiyse o kullanılır. Yoksa uygulama paketindeki, yedek klasördeki (`~/Library/Application Support/Arhivar/engine`) ve Homebrew'daki kopyalar çalıştırılıp **en yeni sürüm** seçilir.

## Metin ekleme (yerelleştirme)

1. `Sources/ArhivarCore/Localization.swift` içindeki `LKey` enum'una anahtarı ekleyin.
2. Aynı anahtarı **üç dosyaya da** ekleyin: `Resources/tr.lproj`, `en.lproj` ve `ro.lproj` altındaki `Localizable.strings`.
3. Biçim belirteçleri (`%@`, `%ld`, `%1$@`) üç dilde aynı olmalıdır. Sıra dile göre değişiyorsa sıralı belirteç (`%1$…`) kullanın.

`swift test` eksik ya da fazla anahtarı ve uyuşmayan belirteçleri yakalar. Görünümlerde metin her zaman `settings.t(.anahtar)` ile alınır; sabit metin yazılmaz.

## Derleme, test, paketleme

```bash
swift build                      # hızlı geliştirme derlemesi
swift test                       # 89 test (ArhivarCoreTests + ArhivarAppTests); gerçek 7zz testleri Vendor/7-Zip/7zz kullanır
./Scripts/build_app.sh           # evrensel build/Arhivar.app (ARCHS=native ile yalnızca bu Mac)
./Scripts/package.sh             # testler + .app + dist/Arhivar-<sürüm>.{dmg,zip,sha256}
./Scripts/package.sh --update-7zip   # önce Vendor/7-Zip'i güncelle, sonra paketle
```

Finder'dan aynı işler için `Paketle.command` ve `7-Zip-Guncelle.command` dosyalarına çift tıklanabilir.

Sürüm numarası `Support/Info.plist` içindeki `CFBundleShortVersionString` alanından okunur. Yeni sürümde bu alanı ve `CHANGELOG.md` dosyasını güncelleyin.

## Sürüm yayımlama (yerel)

Dağıtım yalnızca GitHub Releases üzerinden yapılır. GitHub Actions kullanılmaz; yayım bu Mac'te `Scripts/release.sh` ya da `Yayimla.command` ile yapılır.

1. `./Scripts/set-version.sh 1.1.0`: Info.plist'teki sürümü değiştirir ve derleme numarasını bir artırır.
2. `CHANGELOG.md` içindeki `## [Yayımlanmadı]` başlığını `## [1.1.0] — <tarih>` olarak değiştirin. Betik sürüm notlarını bu bölümden alır.
3. Değişiklikleri commit edip `git push` ile gönderin.
4. `./Scripts/release.sh --dry-run`, ardından `./Scripts/release.sh` (ya da `--draft`).

`release.sh` şu adımları izler:
- Çalışma kopyasının temiz olduğunu, `main` dalında bulunulduğunu, yerel dalın `origin/main` ile aynı olduğunu ve etiketin daha önce kullanılmadığını denetler.
- `package.sh` çalıştırır.
- `v<sürüm>` etiketini oluşturup gönderir.
- `gh release create` ile `.dmg`, `.zip` ve `.sha256` dosyalarını yükler.

Depo adının tek kaynağı Info.plist'teki `ArhivarRepository` anahtarıdır. Hakkında penceresi ve uygulamanın güncelleme denetimi de bu anahtarı kullanır.

**Gizlilik:** Uygulama ilk açılışta izin ister. İzin verilirse açılışta GitHub API'sinden yalnızca herkese açık sürüm listeleri istenir (`api.github.com/repos/<depo>/releases/latest` ve `ip7z/7zip`). Depo özelken Arhivar denetimi "henüz herkese açık sürüm yok" sonucunu verir.

## 7-Zip güncelleme akışı

`update-7zip.sh` hedefi şöyle seçer:

| Nereden çalıştı | Güncellenen |
| --- | --- |
| Projeden (`Scripts/`) | `Vendor/7-Zip/` |
| Uygulamanın içinden (`Arhivar.app/Contents/Resources/`) | O uygulamanın `Contents/MacOS/7zz` dosyası; ardından paket ad-hoc olarak yeniden imzalanır |
| Uygulama paketi yazılamıyorsa | `~/Library/Application Support/Arhivar/engine/` |
| `--dest` / `--app` verildiyse | Verilen hedefler (birden fazla olabilir) |

Doğrulama adımları:
1. GitHub API'sinin verdiği SHA-256 özeti indirilen dosyayla karşılaştırılır.
2. Dosyanın Mach-O olup olmadığına bakılır.
3. İndirilen `7zz`'nin bildirdiği sürüm etiketle karşılaştırılır.
4. Dosya önce geçici adla kopyalanır, sonra tek adımda yerine taşınır; yarım kurulum kalmaz.

## Finder servisleri

Servisler `Support/Info.plist` içindeki `NSServices` altında tanımlıdır; başlıklar `ServicesMenu.strings` dosyalarından gelir. Uygulama ilk açıldığında `NSUpdateDynamicServices()` ile kaydolurlar. Finder'da sağ tık › **Hızlı Eylemler** ya da **Servisler** altında görünürler. Görünmüyorlarsa Sistem Ayarları › Klavye › Klavye Kısayolları › Servisler bölümünden açılabilirler.

## Bilinen sınırlar ve doğrulanmamış noktalar

- Arayüz bu ortamda ekran görüntüsüyle doğrulanamadı; uygulamanın açıldığı ve hatasız çalıştığı denetlendi. Finder'a sürükleme, Hızlı Bakış ve servis menüsü elle denenmeli.
- `update-7zip.sh install --force` 2026-10-17 tarihinde 26.04 ile hem klasör hedefine hem bir uygulama kopyasına uygulandı. İndirme, SHA-256, kurulum ve yeniden imzalama doğrulandı. Gerçekten daha yeni bir sürüme geçiş henüz yaşanmadı.
- Uygulama ad-hoc imzalı ve notarize edilmemiş. Başka bir Mac'te ilk açılışta Gatekeeper onayı gerekir. Dağıtım için Developer ID imzası ve notarization eklenmelidir.
- RAR yalnızca açılabilir; unRAR lisansı RAR oluşturmayı yasaklar.
- Yerinde düzenleme 7z, ZIP, TAR ve WIM ile sınırlıdır; bölünmüş arşivler düzenlenemez.
