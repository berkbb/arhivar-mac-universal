# Code-Graph Wiki — Indexed Symbols & Impact Map

> **Memory Category:** TencentDB Code-Graph Memory Asset  
> **Scope:** Module boundaries, key types, call hierarchy, and cross-file modification impact map.  
> **Generated from:** `graphify-out/GRAPH_REPORT.md` and `graphify-out/graph.json` (graphifyy 0.9.101, local tree-sitter AST, `--code-only`, no LLM backend). Sections 3–4 are hand-maintained and checked against the graph.  
> **Built at commit:** `d5c1455` on 2026-11-04.  
> **Regenerate:** `GRAPHIFY_NO_TIPS=1 GRAPHIFY_QUERY_LOG_DISABLE=1 GRAPHIFY_BACKEND=off graphify extract . --code-only`, then `GRAPHIFY_BACKEND=off graphify cluster-only . --no-label`, then update sections 1–2 from the new report. `graphify-out/` is git-ignored.

---

## 1. Graph Summary

- **Corpus:** 89 code files (80 Swift, 7 shell, 1 C, 1 header) → 2,281 nodes, 6,454 edges, 104 Leiden communities (28 thin ones omitted from the report).
- **Edge provenance:** 88% `EXTRACTED`, 12% `INFERRED` (798 edges, average confidence 0.85), 0% `AMBIGUOUS`.
- **Edge relations:** `calls` 2,739 · `references` 1,472 · `method` 927 · `contains` 434 · `case_of` 426 · `imports` 238 · `implements` 180 · `defines` 23 · `inherits` 15.
- **Module dependencies:** `Arhivar` → `ArhivarCore`; `ArhivarQuickLook` → `ArhivarCore`; `ArhivarCore` → `CLibArchive` (system `libarchive`, Quick Look listing only). `ArhivarCore` imports no app target. Import cycles: none.
- **Not indexed:** `Vendor/` (third-party 7-Zip), Markdown docs (`--code-only`), `.strings` tables, `Info.plist`, and build outputs (see `.graphifyignore`).

## 2. Hub Nodes (most connected)

| Rank | Node | Edges | Why it is a hub |
| :--- | :--- | ---: | :--- |
| 1 | `LKey` | 339 | Every user-facing string; a new case needs all three `.strings` tables |
| 2 | `AppModel` | 192 | App state machine: open, browse, extract, edit, drag, password, update |
| 3 | `Fixture` | 93 | `ArhivarAppTests` helper: an `AppModel` with its own temporary folder, `UserDefaults` suite and the real `7zz` |
| 4 | `AppModelTests` | 88 | App-flow test suite |
| 5 | `CreateOptions` | 71 | Archive creation switches passed to `SevenZipCommand` |
| 6 | `AppSettings` | 65 | `UserDefaults`-backed preferences (`Key.all` for reset) |
| 7 | `AppLog` | 53 | Log window, log file and unified log subsystem |
| 8 | `ArchiveListing` | 50 | Parsed `7zz l -slt` listing (filled by `ListingParser`) and its password probe item |
| 9 | `ArhivarCore` | 50 | Module imported by the app, the Quick Look extension and tests |
| 10 | `CommandRunner` | 47 | Sandboxed `7zz` process runner; `graphify affected "CommandRunner"` lists its callers |

Before changing a hub, run `graphify affected "<node>"` to see what depends on it.

---

## 3. Module & File Index

### Target: `ArhivarCore` (`Sources/ArhivarCore/`)

| File | Primary Symbols | Responsibilities |
| :--- | :--- | :--- |
| `PreviewListing.swift` | `PreviewListing`, `PreviewListing.Content` | Quick Look listing decision: 7zz when it can launch, otherwise libarchive; `content` returns `.locked` for any password-protected archive so names are never shown |
| `LibArchiveReader.swift` | `LibArchiveReader`, `LibArchiveReader.ReadError` | In-process, read-only archive listing through system libarchive (`CLibArchive` target) for the Quick Look sandbox; raw-stream fallback, encrypted-header detection, `maxEntries` cap |
| `CommandRunner.swift` | `ProcessResult`, `SevenZipError` (`reportsWrongPassword` matches 7-Zip's message position only; `sandboxUnavailable` = fail-closed when `sandbox-exec` cannot run), `ProgressParser`, `CommandRunner`, `ProcessBox`, `RunState` | Async subprocess execution, `stdin` pipe feeding, `-bsp1` progress parsing, `SIGTERM` + 2s `SIGKILL` escalation, exit code classification |
| `ItemListFile.swift` | `ItemListFile` (`fitting`, `Fitted`, `isListable`, `directByteLimit`) | Keeps `7zz` under ARG_MAX (1 MiB args + env): above 256 KiB of item names for `a`/`d`/`e`/`t`/`x`, writes a `0600` list file passed as `-scsUTF-8 -i@file` before `--`; names 7-Zip would trim or unquote stay direct. `CommandRunner.run` applies it to every command and adds the file to the sandbox `readableFiles` |
| `ExtractHandoff.swift` | `ExtractHandoff` (`Request`, `Status`, `request(in:)`, `openEvent(for:requestID:)`, `userInfo(_:)`, `statuses(from:)`, `post(requestID:statuses:)`, `infoKey`, `requestKeyword`) | Background Extract Here contract for other apps: marked `odoc` parsing (file references only, event order kept), path-free result notification payload, Info.plist discovery key (see domain wiki §4) |
| `ArchiveOptions.swift` | `ArchiveFormat`, `CompressionLevel`, `OverwriteMode`, `SubfolderMode`, `VolumeSize`, `CreateOptions`, `ExtractOptions`, `SevenZipCommand` | Format capabilities, CLI switch generation for `list`, `test`, `extract`, `create`, and two-step `.tar.*` (`tarStage`, `compressTarStage`) |
| `ArchiveEditing.swift` | `ArchiveCapabilities` (`isEditable`, `supportsEditing`, `isWritable`), `SevenZipCommand.add/delete/rename`, `AddPlan` (`NothingToArchiveError`), `SpecialFiles`, `ItemExtractor` (`SymbolicLinkError`), `DragBatch`, `ArchiveItemTransfer`, `ArchiveTree` navigation helpers | In-place archive editing (multi-volume edit guard), `0o700` subfolder staging (`AddPlan`, skips FIFOs/sockets, refuses special-only sources), FIFO/socket/device exclusion (`-x!`, walks symlinked folders when links are followed), duplicate basename detection, per-target link containment and placeholder cleanup in item extraction, Finder drag-out (`Transferable`; rows dragged together are extracted in one `7zz` run by a shared `DragBatch`, started by `DragBatch.prefetch()` when the drag begins so the drop request does not block on `7zz`; failures are reported once, only on a drop request) |
| `ArchiveListing.swift` | `ArchiveEntry` (`isSymbolicLink`), `ArchiveInfo`, `ArchiveListing`, `ListingParser`, `ArchiveStatistics`, `Int64.saturatingAdding` | Zero-allocation byte-level `7zz l -slt` parser (last `----------` marker = header boundary, brace-delimited comments), civil-calendar timestamp parser (`daysFromCivil`), path normalization (`normalizedPath`, drops `.`/`..`), duplicate-aware saturating statistics |
| `ArchiveTree.swift` | `ArchiveNode`, `ArchiveTree` (`build`, `rawPrefix`, `sorted`, `search`, `index`, `nameComparator`) | Synthesizing hierarchical folder trees from flat entries, deriving raw `archivePath` for implicit folders, `.localizedStandard` sorting |
| `StagedExtraction.swift` | `StagedExtraction` (`makeStagingDirectory`, `contentRoot`, `destination`, `merge`, `secureSymlinks(in:extractionRoot:)`, `removeLinkPlaceholders`, `removeTree`, `installArchive`), `OwnerAccess` (`add`, `granting`, `addTree`, `restore`), `DiskSpace`, `InsufficientSpaceError` | Same-volume atomic staging, symlink escape removal & relative rewriting against the moved content, 7zz dangerous-link placeholder removal, read-only / unenterable target and staged folder merging, atomic archive install (stale `.00N` cleanup), smart subfolder routing, pre-flight free space checks |
| `Sandbox.swift` | `SandboxProfile`, `CommandRunner.sandboxed(_:)` | `/usr/bin/sandbox-exec` SBPL profile generation, `realpath(3)` resolution, personal data directory protection |
| `Quarantine.swift` | `Quarantine` (`value`, `derivedValue`, `set`, `ensure`, `propagate`) | macOS Gatekeeper `com.apple.quarantine` extended attribute propagation (`XATTR_NOFOLLOW`, temporary owner access on `0555`/`0444`/`0111`/`0000` items and folders) and bitmask sanitization (`& ~0x0040`) |
| `OpenSafety.swift` | `OpenSafety` (`executableKind`, `hasDeceptiveCharacters`, `visibleName`) | Executable/script UTI & permission detection, Unicode bidirectional/invisible filler spoof detection |
| `Checksums.swift` | `Checksum`, `SevenZipCommand.hash(file:)`, `ChecksumParser` | `7zz h` CRC32, SHA-256, and BLAKE2sp command builder and output parser |
| `Engine.swift` | `EngineLocator`, `EngineUpdateResult`, `EngineUpdater`, `ArchiveNaming` | Discovering and version-ranking `7zz` binaries, wrapping `update-7zip.sh`, split volume resolution (`firstVolume`, incl. old-style RAR `.r00`…`.r99` and split ZIP `.z01`…`.z99`), archive base/suggested naming (strips `.part01` multi-part suffixes) |
| `AppUpdate.swift` | `AppRelease`, `AppUpdateChecker` (`parse(_:repository:)`, `isReleaseURL`), `UpdateSignature`, `UpdateChecksums` | GitHub Releases API parser, semantic version comparison, Ed25519 signature verification (`CryptoKit`), and SHA-256 checksum validation for Arhivar self-update releases |
| `Localization.swift` | `AppLanguage`, `StringTable`, `LKey` | Runtime-switchable localization engine and exhaustive key enumeration (`tr`, `en`, `ro`) |
| `AppLog.swift` | `AppLog` (`Level`, `Category`, `Entry`, `shared`, `observe`, `clear`, `describe`, `isCancellation`, `milliseconds(since:)`) | Single logging entry point: unified log (`Logger`, subsystem `com.babadogantech.arhivar`, public summary / private detail), user-only rotating file `~/Library/Logs/Arhivar/Arhivar.log` (+ `Arhivar.1.log`, 1 MiB), in-memory ring (2,000) reloaded from the files at launch; memory-only under `swift test` |

---

### Target: `Arhivar` (`Sources/Arhivar/`)

| File | Primary Symbols | Responsibilities |
| :--- | :--- | :--- |
| `ArhivarApp.swift` | `ArhivarApp`, `AppDelegate`, `AppCommands` | SwiftUI scenes (`main`, `about`, `Settings`), menu bar shortcuts (`⌘C`, `⌘V`, `⌘A`, `⌘↓`, `⌘↑`, `⌘I`, `⌘E`), `NSServices` registration, marked `odoc` dispatch to `extractHereInBackground` (`ExtractHandoff.request(in:)`), user activity (plain open, reopen, activation, services) and launch kind fed to `HandoffAutoQuit` |
| `AppModel.swift` | `AppModel`, `ArchiveContext`, `PendingAction`, `EngineStatus`, `UpdateState`, `AppUpdateState`, `AppModel.HandoffBatch` | Central `@Observable` state machine, async `7zz` workflows, off-main tree building, debounced async search (`searchTask`, `isSearching`), nested archive stack (`archiveStack` with cached trees), password retry queue, Finder service queue (`serviceQueue`), background Extract Here requests (`extractHereInBackground`, `handoffBatches`, `reportHandoff`, `onHandoffsSettled`, `handoffAutoQuitActivity`) |
| `AppSettings.swift` | `AppSettings`, `AppAppearance`, `ExtractLocation`, `QuickLookShortcut` | `UserDefaults`-backed preferences, legacy `extractIntoSubfolder` migration, locale-aware byte/date/percent formatting, customizable Quick Look shortcuts (`spaceAndCmdY`, `spaceOnly`, `cmdYOnly`) |
| `LegacyIdentityMigration.swift` | `LegacyIdentityMigration` (`legacyContentTypes(in:)`, `removeLegacyRecords(home:legacyDomain:)`, `run()`, `doneKey`) | One-time `net.babadogan.arhivar` → `com.babadogantech.arhivar` migration at launch: moves Launch Services default-app choices (restores Finder document icons) via `NSWorkspace.setDefaultApplication(at:toOpen:)`, re-runs `AppSettings.migrateLegacyDefaults`, then deletes the legacy preferences domain and `Caches`/`HTTPStorages`/`Saved Application State`/`WebKit`/`Application Support` items in a background task; the old Quick Look container is left alone (app-data protection). `legacyIdentityMigrated` marks it done |
| `FinderServices.swift` | `FinderServices` | macOS `NSServices` handler for `extractHere`, `openArchive`, and `compress`; `onUserRequest` marks the launch as the user's |
| `HandoffAutoQuit.swift` | `HandoffAutoQuit` (`Launch`, `Engagement`, `Activity`, `shouldQuit(launch:activity:)`, `defaultGracePeriod`, `handoffRequested()`, `userEngaged(_:)`, `launchFinished(isDefaultLaunch:)`, `handoffsSettled()`, `pendingQuit`) | Quits a background-only launch 4 s after the last hand-off result unless the user engaged or something is still pending (Descarcator item 506); sleep, activity and terminate are injected for tests |
| `QuickLookCoordinator.swift` | `QuickLookCoordinator` | Native AppKit `QLPreviewPanel.shared()` singleton coordinator replacing SwiftUI `.quickLookPreview` to prevent rapid toggle crash |
| `Views/ContentView.swift` | `ContentView`, `InfoToolbarButton`, `EditDialogs` | `NavigationSplitView` shell, toolbar, drop target, alerts, sheets, and edit confirmation dialogs |
| `Views/ArchiveBrowserView.swift` | `ArchiveBrowserView`, `NameCell`, `PathBar`, `StatusBarView`, `ArchiveInfoView`, `ProgressOverlay`, `ToastView`, `FileIcons` | Hierarchical `Table` (`rows:` builder with `OutlineGroup` + `TableRow.draggable` for multi-row drag to Finder), breadcrumb path bar with nested archive crumbs and folder drop targets, status bar, info popover, bounded icon cache |
| `Views/CreateArchiveSheet.swift` | `CreateArchiveSheet`, `PasswordSheet` | New Archive modal form, duplicate source basename disambiguation, validation messages, password unlock sheet |
| `Views/WelcomeView.swift` | `WelcomeView`, `EngineStatusView`, `UpdateBanner` | Home drop zone, `7zz` engine status, and update banners for both Arhivar and 7-Zip |
| `Views/SettingsView.swift` | `SettingsView`, `GeneralSettingsView`, `ShortcutsSettingsView`, `CompressionSettingsView`, `AdvancedSettingsView` | Preferences UI (language with restart recommendation alert and menubar notice, appearance, shortcuts configuration, extraction subfolder/overwrite rules, compression defaults, custom engine, sandbox toggle, reset) |
| `Views/SidebarView.swift` | `SidebarView` | Home navigation and recent archives list |
| `Views/AboutView.swift` | `AboutView` | Version info, credits, license/manual/repository links |
| `LogStore.swift` | `LogStore` (`Scope`, `visibleEntries`, `hasFile`, `revealFile`, `openInConsole`) | Main-actor mirror of `AppLog` for the Log window; coalesced refresh on `AppLog.observe`, All/Problems scope and search filter |
| `Views/LogView.swift` | `LogView`, `AppLog.Level.titleKey/systemImage/tint`, `AppLog.Category.titleKey` | Console-style Log window (Window › Show Log, ⌥⌘L): time/type/category/process/message table, segmented scope, search, detail pane, Copy, Clear, Show in Finder, Open in Console |

---

### Target: `ArhivarQuickLook` (`Sources/ArhivarQuickLook/`)

| File | Primary Symbols | Responsibilities |
| :--- | :--- | :--- |
| `main.swift` | `QuickLookMain`, `NSExtensionMain` | App Extension process entry point invoking `NSExtensionMain()` |
| `PreviewViewController.swift` | `PreviewViewController`, `QLPreviewingController` | `NSViewController` implementing `preparePreviewOfFile(at:completionHandler:)`, listing via `7zz` when it can launch, otherwise in-process via `LibArchiveReader` (the `quicklook-preview` sandbox forbids child processes), and hosting SwiftUI |
| `QuickLookStrings.swift` | `QuickLookStrings` | Localized strings (`StringTable` from the appex's own `.lproj` tables), system-language resolution and locale-aware byte/date/percent formatting for the sandboxed extension |
| `ArchiveQuickLookView.swift` | `ArchiveQuickLookView` | Native SwiftUI view displaying archive header, format/encryption badges, statistics banner, capped file table (300 items), and password-lock notices |
| `Support/QuickLook-Info.plist` | `QLSupportedContentTypes`, `NSExtensionPrincipalClass` | Quick Look extension manifest declaring 13 supported archive UTTypes |

---

### Build Scripts & Bundle Resources (`Scripts/`, `Support/`, `Resources/`)

| File | Primary Symbols / Artifacts | Responsibilities |
| :--- | :--- | :--- |
| `Scripts/make_icon.swift` | `drawIcon`, `Resources/AppIcon.icns` | Programmatic CoreGraphics generator for the macOS app icon (16px to 1024px) |
| `Scripts/make_document_icons.swift` | `Family`, `zipper`, `box`, `books`, `layers`, `disc`, `drawDocument`, `Resources/DocumentIcons/{zip,7z,rar,tar,disk,archive}.icns` | Programmatic CoreGraphics generator for the six Finder document icon families (up to 512px, ~1.7 MB total, zero SF Symbols) |
| `Scripts/update_signing.swift` | `KeychainService`, `signFile`, `verifySignature` | Ed25519 signing key generation, login Keychain storage (`com.babadogantech.arhivar.update-signing`), and `.dmg.sig` creation |
| `Support/Info.plist` | `CFBundleDocumentTypes`, `NSServices`, `UTImportedTypeDeclarations`, `ArhivarUpdatePublicEDKey` | Declares six document icon families (`LSHandlerRank = Alternate`), Finder context-menu services, 14 custom archive UTIs, and Ed25519 release verification public key |

---

## 4. Change Impact Map

- **Adding a UI String:** Must update `LKey` in `Sources/ArhivarCore/Localization.swift` **and** all three `Resources/{tr,en,ro}.lproj/Localizable.strings` files (`RunnerAndLocalizationTests` enforces 100% key and format-specifier parity).
- **Adding a Supported Archive Format:** Update `ArchiveFormat` (`ArchiveOptions.swift`), `ArchiveNaming.archiveExtensions` (`Engine.swift`), `Support/Info.plist` (`CFBundleDocumentTypes` in exactly one of the six icon families, `NSServices`, `UTImportedTypeDeclarations`), and verify with `DocumentIconTests`, `CommandTests`, and `RoadmapTests`.
- **Modifying `ArchiveNode` or `ArchiveBrowserView` Table Columns:** Never introduce `@Environment` lookups inside `NameCell` or any table cell view; verify with `BrowserViewTests`.
- **Modifying `AppSettings` Keys:** Add new `UserDefaults` keys to `AppSettings.Key.all` so `resetAll()` removes them cleanly (`resetRemovesAllPreferences` test).

### Additions (2026-10-21)

| File | Primary Symbols | Responsibilities |
| :--- | :--- | :--- |
| `StagedExtraction.swift` | `DiskSpaceGuard`, `InsufficientSpaceError.stoppedWhileWriting` | Watches free space during extraction and stops 7zz below a 512 MB floor (decompression bombs with missing or false sizes) |
| `ArchiveEditing.swift` | `SecretLinks`, `FileIdentity`, `AddPlan.skippedSecretLinks` | Detects hard links to files in credential folders (`SandboxProfile.secretDirectories`) inside create/add sources; skipped with a warning, also while copying add sources |
| `ArchiveListing.swift` | `ArchiveListing.passwordProbeItem` | Smallest encrypted file, test-decrypted to verify a password before names of a content-encrypted archive are shown |
| `Scripts/StressProbe.swift`, `Scripts/stress-test.sh` | — | Keyboard-free pre-release stress round over the real app and Finder Quick Look via accessibility identifiers (`arhivar.progress`, `arhivar.progress.cancel`, `arhivar.password`, `arhivar.password.cancel`, `arhivar.browser`) |

---

## 5. Known Graph Gaps

- `Sources/ArhivarQuickLook/main.swift` is only partly parsed: tree-sitter-swift rejects the body-less `@_silgen_name("NSExtensionMain") func NSExtensionMain()` declaration. The file compiles; only its graph edges are incomplete.
- `Sources/CLibArchive/include/CLibArchive.h` and `shim.c` yield no symbols, so the `libarchive` calls from `LibArchiveReader.swift` end at the module boundary.
- About 12% of edges are `INFERRED` (for example test functions linked to the types they exercise); confirm an inferred edge in the source before relying on it.
