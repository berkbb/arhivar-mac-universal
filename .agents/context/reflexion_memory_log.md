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

---

## Episode 17: macOS Metadata Filtering in Smart Subfolder Destination Extraction
- **Context:** Extracting single-folder ZIP archives created on macOS (e.g. via Finder's "Compress" contextual menu or command-line `zip`) using the default `.smart` subfolder extraction mode.
- **Root Cause:**
  - Finder creates AppleDouble metadata directories/files (`__MACOSX/`, `.DS_Store`, and `._*`) alongside the compressed payload folder.
  - In `StagedExtraction.destination(for:base:archiveName:mode:)`, `.smart` mode inspected the staging directory root using `fileManager.contentsOfDirectory(atPath: content.path)`.
  - Because `roots.count` included `__MACOSX` or `.DS_Store` along with the single project folder (e.g., `["Proje", "__MACOSX"]`, count = 2), `roots.count > 1` evaluated to true.
  - This caused `StagedExtraction.destination` to return `subfolder`, extracting into `base/Proje/Proje/...` (unwanted double nesting).
- **Lesson & Guardrail:** Filter out macOS metadata (`.DS_Store`, `__MACOSX`, and `._*`) from root content entries when evaluating whether an archive has a single root or multiple roots in `.smart` mode. If filtering leaves only meaningful entries, evaluate based on the meaningful count; if all items were metadata, fall back to the raw count. Test `smartDestinationIgnoresMacMetadata`.

---

## Episode 18: 11-Discipline Chaos, Security, Stress, Penetration & Robustness Test Matrix
- **Context:** Subjecting the application to an exhaustive testing matrix spanning Security, Stress, Destructive, Penetration, Load, Volume, Endurance, Vulnerability Scanning, Red Team Operations, Fuzzing, and Chaos disciplines.
- **Key Invariants & Verified Traps:**
  1. *Zip-Slip & Path Traversal:* Symbolic links attempting to escape the extraction root via relative (`../../etc/passwd`) or absolute paths (`/private/etc/hosts`) rewritten by `7zz` are aggressively removed or rewritten relative to destination by `StagedExtraction.secureSymlinks`.
  2. *Zero Password Exposure:* Passwords must never be present in argv arrays or process environment variables where `ps` or DTrace can inspect them. Verified that `SevenZipCommand` passes `-p` without argument and supplies credentials strictly through stdin `Pipe`.
  3. *Stack & Heap Memory Under Stress:* Verified `ArchiveTree.build` processes 2,000 flat directory items and 35-level deep recursive hierarchies without deep call-stack recursion overflow or memory exhaustion.
  4. *Destructive Inputs:* Corrupt archives (0 bytes, random non-header bytes) are handled gracefully via typed `SevenZipError` and `ListingParser` error paths with zero process traps.
  5. *Quarantine Cleansing:* Verified `Quarantine.cleansedValue` systematically clears the user-approved flag `0x0040` from `com.apple.quarantine` attributes, ensuring Gatekeeper re-evaluation for extracted items.
  6. *Zip Bomb Protection:* Verified `Int64.saturatingAdding` and `requiredBytes` ensure integer overflow does not trigger `EXC_BAD_INSTRUCTION` traps when summing maliciously inflated archive sizes.
  7. *Endurance & Descriptor Leaks:* Verified 30 consecutive staging make/teardown cycles under read-only (`0o555` / `0o444`) permissions operate without file descriptor leaks or permission degradation.
  8. *Command & Unicode Injection:* Guarded against CLI argument injection via mandatory `--` delimiters and `-spd`, and detected deceptive Trojan Source / bidirectional control characters (`U+202E`, `U+2800`, `U+3164`, `U+200B`) via `OpenSafety`.
  9. *Red Team Containment:* Exfiltration via standalone symbolic links is intercepted with `ItemExtractor.SymbolicLinkError`, and in-place editing operations on read-only files or multi-volume archives are rejected upfront.
  10. *Fuzzing Resilience:* `ListingParser.parse` recovers gracefully from malformed listings, unclosed brace blocks, missing fields, and negative sizes without unhandled fatal errors.
  11. *Chaos & Termination Escalation:* When a child process refuses SIGTERM cancellation, `CommandRunner` escalates to SIGKILL within 2 seconds. Owner permissions on unreadable files (`0o000` / `0o555`) are safely elevated and restored by `OwnerAccess`, and concurrent execution across 20 parallel async tasks operates reentrantly without race conditions.
- **Lesson & Guardrail:** Dedicated matrix tests must be retained in `ChaosAndSecurityMatrixTests.swift` and executed on every CI and pre-release gate.
---

## Episode 19: SwiftUI `.quickLookPreview` Framework Trap on Rapid Key Toggles (`Cmd+Y` / `Space`)
- **Context:** Rapidly toggling file previews inside an archive using `Cmd+Y` or `Space` 3 or more times consecutively.
- **Root Cause:** Apple's private `_QuickLook_SwiftUI` framework has an unhandled condition on macOS Tahoe: when the binding `$model.quickLookURL` changes rapidly, `-[QLPreviewPanelController _doReloadDataIfNecessary]` executes Foundation KVO notifications where `currentPreviewItemIndex` evaluates to `NSNotFound` (`Int.max` = `0x7fffffffffffffff`). Apple's internal Swift closure in `_QuickLook_SwiftUI` performs an out-of-bounds array subscript or range check with `Int.max`, triggering an immediate `EXC_BREAKPOINT` / `SIGTRAP` fatal trap that crashes the application process.
- **Solution & Guardrail:**
  1. Remove SwiftUI's `.quickLookPreview` modifier entirely from views.
  2. Implement a dedicated AppKit `QuickLookCoordinator` managing the native `QLPreviewPanel.shared()` singleton conforming to `QLPreviewPanelDataSource` and `QLPreviewPanelDelegate`.
  3. Wire AppKit responder methods `acceptsPreviewPanelControl`, `beginPreviewPanelControl`, and `endPreviewPanelControl` on `AppDelegate`.
  4. Intercept `Space` (key code 49) and `Esc` (key code 53) in `previewPanel(_:handle:)` to ensure clean keyboard dismissal.
  5. In headless unit testing environments (`isTesting`), bypass `makeKeyAndOrderFront` and asynchronous window visibility KVO observation to prevent background tasks from prematurely clearing `model.quickLookURL`.

---

## Episode 20: PluginKit App Sandbox Entitlement & UTI Declarations for Finder Quick Look (`.appex`)
- **Context:** Quick Look preview of archive files in macOS Finder when pressing Space. Even though the extension was selected in System Settings > Quick Look, pressing Space on an archive displayed only generic file metadata rather than the rich contents view.
- **Root Causes:**
  1. *PluginKit Daemon Rejection:* macOS `pkd` requires all Quick Look App Extensions (`com.apple.quicklook.preview`) to carry `com.apple.security.app-sandbox = true` in their code signature entitlements. When codesigned without `--entitlements Support/QuickLook.entitlements`, `pluginkit -a` silently fails to activate the plug-in (`pkd` marks it inactive).
  2. *UTImportedTypeDeclarations Prerequisite:* QuickLook inspects `QLSupportedContentTypes` in the extension's `Info.plist`. If any UTI (e.g. `org.7-zip.7-zip-archive`, `com.rarlab.rar-archive`, `org.tukaani.xz-archive`) is not declared in `UTImportedTypeDeclarations` in the host or extension `Info.plist`, `QuickLookSupport` logs `Invalid content type identifier` and skips the extension entirely.
  3. *Security-Scoped URL Access in Sandboxed Extensions:* When Finder invokes `preparePreviewOfFile(at:completionHandler:)`, the incoming file URL is security-scoped. The extension must invoke `url.startAccessingSecurityScopedResource()` (and balance with `stopAccessingSecurityScopedResource()`) before passing the URL to subprocess engines or reading attributes.
- **Solution & Guardrail:**
  1. Provide dedicated `Support/QuickLook.entitlements` with `com.apple.security.app-sandbox` and `com.apple.security.files.user-selected.read-only`.
  2. In `Scripts/build_app.sh`, pass `--entitlements "$ROOT/Support/QuickLook.entitlements"` when codesigning `ArhivarQuickLook.appex`.
  3. Add complete `UTImportedTypeDeclarations` covering all supported archive formats to both `Support/Info.plist` and `Support/QuickLook-Info.plist`.
  4. Enclose file access in `PreviewViewController` with security-scoped resource access and set `preferredContentSize = NSSize(width: 740, height: 500)`.

---

## Episode 21: Drag to Finder Belongs on `TableRow`, Not Inside a Table Cell
- **Context:** Dragging archive items from `ArchiveBrowserView` to the Desktop. Single rows worked; a `⌘A` multi-selection could not be dropped, and after one drag, clicks, selection, further drags and the context menu needed several attempts.
- **Root Causes:**
  1. `NameCell` applied `.draggable(item)` to its own content. A cell-level SwiftUI drag only carries the row under the pointer, and the table's data source returned no pasteboard writer for any row, so `NSOutlineView` could not drag the selection.
  2. The cell's drag gesture competed with `NSOutlineView`'s own mouse tracking (selection, double-click, context menu).
  3. `model.dragItem(for:)` ran in every cell `body`, building an extractor and creating the session folder for each drawn row, with an O(entries) `needsPassword` scan per row.
- **Verified Facts (macOS 26 SwiftUI):**
  - `TableRow.itemProvider { NSItemProvider }` yields a pasteboard writer with only `public.item` (file contents). Finder does not turn that into a file.
  - `TableRow.draggable(Transferable)` with a `FileRepresentation` yields `public.item` **and** a lazily provided `public.file-url`, the same shape as a view-level `.draggable`, which Finder accepts. The autoclosure runs only when the drag starts, once per dragged row, all in the same event loop turn.
- **Lesson & Guardrail:** Put drag-out on `TableRow` (`Table(of:selection:sortOrder:) { columns } rows: { OutlineGroup(...) { TableRow(node).draggable(...) } }`), never inside a cell. Gate non-draggable rows with a cheap `canDrag` (set lookups only, it runs for every row). Group the rows of one drag in a `DragBatch` (collected in one event loop turn) so a drop runs a single `7zz`. `BrowserViewTests.selectedRowsDragToFinderTogether` asks the table's data source for writers exactly as `NSOutlineView` does and reads `public.file-url` as Finder would; it fails against the cell-level design.

---

## Episode 22: ⌘A Over Thousands of Items Hit ARG_MAX and Was Reported as "Engine Not Found"
- **Context:** Hunting potential problems after the multi-row drag fix. ⌘A in a folder with ~3,000+ long-named files, then drag, ⌘C, "Extract Selected" or delete; also compressing thousands of Finder files.
- **Root Cause:** Every item name was a `7zz` command-line argument. macOS caps arguments plus environment at `ARG_MAX` = 1 MiB, so `Process.run()` failed with `E2BIG`, and `CommandRunner` mapped every launch failure to `SevenZipError.engineNotFound`.
- **Verified 7-Zip 26.05 Behavior:**
  - `@listfile` after `--` is taken literally (nothing extracted, exit 0). `-i@listfile` placed before `--` works for `x`, `d`, `t` and `a`, matches exactly like direct arguments (folders include children; `-spd` keeps `*` literal) and handles absolute source paths.
  - List lines are trimmed (leading and trailing whitespace), a fully quoted line loses its quotes, and an empty list file is a command-line error (exit 7). `-scsUTF-8` makes the encoding explicit.
  - 25,000 items through a list file extract in about 6 s; direct arguments cannot start at all.
- **Test Trap:** Foundation writes file names to disk decomposed (NFD), so an archive built from them stores NFD names, and 7-Zip matches names byte for byte. Test item names must come from the 7-Zip listing (as the app's do), not from NFC string literals.
- **Lesson & Guardrail:** Never pass an unbounded list of names on a command line. `CommandRunner.run` routes every command through `ItemListFile.fitting` and adds the list file to the sandbox `readableFiles`. `ItemListFileIntegrationTests` and `AppModelTests.selectAllWithThousandsOfItemsWorksEverywhere` exceed 1 MiB on purpose and fail with `.engineNotFound` without the fix.

---

## Episode 23: Drops Into Word Stopped After 3-4 Items Because 7-Zip Ran Inside the Drop Exchange
- **Context:** Images dragged one by one from the list into Microsoft Word (on another Mac). After 3-4 drops dragging stopped entirely; quitting with ⌘Q and relaunching restored it. ⌘A drags and single drags to Finder worked.
- **Evidence:**
  - The drag writer is SwiftUI's private `PasteboardItem`; it offers `public.item` and `public.file-url`, both with `NSPasteboardWritingOptions.promised` (512). The target app asks for the data during the drop.
  - SwiftUI answers that request by blocking the main thread until the async `FileRepresentation` export returns: a `DispatchQueue.main.async` block queued before the read did not run during it. With extraction deferred to that moment, `7zz` (sandbox launch + extraction, longer on older Intel Macs and for large images) ran while Arhivar's main thread was frozen inside the drag-and-drop exchange.
  - The unified log of an earlier ⌘A drop on this Mac already showed `HIServices:DragAndDrop` "Reentrant message: kDragIPCDropEnded" and "SendDragIPCMessage failed with error -1850" (`badDragRefErr`) at the moment the drop data was provided.
- **Root Cause (most likely; not reproduced with Word by hand):** synchronous, slow promised-data provision during the drop leaves the app's drag session state inconsistent after a few drops, so new drags no longer start until relaunch.
- **Fix:** `AppModel.dragItem` calls `DragBatch.prefetch()` (detached, after all dragged rows were added in the same event loop turn); the drop request then only awaits a finished task. Selections above `DragBatch.prefetchLimit` (512 MiB) still extract on the first request. Prefetch failures are logged but reported to the user only when a drop request arrives (a cancelled drag shows no alert).
- **Diagnostics added:** `AppLog` + Log window (⌥⌘L) + Console mirroring. Each drag logs "started … extracting before the drop", "drop target requested the files", "extracted N item(s) in X ms", a warning if a drop request waited over 500 ms, and a watchdog warning every 10 s while an extraction runs. The launch line records macOS version, architecture and processor count, so a report from another Mac shows its environment.
- **Lesson & Guardrail:** Never do slow work inside a lazily provided pasteboard type; the provider runs on the main thread inside another process's drag or paste request. Prepare the data when the drag starts. `BrowserViewTests.singleRowDragsExtractBeforeEachDrop` drags single rows eight times in a row and requires each file to be on disk before the drop and the drop to return in under 300 ms; `EngineIntegrationTests.dragBatchExtractsBeforeTheDrop` covers prefetch, the size limit and deferred failure reporting. If a report recurs, ask for the Log window contents first.
