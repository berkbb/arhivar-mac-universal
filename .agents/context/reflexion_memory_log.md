# Reflexion Memory Log — Self-Correction & Episodic Memory

> **Memory Category:** Google DeepMind Reflexion Asset (Episodic Memory & Self-Correction)  
> **Scope:** Non-obvious root causes, subtle framework traps, and verified architectural lessons discovered during Arhivar development and multi-round audits.

---

## Episode 1: Swift `SE-0230` `try?` Optional Flattening on `SevenZipError.check`
- **Context:** Detecting whether a password-protected `.7z` archive has encrypted file names (`-mhe=on`) by running an unauthenticated `7zz l` check.
- **Faulty Pattern:**
  ```swift
  encryptedHeaders = plain.map { (try? SevenZipError.check($0)) == nil } ?? false
  ```
- **Root Cause:** `SevenZipError.check(_:)` returns `String?` (an optional warning message) and returns `nil` when `exitCode == 0`. Under Swift `SE-0230`, `try?` flattens `String??` into `String?`. Thus, when the unauthenticated listing **succeeded** (`exitCode == 0`, meaning headers were **not** encrypted), `(try? SevenZipError.check($0)) == nil` evaluated to `true`, falsely marking unencrypted headers as encrypted and turning `-mhe=on` on during subsequent `addFiles` operations.
- **Lesson & Guardrail:** Never use `(try? fn()) == nil` to test whether a throwing function that returns an `Optional` threw an error. Use explicit `do/catch` helper `SevenZipError.needsPassword(_:)`.

---

## Episode 2: `7zz -spd` Disables Wildcards in `-xr!._*` Exclusion Switches
- **Context:** Passing `-spd` to `7zz a` so source file names containing `*` or `?` are treated literally while also passing `-xr!.DS_Store -xr!._* -xr!__MACOSX` to exclude macOS metadata.
- **Root Cause:** In `7zz`, `-spd` globally disables wildcard matching for **both** input file arguments and `-x` exclusion switches. When `-spd` is unconditional, `-xr!._*` stops matching AppleDouble `._file` entries.
- **Lesson & Guardrail:** `SevenZipCommand.wildcardSafety(for:)` must pass `-spd` on `create` and `add` **only** when a source path actually contains `*` or `?`.

---

## Episode 3: SwiftUI Hierarchical `Table` Crashes When Cells Read `@Environment`
- **Context:** Navigating into a folder in `ArchiveBrowserView` (`Table(model.displayNodes, children: \.children, ...)`) and returning to the archive root via `PathBar` or `⌘↑`.
- **Root Cause:** AppKit/SwiftUI's `NSTableView`/`NSOutlineView` bridge re-inserts top-level rows during hierarchy updates without propagating SwiftUI `@Environment` values to recycled cell hosts, crashing at runtime with `"No Observable object of type AppModel found"`.
- **Lesson & Guardrail:** Never use `@Environment(AppModel.self)` or `@Environment(AppSettings.self)` inside `TableColumn` cell views (`NameCell`). Always pass `model` and `settings` as explicit struct properties and verify with off-screen `NSWindow` rendering in `BrowserViewTests`.

---

## Episode 4: SwiftUI `Table` Blocks `onCopyCommand`, `onPasteCommand`, and `selectAll:`
- **Context:** Supporting Finder-style `⌘C` (copy selected archive items as files), `⌘V` (paste files into an editable archive), and `⌘A` (select all visible items).
- **Root Cause:** SwiftUI's hierarchical `Table` does not forward `onCopyCommand`, `onPasteCommand`, or the standard `selectAll:` responder action.
- **Lesson & Guardrail:** Replace `CommandGroup(replacing: .pasteboard)` in `AppCommands` and check `AppModel.isEditingText` (`NSApp?.keyWindow?.firstResponder is NSText`). When editing text (search field, rename dialog, password sheet), forward `copy:`, `paste:`, and `selectAll:` via `NSApp.sendAction`; otherwise invoke `model.copyItems()`, `model.pasteFiles()`, or `model.selectAllCommand()`.

---

## Episode 5: `/usr/bin/sandbox-exec` Requires `realpath(3)` (`/private` Prefix)
- **Context:** Generating SBPL `subpath` rules for temporary and staging directories in `/tmp` or `/var/folders/...`.
- **Root Cause:** `URL.resolvingSymlinksInPath()` canonically strips the `/private` prefix from `/private/tmp` and `/private/var`, whereas the macOS kernel sandbox (`sandbox-exec`) matches against the true VFS path (`/private/var/...`).
- **Lesson & Guardrail:** Always resolve paths for `SandboxProfile` and `StagedExtraction.secureSymlinks` using POSIX `realpath(3)` on the nearest existing ancestor directory.

---

## Episode 6: Normalized UI Paths vs. Raw `7zz` Archive Paths (`./` Prefix)
- **Context:** Opening `.tar` archives created with `tar -cf a.tar -C dir .`, where every entry path starts with `./` (e.g., `./alt/b.txt`).
- **Root Cause:** Displaying raw paths creates a redundant `"."` folder in the UI, and trailing/duplicate slashes break breadcrumb lookup. However, if only the normalized path (`alt/b.txt`) is stored, passing `alt/b.txt` back to `7zz x`, `7zz d`, or `7zz rn` fails because `7zz` compares arguments against the exact raw string stored in the archive header (`./alt/b.txt`).
- **Lesson & Guardrail:** Store both `path` (normalized for UI, tree IDs, and breadcrumbs) and `archivePath` (raw for `7zz` commands) on `ArchiveEntry` and `ArchiveNode`, deriving `archivePath` for synthesized intermediate folders via `ArchiveTree.rawPrefix`.

---

## Episode 7: Cleaning Up `archiveStack` Sessions on App Termination (`⌘Q`)
- **Context:** Browsing a nested archive (`archiveStack` non-empty) and quitting the app (`applicationWillTerminate` → `discardTemporaryFiles()`).
- **Root Cause:** Calling only `discardSessionDirectory()` on termination deleted only the innermost archive's `sessionRoot`, leaving parent session directories in `archiveStack` (containing extracted inner archives and outer previews) on disk until the 6-hour stale sweep.
- **Lesson & Guardrail:** `discardTemporaryFiles()` must call `discardAllSessions()` so every `sessionRoot` in `archiveStack` is removed immediately on quit.

---

## Episode 8: `7zz l -slt` Multi-Line Archive Comments (`{ ... }`) & Fake `----------` Marker Injection
- **Context:** Parsing `7zz l -slt` output when an archive header contains a multi-line `Comment = \n{\n...\n}` block.
- **Root Cause:** `7zz` outputs multi-line archive comments verbatim inside `{ ... }` before the entry list, whereas newlines inside actual entry fields are sanitized to `_`. Treating the *first* `----------` line as the entry boundary or parsing `key = value` lines inside `{ ... }` allowed crafted archive comments to overwrite header fields (`Type`, `Solid`) and inject fake `ArchiveEntry` rows.
- **Lesson & Guardrail:** Always split header vs. entries on the **last** `----------` marker line (`ListingParser.parse`) and consume brace-delimited multi-line header values up to the last `}` in `ListingParser.parseInfo`.

---

## Episode 9: Content-Rooted Symlink Validation & `7zz` 0-Byte Dangerous-Link Placeholders
- **Context:** Extracting selected items from a subfolder (`stripping = "a/b"`) or via `ItemExtractor`, and handling `7zz` `Dangerous link path was ignored` warnings.
- **Root Cause:**
  1. `7zz` rewrites absolute symlinks (`/etc/hosts`) to point inside the extraction root (`<staging>/etc/hosts`). Validating symlinks against `staging` before stripping `a/b` rewrote `a/b/link` to `../../etc/hosts`, which escaped two levels above `destination` once `<staging>/a/b` was moved.
  2. When `7zz` rejects a traversal symlink (`../outside`), it leaves a 0-byte regular file at the symlink path, which could clobber an existing file in `.replace` mode or serve a fake 0-byte file to Quick Look / Checksums.
- **Lesson & Guardrail:** Always run `StagedExtraction.secureSymlinks(in: content, extractionRoot: staging)` against the actual moved content root, and call `StagedExtraction.removeLinkPlaceholders` using `ArchiveEntry.isSymbolicLink` before merging or previewing.

---

## Episode 10: `setxattr` `EACCES` on Read-Only (`0o555`) Executables & `7zz` Kernel Hang on FIFOs
- **Context:** Propagating `com.apple.quarantine` to extracted `.app` binaries / `.command` scripts with mode `0o555`/`0o444`/`0o111`/`0o000`, and archiving folders containing named pipes (`mkfifo`).
- **Root Cause:**
  1. On macOS, `setxattr` and `FileManager.replaceItemAt` fail with `EACCES` if a file lacks owner write (`S_IWUSR`), and `getxattr` fails if a file lacks owner read (`S_IRUSR`).
  2. `7zz a` opens FIFO named pipes with `open(..., O_RDONLY)` without `O_NONBLOCK`, hanging in the kernel indefinitely.
- **Lesson & Guardrail:** Wrap xattr reads/writes, directory merges, and tree removals with `OwnerAccess` (restoring the original mode afterward), and exclude FIFOs, sockets, and device nodes via `SpecialFiles` (`-x!` and `SkippingCopier`).

---

## Episode 11: `7zz` Treats the Archive Path Argument Itself as a Wildcard Glob
- **Context:** Listing, testing, extracting, or hashing an archive whose filename contains `*` or `?` (e.g., `yedek*1.7z`).
- **Root Cause:** Without `-spd`, `7zz` expands `*` and `?` in the archive/file path argument itself, operating on all matching sibling archives in the same directory.
- **Lesson & Guardrail:** Pass `-spd` unconditionally in `list`, `test`, `extract`, `delete`, `rename`, and `hash`, and include the archive/output path and `excluding` paths in `wildcardSafety(for:)` for `create`, `compressTarStage`, and `add`.

---

## Episode 12: `..` Intermediate Folder Raw Prefix & Standalone Symbolic Link Safety
- **Context:** Synthesized folder trees from entries with `..` components (e.g. `../a/b.txt`), and single-item actions on standalone archive symbolic links.
- **Root Cause:**
  1. `ArchiveTree.rawPrefix` skipped `.` but not `..`, assigning `..` as the raw `archivePath` for synthesized folder `a`, causing 7zz to extract all sibling items under `..`.
  2. Standalone symbolic links extracted via `ItemExtractor` were removed to prevent escaping links or 0-byte placeholders, but threw `SevenZipError.failed(code: 0)`. In multi-select copy (`⌘A` + `⌘C`), a single symlink failed the entire copy with code 0.
- **Lesson & Guardrail:** `ArchiveTree.rawPrefix` must skip both `.` and `..`. Standalone links throw typed `ItemExtractor.SymbolicLinkError`, multi-selection copy skips standalone links and copies the remaining files, and single-item actions show an informative explanation without spawning 7zz.

---

## Episode 13: Read-Only Directory Tree (`0o555` / `0o444`) Immunity & Unlocked Password Reuse
- **Context:** Extracting and merging archives into existing directories that have mode `0o555` / `0o444` / `0o000`, and invoking "Extract Here" on an archive currently open and unlocked in the main window.
- **Root Cause:**
  1. In `.replace` mode, replacing an existing target directory with a file used `fileManager.removeItem(at: target)` instead of `removeTree`, failing with `EACCES` (Cocoa error 513) if the target contained read-only items. Similarly, merging into `0o444` directories lacked `S_IXUSR`, and scanning/rewriting symlinks inside `0o555` folders silently failed with `EACCES`.
  2. `AppModel.extractHere` passed `password: nil` even when the target archive was already open and unlocked in the main window (`archive == archiveURL`), causing 7zz to abort and `handle` to clear the open archive's valid `password`.
- **Lesson & Guardrail:** Use `removeTree` when replacing directories, grant `S_IWUSR | S_IXUSR` when merging directories, temporarily open `S_IRWXU` during `secureSymlinks` directory traversal (restoring original modes afterward), and reuse `archive == archiveURL ? password : nil` in `extractHere`.

---

## Episode 14: Folder Collision Pre-Flight, Read-Only Archive In-Place Guard & Old-Style RAR Multi-Volume
- **Context:** Creating an archive whose target name collides with an existing folder, opening read-only archives for editing, and handling old-style multi-part RAR archives (`.r00`..`.r99`).
- **Root Cause:**
  1. `CreateArchiveSheet` used `fileExists` which returned true for directories, misleadingly stating an archive would be replaced, while `AppModel.createArchive` ran `7zz a` first before failing on `installArchive` (`CocoaError.fileWriteFileExists`).
  2. `ArchiveCapabilities.isEditable` didn't verify filesystem permissions, offering Add/Delete/Rename on read-only archives (`0o444`, locked files, or read-only DMGs) where 7zz failed with `errno=13 : Permission denied`.
  3. Old-style multi-volume RAR archives (`.r00`..`.r99`) were unrecognized in `ArchiveNaming.archiveExtensions` and failed in 7zz if not opened from `.rar`.
  4. Negative sizes in corrupted/malicious archive entries could reduce total bytes in `DiskSpace.requiredBytes`.
- **Lesson & Guardrail:** Validate folder collisions upfront (`!isFolderConflict` in `CreateArchiveSheet`, pre-flight check in `createArchive`), verify `isWritableFile` on archive and parent directory for `isEditable`, recognize `r\d\d` in `ArchiveNaming.firstVolume`, and read sizes as non-negative with saturating arithmetic.

---

## Episode 15: RAR Multi-Part Name Stripping, Split ZIP `.z01` Handling & Multi-Volume In-Place Edit Guard
- **Context:** Extracting multi-part RAR archives (`film.part01.rar`), opening split ZIP secondary volumes (`archive.z01`), and preventing in-place editing on multi-volume archives.
- **Root Cause:**
  1. `ArchiveNaming.baseName(of:)` only stripped extensions if `isArchiveExtension(ext)`. For `film.part01.rar`, `.rar` was removed, but `.part01` was not in `archiveExtensions`, leaving `"film.part01"` and causing smart subfolder extractions to create `film.part01/` instead of `film/`.
  2. Classic split ZIP secondary parts (`.z01`..`.z99`) were not recognized as archive extensions and lacked redirection to `archive.zip` in `ArchiveNaming.firstVolume(of:)`.
  3. 7-Zip cannot update multi-volume archives in place. `ArchiveCapabilities.supportsEditing` only checked for 3-digit numeric extensions (`.001`), so multi-volume ZIP/7z archives (`volumes > 1`) enabled editing buttons in the toolbar and failed upon modification.
- **Lesson & Guardrail:** Strip `part\d+` suffixes in `ArchiveNaming.baseName(of:)`, recognize split ZIP volumes (`isSplitZipVolume`) in `isArchiveExtension` and redirect to `.zip` in `firstVolume(of:)`, and check `volumes > 1` along with split volume extensions in `ArchiveCapabilities.supportsEditing`.

---

## Episode 16: Split ZIP (`.zNN`) False Positives on ROMs (`.z64`, `.z80`) & Sibling `.zip` Verification
- **Context:** Dropping non-archive files with `z + digits` extensions (such as Nintendo 64 ROMs `.z64` or ZX Spectrum snapshots `.z80`) onto the app window or double-clicking them inside an archive.
- **Root Cause:**
  - `isSplitZipVolume` matched any extension starting with `z` followed by digits. When included unconditionally in `isArchiveExtension(ext)`, standalone `.z64` or `.z80` files were classified as archives by filename alone.
  - Dropping one caused Arhivar to attempt opening it as an archive (failing with "not an archive") instead of presenting the New Archive creation sheet.
  - Inside an archive, `isBrowsable` offered them for nested archive browsing rather than launching the default external app.
- **Lesson & Guardrail:** Name-only `isArchiveExtension` must exclude split ZIP secondary volumes (`.z01`..`.z99`). Instead, `ArchiveNaming.isArchive(url, fileManager:)` verifies the existence of a sibling `.zip` master volume on disk before accepting a `.zNN` file as an archive. Inside an archive (where sibling checks cannot be performed), `.zNN` files open with the user's default external application.



