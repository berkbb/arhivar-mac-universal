# Code-Graph Wiki — Indexed Symbols & Impact Map

> **Memory Category:** TencentDB Code-Graph Memory Asset  
> **Scope:** Module boundaries, key types, call hierarchy, and cross-file modification impact map.

---

## 1. Module & File Index

### Target: `ArhivarCore` (`Sources/ArhivarCore/`)

| File | Primary Symbols | Responsibilities |
| :--- | :--- | :--- |
| `CommandRunner.swift` | `ProcessResult`, `SevenZipError`, `ProgressParser`, `CommandRunner`, `ProcessBox`, `RunState` | Async subprocess execution, `stdin` pipe feeding, `-bsp1` progress parsing, `SIGTERM` + 2s `SIGKILL` escalation, exit code classification |
| `ArchiveOptions.swift` | `ArchiveFormat`, `CompressionLevel`, `OverwriteMode`, `SubfolderMode`, `VolumeSize`, `CreateOptions`, `ExtractOptions`, `SevenZipCommand` | Format capabilities, CLI switch generation for `list`, `test`, `extract`, `create`, and two-step `.tar.*` (`tarStage`, `compressTarStage`) |
| `ArchiveEditing.swift` | `ArchiveCapabilities`, `SevenZipCommand.add/delete/rename`, `AddPlan`, `ItemExtractor`, `ArchiveItemTransfer`, `ArchiveTree` navigation helpers | In-place archive editing, `0o700` subfolder staging (`AddPlan`), duplicate basename detection, per-session item extraction, Finder drag-out (`Transferable`) |
| `ArchiveListing.swift` | `ArchiveEntry`, `ArchiveInfo`, `ArchiveListing`, `ListingParser`, `ArchiveStatistics`, `Int64.saturatingAdding` | Zero-allocation byte-level `7zz l -slt` parser, civil-calendar timestamp parser (`daysFromCivil`), path normalization (`normalizedPath`), saturating statistics |
| `ArchiveTree.swift` | `ArchiveNode`, `ArchiveTree` (`build`, `rawPrefix`, `sorted`, `search`, `index`, `nameComparator`) | Synthesizing hierarchical folder trees from flat entries, deriving raw `archivePath` for implicit folders, `.localizedStandard` sorting |
| `StagedExtraction.swift` | `StagedExtraction` (`makeStagingDirectory`, `contentRoot`, `destination`, `merge`, `secureSymlinks`), `DiskSpace`, `InsufficientSpaceError` | Same-volume atomic staging, symlink escape removal & relative rewriting, `.usingNewMetadataOnly` replacement, smart subfolder routing, pre-flight free space checks |
| `Sandbox.swift` | `SandboxProfile`, `CommandRunner.sandboxed(_:)` | `/usr/bin/sandbox-exec` SBPL profile generation, `realpath(3)` resolution, personal data directory protection |
| `Quarantine.swift` | `Quarantine` (`value`, `sanitizedValue`, `set`, `ensure`, `propagate`) | macOS Gatekeeper `com.apple.quarantine` extended attribute propagation (`XATTR_NOFOLLOW`) and bitmask sanitization (`& ~0x0040`) |
| `OpenSafety.swift` | `OpenSafety` (`executableKind`, `hasDeceptiveCharacters`, `visibleName`) | Executable/script UTI & permission detection, Unicode bidirectional/invisible filler spoof detection |
| `Checksums.swift` | `Checksum`, `SevenZipCommand.hash(file:)`, `ChecksumParser` | `7zz h` CRC32, SHA-256, and BLAKE2sp command builder and output parser |
| `Engine.swift` | `EngineLocator`, `EngineUpdateResult`, `EngineUpdater`, `ArchiveNaming` | Discovering and version-ranking `7zz` binaries, wrapping `update-7zip.sh`, split volume resolution (`firstVolume`), archive base/suggested naming |
| `AppUpdate.swift` | `AppRelease`, `AppUpdateChecker` | GitHub Releases API parser and semantic version comparison for Arhivar self-update checks |
| `Localization.swift` | `AppLanguage`, `StringTable`, `LKey` | Runtime-switchable localization engine and exhaustive key enumeration (`tr`, `en`, `ro`) |

---

### Target: `Arhivar` (`Sources/Arhivar/`)

| File | Primary Symbols | Responsibilities |
| :--- | :--- | :--- |
| `ArhivarApp.swift` | `ArhivarApp`, `AppDelegate`, `AppCommands` | SwiftUI scenes (`main`, `about`, `Settings`), menu bar shortcuts (`⌘C`, `⌘V`, `⌘A`, `⌘↓`, `⌘↑`, `⌘I`, `⌘E`), `NSServices` registration |
| `AppModel.swift` | `AppModel`, `ArchiveContext`, `PendingAction`, `EngineStatus`, `UpdateState`, `AppUpdateState` | Central `@Observable` state machine, all async `7zz` workflows, nested archive stack (`archiveStack`), password retry queue, Finder service queue (`serviceQueue`) |
| `AppSettings.swift` | `AppSettings`, `AppAppearance`, `ExtractLocation` | `UserDefaults`-backed preferences, legacy `extractIntoSubfolder` migration, locale-aware byte/date/percent formatting |
| `FinderServices.swift` | `FinderServices` | macOS `NSServices` handler for `extractHere`, `openArchive`, and `compress` |
| `Views/ContentView.swift` | `ContentView`, `InfoToolbarButton`, `EditDialogs` | `NavigationSplitView` shell, toolbar, drop target, alerts, sheets, and edit confirmation dialogs |
| `Views/ArchiveBrowserView.swift` | `ArchiveBrowserView`, `NameCell`, `PathBar`, `StatusBarView`, `ArchiveInfoView`, `ProgressOverlay`, `ToastView`, `FileIcons` | Hierarchical `Table`, breadcrumb path bar with nested archive crumbs and folder drop targets, status bar, info popover, bounded icon cache |
| `Views/CreateArchiveSheet.swift` | `CreateArchiveSheet`, `PasswordSheet` | New Archive modal form, duplicate source basename disambiguation, validation messages, password unlock sheet |
| `Views/WelcomeView.swift` | `WelcomeView`, `EngineStatusView`, `UpdateBanner` | Home drop zone, `7zz` engine status, and update banners for both Arhivar and 7-Zip |
| `Views/SettingsView.swift` | `SettingsView`, `GeneralSettingsView`, `CompressionSettingsView`, `AdvancedSettingsView` | Preferences UI (language, appearance, extraction subfolder/overwrite rules, compression defaults, custom engine, sandbox toggle, reset) |
| `Views/SidebarView.swift` | `SidebarView` | Home navigation and recent archives list |
| `Views/AboutView.swift` | `AboutView` | Version info, credits, license/manual/repository links |

---

### Build Scripts & Bundle Resources (`Scripts/`, `Support/`, `Resources/`)

| File | Primary Symbols / Artifacts | Responsibilities |
| :--- | :--- | :--- |
| `Scripts/make_icon.swift` | `drawIcon`, `Resources/AppIcon.icns` | Programmatic CoreGraphics generator for the macOS app icon (16px to 1024px) |
| `Scripts/make_document_icons.swift` | `Family`, `zipper`, `box`, `books`, `layers`, `disc`, `drawDocument`, `Resources/DocumentIcons/{zip,7z,rar,tar,disk,archive}.icns` | Programmatic CoreGraphics generator for the six Finder document icon families (up to 512px, ~1.7 MB total, zero SF Symbols) |
| `Support/Info.plist` | `CFBundleDocumentTypes`, `NSServices`, `UTImportedTypeDeclarations` | Declares six document icon families (`LSHandlerRank = Alternate`), Finder context-menu services, and 14 custom archive UTIs |

---

## 2. Change Impact Map

- **Adding a UI String:** Must update `LKey` in `Sources/ArhivarCore/Localization.swift` **and** all three `Resources/{tr,en,ro}.lproj/Localizable.strings` files (`RunnerAndLocalizationTests` enforces 100% key and format-specifier parity).
- **Adding a Supported Archive Format:** Update `ArchiveFormat` (`ArchiveOptions.swift`), `ArchiveNaming.archiveExtensions` (`Engine.swift`), `Support/Info.plist` (`CFBundleDocumentTypes` in exactly one of the six icon families, `NSServices`, `UTImportedTypeDeclarations`), and verify with `DocumentIconTests`, `CommandTests`, and `RoadmapTests`.
- **Modifying `ArchiveNode` or `ArchiveBrowserView` Table Columns:** Never introduce `@Environment` lookups inside `NameCell` or any table cell view; verify with `BrowserViewTests`.
- **Modifying `AppSettings` Keys:** Add new `UserDefaults` keys to `AppSettings.Key.all` so `resetAll()` removes them cleanly (`resetRemovesAllPreferences` test).
