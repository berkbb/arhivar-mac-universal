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
