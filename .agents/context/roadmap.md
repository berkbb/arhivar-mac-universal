# SOTA Roadmap & Project Enhancement Checklist

> **Memory Category:** TencentDB Context & SOTA Roadmap Asset  
> **Single Canonical Roadmap:** This file is the single source of truth for planned work, technical fixes, security/concurrency hardening, and completed milestones across Arhivar (`Sources/ArhivarCore`, `Sources/Arhivar`, `Scripts`, `Support/Info.plist`, `Resources`, and `Tests`). See [`/CHANGELOG.md`](../../CHANGELOG.md) for shipped release notes.

**Status legend:** ✅ Done · 🟡 Partially done · ⬜ Open.

---

## Open / In Progress

### Fifth Hardening Round — Existing Directory Conflicts, Read-Only Archive In-Place Guard, Old RAR Multi-Volume & Saturating Negative Size (2026-10-18)

#### R5-1. ⬜ [P1] Existing Target Directory Collision & Pre-Flight Validation in `CreateArchiveSheet` & `AppModel.createArchive`
- **Status:** ⬜ Open
- **Locations:**
  - `Sources/Arhivar/Views/CreateArchiveSheet.swift` (`validationMessage`, lines 212–215; `isValid`, lines 225–227)
  - `Sources/Arhivar/AppModel.swift` (`createArchive`, lines 1323–1355)
- **Problem:**
  1. When creating a new archive, if a directory with the intended destination name (`firstOutput`) already exists on disk (e.g., a previously extracted `Project.7z/` folder):
     - `CreateArchiveSheet.validationMessage` checks `FileManager.default.fileExists(atPath: firstOutput(for: destination).path)`, which returns `true` for directories.
     - The sheet surfaces `settings.t(.createExistsWarning)` (*"An archive with this name already exists and will be replaced"*), which is misleading since the target is a directory, not an archive, and Arhivar strictly avoids overwriting existing folders (`StagedExtraction.installArchive` explicitly throws `CocoaError(.fileWriteFileExists)`).
     - `isValid` remains `true`, leaving the Create button enabled.
     - Clicking Create causes `AppModel.createArchive` to invoke `7zz a` inside `staging`, performing full archive compression only to abort during `installArchive` with an error alert, wasting CPU and disk I/O.
  2. `AppModel.createArchive` lacks a pre-flight check for existing directory targets before spawning `7zz a` and preparing staging.
- **Fix:**
  - In `CreateArchiveSheet.swift`, detect if `firstOutput(for: destination)` exists and is a directory (`StagedExtraction.itemType == .typeDirectory`). Surface `settings.t(.renameExists, target.lastPathComponent)` and disable the Create button (`!isFolderConflict` in `isValid`). Reserve `createExistsWarning` exclusively for existing regular files/archives.
  - In `AppModel.createArchive`, add an upfront pre-flight check before staging:
    ```swift
    let first = options.firstOutput
    if StagedExtraction.itemType(first, fileManager: fileManager) == .typeDirectory {
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: first.path])
    }
    ```

#### R5-2. ⬜ [P1] Read-Only Archive & Directory Immunity for In-Place Editing (`ArchiveCapabilities.isEditable`)
- **Status:** ⬜ Open
- **Locations:**
  - `Sources/ArhivarCore/ArchiveEditing.swift` (`ArchiveCapabilities.isEditable`, lines 11–16)
  - `Sources/Arhivar/AppModel.swift` (`apply`, line 550)
- **Problem:**
  - If a `.7z`, `.zip`, or `.tar` archive file is marked read-only on disk (`chmod 0444` / locked file), or is located on a read-only volume (e.g. mounted DMG, optical media, or read-only network volume):
    - `ArchiveCapabilities.isEditable` only checks the archive format and split volume status, returning `true`.
    - `AppModel.isEditable` is enabled, surfacing Add, Delete, and Rename actions in the toolbar and context menus.
    - Attempting any in-place edit causes `7zz a` / `7zz d` / `7zz rn` to fail with `System ERROR: errno=13 : Permission denied` (exit code 2) because 7zz cannot update read-only archives or write temporary staging files next to them.
- **Fix:**
  - In `ArchiveCapabilities.isEditable(type:url:fileManager:)`:
    - When `fileManager.fileExists(atPath: url.path)`, verify that both the archive file and its containing directory are writable:
      ```swift
      guard fileManager.isWritableFile(atPath: url.path),
            fileManager.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
          return false
      }
      ```
    - When read-only, `isEditable` evaluates to `false`, editing controls are disabled with the tooltip `settings.t(.readOnlyArchive)` (*"This archive type can't be edited"*), and file drops onto the window trigger the New Archive flow instead of impossible additions.

#### R5-3. ⬜ [P2] Old-Style Multi-Volume RAR Archive Recognition & First-Volume Resolution (`.r00`..`.r99`)
- **Status:** ⬜ Open
- **Locations:**
  - `Sources/ArhivarCore/Engine.swift` (`ArchiveNaming.archiveExtensions`, lines 143–154; `ArchiveNaming.firstVolume`, lines 169–190)
- **Problem:**
  - In old-style multi-part RAR archives, secondary volumes use extensions `.r00`, `.r01`, ... while the primary master header resides in `archive.rar`.
  - `ArchiveNaming.archiveExtensions` only matches `.rar` and strictly 3-digit numeric extensions (`.001`), excluding `.r00`..`.r99`.
  - Double-clicking or invoking "Extract Here" on `archive.r00` fails to recognize it as an archive (`isArchive == false`), and `firstVolume` does not redirect to `archive.rar`.
  - Passing `archive.r00` directly to `7zz` fails with `Cannot open the file as archive` because 7-Zip requires old-style RAR volumes to be opened from the `.rar` file.
- **Fix:**
  - In `ArchiveNaming.isArchiveExtension`, match `r\d\d` extensions (`ext.count == 3 && ext.lowercased().hasPrefix("r") && ext.dropFirst().allSatisfy(\.isNumber)`).
  - In `ArchiveNaming.firstVolume`, if the extension matches `r\d\d`, check if `archive.rar` exists in the same directory and return it as the first volume.

#### R5-4. ⬜ [P2] Non-Negative Size Accumulation Guard in `DiskSpace.requiredBytes`
- **Status:** ⬜ Open
- **Location:**
  - `Sources/ArhivarCore/StagedExtraction.swift` (`DiskSpace.requiredBytes`, lines 419–425)
- **Problem:**
  - In `DiskSpace.requiredBytes`, entry sizes are summed with `total.saturatingAdding(entry.size ?? 0)`.
  - If a corrupted or maliciously crafted archive entry specifies a negative size (e.g. `Size = -1`), `saturatingAdding(-1)` reduces the accumulated total bytes, potentially tricking the pre-flight disk space safety check.
- **Fix:**
  - Wrap entry size with `max(0, entry.size ?? 0)` to guarantee strictly non-negative accumulation.

### Upstream-Dependent Items

#### 1. 🟡 [Medium] Zstandard (`.zst` / `.tar.zst`) Archive Creation
- **Status:** 🟡 Partially done — one-step `.tar.gz`, `.tar.xz`, and `.tar.bz2` creation is completed (tests `tarCompressionCommands`, `createsCompressedTar`, `createsTarGzInOneStep`).
- ⬜ **Remaining:** Zstandard (`.zst` and `.tar.zst`) creation is currently **blocked upstream**: the official 7-Zip `7zz` (26.04) extracts `.zst` / `.tzst` (`K` flag in `7zz i`) but does not implement `zstd` archive creation (`7zz a -tzstd` fails with `E_NOTIMPL`).
- **Next steps:** Offer `.zst` and `.tar.zst` in `ArchiveFormat` (`Sources/ArhivarCore/ArchiveOptions.swift`) once upstream `7zz` enables `C` (Create) support for `zstd`, or dynamically when the active engine reports `zstd` creation capability. `.tar.zst` will directly reuse `SevenZipCommand.tarStage` and `compressTarStage`.

---

## Done

### Fourth Hardening Round — Read-Only Trees, Extract Here Password & Special-File Validation (2026-10-18)

All three items were reproduced with failing tests before the fix; the suite grew from 189 to 194 tests.

#### R4-1. ✅ [P1] Read-Only Directory Tree (`0o555` / `0o444`) Permission Immunity in `StagedExtraction.mergeItem` and `secureSymlinks`
- **Status:** ✅ Done — `mergeItem` replaces a folder by a file with `removeTree` (read-only contents no longer abort with Cocoa 513), grants `S_IWUSR | S_IXUSR` on the target folder and `S_IRWXU` on the staged folder while merging (`0444` / `0000` targets, `0311` / `0555` staged folders), restoring both modes. `secureSymlinks` walks the tree itself and grants owner access to folders it can't read, enter or modify, so links inside `0000` / `0311` / `0555` folders are found, removed or rewritten; the modes are restored deepest-first (`OwnerAccess.addTree` / `restore`, also used by `removeTree`). Tests `replacingAFolderWithReadOnlyContentsByAFile`, `mergingThroughFoldersWithoutSearchPermission`, `linksInsideReadOnlyFoldersAreStillSecured`.
- **Locations:**
  - `Sources/ArhivarCore/StagedExtraction.swift` (`mergeItem`, lines 75–105; `secureSymlinks`, lines 171–178)
- **Problem:**
  1. In `StagedExtraction.mergeItem`, when overwriting an existing item with `.replace`, line 102 executes `try fileManager.removeItem(at: target)` when replacing a target directory with an extracted regular file. If `target` is a directory containing read-only (`0o555` or `0o444`) items or subdirectories, `removeItem` fails with POSIX `EACCES` (Cocoa error 513: permission denied) and aborts extraction. It should use `StagedExtraction.removeTree(at: target, fileManager: fileManager)` instead.
  2. In `mergeItem`, when recursively merging two directories, line 77 calls `OwnerAccess.granting(S_IWUSR, on: target.path)`. If `target` on disk has mode `0o444` (read-only without directory search/execute `S_IXUSR`) or `0o000`, granting only `S_IWUSR` results in `0o644`, where child operations fail with `EACCES`. It must grant `S_IWUSR | S_IXUSR`.
  3. In `StagedExtraction.secureSymlinks`, lines 171–178 delete (`removals`) or rewrite (`rewrites`) symbolic links. If a symbolic link is inside an extracted or existing directory with mode `0o555` (no write permission on parent), `try? fileManager.removeItem(atPath: link)` silently fails with `EACCES`. The escaping link is not removed, yet it is reported in `removals` and subsequently moved into the destination tree. The parent directory should have `S_IWUSR | S_IXUSR` granted during removal/rewrite.
- **Fix:** Use `removeTree` for target directory removal in `mergeItem`, grant `S_IWUSR | S_IXUSR` on target directories during merge, and temporarily grant `S_IWUSR | S_IXUSR` on the immediate parent directory when removing or rewriting symbolic links in `secureSymlinks`.

#### R4-2. ✅ [P1] Preserve Unlocked Archive Password in `AppModel.extractHere`
- **Status:** ✅ Done — `extractHere` passes the password already verified in this session (`knownPassword(for:)`: the open archive, or the outermost archive while browsing a nested one), so the open archive is not asked again and its password is not cleared. Test `extractHereReusesTheOpenArchivePassword`.
- **Locations:**
  - `Sources/Arhivar/AppModel.swift` (`extractHere`, lines 1242–1260; `handle`, line 1488)
- **Problem:** When an encrypted archive (`sifreli.zip` or `sifreli.7z`) is currently open and already unlocked in the main window (`archive == archiveURL` and `password != nil`), invoking "Extract Here" (`extractHere`) from Finder Services or the context menu passes `password: nil` to `runExtract`. Extraction fails with `.wrongPassword`, triggering line 1488 in `AppModel.handle`: `if archive == archiveURL { password = nil }`. This wipes out the user's previously validated password for the open archive and unnecessarily displays a password prompt.
- **Fix:** In `extractHere`, pass `password: archive == archiveURL ? password : nil` to `runExtract` so that the unlocked password is reused without clearing `self.password` or prompting again.

#### R4-3. ✅ [P2] In-Form Validation for Special-File-Only Sources in `CreateArchiveSheet`
- **Status:** ✅ Done — `SpecialFiles.containsOnlySpecialFiles(_:followingSymlinks:)` drives `CreateArchiveSheet.onlySpecialProblem` (shows `nothingToArchive`, disables Create) and the same check in `AppModel.createArchive`. Test `detectsSourcesMadeOnlyOfSpecialFiles`.
- **Locations:**
  - `Sources/Arhivar/Views/CreateArchiveSheet.swift` (`validationMessage`, lines 196–209; `isValid`, lines 218–220)
- **Problem:** When a user drops or selects only FIFOs, sockets, or device nodes into `CreateArchiveSheet`, the form allows clicking **Create** because `singleFileProblem` and `duplicateNames` do not trigger. Only after the sheet dismisses does `AppModel.createArchive` throw `AddPlan.NothingToArchiveError`, causing a post-dismissal error alert.
- **Fix:** Add an `onlySpecialProblem` check in `CreateArchiveSheet` (`!sources.isEmpty && sources.allSatisfy { SpecialFiles.isSpecial(atPath: $0.path, followingSymlinks: !(storeSymlinks && format.supportsSymlinks)) }`), display `settings.t(.nothingToArchive)` in `validationMessage`, and disable the **Create** button (`isValid == false`).

---

### Third Hardening Round — `..` Prefixes, Symlink Rows, Special-File Sources & Busy-State Guards (2026-10-18)

All four items were reproduced or confirmed against the bundled `7zz` 26.04 before the fix; the suite grew from 179 to 189 tests.

#### R3-1. ✅ [P1] Skip `..` Components in `ArchiveTree.rawPrefix` When Deriving Intermediate Folder `archivePath`
- **Status:** ✅ Done — `ArchiveTree.rawPrefix` skips `..` like `ListingParser.normalizedPath`, so the synthesized folder `a` of `../a/b.txt` is passed to 7zz as `../a` (with `..`, 7zz extracted everything under `..`, e.g. `../z` too). Note: 7zz cannot delete `..` entries from a TAR in any spelling (`7zz d` exits 0 and changes nothing) — an engine limitation. Tests `rawPrefixSkipsParentComponents`, `parentPrefixedFolderExtractsOnlyItself`.
- **Locations:**
  - `Sources/ArhivarCore/ArchiveTree.swift` (`ArchiveTree.rawPrefix`, lines 98–112)
- **Problem:** In `R2-8`, `ListingParser.normalizedPath` was updated to drop both `"."` and `".."` path components (`"../a/b.txt"` → `"a/b.txt"`, `"a/../b/c.txt"` → `"a/b/c.txt"`). However, `ArchiveTree.rawPrefix(_:components:)` — which derives the raw `archivePath` for synthesized intermediate folders in `ArchiveTree.build` — only checks `if !component.isEmpty && component != "."` and does not skip `".."`:
  - For an entry with `archivePath = "../a/b.txt"`, `rawPrefix("../a/b.txt", components: 1)` counts `".."` as the first component and assigns `archivePath = ".."` (instead of `"../a"`) to the synthesized folder `"a"`.
  - For an entry with `archivePath = "a/../b/c.txt"`, `rawPrefix("a/../b/c.txt", components: 2)` assigns `archivePath = "a/.."` (instead of `"a/../b"`) to the synthesized folder `"a/b"`.
  - Selecting that folder for extraction or deletion then passes `".."` or `"a/.."` to `7zz`.
- **Fix:** Update `ArchiveTree.rawPrefix` to check `if !component.isEmpty && component != "." && component != ".."`.

#### R3-2. ✅ [P1] Graceful Symbolic Link Handling in `copyItems` (`⌘A` + `⌘C`), `dragItem`, and Single-Item Actions (`openItem`, `toggleQuickLook`, `showChecksums`)
- **Status:** ✅ Done — `ItemExtractor` throws `ItemExtractor.SymbolicLinkError` for a standalone link (before running 7zz when the link is known from the listing) instead of `failed(code: 0)`; `AppModel` skips standalone links in `copyItems` (copies the rest, explains when only links were chosen), returns `nil` from `dragItem(for:)`, and `openItem`, `toggleQuickLook`, `showChecksums` and `browseArchive` show the new `symbolicLinkItem` message without running 7zz. The context menu hides Quick Look / Open / Checksums / Browse for a link and disables Copy for link-only selections; the menu bar uses `selectionIsSymbolicLink`. Tests `standaloneLinkIsRefusedWithAClearError`, `itemExtractorContainsLinksAndPlaceholders`, `symbolicLinkRowsAreSkippedOrExplained`.
- **Locations:**
  - `Sources/ArhivarCore/ArchiveEditing.swift` (`ItemExtractor.extract`, lines 245–263)
  - `Sources/Arhivar/AppModel.swift` (`openItem`, lines 839–855; `toggleQuickLook`, lines 865–874; `dragItem`, lines 935–942; `copyItems`, lines 948–970; `showChecksums`, lines 1019–1044)
  - `Sources/Arhivar/Views/ArchiveBrowserView.swift` (`contextMenu`, lines 88–108)
- **Problems:**
  1. In `R2-2`, `ItemExtractor.extract` removes standalone extracted symbolic links (`if symbolicLinks.contains(path) || type == .typeSymbolicLink { try? fileManager.removeItem(at: target); continue }`), and then on line 261 sees that `target` no longer exists and throws `SevenZipError.failed(code: result.exitCode, message: missing.0)` where `result.exitCode == 0`.
  2. **Multi-selection Copy (`⌘A` + `⌘C`) failure:** When a user selects all items (`⌘A`) in a folder containing regular files alongside even a single symbolic link and presses `⌘C` (`copyItems`), `ItemExtractor.extract` deletes the symlink and throws `SevenZipError.failed(code: 0, ...)` — aborting the entire copy operation and showing **`"The operation failed (code 0)."`** (`"İşlem başarısız oldu (kod 0)."`) instead of copying the regular files/folders.
  3. **Standalone symlink actions & drag:** Double-clicking (`openItem`), pressing Space (`toggleQuickLook`), or requesting Checksums (`showChecksums`) on a symbolic link row runs `7zz` and shows `"The operation failed (code 0)."` instead of skipping/disabling or showing a clear message; similarly, `dragItem(for:)` returns a non-`nil` `ArchiveItemTransfer` for symbolic link rows that then fails during transfer.
- **Fix:** Return `nil` from `dragItem(for:)` when `symbolicLinks.contains(node.id)`; filter out standalone `symbolicLinks` in `copyItems` when copying multiple items (or skip standalone symlinks without failing the remaining targets); and disable/guard `openItem`, `toggleQuickLook`, `showChecksums`, and `copyItems` on standalone symbolic link entries so users never hit a bogus `(code 0)` error.

#### R3-3. ✅ [P1] All-Special-File Sources (`FIFOs` / Sockets) in `AddPlan.make` & `addFiles`, Symlinked Directories When `storeSymlinks == false` in `SpecialFiles.archivePaths`, and `removeTree` in `AddPlan.make`
- **Status:** ✅ Done — `AddPlan.make` drops special sources first and throws `AddPlan.NothingToArchiveError` when nothing is left (no empty name list, no empty target folder); `createArchive` refuses special-only sources the same way (`nothingToArchive`). `AddPlan.make(followingSymlinks:)` (passed `!storeSymlinks`) also skips links to FIFOs, and its `catch` uses `StagedExtraction.removeTree`. `SpecialFiles.archivePaths(followingSymlinks: true)` walks into symlinked folders (also a symlinked source) with per-path cycle protection, reporting every path 7zz would read. Tests `addPlanRefusesOnlySpecialSources`, `addPlanCleansUpReadOnlyCopiesOnFailure`, `specialFilesBehindSymlinkedFolders`, `fifoBehindSymlinkedFolderDoesNotHang`, `onlySpecialFilesAreRefused`.
- **Locations:**
  - `Sources/ArhivarCore/ArchiveEditing.swift` (`AddPlan.make`, lines 83–118; `SpecialFiles.archivePaths`, lines 140–160)
  - `Sources/Arhivar/AppModel.swift` (`addFiles`, lines 1089–1106)
- **Problems (verified with live `7zz`):**
  1. **Empty `plan.names` or empty subfolder when all added sources are special files (FIFOs/sockets):**
     - In `AddPlan.make`, if the user adds two FIFOs from different directories to the archive root (`folder = ""`), the copy loop skips both FIFOs and returns `names = []`. Invoking `7zz a -- archive.zip` with an empty `names` list causes `7zz` to default to `*` and archive the entire working directory.
     - If the user adds only a FIFO into an archive subfolder (`folder = "alt"`), `AddPlan.make` creates `staging/alt`, skips the FIFO (`names = []`), and still returns `names = ["alt"]` (`topLevel`), causing `7zz` to add an empty `alt/` directory into the archive.
     - If `sources` in the same-parent fast path (`folder.isEmpty`) consists solely of FIFOs, `addFiles` still invokes `7zz a` where every input is excluded via `-x!`.
  2. **Symlinked directories when `storeSymlinks == false` (`followingSymlinks == true`):** In `SpecialFiles.archivePaths`, line 148 checks `StagedExtraction.itemType(source, fileManager: fileManager) == .typeDirectory` (which uses `lstat` and returns `.typeSymbolicLink` if `source` is a symlink to a directory), and `fileManager.enumerator(atPath: source.path)` does not descend into symlinked subdirectories. When `storeSymlinks == false` (or the format does not support symlinks), `7zz a` follows symlinked directories and hangs if a FIFO exists inside them. Similarly, `AddPlan.make` checks `SpecialFiles.isSpecial` with `followingSymlinks = false` even when `storeSymlinks == false`.
  3. **Read-only cleanup on `AddPlan.make` error:** Line 115 in `AddPlan.make`'s `catch` block calls `try? fileManager.removeItem(at: staging)` instead of `StagedExtraction.removeTree(at: staging, fileManager: fileManager)`, which fails to clean up `staging` if an earlier source copied a read-only (`0o555`) directory before a subsequent source threw an error.
- **Fix:** Ensure `AddPlan.make` (and `addFiles` / `createArchive`) does not return empty `names` or an empty `topLevel` directory when all sources are special files, traverse symlinked directories (with cycle protection) in `SpecialFiles.archivePaths` when `followingSymlinks == true`, pass `followingSymlinks: !storeSymlinks` to `AddPlan.make`, and use `StagedExtraction.removeTree` in `AddPlan.make`'s `catch` block.

#### R3-4. ✅ [P2] Guard `beginCreate` (`⌘N`) and `presentOpenPanel` (`⌘O`) During Active Operations
- **Status:** ✅ Done — `beginCreate` and `presentOpenPanel` return while an operation runs; New Archive… and Open Archive… are disabled in the File menu, the toolbar and the welcome screen. Test `newArchiveWaitsForTheRunningOperation`.
- **Locations:**
  - `Sources/Arhivar/AppModel.swift` (`presentOpenPanel`, lines 473–482; `beginCreate`, lines 1281–1283)
  - `Sources/Arhivar/ArhivarApp.swift` (`menuNewArchive`, `menuOpenArchive`, lines 85–94)
  - `Sources/Arhivar/Views/ContentView.swift` (`toolbarOpen`, `toolbarCreate`, lines 80–93)
- **Problem:** While an operation is running (`model.operation != nil`), `⇧⌘W` (`closeArchive`) and file drops (`handleDrop`) are blocked, but `⌘N` (`beginCreate`) and `⌘O` (`presentOpenPanel`) remain enabled in both the menu bar and the toolbar. Pressing `⌘N` during an active operation opens `CreateArchiveSheet` on top of `ProgressOverlay`; if the user fills out the sheet and clicks **Create** while the operation is still running, `createArchive` calls `perform`, which hits `guard operation == nil else { return }` and silently drops the creation request. Similarly, choosing an archive via `⌘O` while an operation is running silently does nothing.
- **Fix:** Guard `guard operation == nil else { return }` in `beginCreate` and `presentOpenPanel`, and add `.disabled(model.operation != nil)` to the **New Archive…** and **Open Archive…** buttons in `ArhivarApp.swift` and `ContentView.swift`.

---

### Second Hardening Round — Parser, Symlinks, Atomic Create, Quarantine, Wildcards & Special Files (2026-10-18)

All 13 items were reproduced against the bundled `7zz` 26.04 before the fix; the suite grew from 146 to 179 tests.

#### R2-1. ✅ [P0] Multi-Line Archive Comment (`Comment = \n{\n...\n}`) Header Spoofing & Fake Entry Injection in `ListingParser`
- **Status:** ✅ Done — `ListingParser.parse` treats the **last** `----------` line as the header/entries boundary (7zz turns newlines in entry fields into `_` and prints the marker for empty archives too, so a later marker proves the earlier ones were comment text); `parseInfo` reads a `Key = ` value followed by `{` up to the last `}` of the header and drops the wrapper lines. Tests `commentCannotSpoofHeaderOrInjectEntries`, `zipCommentCannotInjectEntries`.
- **Locations:**
  - `Sources/ArhivarCore/ArchiveListing.swift` (`ListingParser.parse`, lines 92–108)
  - `Sources/ArhivarCore/ArchiveListing.swift` (`ListingParser.parseInfo`, lines 118–148)
- **Problems (verified with live `7zz l -slt`):**
  1. `7zz l -slt` wraps multi-line archive comments in `{` and `}` (`Comment = \n{\n...\n}`). `parseInfo` currently includes the literal `{` and `}` wrapper lines in `ArchiveInfo.comment`.
  2. Inside `parseInfo`, `if let (key, value) = keyValue(line)` executes **before** `else if lastKey == "Comment"`. Any line inside a multi-line archive comment containing ` = ` (e.g. `Type = zip`, `Solid = +`, `Physical Size = 0`) overwrites `ArchiveInfo` header fields (which can trick `ArchiveCapabilities.isEditable` into treating a read-only archive as editable or vice versa) and truncates the remainder of the comment.
  3. **Fake entry injection:** If a multi-line archive comment contains a line of 10 dashes (`----------`) followed by `Path = fake_file.txt\nSize = 999999`, `ListingParser.parse` hits `isMarker(line, "----------")` while still inside the header comment block, switches `inEntries = true` prematurely, and injects fake `ArchiveEntry` rows into the browser table. (In the real entry section after the last `----------`, `7zz` replaces all `\n` in entry paths and entry comments with `_`, so `----------` can never legitimately appear inside an entry.)
- **Fix:** Track brace-delimited multi-line values (`{\n...\n}`) in `parseInfo` and `parse` (or split header vs. entries on the last `----------` marker outside a `{ ... }` block) so comment lines cannot spoof header fields or inject fake entries, and strip the outer `{` / `}` wrapper lines from `ArchiveInfo.comment`.

#### R2-2. ✅ [P0] Subfolder (`stripping`) & `ItemExtractor` Symlink Escape + `7zz` Dangerous-Link 0-Byte Placeholder Files
- **Status:** ✅ Done — `secureSymlinks(in: content, extractionRoot: staging)` validates links against the content that is actually moved (absolute links rewritten by 7zz must land inside it); `ItemExtractor` validates each target, never hands out a standalone symlink target, and removes the 0-byte placeholders 7zz leaves for rejected links (`StagedExtraction.removeLinkPlaceholders`, driven by the new `ArchiveEntry.isSymbolicLink` from `Attributes` / `Mode` / `Symbolic Link`); `contentRoot` refuses a stripped folder reached through a symlink. Tests `symlinksAreCheckedAgainstTheMovedContent`, `linkPlaceholdersAreRemoved`, `contentRootRejectsSymlinkedFolders`, `detectsSymbolicLinkEntries`, `itemExtractorContainsLinksAndPlaceholders`, `extractionDropsLinkPlaceholdersAndEscapingLinks`.
- **Locations:**
  - `Sources/Arhivar/AppModel.swift` (`runExtract`, lines 763–772)
  - `Sources/ArhivarCore/StagedExtraction.swift` (`secureSymlinks`, lines 113–157)
  - `Sources/ArhivarCore/ArchiveEditing.swift` (`ItemExtractor.extract`, lines 176–184)
- **Problems (verified with live `7zz x`):**
  1. **Subfolder (`stripping`) & `ItemExtractor` symlink escape:** In `AppModel.runExtract`, `StagedExtraction.secureSymlinks(in: staging)` runs against `staging` **before** `let content = StagedExtraction.contentRoot(in: staging, stripping: stripping)`. When extracting selected items from subfolder `a/b` (`stripping = "a/b"`), an absolute symlink `a/b/abs_link -> /etc/hosts` is rewritten by `7zz` to `<staging>/etc/hosts`; `secureSymlinks(in: staging)` rewrites it to `../../etc/hosts` (valid relative to `staging`, but **2 levels outside `content` (`<staging>/a/b`)**). `merge(from: content, into: destination)` then moves `abs_link -> ../../etc/hosts` directly to `destination/abs_link`, pointing two directories above `destination`. Similarly, in `ItemExtractor.extract` (used by Drag-to-Finder and `⌘C` Copy), `secureSymlinks(in: directory)` validates against the session `directory` rather than each extracted `target` in `targets`, allowing a symlink inside `a/b` (`a/b/link -> ../outside_b`) or a top-level symlink to escape when copied/dragged to Finder.
  2. **`7zz` 0-byte placeholder on ignored symlinks:** When `7zz x` rejects a traversal symlink with `ERROR: Dangerous link path was ignored : badlink : ../outside`, `7zz` leaves behind a **0-byte regular file (`-rw-r--r-- 0 badlink`)** on disk. In `runExtract` (with `.replace`), this 0-byte placeholder clobbers an existing file named `badlink` in `destination` (or creates a bogus 0-byte file). In `ItemExtractor.extract` (`openItem`, `toggleQuickLook`, `showChecksums`), `SevenZipError.check` returns a warning that `ItemExtractor` ignores, so Quick Look / Open opens a fake 0-byte file and Checksums reports the SHA-256 of 0 bytes (`e3b0c442...`).
- **Fix:** Run `secureSymlinks` against `content` (with `stagingPrefix` set to `staging` so `7zz`-rewritten absolute links into `<staging>/...` are still recognized and rejected if outside `content`), validate each `target` root in `ItemExtractor.extract` (and reject standalone symlinks or targets whose archive entry is a symlink that was turned into a 0-byte regular file by `7zz`), and remove any 0-byte regular files in staging whose archive entry was a symbolic link (`isSymbolicLink`).

#### R2-3. ✅ [P0] Atomic Staged Archive Creation (`createArchive` Overwrite Append/Failure, Split `.001` Existence Check & Partial File on Cancel)
- **Status:** ✅ Done — `createArchive` builds the archive in a same-volume staging folder (writable only there under the sandbox) and `StagedExtraction.installArchive` moves it into place only after success: an existing file is replaced in one step (also read-only ones), stale `.00N` volumes are removed first, and a folder with the same name is never deleted. `CreateArchiveSheet` checks `firstOutput` and rejects `.` / `..`; `createExistsWarning` now says the archive will be replaced (tr/en/ro). Tests `installedArchiveReplacesOldOneAndStaleVolumes`, `creatingReplacesAnExistingArchive`, `creatingASplitArchiveRemovesStaleVolumes`.
- **Locations:**
  - `Sources/Arhivar/AppModel.swift` (`createArchive`, lines 1209–1255)
  - `Sources/Arhivar/Views/CreateArchiveSheet.swift` (`destinationExists`, lines 201–203; `sanitizedName`, lines 170–179)
- **Problems (verified with live `7zz a`):**
  `CreateArchiveSheet` warns `"An archive with this name already exists and will be replaced"` (`createExistsWarning`), but `AppModel.createArchive` invokes `7zz a` directly on `options.destination`:
  1. If `.zip`, `.7z`, `.tar`, or `.wim` already exists at `destination`: `7zz a` **appends/merges** into the existing archive instead of replacing it, retaining old entries from the previous file.
  2. If an existing `.7z` at `destination` has encrypted headers (`-mhe=on`): `7zz a` fails with `Break signaled (EXIT=255)`, triggering a false `.wrongPassword` error when creating a brand-new archive.
  3. If `.gz`, `.bz2`, `.xz`, `.tar.gz`, `.tar.bz2`, or `.tar.xz` already exists at `destination`: `7zz a` fails with `System ERROR: E_INVALIDARG (EXIT=2)`.
  4. If a split archive (`ad.7z.001`) already exists: `CreateArchiveSheet.destinationExists` checks `destination.path` (`ad.7z`) instead of `firstOutput.path` (`ad.7z.001`), showing no warning, and `7zz a -v...` fails with `Updating for multivolume archives is not implemented (E_NOTIMPL)`.
  5. If the user cancels `createArchive` mid-operation, `7zz a` leaves a half-written corrupt archive at `options.destination`.
  6. In `CreateArchiveSheet`, typing `.` or `..` as the archive name passes `!sanitizedName.isEmpty`, producing hidden or malformed output filenames (`.7z`, `..7z`).
- **Fix:** Reject `.` and `..` in `CreateArchiveSheet.sanitizedName`, check `options.firstOutput.path` in `CreateArchiveSheet.destinationExists`, build new archives inside a same-volume `StagedExtraction.makeStagingDirectory(for: directory)`, and atomically move/replace the finished archive (or split volume set, removing any stale `.001`, `.002`, ... volumes first) into `directory` only after `7zz` succeeds.

#### R2-4. ✅ [P0] Gatekeeper Quarantine Bypass on Read-Only / Execute-Only Files (`0o555` / `0o444` / `0o111` / `0o000`) & `.replace` Failure on Read-Only Targets
- **Status:** ✅ Done — `OwnerAccess` grants the owner's missing permission bits briefly and restores them: `Quarantine.set` / `value` (now `XATTR_NOFOLLOW`) retry on `EACCES` / `EPERM`, `Quarantine.propagate` walks into `0000` / `0311` folders, `mergeItem` replaces read-only files and writes into read-only folders left by an earlier extraction, `ItemExtractor` uses `since: .distantPast`. `StagedExtraction.removeTree` also deletes read-only staging and session trees (`FileManager.removeItem` cannot). Tests `quarantineReachesReadOnlyItems`, `replaceWorksOnReadOnlyTargets`, `removeTreeDeletesReadOnlyFolders`, `readOnlyFilesKeepQuarantineAndCanBeReplaced`.
- **Locations:**
  - `Sources/ArhivarCore/Quarantine.swift` (`value`, lines 14–21; `set`, lines 31–34)
  - `Sources/ArhivarCore/StagedExtraction.swift` (`mergeItem`, lines 85–92)
  - `Sources/ArhivarCore/ArchiveEditing.swift` (`ItemExtractor.extract`, line 183)
- **Problems (verified on macOS 26 XNU / APFS):**
  1. **Gatekeeper bypass on `0o555` / `0o111` executables:** On macOS, `setxattr(..., "com.apple.quarantine", ..., XATTR_NOFOLLOW)` fails with `EACCES` (`errno = 13`) whenever the target file or folder lacks owner write permission (`S_IWUSR` / `0o200`), such as `0o555` (`r-xr-xr-x`, common on `.app/Contents/MacOS/*` binaries and `.command` scripts), `0o444`, `0o111`, or `0o000`. `Quarantine.set` discards the `-1` return value, allowing read-only executables inside a quarantined archive to be extracted **without `com.apple.quarantine`**, bypassing macOS Gatekeeper.
  2. **`Quarantine.value(of:)` on `0o111` / `0o000` & symlinks:** `getxattr` in `Quarantine.value(of:)` omits `XATTR_NOFOLLOW` and fails with `EACCES` on execute-only (`0o111`) or `0o000` files lacking `S_IRUSR` (`0o400`).
  3. **`.replace` failure on read-only existing files:** When extracting an archive a second time with `OverwriteMode.replace` over an existing read-only (`0o444` / `0o555`) file in `destination`, `FileManager.replaceItemAt(target, withItemAt: source, options: .usingNewMetadataOnly)` throws `NSCocoaErrorDomain Code=513 (Permission denied)`.
  4. **`ItemExtractor` timestamp threshold:** `ItemExtractor.extract` passes `since: start` instead of `since: .distantPast` to `Quarantine.propagate` even though `directory` is a freshly created `UUID` folder.
- **Fix:** In `Quarantine.set` and `Quarantine.value`, pass `XATTR_NOFOLLOW` and, if `setxattr`/`getxattr` fails with `EACCES`/`EPERM` on a non-symlink (`lstat`), temporarily add `S_IWUSR`/`S_IRUSR` (`chmod`) and restore the original mode immediately after; in `StagedExtraction.mergeItem`, ensure `S_IWUSR` on `target` before `replaceItemAt`; and pass `since: .distantPast` in `ItemExtractor.extract`.

#### R2-5. ✅ [P0] Wildcard Glob Expansion on Archive & Hash Paths (`-spd` Missing in `list`, `test`, `extract`, `hash`, `create`, `add`)
- **Status:** ✅ Done — `-spd` is always passed to `l`, `t`, `x` and `h` (as before to `d` and `rn`); `create`, `add` and `compressTarStage` include the archive path and the exclusions in `wildcardSafety`. Tests `archivePathsAreNeverWildcards`, `starredArchiveNamesAreLiteral`, `listAndTestArguments`, `extractAllArguments`.
- **Locations:**
  - `Sources/ArhivarCore/ArchiveOptions.swift` (`SevenZipCommand.list`, `test`, `extract`, `create`, `compressTarStage`, lines 228–314)
  - `Sources/ArhivarCore/ArchiveEditing.swift` (`SevenZipCommand.add`, line 31)
  - `Sources/ArhivarCore/Checksums.swift` (`SevenZipCommand.hash`, lines 19–21)
- **Problems (verified with live `7zz`):**
  `7zz` treats the **archive path argument itself** as a wildcard glob unless `-spd` is passed:
  1. Opening an archive whose filename or parent directory contains `*` or `?` (e.g. `yedek*1.7z` alongside `yedekX1.7z`) causes `SevenZipCommand.list` (no `-spd`) to list **all matching archives** in that directory; `ListingParser.parse` then parses the second archive's header and entries as entries of the first archive.
  2. `SevenZipCommand.extract` only passes `-spd` when `!options.items.isEmpty`; clicking **Extract All** (`items = []`) on `yedek*1.7z` extracts **all matching archives** in the folder.
  3. `SevenZipCommand.hash` (no `-spd`) hashes all matching files and outputs a combined multi-file digest (`...-00000001`) instead of the single file's digest.
  4. `SevenZipCommand.create` and `SevenZipCommand.add` only check `sources`/`names` for `*` or `?`, omitting `-spd` when the archive path itself contains `*` or `?`.
- **Fix:** Pass `-spd` unconditionally in `SevenZipCommand.list`, `test`, `extract`, `delete`, `rename`, and `hash` (none of which use wildcard filters), and include the archive/output path in `wildcardSafety(for:)` for `create`, `compressTarStage`, and `add`.

#### R2-6. ✅ [P0] Infinite Kernel Hang on FIFO Named Pipes (`mkfifo`), `AddPlan` Socket/FIFO Copy Failure & Sandbox Personal-Data Protection During Create/Add
- **Status:** ✅ Done — `SpecialFiles` finds FIFOs, sockets and device nodes (and links to them when links are followed) and they are excluded with `-x!<archive path>` (`CreateOptions.excludedPaths`, `SevenZipCommand.add(excluding:)`, `-spd` when such a path contains `*`/`?`); `AddPlan.make` copies with a `FileManagerDelegate` that skips them. Create and add keep personal-data protection: `SandboxProfile.forOperation(readable:)` only opens a protected folder the user picked a source from; `.zsh_history`, `.bash_history`, `Library/Containers`, `Library/Group Containers` and `Library/HTTPStorages` were added. Tests `specialFilesAreExcludedByArchivePath`, `addPlanSkipsFifosAndSockets`, `creatingKeepsPersonalDataProtected`, `fifosDoNotHangArchiveCreation`, `fifosAreSkippedWhenCreatingAndAdding`.
- **Locations:**
  - `Sources/ArhivarCore/ArchiveOptions.swift` (`SevenZipCommand.create`, lines 267–295)
  - `Sources/ArhivarCore/ArchiveEditing.swift` (`AddPlan.make`, lines 78–107)
  - `Sources/ArhivarCore/Sandbox.swift` (`SandboxProfile.forOperation`, lines 24–56)
  - `Sources/Arhivar/AppModel.swift` (`addFiles`, line 1047; `createArchive`, lines 1228–1230)
- **Problems (verified with live `7zz` & XNU kernel):**
  1. **Infinite kernel hang on FIFOs:** When compressing a folder containing a FIFO named pipe (`mkfifo`, common in developer/socket directories) into `.zip`, `.tar`, `.wim`, `.gz`, `.bz2`, `.xz`, or `.tar.*`, `7zz a` calls `open(fifo, O_RDONLY)` without `O_NONBLOCK` and **blocks in the kernel forever**.
  2. **`AddPlan.make` crash on FIFOs & Unix sockets:** When adding a folder containing a FIFO or Unix domain socket (`AF_UNIX`) into an archive subfolder, `FileManager.copyItem` throws `NSPOSIXErrorDomain Code=45 (ENOTSUP)` and aborts the entire add operation.
  3. **Symlink exfiltration when `protectPersonalData: false`:** `createArchive` and `addFiles` pass `protectPersonalData: false` to `SandboxProfile.forOperation`, disabling read protection for `~/.ssh`, `~/.aws`, `~/Library/Keychains`, etc. If a source folder contains a symlink to `~/.ssh/id_ed25519` and `storeSymlinks == false` (or the format is `.gz`/`.bz2`/`.xz`), `7zz` dereferences the symlink and packs the secret file into the archive.
- **Fix:** Exclude/skip non-regular/non-directory/non-symlink special files (FIFOs, sockets, device nodes) when staging in `AddPlan.make` and via `-x!` switches in `SevenZipCommand` (or pre-filtering), pass explicit `readable: sources` to `SandboxProfile.forOperation` so `protectPersonalData` remains `true` even during `create` and `add`, and expand `personalDataDirectories` with `Library/Containers`, `Library/Group Containers`, `Library/HTTPStorages`, `.zsh_history`, and `.bash_history`.

#### R2-7. ✅ [P1] `ArchiveTree.renamedPath` Trailing Slash Corruption & Duplicate Sibling Collision Check in `rename`
- **Status:** ✅ Done — `ArchiveTree.renamedPath` finds the parent without the trailing `/` and keeps that spelling (`klasor/` → `yeni/`); `AppModel.renameConflicts` (sibling names, case-insensitive like APFS; a case-only rename of the item itself is allowed) disables the Rename button and `rename` refuses with the new `renameExists` message. Tests `renamedPathKeepsTrailingSlashSpelling`, `renameRejectsSiblingNames`.
- **Locations:**
  - `Sources/ArhivarCore/ArchiveEditing.swift` (`ArchiveTree.renamedPath`, lines 236–245)
  - `Sources/Arhivar/AppModel.swift` (`rename`, lines 1090–1112)
- **Problems:**
  1. When `rawPath` (`entry.archivePath`) ends with a trailing slash (e.g. `"klasor/"`), `ArchiveTree.parent(of: "klasor/")` finds the trailing `/` and returns `"klasor"`, causing `ArchiveTree.renamedPath("klasor/", to: "yeni")` to return `"klasor/yeni"` (moving the folder inside itself instead of renaming it to `"yeni/"`).
  2. In `7zz rn -y`, renaming `a.txt` to an existing sibling `b.txt` succeeds without error and creates **two entries with identical `Path = b.txt`** inside the archive.
- **Fix:** Strip any trailing `/` before computing `parent(of:)` in `ArchiveTree.renamedPath` (preserving the trailing `/` on the resulting path if the original had one), and reject renames in `AppModel.rename` and `EditDialogs` when a sibling node already exists at the target normalized path.

#### R2-8. ✅ [P1] `AddPlan.make` Leading `./` Prefix Bug, `..` Component Normalization in `ListingParser` / `ItemExtractor`, and Duplicate Entry Deduplication in `ArchiveStatistics`
- **Status:** ✅ Done — `AddPlan.make` normalizes the target folder; `ListingParser.normalizedPath` drops `..` components exactly like 7zz (`a/../x` → `a/x`); `ItemExtractor` locates targets by normalized path; `ArchiveStatistics` counts only the latest of duplicate file entries (like `ArchiveTree.build`). Tests `normalizesEntryPaths`, `addPlanNormalizesDotPrefixedFolder`, `statisticsCountAppendedDuplicatesOnce`, `dotDotEntriesAndAppendedDuplicates`.
- **Locations:**
  - `Sources/ArhivarCore/ArchiveEditing.swift` (`AddPlan.make`, lines 83–103; `ItemExtractor.extract`, lines 162–168)
  - `Sources/ArhivarCore/ArchiveListing.swift` (`ListingParser.normalizedPath`, lines 193–212; `ArchiveStatistics.init`, lines 267–296)
- **Problems:**
  1. In an archive whose raw paths are prefixed with `./`, `AppModel.addFiles` passes `folderPath = archivePath(for: target)` (e.g. `"./belgeler"`). Inside `AddPlan.make`, `folder.split(separator: "/").first` evaluates to `"."` instead of `"belgeler"`, passing `.` as the staging item name.
  2. When an archive entry path contains `..` components (e.g. `a/../file.txt` or `../file.txt`), `7zz x` strips `..` components without collapsing `a/..` (extracting `<out>/a/file.txt` and `<out>/file.txt`), whereas `ListingParser.normalizedPath` keeps `".."` as a literal folder node in `ArchiveTree`, and `ItemExtractor.extract` resolves `a/../file.txt` via `standardizedFileURL` to `<dir>/file.txt` (mismatching `<dir>/a/file.txt`).
  3. When a `.tar` archive contains appended/updated duplicate entries for the same file path (`tar -rf`), `ArchiveTree.build` keeps the latest entry per path while `ArchiveStatistics.init` sums all duplicate entries, inflating `fileCount` and `totalSize`.
- **Fix:** Normalize `folder` in `AddPlan.make` with `ListingParser.normalizedPath(folder)`, filter out `".."` components in `ListingParser.normalizedPath` (matching `7zz`'s path sanitization) and use `ListingParser.normalizedPath` when computing `targets` in `ItemExtractor.extract`, and deduplicate file entries by normalized path in `ArchiveStatistics.init` (keeping the latest entry's size, matching `ArchiveTree.build`).

#### R2-9. ✅ [P1] Nested Archive Navigation Trap in Tree View (`⌘2`) and Search + Folder `Return`/`⌘↓` in Tree View
- **Status:** ✅ Done — `AppModel.showsPathBar` (folder view, or any view inside a nested archive) drives the path bar, whose folder crumbs appear only in folder view; ⌘↑ is enabled by `canGoUp && operation == nil` in every view (in tree view and search it returns to the parent archive); `primaryAction` on a folder switches to folder view and enters it. Test `treeViewKeepsTheWayBackFromNestedArchives`.
- **Locations:**
  - `Sources/Arhivar/Views/ArchiveBrowserView.swift` (`body`, line 72)
  - `Sources/Arhivar/ArhivarApp.swift` (`goUp`, line 150)
  - `Sources/Arhivar/AppModel.swift` (`primaryAction`, lines 676–685; `goUp`, lines 687–701)
- **Problems:**
  1. `PathBar` is only rendered when `model.browserMode == .folders && model.searchText.isEmpty`, and `⌘↑` (`goUp`) in `ArhivarApp.swift` is disabled whenever `model.browserMode != .folders`. If the user double-clicks a nested archive while in Tree View (`⌘2`), the nested archive opens in Tree View with `PathBar` hidden and `⌘↑` disabled — trapping the user inside the nested archive with no way back to the parent archive.
  2. In Tree View, pressing `Return` or `⌘↓` (`primaryAction`) on a folder does nothing (`if browserMode == .folders || !searchText.isEmpty`), whereas choosing **Open** from the context menu switches to `.folders` mode and enters the folder.
- **Fix:** Show `PathBar` whenever `(model.browserMode == .folders && model.searchText.isEmpty) || !model.archiveStack.isEmpty`, enable `⌘↑` whenever `model.canGoUp && model.operation == nil` (in Tree View or search, `goUp()` returns to the parent archive when `!archiveStack.isEmpty`), and make `primaryAction()` on a folder in Tree View switch `browserMode = .folders` and navigate into the folder.

#### R2-10. ✅ [P1] `closeArchive()` Zombie Resurrection During Active Operations & Unchecked Cancellation After `ensureEngine()` in `perform()`
- **Status:** ✅ Done — `closeArchive()` is ignored while an operation runs and ⇧⌘W is disabled unless `canOperate`; `perform` does not start the operation if it was cancelled while the engine was being checked. Tests `closeAndDropWaitForTheRunningOperation`, `cancellingWhileTheEngineIsCheckedStopsTheOperation`.
- **Locations:**
  - `Sources/Arhivar/AppModel.swift` (`closeArchive`, lines 544–559; `perform`, lines 1328–1338)
  - `Sources/Arhivar/ArhivarApp.swift` (`menuCloseArchive`, lines 96–98)
- **Problems:**
  1. `closeArchive()` (`⇧⌘W`) can be invoked while an operation (`addFiles`, `deleteItems`, `rename`, `openItem`, `browseArchive`) is running: it deletes `sessionRoot` mid-operation without cancelling `currentTask`, and when the operation's `readListing` finishes, the closed archive resurrects in the UI.
  2. In `AppModel.perform`, when `!engineChecked`, `currentTask` awaits `ensureEngine()` and then unconditionally calls `perform(...)` even if `cancelOperation()` was called while `ensureEngine()` was running.
- **Fix:** Guard `guard operation == nil else { return }` in `closeArchive()` (and disable `menuCloseArchive` when `!model.canOperate`), and check `guard !Task.isCancelled else { return }` after `await ensureEngine()` in `perform()`.

#### R2-11. ✅ [P2] Expand `OpenSafety` for `.workflow`, `.action`, `.osax`, `.url`, `.webloc` & Default-Ignorable Unicode Code Points
- **Status:** ✅ Done — `workflow`, `action`, `osax`, `url` and `webloc` added to `OpenSafety.riskyExtensions`; default-ignorable code points are flagged, except an emoji variation selector (U+FE0E / U+FE0F) right after an emoji. Test `moreRiskyExtensionsAndInvisibleCharacters`.
- **Locations:**
  - `Sources/ArhivarCore/OpenSafety.swift` (`riskyExtensions`, lines 13–25; `containsSpoofingCharacters`, lines 56–68)
- **Problems (verified on macOS 26):**
  1. On macOS 26, `UTType(filenameExtension: "workflow")` resolves to a dynamic UTI (`dyn.ah62d4rv4ge81s55wrrxg2551`) that does not conform to `com.apple.automator-workflow`. As a result, `OpenSafety.executableKind` returns `nil` for `.workflow`, `.action`, `.osax`, `.url`, and `.webloc` files unless their extensions are included in `riskyExtensions`.
  2. `containsSpoofingCharacters` does not check `scalar.properties.isDefaultIgnorableCodePoint`, missing invisible `nonspacingMark` spoofing code points such as `U+034F` (Combining Grapheme Joiner) and `U+17B4`/`U+17B5` (Khmer inherent vowels).
- **Fix:** Add `"workflow"`, `"action"`, `"osax"`, `"url"`, and `"webloc"` to `OpenSafety.riskyExtensions`, and include `scalar.properties.isDefaultIgnorableCodePoint` in `containsSpoofingCharacters`.

#### R2-12. ✅ [P2] Preserve `SidebarView` Selection & Cached Password When Navigating Nested Archives
- **Status:** ✅ Done — the sidebar selection follows `rootArchiveURL`, and `openArchive(_:)` of the root archive while nested calls `returnToArchive(level: 0)` (no reload, password and folder kept). Test `reopeningTheRootArchiveReturnsWithItsPassword`.
- **Locations:**
  - `Sources/Arhivar/Views/SidebarView.swift` (`selection`, lines 45–56)
  - `Sources/Arhivar/AppModel.swift` (`openArchive`, line 481)
- **Problem:** `SidebarView` binds its `List` selection to `model.archiveURL` instead of `model.rootArchiveURL`. Entering a nested archive deselects the root archive in the sidebar; clicking the root archive in the sidebar then calls `model.openArchive(url)` where `url == archiveURL` is `false` (since `archiveURL` is the nested archive in the temp session folder), which reloads the root archive from disk and discards its cached password instead of calling `returnToArchive(level: 0)`.
- **Fix:** Bind `SidebarView` selection to `model.rootArchiveURL`, and in `openArchive(_:)` return via `returnToArchive(level: 0)` when `url == rootArchiveURL && !archiveStack.isEmpty`.

#### R2-13. ✅ [P2] Guard `handleDrop` During Active Operations, Context-Menu `toggleQuickLook` Target Switching, Single `rebuildDisplay()` in `apply`, and Shell Script Hardening (`release.sh`, `package.sh`, `update-7zip.sh`)
- **Status:** ✅ Done — `handleDrop` ignores drops during an operation; `toggleQuickLook(path)` switches the preview to a different item (same item or Space closes it); `apply`, `returnToArchive` and `closeArchive` change tree/folder/search inside `updatingDisplayOnce` (one rebuild); `release.sh` matches the CHANGELOG heading literally with `index()`, `package.sh` lists outputs space-safely, `update-7zip.sh` ad-hoc signs the fallback-folder `7zz`. Tests `closeAndDropWaitForTheRunningOperation`, `quickLookSwitchesItemsAndDisplayIsRebuiltOnce`.
- **Locations:**
  - `Sources/Arhivar/AppModel.swift` (`handleDrop`, lines 540–541; `toggleQuickLook`, lines 652–662; `apply`, lines 824–831)
  - `Scripts/release.sh` (line 56), `Scripts/package.sh` (line 64), `Scripts/update-7zip.sh` (line 222)
- **Problems:**
  1. When `operation != nil`, dropping files onto the window evaluates `canAddFiles` as `false` and falls through to `beginCreate(sources: files)`, opening `CreateArchiveSheet` on top of a running operation.
  2. Calling `toggleQuickLook(path)` with an explicit `path` from the context menu while Quick Look is already open for another item closes Quick Look instead of switching the preview to `path`.
  3. `apply(_:keepFolder:)` sets `tree` and then `currentFolder`, triggering `rebuildDisplay()` twice (the first time with a stale `currentFolder`).
  4. In `Scripts/release.sh` line 56, `VERSION` is interpolated directly into an `awk` regex without escaping `.` characters; in `Scripts/package.sh` line 64, `ls -lh | awk '{ print $9 }'` truncates paths containing spaces; in `Scripts/update-7zip.sh` `install_to_dir`, `codesign --force --sign -` is not run on `$dest/7zz`.
- **Fix:** Guard `guard operation == nil else { return }` at the start of `handleDrop`, switch preview targets in `toggleQuickLook(_:)` when an explicit `path` differs from the currently previewed item, suppress the duplicate `rebuildDisplay()` in `apply(_:keepFolder:)`, escape `.` in `Scripts/release.sh`, use space-safe output in `Scripts/package.sh`, and ad-hoc sign `$dest/7zz` in `Scripts/update-7zip.sh`.

---

### Priority 0 (P0) — Critical Bugs, Security, Crash Prevention & Data Integrity

#### 1. ✅ [P0] Fix `encryptedHeaders` False Positive in `AppModel.readListing` (Swift `try?` Optional Flattening Bug)
- **Status:** ✅ Done — `SevenZipError.needsPassword(_:)` classifies the unauthenticated listing explicitly; regression tests `addingWithPasswordKeepsHeadersPlain`, `detectsEncryptedHeaders`.
- **Location:** `Sources/Arhivar/AppModel.swift` (lines 440–444)
- **Bug:**
  ```swift
  let plain = try? await runner.run(SevenZipCommand.list(archive: url))
  encryptedHeaders = plain.map { (try? SevenZipError.check($0)) == nil } ?? false
  ```
  `SevenZipError.check(_:)` returns `String?` and returns `nil` when `exitCode == 0` (success with no warnings). Under Swift's `SE-0230`, `try?` flattens `String??` to `String?`. Consequently, when the unauthenticated `plain` listing **succeeds** (`exitCode == 0`, meaning file names are **not** encrypted), `SevenZipError.check($0)` returns `nil`, and `(try? SevenZipError.check($0)) == nil` evaluates to `true`.
- **Impact:** Any password-protected `.7z` archive with unencrypted file names (`-mhe=off`) is misclassified as `headersEncrypted = true`, causing subsequent `addFiles` operations to pass `-mhe=on` and silently encrypt headers.
- **Fix:** Replace `(try? SevenZipError.check($0)) == nil` with `SevenZipError.needsPassword(plain)`.

#### 2. ✅ [P0] Prevent Integer Overflow Crash on Zip Bombs (`DiskSpace`, `ArchiveStatistics`, `ArchiveTree`)
- **Status:** ✅ Done — `Int64.saturatingAdding` / `saturatingSum()` used in all three places; test `hugeDeclaredSizesSaturate`.
- **Locations:**
  - `Sources/ArhivarCore/StagedExtraction.swift` (`DiskSpace.requiredBytes`, lines 120–126)
  - `Sources/ArhivarCore/ArchiveListing.swift` (`ArchiveStatistics.init`, lines 184–185)
  - `Sources/ArhivarCore/ArchiveTree.swift` (`ArchiveTree.convert`, lines 93–94)
- **Bug:** Unpacked and packed entry sizes (`Int64`) are summed using unchecked `+` (`reduce(0) { $0 + ($1.size ?? 0) }`). A maliciously crafted archive (Zip/7z bomb) declaring multiple entries whose sizes sum to `> Int64.max` triggers a Swift integer overflow trap (`EXC_BAD_INSTRUCTION`), crashing the app immediately upon opening or extracting the archive.
- **Fix:** Use saturating addition (`addingReportingOverflow`, clamping at `Int64.max`) wherever entry sizes are accumulated.

#### 3. ✅ [P0] Preserve `AES-256` When Adding Files to Encrypted ZIP Archives
- **Status:** ✅ Done — `SevenZipCommand.add(…, archiveType:)` passes `-mem=AES256` for ZIP; tests `addingToEncryptedZipKeepsAES`, `addToEncryptedZipUsesAES`.
- **Location:** `Sources/ArhivarCore/ArchiveEditing.swift` (`SevenZipCommand.add`, lines 20–26)
- **Problem:** `SevenZipCommand.create` passes `-mem=AES256` when creating an encrypted `.zip`, but `SevenZipCommand.add` only passes `-p`. Without `-mem=AES256`, `7zz` defaults to legacy weak `ZipCrypto` for newly added files in an existing encrypted `.zip`.
- **Fix:** Pass `-mem=AES256` in `SevenZipCommand.add` when updating a `.zip` archive with a password.

#### 4. ✅ [P0] Symlink Target Validation, Quarantine Preservation & `0o700` Staging Permissions
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

#### 5. ✅ [P0] Preserve Symbolic Links (`-snl`) When Archiving macOS `.app` Bundles & Frameworks
- **Status:** ✅ Done — `-snl` for 7z/ZIP/TAR/WIM/`.tar.*` on create and add, controlled by Settings › Compression › "Store symbolic links as links" (on by default); test `storesSymlinksAsLinks`.
- **Locations:** `Sources/ArhivarCore/ArchiveOptions.swift` (`SevenZipCommand.create`) & `Sources/ArhivarCore/ArchiveEditing.swift` (`SevenZipCommand.add`)
- **Problem:** `7zz a` is invoked without `-snl`. By default, `7zz` dereferences symbolic links instead of storing them as links. On macOS, archiving a `.app` bundle or `.framework` (which rely on versioned symlinks inside `Contents/Frameworks`) bloats the archive size ~3x, breaks code signatures upon extraction, and fails if a relative symlink is dangling.
- **Fix:** Pass `-snl` (with a default-enabled "Store symbolic links as links" option) when creating or adding to archives that support symlinks.

#### 6. ✅ [P0] Disable Wildcard Matching (`-spd`) in `SevenZipCommand.create` & `SevenZipCommand.add`
- **Status:** ✅ Done — `-spd` is passed whenever a source name contains `*` or `?` (it also disables the wildcards of `-x` patterns, so it is not passed otherwise); test `wildcardSourceNamesAreLiteral`.
- **Locations:** `Sources/ArhivarCore/ArchiveOptions.swift` (`SevenZipCommand.create`, lines 189–209) & `Sources/ArhivarCore/ArchiveEditing.swift` (`SevenZipCommand.add`, lines 20–26)
- **Problem:** `extract`, `delete`, and `rename` pass `-spd` so `*` and `?` in file names are not treated as wildcards, but `create` and `add` omit `-spd`. Compressing or adding a macOS file or folder whose name contains `*` or `?` (valid APFS characters, e.g. `İş*Yedek`) causes `7zz` to treat the path as a glob pattern.
- **Fix:** Conditionally pass `-spd` in `SevenZipCommand.create` and `SevenZipCommand.add` when source names contain `*` or `?`.

#### 7. ✅ [P0] Tighten `"Break signaled"` Password Classification & Escalate Hung `terminate()` to `SIGKILL`
- **Status:** ✅ Done — `"Break signaled"` counts as a password failure only together with `"Enter password"`; `ProcessBox.terminate()` sends `SIGKILL` after 2 seconds; tests `breakSignalWithoutPromptIsNotPassword`, `cancellationKillsProcessIgnoringSigterm`.
- **Location:** `Sources/ArhivarCore/CommandRunner.swift` (lines 33–37, 190–192)
- **Problems:**
  1. `SevenZipError.check` classifies any output containing `"Break signaled"` as `.wrongPassword`. However, `7zz` also prints `"Break signaled"` when terminated by an external `SIGINT`/`SIGTERM`. Only when `"Break signaled"` is accompanied by `"Enter password"` does it indicate an empty-stdin password abort.
  2. `ProcessBox.terminate()` sends `SIGTERM` (`process.terminate()`), but if `7zz` is wedged in a corrupted header loop and ignores `SIGTERM`, the continuation never resumes.
- **Fix:** Require `"Enter password"` alongside `"Break signaled"` for `.wrongPassword`, and schedule a `SIGKILL` (`kill(pid, SIGKILL)`) fallback if the process is still running 2 seconds after `terminate()`.

---

### Priority 1 (P1) — High-Impact Functional & UX Bugs

#### 8. ✅ [P1] Normalize Archive Entry Paths (`./`, Trailing `/`) in `ListingParser` & `ArchiveTree`
- **Status:** ✅ Done — `ArchiveEntry.path` / `ArchiveNode.id` are normalized; the raw path 7zz needs is kept in `archivePath` and used for every command; tests `normalizesEntryPaths`, `extractsDotPrefixedTarEntries`, `dotPrefixedTarBrowsesAndExtracts`.
- **Locations:** `Sources/ArhivarCore/ArchiveListing.swift` (`makeEntry`, line 148) & `Sources/ArhivarCore/ArchiveTree.swift` (`build`, line 90)
- **Problem:**
  1. `.tar` archives created with `tar -czf out.tgz .` store paths prefixed with `./` (e.g. `./src/main.swift`), creating a literal `"."` top-level folder in the browser.
  2. In `ArchiveTree.convert` (line 90), a directory node's `id` is set to `node.entry?.path ?? node.path`. If `node.entry?.path` contains a trailing slash (`"folder/"`) or duplicate slashes (`"a//b"`), `node.id` differs from the normalized path `"folder"` built by `breadcrumbs`, causing `nodeIndex[currentFolder]` lookups to return `nil`.
- **Fix:** Normalize entry paths in `ListingParser` (strip leading `./` and trailing `/`), always use the canonical `node.path` for `ArchiveNode.id`, and preserve `archivePath` for `7zz` invocations.

#### 9. ✅ [P1] Read-Only `.app` Bundle Version Detection in `update-7zip.sh` & `AppModel`
- **Status:** ✅ Done — `EngineUpdater(currentVersion:)` passes `--current` (unless a custom 7zz is chosen); the script falls back to the bundled 7zz version; test `updaterPassesCurrentVersion`, verified by hand on a read-only app copy.
- **Locations:** `Scripts/update-7zip.sh` (lines 68–78, 132–143) & `Sources/Arhivar/AppModel.swift` (lines 355–363)
- **Problem:** When `Arhivar.app/Contents/MacOS` is not writable (e.g. installed by root/admin or under App Translocation), `update-7zip.sh` switches its target to `~/Library/Application Support/Arhivar/engine`. If that fallback folder has not been created yet, `engine_version` reads `CURRENT=none` instead of the bundled `7zz` version, falsely reporting `STATUS=update-available` even when the bundled `7zz` is already up to date.
- **Fix:** Pass `--current <engineVersion>` from `AppModel` to `EngineUpdater`, and fall back to reading the bundled `Arhivar.app/Contents/MacOS/7zz` version in `update-7zip.sh` when `FALLBACK_DIR/7zz` does not exist yet.

#### 10. ✅ [P1] Fix Unreachable `localizedStandardCompare` in `ArchiveTree.sorted` & `ArchiveBrowserView`
- **Status:** ✅ Done — `ArchiveTree.nameComparator` (`.localizedStandard`) is the default sort order and the Name column's comparator; test `namesSortLikeFinder`.
- **Locations:** `Sources/ArhivarCore/ArchiveTree.swift` (lines 115–124) & `Sources/Arhivar/Views/ArchiveBrowserView.swift` (line 14)
- **Problem:** `TableColumn(settings.t(.columnName), value: \.name)` constructs a `KeyPathComparator(\ArchiveNode.name)` using raw Swift `String` `<` comparison (ASCII/Unicode scalar order). In `ArchiveTree.sorted`, `comparator.compare(lhs, rhs)` runs first and only falls through to line 123 (`lhs.name.localizedStandardCompare(rhs.name)`) when two items have the exact same name. As a result, `"Zebra"` sorts before `"apple"`, `"file10.txt"` before `"file2.txt"`, and Turkish `"Çanta"` after `"Z"`.
- **Fix:** Use `String.StandardComparator.localizedStandard` on the Name `TableColumn` and in `ArchiveTree.sorted`.

#### 11. ✅ [P1] Multi-Volume (Split) Archive Handling on Create, Open & Size Reporting
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

#### 12. ✅ [P1] Surface Automatic Arhivar App Updates on the Welcome Screen
- **Status:** ✅ Done — `UpdateBanner` shows a download banner for `model.appUpdateState == .available`.
- **Locations:** `Sources/Arhivar/AppModel.swift` (`launch`, line 230) & `Sources/Arhivar/Views/WelcomeView.swift` (`UpdateBanner`, lines 151–184)
- **Problem:** `AppModel.launch()` calls `checkForAppUpdate(interactive: false)` at startup, setting `model.appUpdateState = .available(release)`. However, `UpdateBanner` on `WelcomeView` only observes `model.updateState` (7-Zip engine updates) and ignores `model.appUpdateState`. Startup app update checks are therefore invisible unless the user opens **Settings › Advanced**.
- **Fix:** Display a download banner in `UpdateBanner` when `model.appUpdateState` is `.available(release)`.

#### 13. ✅ [P1] Clear `serviceQueue` When Cancelling an Active Operation
- **Status:** ✅ Done — `cancelOperation()` empties `serviceQueue`; test `cancelStopsServiceQueue`.
- **Locations:** `Sources/Arhivar/AppModel.swift` (`extractHere`, lines 805–822 & `cancelOperation`, line 927)
- **Problem:** When extracting multiple archives via Finder's **"Extract Here with Arhivar"** service, clicking **Cancel** on the progress overlay cancels `currentTask` for the current archive, but `serviceQueue` retains the remaining archives and immediately starts extracting the next one.
- **Fix:** Clear `serviceQueue` inside `cancelOperation()` so cancelling stops the entire batch.

#### 14. ✅ [P1] Duplicate Basename Detection in `CreateArchiveSheet` & `AddPlan`
- **Status:** ✅ Done — `AddPlan.duplicateNames(in:)`; the sheet shows the parent folders and disables Create, and both `AddPlan.make` and `AppModel.createArchive` throw `DuplicateNameError` with a readable message; tests `duplicateSourceNames`, `addingDuplicateNamesShowsError`, `createArchiveRejectsDuplicateNames`.
- **Locations:** `Sources/Arhivar/Views/CreateArchiveSheet.swift` (lines 78–96, 177–188) & `Sources/ArhivarCore/ArchiveEditing.swift` (`AddPlan.make`, lines 58–62)
- **Problem:** Selecting two files with the same name from different folders (e.g. `/FolderA/report.pdf` and `/FolderB/report.pdf`) shows both as `report.pdf` in `CreateArchiveSheet` without disambiguating paths and leaves **Create** enabled, causing `7zz` to fail with `Duplicate filename on disk`. In `AddPlan.make`, `fileManager.copyItem` throws a Cocoa file-exists error on the second file before `7zz` runs.
- **Fix:** Detect duplicate `lastPathComponent` values in `CreateArchiveSheet` (showing parent directory paths and a validation message) and guard against collisions in `AddPlan.make` and `AppModel.createArchive`.

#### 15. ✅ [P1] Relative Path Stripping When Extracting Selected Items from a Subfolder
- **Status:** ✅ Done — `StagedExtraction.contentRoot(in:stripping:)`; search results and tree view keep full paths; test `extractingFromSubfolderStripsPath`.
- **Locations:** `Sources/Arhivar/AppModel.swift` (`runExtract`, lines 573–581) & `Sources/ArhivarCore/StagedExtraction.swift`
- **Problem:** When browsing inside `a/b/c/` in Folder View and clicking **Extract Selected**, `7zz x` preserves the full internal path and creates `Destination/a/b/c/file.txt` instead of `Destination/file.txt` (unlike drag-to-Finder, which extracts the item directly).
- **Fix:** Strip the active `currentFolder` prefix in `StagedExtraction` when extracting selected items from Folder View.

#### 16. ✅ [P1] Preserve `currentFolder` on Cancelled PathBar Drop & Show Validation Hint for Empty Password Confirmation
- **Status:** ✅ Done — `AddRequest.folder` carries the target folder (no `goTo` before confirmation, ignored while an operation runs or with no files); the sheet shows "Enter the password again to confirm it."; test `addRequestCarriesTargetFolder`.
- **Locations:**
  - `Sources/Arhivar/Views/ArchiveBrowserView.swift` (`PathBar.crumb`, lines 218–224)
  - `Sources/Arhivar/Views/CreateArchiveSheet.swift` (`validationMessage`, line 179)
- **Problems:**
  1. Dropping files onto a breadcrumb in `PathBar` immediately calls `model.goTo(path)` before showing the confirmation dialog (`addRequest`). If the user clicks **Cancel** in the confirmation dialog, their current folder has already been changed; furthermore, `PathBar` does not check `model.operation == nil` or `!urls.isEmpty`.
  2. In `CreateArchiveSheet`, when `password` is non-empty and `confirmation` is empty, `isValid` is `false` (disabling the **Create Archive** button), but `validationMessage` checks `!confirmation.isEmpty` and shows no warning explaining why the button is disabled.
- **Fix:** Store the target folder inside `AddRequest` instead of calling `goTo(path)` before confirmation, and display the password confirmation hint whenever `password != confirmation`.

---

### Priority 2 (P2) — Security Hardening, System Integration & Polish

#### 17. ✅ [P2] Strengthen `SandboxProfile.personalDataDirectories` & `OpenSafety` Detection
- **Status:** ✅ Done — new personal and browser profile folders, AppleScript/Shortcuts/prefPane/qlgenerator UTIs plus an extension fallback, Braille and Hangul blank fillers; test `strongerPersonalDataAndOpenSafety`.
- **Locations:** `Sources/ArhivarCore/Sandbox.swift` (lines 24–30) & `Sources/ArhivarCore/OpenSafety.swift` (lines 7–15, 52–59)
- **Enhancements:**
  - Add `~/.kube`, `~/.docker`, `~/.npmrc`, `~/.pypirc`, `~/.git-credentials`, and browser profile directories to `SandboxProfile.personalDataDirectories`.
  - Add `.scpt`/`.applescript`, `.shortcut`, `.prefPane`, and `.qlgenerator` UTIs to `OpenSafety.riskyTypes`, and detect deceptive Unicode filler/blank characters (`U+2800` Braille blank, `U+3164` Hangul filler, `U+115F`/`U+1160`) in `OpenSafety.isDeceptive`.

#### 18. ✅ [P2] Count Implicit Intermediate Folders in `ArchiveStatistics.folderCount`
- **Status:** ✅ Done — `folderCount` counts explicit folder entries and the unique parent folders of every path; test `statisticsUsePhysicalSize`.
- **Locations:** `Sources/ArhivarCore/ArchiveListing.swift` (`ArchiveStatistics.init`, lines 180–188) & `Sources/ArhivarCore/ArchiveTree.swift`
- **Problem:** Many `.zip` and `.tar` archives omit explicit directory entries (`Folder = +`) and only store file paths such as `photos/vacation/img.jpg`. While `ArchiveTree.build` synthesizes intermediate folders for display, `ArchiveStatistics` computes `folderCount = listing.entries.count - files.count`, reporting `0` (or fewer) folders in the status bar and Info popover.
- **Fix:** Compute `folderCount` from the synthesized tree or unique parent directory paths.

#### 19. ✅ [P2] Pre-Flight Disk Space Check for Archive Creation & In-Place Editing
- **Status:** ✅ Done — `DiskSpace.requiredForWriting` before create, add, delete, and rename (current archive size for edits; source size for uncompressed output and the `.tar.*` intermediate tar; compressed output is not blocked because its size is unknown); test `spaceNeededForWriting`.
- **Location:** `Sources/Arhivar/AppModel.swift` (`createArchive`, line 874; `addFiles`, line 717; `deleteItems`, line 752; `rename`, line 773)
- **Problem:** `DiskSpace` / `InsufficientSpaceError.check` guards extraction, Quick Look, and drag-to-Finder, but archive creation and in-place edits (where `7zz` writes a temporary copy of the archive next to the original) do not check available disk space beforehand.
- **Fix:** Check available disk space on the target volume before creating or updating archives.

#### 20. ✅ [P2] Defer First-Launch Consent Alert When Launched via "Open With" / Finder Service
- **Status:** ✅ Done — the consent is pending until no operation, password prompt, alert, or sheet is shown; test `consentWaitsForColdStartOperation`.
- **Location:** `Sources/Arhivar/AppModel.swift` (`launch`, lines 226–228)
- **Problem:** If a user launches Arhivar for the first time by opening an archive from Finder, `launch()` immediately sets `alert = AlertItem(title: t(.consentTitle), ...)`, which can collide with or overwrite an archive warning/error alert from the cold-start operation.
- **Fix:** Present `askUpdateConsent()` only when `operation == nil && passwordRequest == nil && alert == nil`.

#### 21. ✅ [P2] Align Multi-File Handling (`handleOpenRequest`), Expand `Info.plist` UTIs & Document Icon Families
- **Status:** ✅ Done — archives together with other files go to the New Archive sheet (only archives → the first one opens); 14 imported type declarations and the known system archive UTIs added to document types and services, organized into six icon families (`zip`, `7z`, `rar`, `tar`, `disk`, `archive`) with `LSHandlerRank = Alternate`; tests `openRequestWithMixedFilesCreatesArchive`, `everyDocumentTypeHasItsIcon`, `documentTypesCoverEveryArchiveTypeOnce`.
- **Locations:** `Sources/Arhivar/AppModel.swift` (lines 480–487), `Sources/Arhivar/FinderServices.swift` (lines 22–26), `Support/Info.plist` & `Tests/ArhivarCoreTests/DocumentIconTests.swift`
- **Problems:**
  - `handleDrop` checks `files.count == 1` before opening an archive, whereas `handleOpenRequest` checks `files.first(where: isArchive)`, ignoring regular files dropped onto the Dock icon alongside an archive.
  - `ArchiveNaming.archiveExtensions` supports ~40 formats, but `Info.plist` only declares 10 base UTIs, leaving `.zst`, `.wim`, `.vmdk`, `.qcow2`, `.deb`, `.rpm`, and `.001` unlisted for Finder's **Open With** and **Services** menus.
- **Fix:** Align `handleOpenRequest` with `handleDrop` and declare the remaining archive UTIs in `Support/Info.plist`.

---

### Priority 3 (P3) — Resource Hygiene, Build Scripts & Performance

#### 22. ✅ [P3] Resource Hygiene & Zero-Allocation `ListingParser`
- **Status:** ✅ Done — stale previews are deleted when the same archive is reloaded, `discardTemporaryFiles()` cleans up the entire `archiveStack` on app exit, `resetAll()` removes `AppleLanguages` last and the browser mode, `FileIcons.byPath` is capped at 256 entries, `ListingParser` reads lines lazily; tests `editDiscardsStalePreviews`, `quittingInsideNestedArchiveRemovesAllSessions`, `resetRemovesAllPreferences`.
- **Locations:**
  - `Sources/Arhivar/AppModel.swift` (line 455): Clean up stale extracted files inside `sessionRoot` and reset `quickLookURL` when reloading the same archive after an in-place edit.
  - `Sources/Arhivar/AppSettings.swift` (lines 131–148): In `resetAll()`, remove `"AppleLanguages"` *after* setting `language = .tr` (or set `language` without writing `"AppleLanguages"`), and reset `browserMode`.
  - `Sources/Arhivar/Views/ArchiveBrowserView.swift` (lines 380–405): Bound or clear `FileIcons.byPath` so cached `NSImage` instances do not grow indefinitely.
  - `Sources/ArhivarCore/ArchiveListing.swift` (lines 59–63): Iterate over `output.utf8` lines lazily instead of allocating an intermediate `[Substring]` array (~2.4M elements for a 200k-entry archive).

#### 23. ✅ [P3] Packaging & Script Refinements (`package.sh`, `build_app.sh`, `update-7zip.sh`)
- **Status:** ✅ Done — `ditto` for `.dmg` staging; `SIGN_IDENTITY` (default ad-hoc; other identities get `--options runtime --timestamp`); `build_app.sh` bundles `Resources/DocumentIcons/*.icns` (drawing them via `make_document_icons.swift` if missing).
- **Locations:** `Scripts/package.sh` (line 54), `Scripts/build_app.sh` (lines 34–46, 52, 59) & `Scripts/update-7zip.sh` (line 103)
- **Enhancements:**
  - Use `ditto "$APP" "$STAGING/Arhivar.app"` instead of `cp -R` when staging the `.dmg` in `package.sh` to preserve bundle metadata and extended attributes cleanly.
  - Support an optional `SIGN_IDENTITY` environment variable in `build_app.sh` (defaulting to ad-hoc `-`) for Developer ID signing.

---

### Completed Features

#### 1. ✅ [High] Smart Subfolder Extraction ("Tarbomb" Protection)
- **Status:** ✅ Done — `SubfolderMode` (Smart default, Always, Never) in Settings › General; the decision looks at the extracted top-level items; the old Bool preference is migrated (off → Never); tests `contentRootAndSmartDestination`, `smartSubfolderWithRealArchive`, `smartSubfolderAvoidsDoubleNesting`.
- Single root item in the archive → extract directly into the destination folder (avoids `ArchiveName/ArchiveName/…` double nesting).
- Multiple root items → automatically create a subfolder named after the archive (`ArchiveNaming.baseName(of:)`).

#### 2. ✅ [High] Exclude macOS Metadata Files (`.DS_Store`, `._*`, `__MACOSX`)
- **Status:** ✅ Done — toggle in the New Archive sheet and Settings › Compression, also applied when adding; tests `excludesMacMetadataSwitches`, `excludesMacMetadata`. (When a source name contains `*` or `?`, `-spd` is required and the `._*` pattern cannot apply; `.DS_Store` and `__MACOSX` still do.)

#### 3. ✅ [High] Finder-Style Keyboard Shortcuts (`⌘↓`, `⌘I`, `⌘C` / `⌘V`, `⌘A`)
- **Status:** ✅ Done — Archive menu items for ⌘↓ and ⌘I; ⌘C / ⌘V through Edit menu commands (`AppModel.copyCommand` / `pasteCommand`, because `onCopyCommand` never reaches the hierarchical table), "Copy" in the context menu; tests `copyAndPasteFiles`, `editMenuCopiesAndPastesFiles`; ⌘A (`AppModel.selectAllCommand`) selects the visible items, test `editMenuSelectsAllItems`.

#### 4. ✅ [Medium] One-Step `.tar.gz`, `.tar.xz` & `.tar.bz2` Archive Creation
- **Status:** ✅ Done — two-step staged `.tar` + compression in `SevenZipCommand.tarStage` / `compressTarStage` and `AppModel.createArchive`; tests `tarCompressionCommands`, `createsCompressedTar`, `createsTarGzInOneStep`.

#### 5. ✅ [Medium] Nested Archive Navigation
- **Status:** ✅ Done — double-click / ⌘↓ / "Open in Arhivar"; `AppModel.archiveStack`, path bar crumbs for the enclosing archives, ⌘↑ at the root returns; nested archives are read-only and their session folders are deleted on return and on app exit; tests `browsesNestedArchives`, `returningFromNestedArchiveDoesNotCrash`, `quittingInsideNestedArchiveRemovesAllSessions`.

#### 6. ✅ [Nice-to-Have] Built-in Checksum / Hash Inspector (`7zz h`) & Archive Comments
- **Status:** ✅ Done — "Checksums…" in the context and Archive menus (CRC32, SHA-256, BLAKE2sp with a Copy button); the info panel shows the comment, solid blocks, and volumes; tests `parsesChecksumsAndComments`, `computesChecksums`, `showsChecksums`.

#### 7. ✅ [Nice-to-Have] Custom Finder Document Icons (Six Archive Families)
- **Status:** ✅ Done — `Scripts/make_document_icons.swift` draws six CoreGraphics document icon families (`zip`, `7z`, `rar`, `tar`, `disk`, `archive`, up to 512 px, ~1.7 MB total without SF Symbols) bundled into `Resources/DocumentIcons/*.icns`; `Support/Info.plist` maps all supported UTIs across the six families with `LSHandlerRank = Alternate`; tests `everyDocumentTypeHasItsIcon`, `documentTypesCoverEveryArchiveTypeOnce` (`Tests/ArhivarCoreTests/DocumentIconTests.swift`).
