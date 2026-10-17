# Roadmap

Exhaustive master list of technical fixes, security/concurrency hardening, UX refinements and planned features identified across **multiple full-repository audit rounds** of Arhivar (`Sources/ArhivarCore`, `Sources/Arhivar`, `Scripts`, `Support/Info.plist`, `Resources` and `Tests`), **ordered strictly by priority and severity**.

**Status legend:** ✅ Done · 🟡 Partially done · ⬜ Open. Line numbers in "Location" refer to the code at the time of the audit; see [CHANGELOG.md](CHANGELOG.md) (Unreleased) for what shipped.

---

## Priority 0 (P0) — Critical Bugs, Security, Crash Prevention & Data Integrity

### 1. ✅ [P0] Fix `encryptedHeaders` False Positive in `AppModel.readListing` (Swift `try?` Optional Flattening Bug)
- **Status:** ✅ Done — `SevenZipError.needsPassword(_:)` classifies the unauthenticated listing explicitly; regression tests `addingWithPasswordKeepsHeadersPlain`, `detectsEncryptedHeaders`.
- **Location:** `Sources/Arhivar/AppModel.swift` (lines 440–444)
- **Bug:**
  ```swift
  let plain = try? await runner.run(SevenZipCommand.list(archive: url))
  encryptedHeaders = plain.map { (try? SevenZipError.check($0)) == nil } ?? false
  ```
  `SevenZipError.check(_:)` returns `String?` and returns `nil` when `exitCode == 0` (success with no warnings). Under Swift's `SE-0230`, `try?` flattens `String??` to `String?`. Consequently, when the unauthenticated `plain` listing **succeeds** (`exitCode == 0`, meaning file names are **not** encrypted), `SevenZipError.check($0)` returns `nil`, and `(try? SevenZipError.check($0)) == nil` evaluates to `true`.
- **Impact:** Any password-protected `.7z` archive with unencrypted file names (`-mhe=off`) is misclassified as `headersEncrypted = true`, causing subsequent `addFiles` operations to pass `-mhe=on` and silently encrypt headers.
- **Fix:** Replace `(try? SevenZipError.check($0)) == nil` with an explicit throwing check (`(try? { _ = try SevenZipError.check($0) }()) == nil`), or parse `Encrypted = +` directly from the archive header block in `ListingParser.parseInfo` to avoid spawning a second `7zz l` process altogether.

### 2. ✅ [P0] Prevent Integer Overflow Crash on Zip Bombs (`DiskSpace`, `ArchiveStatistics`, `ArchiveTree`)
- **Status:** ✅ Done — `Int64.saturatingAdding` / `saturatingSum()` used in all three places; test `hugeDeclaredSizesSaturate`.
- **Locations:**
  - `Sources/ArhivarCore/StagedExtraction.swift` (`DiskSpace.requiredBytes`, lines 120–126)
  - `Sources/ArhivarCore/ArchiveListing.swift` (`ArchiveStatistics.init`, lines 184–185)
  - `Sources/ArhivarCore/ArchiveTree.swift` (`ArchiveTree.convert`, lines 93–94)
- **Bug:** Unpacked and packed entry sizes (`Int64`) are summed using unchecked `+` (`reduce(0) { $0 + ($1.size ?? 0) }`). A maliciously crafted archive (Zip/7z bomb) declaring multiple entries whose sizes sum to `> Int64.max` triggers a Swift integer overflow trap (`EXC_BAD_INSTRUCTION`), crashing the app immediately upon opening or extracting the archive.
- **Fix:** Use saturating addition (`addingReportingOverflow`, clamping at `Int64.max`) wherever entry sizes are accumulated.

### 3. ✅ [P0] Preserve `AES-256` When Adding Files to Encrypted ZIP Archives
- **Status:** ✅ Done — `SevenZipCommand.add(…, archiveType:)` passes `-mem=AES256` for ZIP; tests `addingToEncryptedZipKeepsAES`, `addToEncryptedZipUsesAES`.
- **Location:** `Sources/ArhivarCore/ArchiveEditing.swift` (`SevenZipCommand.add`, lines 20–26)
- **Problem:** `SevenZipCommand.create` passes `-mem=AES256` when creating an encrypted `.zip`, but `SevenZipCommand.add` only passes `-p`. Without `-mem=AES256`, `7zz` defaults to legacy weak `ZipCrypto` for newly added files in an existing encrypted `.zip`.
- **Fix:** Pass `-mem=AES256` in `SevenZipCommand.add` when updating a `.zip` archive with a password.

### 4. ✅ [P0] Symlink Target Validation, Quarantine Preservation & `0o700` Staging Permissions
- **Status:** ✅ Done — `StagedExtraction.secureSymlinks(in:)` (also in `ItemExtractor`), `replaceItemAt(…, options: .usingNewMetadataOnly)` + `Quarantine.ensure`, `AddPlan` staging created `0o700`; tests `symlinksPointingOutsideAreRemoved`, `replaceKeepsNewQuarantine`, `addPlanStagingIsPrivate`.
- **Locations:**
  - `Sources/ArhivarCore/StagedExtraction.swift` (`mergeItem`, lines 40–71)
  - `Sources/Arhivar/AppModel.swift` (`runExtract`, lines 580–581)
  - `Sources/ArhivarCore/ArchiveEditing.swift` (`AddPlan.make`, lines 55–57)
- **Problems:**
  1. `StagedExtraction.merge` uses `lstat` so it never writes through symlinks already in `destination`, but symlinks extracted into `staging` from an archive are moved into `destination` without verifying whether their target points outside the destination tree.
  2. In `.replace` mode, `fileManager.replaceItemAt(target, withItemAt: source)` can preserve the target file's old metadata/xattrs instead of the newly applied `com.apple.quarantine` xattr on `source`.
  3. `AddPlan.make` creates its temporary `staging` folder with default permissions (`0o755`) instead of `0o700` (unlike `ItemExtractor` and `sessionDirectory`).
- **Fix:** Validate symlink targets inside `staging` before merging, re-verify `com.apple.quarantine` on replaced items, and create `AddPlan` staging directories with `0o700`.

### 5. ✅ [P0] Preserve Symbolic Links (`-snl`) When Archiving macOS `.app` Bundles & Frameworks
- **Status:** ✅ Done — `-snl` for 7z/ZIP/TAR/WIM/`.tar.*` on create and add, controlled by Settings › Compression › "Store symbolic links as links" (on by default); test `storesSymlinksAsLinks`.
- **Locations:** `Sources/ArhivarCore/ArchiveOptions.swift` (`SevenZipCommand.create`) & `Sources/ArhivarCore/ArchiveEditing.swift` (`SevenZipCommand.add`)
- **Problem:** `7zz a` is invoked without `-snl`. By default, `7zz` dereferences symbolic links instead of storing them as links. On macOS, archiving a `.app` bundle or `.framework` (which rely on versioned symlinks inside `Contents/Frameworks`) bloats the archive size ~3x, breaks code signatures upon extraction, and fails if a relative symlink is dangling.
- **Fix:** Pass `-snl` (or provide a default-enabled "Store symbolic links as links" option) when creating or adding to archives that support symlinks.

### 6. ✅ [P0] Disable Wildcard Matching (`-spd`) in `SevenZipCommand.create` & `SevenZipCommand.add`
- **Status:** ✅ Done — `-spd` is passed whenever a source name contains `*` or `?` (it also disables the wildcards of `-x` patterns, so it is not passed otherwise); test `wildcardSourceNamesAreLiteral`.
- **Locations:** `Sources/ArhivarCore/ArchiveOptions.swift` (`SevenZipCommand.create`, lines 189–209) & `Sources/ArhivarCore/ArchiveEditing.swift` (`SevenZipCommand.add`, lines 20–26)
- **Problem:** `extract`, `delete` and `rename` pass `-spd` so `*` and `?` in file names are not treated as wildcards, but `create` and `add` omit `-spd`. Compressing or adding a macOS file or folder whose name contains `*` or `?` (valid APFS characters, e.g. `İş*Yedek`) causes `7zz` to treat the path as a glob pattern.
- **Fix:** Pass `-spd` in `SevenZipCommand.create` and `SevenZipCommand.add`.

### 7. ✅ [P0] Tighten `"Break signaled"` Password Classification & Escalate Hung `terminate()` to `SIGKILL`
- **Status:** ✅ Done — `"Break signaled"` counts as a password failure only together with `"Enter password"`; `ProcessBox.terminate()` sends `SIGKILL` after 2 seconds; tests `breakSignalWithoutPromptIsNotPassword`, `cancellationKillsProcessIgnoringSigterm`.
- **Location:** `Sources/ArhivarCore/CommandRunner.swift` (lines 33–37, 190–192)
- **Problems:**
  1. `SevenZipError.check` classifies any output containing `"Break signaled"` as `.wrongPassword`. However, `7zz` also prints `"Break signaled"` when terminated by an external `SIGINT`/`SIGTERM`. Only when `"Break signaled"` is accompanied by `"Enter password"` does it indicate an empty-stdin password abort.
  2. `ProcessBox.terminate()` sends `SIGTERM` (`process.terminate()`), but if `7zz` is wedged in a corrupted header loop and ignores `SIGTERM`, the continuation never resumes.
- **Fix:** Require `"Enter password"` alongside `"Break signaled"` for `.wrongPassword`, and schedule a `SIGKILL` (`kill(pid, SIGKILL)`) fallback if the process is still running 2 seconds after `terminate()`.

---

## Priority 1 (P1) — High-Impact Functional & UX Bugs

### 8. ✅ [P1] Normalize Archive Entry Paths (`./`, Trailing `/`) in `ListingParser` & `ArchiveTree`
- **Status:** ✅ Done — `ArchiveEntry.path` / `ArchiveNode.id` are normalized; the raw path 7zz needs is kept in `archivePath` and used for every command; tests `normalizesEntryPaths`, `extractsDotPrefixedTarEntries`, `dotPrefixedTarBrowsesAndExtracts`.
- **Locations:** `Sources/ArhivarCore/ArchiveListing.swift` (`makeEntry`, line 148) & `Sources/ArhivarCore/ArchiveTree.swift` (`build`, line 90)
- **Problem:**
  1. `.tar` archives created with `tar -czf out.tgz .` store paths prefixed with `./` (e.g. `./src/main.swift`), creating a literal `"."` top-level folder in the browser.
  2. In `ArchiveTree.convert` (line 90), a directory node's `id` is set to `node.entry?.path ?? node.path`. If `node.entry?.path` contains a trailing slash (`"folder/"`) or duplicate slashes (`"a//b"`), `node.id` differs from the normalized path `"folder"` built by `breadcrumbs`, causing `nodeIndex[currentFolder]` lookups to return `nil`.
- **Fix:** Normalize entry paths in `ListingParser` (strip leading `./` and trailing `/`) and always use the canonical `node.path` for `ArchiveNode.id`.

### 9. ✅ [P1] Read-Only `.app` Bundle Version Detection in `update-7zip.sh` & `AppModel`
- **Status:** ✅ Done — `EngineUpdater(currentVersion:)` passes `--current` (unless a custom 7zz is chosen); the script falls back to the bundled 7zz version; test `updaterPassesCurrentVersion`, verified by hand on a read-only app copy.
- **Locations:** `Scripts/update-7zip.sh` (lines 68–78, 132–143) & `Sources/Arhivar/AppModel.swift` (lines 355–363)
- **Problem:** When `Arhivar.app/Contents/MacOS` is not writable (e.g. installed by root/admin or under App Translocation), `update-7zip.sh` switches its target to `~/Library/Application Support/Arhivar/engine`. If that fallback folder has not been created yet, `engine_version` reads `CURRENT=none` instead of the bundled `7zz` version, falsely reporting `STATUS=update-available` even when the bundled `7zz` is already up to date.
- **Fix:** Pass `--current <engineVersion>` from `AppModel` to `EngineUpdater`, and fall back to reading the bundled `Arhivar.app/Contents/MacOS/7zz` version in `update-7zip.sh` when `FALLBACK_DIR/7zz` does not exist yet.

### 10. ✅ [P1] Fix Unreachable `localizedStandardCompare` in `ArchiveTree.sorted` & `ArchiveBrowserView`
- **Status:** ✅ Done — `ArchiveTree.nameComparator` (`.localizedStandard`) is the default sort order and the Name column's comparator; test `namesSortLikeFinder`.
- **Locations:** `Sources/ArhivarCore/ArchiveTree.swift` (lines 115–124) & `Sources/Arhivar/Views/ArchiveBrowserView.swift` (line 14)
- **Problem:** `TableColumn(settings.t(.columnName), value: \.name)` constructs a `KeyPathComparator(\ArchiveNode.name)` using raw Swift `String` `<` comparison (ASCII/Unicode scalar order). In `ArchiveTree.sorted`, `comparator.compare(lhs, rhs)` runs first and only falls through to line 123 (`lhs.name.localizedStandardCompare(rhs.name)`) when two items have the exact same name. As a result, `"Zebra"` sorts before `"apple"`, `"file10.txt"` before `"file2.txt"`, and Turkish `"Çanta"` after `"Z"`.
- **Fix:** Use `String.StandardComparator.localizedStandard` on the Name `TableColumn` and in `ArchiveTree.sorted`.

### 11. ✅ [P1] Multi-Volume (Split) Archive Handling on Create, Open & Size Reporting
- **Status:** ✅ Done — `CreateOptions.firstOutput` (`.001`), `ArchiveNaming.firstVolume(of:)` for `.00N` and `.partN.rar`, `Total Physical Size` preferred; tests `splitArchiveVolumes`, `splitArchivesOpenFromFirstVolume`.
- **Locations:**
  - `Sources/Arhivar/AppModel.swift` (`createArchive`, lines 874–887)
  - `Sources/ArhivarCore/Engine.swift` (`ArchiveNaming`, lines 145–155)
  - `Sources/ArhivarCore/ArchiveListing.swift` (`parseInfo`, line 108)
- **Problems:**
  - **On create:** When `options.volumeSizeMB` is set, `7zz` writes `archive.7z.001`, `archive.7z.002`, etc. instead of `archive.7z`. Checking `FileManager.default.fileExists(atPath: options.destination.path)` returns `false`, so the newly created split archive is not added to `recentArchives` and Finder reveals the parent directory instead of selecting `.001`.
  - **On open:** `ArchiveNaming.isArchiveExtension` accepts `.001`, `.002`, `.003`, etc., but `7zz` only opens a split archive from its first volume (`.001` or `.part1.rar`). Double-clicking `.002` in Finder fails with `notArchive`.
  - **On size reporting:** `ListingParser.parseInfo` reads `Physical Size` (size of `.001` only) and ignores `Total Physical Size` (total size across all split volumes).
- **Fix:** Check `destination.appendingPathExtension("001")` when `volumeSizeMB != nil`, resolve `.002`/`.003` (and `.partN.rar`) to the sibling first volume when opening, and prefer `Total Physical Size` in `ListingParser.parseInfo`.

### 12. ✅ [P1] Surface Automatic Arhivar App Updates on the Welcome Screen
- **Status:** ✅ Done — `UpdateBanner` shows a download banner for `model.appUpdateState == .available`.
- **Locations:** `Sources/Arhivar/AppModel.swift` (`launch`, line 230) & `Sources/Arhivar/Views/WelcomeView.swift` (`UpdateBanner`, lines 151–184)
- **Problem:** `AppModel.launch()` calls `checkForAppUpdate(interactive: false)` at startup, setting `model.appUpdateState = .available(release)`. However, `UpdateBanner` on `WelcomeView` only observes `model.updateState` (7-Zip engine updates) and ignores `model.appUpdateState`. Startup app update checks are therefore invisible unless the user opens **Settings › Advanced**.
- **Fix:** Display a download banner in `UpdateBanner` when `model.appUpdateState` is `.available(release)`.

### 13. ✅ [P1] Clear `serviceQueue` When Cancelling an Active Operation
- **Status:** ✅ Done — `cancelOperation()` empties `serviceQueue`; test `cancelStopsServiceQueue`.
- **Locations:** `Sources/Arhivar/AppModel.swift` (`extractHere`, lines 805–822 & `cancelOperation`, line 927)
- **Problem:** When extracting multiple archives via Finder's **"Extract Here with Arhivar"** service, clicking **Cancel** on the progress overlay cancels `currentTask` for the current archive, but `serviceQueue` retains the remaining archives and immediately starts extracting the next one.
- **Fix:** Clear `serviceQueue` inside `cancelOperation()` so cancelling stops the entire batch.

### 14. ✅ [P1] Duplicate Basename Detection in `CreateArchiveSheet` & `AddPlan`
- **Status:** ✅ Done — `AddPlan.duplicateNames(in:)`; the sheet shows the parent folders and disables Create, `AddPlan.make` throws `DuplicateNameError` with a readable message; tests `duplicateSourceNames`, `addingDuplicateNamesShowsError`.
- **Locations:** `Sources/Arhivar/Views/CreateArchiveSheet.swift` (lines 78–96, 177–188) & `Sources/ArhivarCore/ArchiveEditing.swift` (`AddPlan.make`, lines 58–62)
- **Problem:** Selecting two files with the same name from different folders (e.g. `/FolderA/report.pdf` and `/FolderB/report.pdf`) shows both as `report.pdf` in `CreateArchiveSheet` without disambiguating paths and leaves **Create** enabled, causing `7zz` to fail with `Duplicate filename on disk`. In `AddPlan.make`, `fileManager.copyItem` throws a Cocoa file-exists error on the second file before `7zz` runs.
- **Fix:** Detect duplicate `lastPathComponent` values in `CreateArchiveSheet` (showing parent directory paths and a validation message) and guard against collisions in `AddPlan.make`.

### 15. ✅ [P1] Relative Path Stripping When Extracting Selected Items from a Subfolder
- **Status:** ✅ Done — `StagedExtraction.contentRoot(in:stripping:)`; search results and tree view keep full paths; test `extractingFromSubfolderStripsPath`.
- **Locations:** `Sources/Arhivar/AppModel.swift` (`runExtract`, lines 573–581) & `Sources/ArhivarCore/StagedExtraction.swift`
- **Problem:** When browsing inside `a/b/c/` in Folder View and clicking **Extract Selected**, `7zz x` preserves the full internal path and creates `Destination/a/b/c/file.txt` instead of `Destination/file.txt` (unlike drag-to-Finder, which extracts the item directly).
- **Fix:** Strip the active `currentFolder` prefix in `StagedExtraction` when extracting selected items from Folder View.

### 16. ✅ [P1] Preserve `currentFolder` on Cancelled PathBar Drop & Show Validation Hint for Empty Password Confirmation
- **Status:** ✅ Done — `AddRequest.folder` carries the target folder (no `goTo` before confirmation, ignored while an operation runs or with no files); the sheet shows "Enter the password again to confirm it."; test `addRequestCarriesTargetFolder`.
- **Locations:**
  - `Sources/Arhivar/Views/ArchiveBrowserView.swift` (`PathBar.crumb`, lines 218–224)
  - `Sources/Arhivar/Views/CreateArchiveSheet.swift` (`validationMessage`, line 179)
- **Problems:**
  1. Dropping files onto a breadcrumb in `PathBar` immediately calls `model.goTo(path)` before showing the confirmation dialog (`addRequest`). If the user clicks **Cancel** in the confirmation dialog, their current folder has already been changed; furthermore, `PathBar` does not check `model.operation == nil` or `!urls.isEmpty`.
  2. In `CreateArchiveSheet`, when `password` is non-empty and `confirmation` is empty, `isValid` is `false` (disabling the **Create Archive** button), but `validationMessage` checks `!confirmation.isEmpty` and shows no warning explaining why the button is disabled.
- **Fix:** Store the target folder inside `AddRequest` instead of calling `goTo(path)` before confirmation, and display the password confirmation hint whenever `password != confirmation`.

---

## Priority 2 (P2) — Security Hardening, System Integration & Polish

### 17. ✅ [P2] Strengthen `SandboxProfile.personalDataDirectories` & `OpenSafety` Detection
- **Status:** ✅ Done — new personal and browser profile folders, AppleScript/Shortcuts/prefPane/qlgenerator UTIs plus an extension fallback, Braille and Hangul blank fillers; test `strongerPersonalDataAndOpenSafety`.
- **Locations:** `Sources/ArhivarCore/Sandbox.swift` (lines 24–30) & `Sources/ArhivarCore/OpenSafety.swift` (lines 7–15, 52–59)
- **Enhancements:**
  - Add `~/.kube`, `~/.docker`, `~/.npmrc`, `~/.pypirc`, `~/.git-credentials` and browser profile directories to `SandboxProfile.personalDataDirectories`.
  - Add `.scpt`/`.applescript`, `.shortcut`, `.prefPane` and `.qlgenerator` UTIs to `OpenSafety.riskyTypes`, and detect deceptive Unicode filler/blank characters (`U+2800` Braille blank, `U+3164` Hangul filler, `U+115F`/`U+1160`) in `OpenSafety.isDeceptive`.

### 18. ✅ [P2] Count Implicit Intermediate Folders in `ArchiveStatistics.folderCount`
- **Status:** ✅ Done — `folderCount` counts explicit folder entries and the unique parent folders of every path; test `statisticsUsePhysicalSize`.
- **Locations:** `Sources/ArhivarCore/ArchiveListing.swift` (`ArchiveStatistics.init`, lines 180–188) & `Sources/ArhivarCore/ArchiveTree.swift`
- **Problem:** Many `.zip` and `.tar` archives omit explicit directory entries (`Folder = +`) and only store file paths such as `photos/vacation/img.jpg`. While `ArchiveTree.build` synthesizes intermediate folders for display, `ArchiveStatistics` computes `folderCount = listing.entries.count - files.count`, reporting `0` (or fewer) folders in the status bar and Info popover.
- **Fix:** Compute `folderCount` from the synthesized tree or unique parent directory paths.

### 19. ✅ [P2] Pre-Flight Disk Space Check for Archive Creation & In-Place Editing
- **Status:** ✅ Done — `DiskSpace.requiredForWriting` before create, add, delete and rename (current archive size for edits; source size for uncompressed output and the `.tar.*` intermediate tar; compressed output is not blocked because its size is unknown); test `spaceNeededForWriting`.
- **Location:** `Sources/Arhivar/AppModel.swift` (`createArchive`, line 874; `addFiles`, line 717; `deleteItems`, line 752; `rename`, line 773)
- **Problem:** `DiskSpace` / `InsufficientSpaceError.check` guards extraction, Quick Look and drag-to-Finder, but archive creation and in-place edits (where `7zz` writes a temporary copy of the archive next to the original) do not check available disk space beforehand.
- **Fix:** Check available disk space on the target volume before creating or updating archives.

### 20. ✅ [P2] Defer First-Launch Consent Alert When Launched via "Open With" / Finder Service
- **Status:** ✅ Done — the consent is pending until no operation, password prompt, alert or sheet is shown; test `consentWaitsForColdStartOperation`.
- **Location:** `Sources/Arhivar/AppModel.swift` (`launch`, lines 226–228)
- **Problem:** If a user launches Arhivar for the first time by opening an archive from Finder, `launch()` immediately sets `alert = AlertItem(title: t(.consentTitle), ...)`, which can collide with or overwrite an archive warning/error alert from the cold-start operation.
- **Fix:** Present `askUpdateConsent()` only when `operation == nil && passwordRequest == nil && alert == nil`.

### 21. ✅ [P2] Align Multi-File Handling (`handleOpenRequest`) & Expand `Info.plist` UTIs
- **Status:** ✅ Done — archives together with other files go to the New Archive sheet (only archives → the first one opens); 14 imported type declarations and the known system archive UTIs added to document types and services; test `openRequestWithMixedFilesCreatesArchive`.
- **Locations:** `Sources/Arhivar/AppModel.swift` (lines 480–487), `Sources/Arhivar/FinderServices.swift` (lines 22–26) & `Support/Info.plist` (lines 20–32, 78–89, 104–115)
- **Problems:**
  - `handleDrop` checks `files.count == 1` before opening an archive, whereas `handleOpenRequest` checks `files.first(where: isArchive)`, ignoring regular files dropped onto the Dock icon alongside an archive.
  - `ArchiveNaming.archiveExtensions` supports ~40 formats, but `Info.plist` only declares 10 base UTIs, leaving `.zst`, `.wim`, `.vmdk`, `.qcow2`, `.deb`, `.rpm` and `.001` unlisted for Finder's **Open With** and **Services** menus.
- **Fix:** Align `handleOpenRequest` with `handleDrop` and declare the remaining archive UTIs in `Support/Info.plist`.

---

## Priority 3 (P3) — Resource Hygiene, Build Scripts & Performance

### 22. ✅ [P3] Resource Hygiene & Zero-Allocation `ListingParser`
- **Status:** ✅ Done — stale previews are deleted when the same archive is reloaded, `resetAll()` removes `AppleLanguages` last and the browser mode, `FileIcons.byPath` is capped at 256 entries, `ListingParser` reads lines lazily; tests `editDiscardsStalePreviews`, `resetRemovesAllPreferences`.
- **Locations:**
  - `Sources/Arhivar/AppModel.swift` (line 455): Clean up stale extracted files inside `sessionRoot` and reset `quickLookURL` when reloading the same archive after an in-place edit.
  - `Sources/Arhivar/AppSettings.swift` (lines 131–148): In `resetAll()`, remove `"AppleLanguages"` *after* setting `language = .tr` (or set `language` without writing `"AppleLanguages"`), and reset `browserMode`.
  - `Sources/Arhivar/Views/ArchiveBrowserView.swift` (lines 380–405): Bound or clear `FileIcons.byPath` so cached `NSImage` instances do not grow indefinitely.
  - `Sources/ArhivarCore/ArchiveListing.swift` (lines 59–63): Iterate over `output.utf8` lines lazily instead of allocating an intermediate `[Substring]` array (~2.4M elements for a 200k-entry archive).

### 23. ✅ [P3] Packaging & Script Refinements (`package.sh`, `build_app.sh`, `update-7zip.sh`)
- **Status:** ✅ Done — `ditto` for `.dmg` staging; `SIGN_IDENTITY` (default ad-hoc; other identities get `--options runtime --timestamp`).
- **Locations:** `Scripts/package.sh` (line 54), `Scripts/build_app.sh` (lines 52, 59) & `Scripts/update-7zip.sh` (line 103)
- **Enhancements:**
  - Use `ditto "$APP" "$STAGING/Arhivar.app"` instead of `cp -R` when staging the `.dmg` in `package.sh` to preserve bundle metadata and extended attributes cleanly.
  - Support an optional `SIGN_IDENTITY` environment variable in `build_app.sh` (defaulting to ad-hoc `-`) for Developer ID signing.

---

## Planned Features (Ordered by User Impact)

### 1. ✅ [High] Smart Subfolder Extraction ("Tarbomb" Protection)
- **Status:** ✅ Done — `SubfolderMode` (Smart default, Always, Never) in Settings › General; the decision looks at the extracted top-level items; the old Bool preference is migrated (off → Never); tests `contentRootAndSmartDestination`, `smartSubfolderWithRealArchive`, `smartSubfolderAvoidsDoubleNesting`.

Replace the boolean `extractIntoSubfolder` toggle with a three-way mode: **Smart (Default)**, **Always**, **Never**.
- Single root item in the archive → extract directly into the destination folder (avoids `ArchiveName/ArchiveName/…` double nesting).
- Multiple root items → automatically create a subfolder named after the archive (`ArchiveNaming.baseName(of:)`).

### 2. ✅ [High] Exclude macOS Metadata Files (`.DS_Store`, `._*`, `__MACOSX`)
- **Status:** ✅ Done — toggle in the New Archive sheet and Settings › Compression, also applied when adding; tests `excludesMacMetadataSwitches`, `excludesMacMetadata`. (When a source name contains `*` or `?`, `-spd` is required and the `._*` pattern cannot apply; `.DS_Store` and `__MACOSX` still do.)

Add an `excludeMacMetadata: Bool` toggle in `CreateArchiveSheet` and **Settings › Compression** that passes `-xr!.DS_Store`, `-xr!._*` and `-xr!__MACOSX` to `7zz` when creating or updating archives.

### 3. ✅ [High] Finder-Style Keyboard Shortcuts (`⌘↓`, `⌘I`, `⌘C` / `⌘V`)
- **Status:** ✅ Done — Archive menu items for ⌘↓ and ⌘I; ⌘C / ⌘V through Edit menu commands (`AppModel.copyCommand` / `pasteCommand`, because `onCopyCommand` never reaches the hierarchical table), "Copy" in the context menu; tests `copyAndPasteFiles`, `editMenuCopiesAndPastesFiles`. Pasting into Finder by hand is not verified yet.
- **`⌘↓` (Command + Down Arrow):** Enter the selected folder or open the selected file (symmetric with `⌘↑` to go up).
- **`⌘I` (Command + I):** Toggle the Archive Info popover (`model.showInfo.toggle()`).
- **`⌘C` / `⌘V` (Copy & Paste):** Copy selected archive items to `NSPasteboard` (extracting on demand for pasting into Finder) and allow `⌘V` in editable archives to add files from the Finder clipboard.

### 4. 🟡 [Medium] Zstandard (`.zst`) Compression & One-Step `.tar.*` Creation
- **Status:** 🟡 Partially done — one-step `.tar.gz`, `.tar.xz` and `.tar.bz2` are done (tests `tarCompressionCommands`, `createsCompressedTar`, `createsTarGzInOneStep`). ⬜ Zstandard creation is **open / blocked**: the official 7-Zip `7zz` (26.04) extracts `.zst` but `7zz a -tzstd` fails with `E_NOTIMPL`. It could be offered only when the selected engine reports zstd support, or once upstream adds it; `.tar.zst` would reuse `SevenZipCommand.tarStage` / `compressTarStage`.
- ⬜ Add `.zst` to `ArchiveFormat` (`Sources/ArhivarCore/ArchiveOptions.swift`).
- ✅ Support one-step `.tar.gz`, `.tar.xz`, `.tar.bz2` and `.tar.zst` archive creation when compressing folders or multiple files (`.tar.zst` blocked as above).

### 5. ✅ [Medium] Nested Archive Navigation
- **Status:** ✅ Done — double-click / ⌘↓ / "Open in Arhivar"; `AppModel.archiveStack`, path bar crumbs for the enclosing archives, ⌘↑ at the root returns; nested archives are read-only and their session folders are deleted on return; test `browsesNestedArchives`.

When double-clicking an archive (`.zip`, `.tar.gz`, `.pkg`, `.dmg`, etc.) inside an open archive, extract it into the session folder and open it directly inside the Arhivar browser with a breadcrumb back-stack to return to the parent archive.

### 6. ✅ [Nice-to-Have] Built-in Checksum / Hash Inspector (`7zz h`) & Archive Comments
- **Status:** ✅ Done — "Checksums…" in the context and Archive menus (CRC32, SHA-256, BLAKE2sp with a Copy button); the info panel shows the comment, solid blocks and volumes; tests `parsesChecksumsAndComments`, `computesChecksums`, `showsChecksums`.
- Add a context-menu action (**Checksums / File Info**) using `7zz h -scrcSHA256` (`CRC32`, `SHA-256`, `BLAKE2sp`) with zero extra dependencies.
- Parse and display `Comment = …` and solid block count from `7zz l -slt` in `ArchiveInfoView`.
