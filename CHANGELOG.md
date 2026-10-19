# Changelog

This file follows the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Comprehensive 11-discipline chaos and security test matrix (`ChaosAndSecurityMatrixTests.swift`) with 17 dedicated automated tests covering Security (Zip-Slip traversal, zero CLI password exposure), Stress (2,000 flat entries, 35-level hierarchy depth, rapid parsing), Destructive (0-byte archives, corrupt random bytes), Penetration (quarantine user-approval bit stripping), Load & Volume (zip bomb `Int64.max` saturating sum), Endurance (multi-cycle staging cleanup under read-only permissions), Vulnerability Scanning (option injection shielding, Trojan Source Unicode spoofing detection, risky executable UTType detection), Red Team (standalone symlink exfiltration rejection, read-only and multi-volume in-place edit blocking), Fuzzing (listing parser mutations, malformed braces and negative sizes), and Chaos (process termination SIGKILL timeout after 2s grace period, `0o000`/`0o555` owner permissions recovery, high-concurrency reentrancy). Total automated test count increased to 230 tests.
- Deterministic, seeded fuzz suite (`FuzzTests.swift`) that feeds hostile and grammar-like input to every pure parser and path helper (listing, checksum, progress, timestamp, path normalization, tree build, naming, quarantine, open-safety) and asserts no crash, termination, and invariants (non-negative sizes, normalized ids), plus a depth regression suite (`ArchiveTreeDepthTests.swift`). Total automated test count is now 245.

### Fixed

- Opening an archive whose metadata declared a very deeply nested entry path (thousands of path segments) could crash the app with a stack overflow while building the browse tree — triggered just by listing the archive, before any extraction. The browse tree is now depth-bounded (`ArchiveTree.maxDepth`); such entries remain fully counted and extractable, they are only not individually browsable past the cap. Found by the new fuzz suite.
- Opening an archive that declares an enormous number of entries could exhaust memory while listing it (the whole `7zz` output was buffered); the subprocess output is now capped (`CommandRunner.maxOutputBytes`, 512 MiB) and the operation stops with an error instead of running the machine out of memory.
- Terminal session files (`.term`) are now treated as risky and ask for confirmation before opening, like `.terminal` and `.command` (a `.term` file can run a shell command on open).
- `7zz` is kept away from more credential stores when reading archives and when creating/adding from a folder that symlinks into them: `~/.config/gcloud`, `~/.azure`, `~/.oci`, `~/.terraform.d`, `~/.m2`, `~/.gradle`, `~/.cargo`, `~/.gem` and VS Code settings.
- The 0-byte placeholder that `7zz` leaves for a rejected dangerous link is now removed even inside a read-only (`0555`) folder, so "Replace it" can no longer zero an existing same-named file there.
- An archive opened through a symbolic link (for example a Finder symlink to a download) now propagates the real file's quarantine flag to extracted items; previously the link's own (empty) attribute was read and nothing was flagged.
- An extremely long password (tens of thousands of characters) no longer freezes the app before 7-Zip starts: the data written to 7-Zip's standard input is kept under the pipe buffer size (the password is not changed; it is just repeated fewer times).
- A truncated archive that also contains a dangerous link is reported as a failure instead of being merged into the destination as "extracted with warnings"; error messages now keep 7-Zip's reason line (e.g. "Unexpected end of archive").
- A negative or overlarge "Physical Size" in a listing no longer produces a negative packed size in the status bar.

## [1.1.2] — 2026-10-18

### Fixed

- Smart subfolder extraction ("When there is more than one item") now ignores macOS metadata (`.DS_Store`, `__MACOSX`, and `._*` AppleDouble files) when deciding whether to create a wrapper folder. Archives created on macOS containing a single root folder alongside macOS metadata now extract directly without creating an unwanted double folder (`Name/Name/…`).
- When Smart mode extracts such an archive directly into the destination, the macOS metadata beside the single item (`__MACOSX`, `.DS_Store`) is left out instead of being moved there, so the destination gets no `__MACOSX` folder and keeps its own `.DS_Store` (Finder view settings). Archives that contain only metadata, selected items, and the *Always* / *Never* options extract everything as before.
- Files whose names start with `._` (for example `._config`) were silently left out when extracting and did not get the quarantine flag, because macOS hides them from folder listings; they are now extracted, flagged and counted in the free-space check. Only real AppleDouble files (with the AppleDouble signature, or next to the file they describe) count as macOS metadata.

## [1.1.1] — 2026-10-18

### Fixed

- Files whose extension looks like a split ZIP volume (for example Nintendo 64 `.z64` or ZX Spectrum `.z80` files) are no longer treated as archives when there is no `.zip` with the same name next to them: dropping one offers a new archive instead of failing to open it, and inside an archive it opens with its own app.

## [1.1.0] — 2026-10-18

### Added

- **Smart subfolder extraction:** "Folder named after the archive" is now *When there is more than one item* (default), *Always* or *Never*. An archive with a single top-level item is extracted directly (no `Name/Name/…` nesting); an archive with several top-level items ("tarbomb") is gathered in a folder named after it. The old on/off preference is migrated (off → Never).
- **Exclude macOS metadata** (`.DS_Store`, `._*`, `__MACOSX`) when creating or adding to archives: an option in the New Archive sheet and in Settings › Compression.
- **Finder-style shortcuts:** ⌘↓ enters the selected folder or opens the selected file, ⌘I toggles the archive info, ⌘C copies the selected items as files (paste them in Finder while the archive is open), ⌘V adds the files on the clipboard to an editable archive. "Copy" is also in the context menu. The Edit menu's Cut, Copy, Paste and Select All are Arhivar commands that act on the archive table (⌘A selects every item in the current folder or search results) and pass through to text fields as usual.
- **One-step `.tar.gz`, `.tar.xz` and `.tar.bz2`** creation for folders and multiple files. (The official 7-Zip engine can extract `.zst` but cannot create it, so Zstandard creation is not offered.)
- **Nested archives:** double-clicking an archive inside an archive (or "Open in Arhivar" in the context menu) opens it in the browser; the path bar shows the enclosing archives, and clicking one or pressing ⌘↑ at the root returns to it. Nested archives are read-only.
- **Checksums:** "Checksums…" in the context menu and the Archive menu shows the CRC32, SHA-256 and BLAKE2sp of a file (`7zz h`) with a Copy button.
- **Document icons:** when Arhivar is chosen as the default app for an archive type (Get Info › Open with › Change All), Finder shows Arhivar's own icons in six families: ZIP, 7Z, RAR, TAR and compressed files (gz, bz2, xz, zst, …), disk images (ISO, DMG, VHD, VMDK, QCOW2, WIM, …) and other archives (CAB, DEB, RPM, XAR, split `.001`, …). The icons are drawn by `Scripts/make_document_icons.swift`.
- The archive info panel shows the archive comment, the number of solid blocks and the number of volumes.
- The welcome screen announces a new Arhivar release found by the check at launch (previously only visible in Settings › Advanced).
- Finder "Open With" and the services menu now list more archive types: Zstandard, LZ4, lzip, LZMA, WIM, VHDX, QCOW2, DEB, RPM, split `.001`, ARJ, LZH, SquashFS, UDF, CAB, CPIO, XAR, VMDK, VHD and the `.tgz`/`.tbz`/`.txz` variants.
- `build_app.sh` accepts `SIGN_IDENTITY` (default ad-hoc) for Developer ID signing; non ad-hoc identities get the hardened runtime and a timestamp.

### Security

- An archive declaring sizes that add up to more than `Int64.max` (zip bomb) no longer crashes the app; sizes are summed with saturation.
- Files added to an encrypted ZIP are encrypted with AES-256 like the rest of the archive (7-Zip used the weak ZipCrypto for them).
- Symbolic links that would point outside the destination after extraction are removed, and links 7-Zip wrote relative to the staging folder are made relative; extraction reports the skipped links as a warning instead of failing.
- "Replace it" no longer carries the old file's metadata over to the new file; the new file keeps the archive's quarantine flag.
- The temporary copies made when adding files into a subfolder are readable only by the user (`0700`).
- 7zz no longer gets read access to `~/.kube`, `~/.docker`, `~/.npmrc`, `~/.pypirc`, `~/.git-credentials` and browser profiles while reading an archive.
- AppleScript, Shortcuts, preference panes and Quick Look generators ask for confirmation before opening, and names hidden with Braille or Hangul blank characters are flagged as deceptive.
- A 7zz process that ignores the cancel request is killed after 2 seconds, so cancelling never hangs.
- A multi-line archive comment can no longer add fake items to the list or change the archive's type or size: the listing is split at 7-Zip's last separator line and the comment is read between its braces.
- Extracting selected items from a subfolder, dragging, copying and previewing check symbolic links against what is actually moved: links to sibling folders or absolute targets are dropped, a link selected on its own is not handed out, and the empty placeholder 7-Zip leaves for a rejected link no longer overwrites an existing file or shows up as content.
- Read-only and execute-only files (`0555`, `0444`, `0111`, `0000`, e.g. app binaries and `.command` scripts) now get the quarantine flag; macOS refused to write it, so they could open without a Gatekeeper check.
- Folders containing named pipes (FIFOs), sockets or device files no longer hang 7-Zip forever when creating an archive or adding files; those items are skipped.
- Creating archives and adding files keep 7-Zip away from personal folders (`~/.ssh`, Keychains, …) unless a source was picked from there, so a symbolic link inside a source folder cannot pull a key into the archive. Shell histories, app containers and HTTP storage were added to the protected folders.
- `.workflow`, `.action`, `.osax`, `.url` and `.webloc` files ask for confirmation before opening, and names hiding characters such as U+034F are flagged as deceptive (emoji presentation selectors are allowed).

### Fixed

- The app crashed ("No Observable object of type AppModel found") when returning to the archive root from a folder with the path bar or ⌘↑; the table's name cells no longer read the model from the environment.
- Adding files to a password-protected 7z whose file names were not encrypted turned file name encryption on.
- `.app` bundles and frameworks are archived with their symbolic links as links (they were stored as copies, about three times larger and with broken signatures).
- Creating or adding a file or folder whose name contains `*` or `?` could pick up other files matching it as a pattern.
- A 7zz stopped by an external signal was reported as "wrong password".
- TAR archives made with `tar -czf a.tgz .` showed a "." folder, and items with `./`, `//` or a trailing `/` in their path could not be navigated, extracted, renamed or deleted correctly.
- The Name column sorts like Finder ("file2" before "file10", case-insensitive, "Çanta" before "Zebra").
- Split archives: a new split archive is added to the recent archives and revealed by its first volume, opening `.002` (or `.part2.rar`) opens the first volume, and the archive size is the total of all volumes.
- When the app bundle is not writable, the 7-Zip update check no longer reports a false "update available".
- Cancelling "Extract Here with Arhivar" stops the whole batch instead of continuing with the next archive.
- Selecting files with the same name from different folders is caught in the New Archive sheet (their folders are shown) and when adding; previously 7-Zip failed with "Duplicate filename on disk".
- Extracting selected items while inside a subfolder no longer recreates the whole inner path at the destination.
- Dropping files on a path bar folder and then cancelling no longer changes the current folder; the drop is ignored while an operation runs.
- The New Archive sheet explains why Create is disabled when the password is not confirmed yet.
- The status bar and info panel count folders that exist only in file paths.
- Creating archives and editing archives in place check free disk space first (the archive size for edits; the source size for uncompressed formats and `.tar.*`).
- The first-launch update consent no longer collides with an archive opened with "Open With"; it is asked once the operation is finished.
- Opening several files from the Dock together with an archive now offers to create an archive with all of them, as dragging does.
- Quitting while inside a nested archive deletes the temporary folders of the enclosing archives too (previously they stayed until the next launch's cleanup).
- Creating an archive from sources with the same name is refused with a clear message even when the New Archive sheet is bypassed.
- Copying (⌘C) and calculating checksums show their own symbols in the progress overlay.
- Reloading an archive after an edit removes stale preview files; "Reset All Settings" no longer leaves the language or browser mode preference behind.
- An archive whose name or folder contains `*` or `?` (e.g. `backup*1.7z`) no longer lists, tests, extracts or checksums the other archives matching it.
- Extracting over earlier results with "Replace it" works when the existing files or folders are read-only.
- Temporary and staging folders that contain read-only folders are deleted instead of being left behind.
- Renaming a folder whose stored path ends with `/` no longer moves it into itself, and renaming to the name of another item in the same folder is refused (7-Zip would create two items with the same path).
- Adding files to a folder of a `./`-prefixed TAR archive works; items with `..` in their stored path are shown and extracted where 7-Zip writes them; a TAR with appended copies of a file counts it once.
- Inside a nested archive in tree view or while searching, the path bar and ⌘↑ lead back to the enclosing archive; Return and ⌘↓ on a folder in tree view open it.
- Closing the archive (⇧⌘W) while an operation runs is ignored (the archive used to come back when the operation finished), and an operation cancelled while 7-Zip is being located does not start afterwards.
- Choosing the outer archive in the sidebar while inside a nested archive returns to it without reloading it, keeping its password; the sidebar keeps it selected.
- Dropping files while an operation runs no longer opens the New Archive sheet, Quick Look from the context menu switches to the chosen item, and the table is rebuilt once when an archive loads.
- `release.sh` finds the CHANGELOG section of the exact version, `package.sh` lists outputs whose paths contain spaces, and `update-7zip.sh` signs 7-Zip installed into the fallback folder.
- A folder that exists only in the paths of `..`-prefixed TAR entries is extracted by its own path; previously everything under `..` came along.
- Symbolic links in the list: selecting all (⌘A) and copying (⌘C) copies everything except standalone links instead of failing with "code 0"; opening, previewing or checksumming a link explains why it can't be done, and links can't be dragged on their own.
- Adding or creating from nothing but named pipes, sockets or device files is refused with a clear message (adding used to pick up the whole source folder or an empty folder). A folder reached through a symbolic link is checked for pipes too when links are not stored as links, and a failed add removes its read-only temporary copies.
- New Archive (⌘N) and Open Archive (⌘O) are disabled while an operation runs (their result used to be dropped silently).
- Extracting with "Replace it" over folders left read-only (`0555`), unreadable or unenterable (`0444`, `0000`) by an earlier extraction works, also when a folder has to be replaced by a file; symbolic links inside such folders are checked and removed like any other, and the folders keep their permissions.
- "Extract Here" on the archive that is open and unlocked uses its password instead of asking again and forgetting it.
- The New Archive sheet says right away when the chosen items are only named pipes, sockets or device files, and keeps Create disabled.
- If a folder already has the new archive's name, the New Archive sheet says so and keeps Create disabled (it used to promise to replace it, compress everything and then fail); the folder is never touched.
- Archives that are read-only, locked or on a read-only disk are no longer offered for editing (adding, deleting or renaming failed with "Permission denied"); the toolbar explains why, and dropped files go to the New Archive sheet.
- Old-style multi-volume RAR archives (`.rar` with `.r00`, `.r01`, …) open from any volume, also with Extract Here.
- An archive declaring a negative size, or a size too large for a signed 64-bit number, can no longer shrink or skip the free-space check before extraction.
- Multi-part RAR archives (`.part01.rar`, `.part1.rar`, …) strip their volume suffix when extracted into a subfolder, so the resulting folder is named `film/` instead of `film.part01/`.
- Classic split ZIP archives (`.z01` … `.z99`) are recognized as archives and redirected to the master `.zip` volume when opened or sent to Extract Here.
- Multi-volume archives (such as split `.zip` and `.7z` archives with more than one volume) disable editing actions; 7-Zip cannot update multi-volume archives in place.

### Changed

- The archive listing is parsed without building an intermediate array of lines, and cached path icons are bounded.
- The `.dmg` is staged with `ditto` so bundle metadata is preserved.
- Creating an archive with the name of an existing one now **replaces** it instead of adding to it (gzip/xz, split and name-encrypted archives used to fail). The archive is built in a staging folder and moved into place only on success, so cancelling leaves nothing behind; stale split volumes are removed. The New Archive sheet warns about an existing first volume (`.001`) and rejects `.` and `..` as names.

## [1.0.2] — 2026-10-17

### Fixed

- When Arhivar was started from the Finder context menu (Open / Extract Here / Compress with Arhivar) or with "Open With", its main window never appeared, so the progress overlay could not be seen until the app was clicked. The main window now opens and comes to the front for every such request.

## [1.0.1] — 2026-10-17

### Security

- Passwords are passed to 7zz through standard input instead of the command line, so they cannot be read with `ps` while an operation runs.
- Extraction first goes to a staging folder on the same disk as the destination and is moved into place only on success. If the operation is cancelled, hits a CRC error or runs out of disk space, the destination is left untouched; existing files stay intact even with "Replace it" selected.
- Free disk space is checked before extraction, Quick Look and drag-to-Finder.
- 7zz runs isolated with `sandbox-exec` for every operation: no network access, it can write only to the operation's target folder, and while reading an archive it cannot read personal folders such as `~/.ssh` or Keychains. It can be turned off in Settings › Advanced; it is on by default.

### Fixed

- Choosing "Extract Here with Arhivar" or "Open with Arhivar" from the Finder context menu while the app was not running showed a "7-Zip engine not found" error. The operation now waits until the engine has been found.
- With the correct password, another error in an encrypted archive (for example a CRC error) could be reported as "wrong password".

### Changed

- The progress overlay shows "Opening…" and "Reading archive…" with a symbol animated for each operation. The symbol stays still when Reduce Motion is on.

## [1.0.0] — 2026-10-17

First release. macOS 26 (Tahoe) or later; Apple Silicon and Intel (universal).

### Added

- **Archive browser**
  - **Folder view** like 7-Zip File Manager: double-click or Return to enter a folder, ⌘↑ to go up, clickable path bar
  - Expandable **tree view**; switch between the two with ⌘1 / ⌘2
  - Sortable columns (Name, Size, Packed, Modified, Method), Finder icons, lock icon on encrypted entries
  - Search across all subfolders, status bar, archive info panel
  - Fast listing of large archives (200,000 entries in about 1.3 seconds)
- **Quick Look:** preview the selected file with Space or ⌘Y
- **Drag to Finder:** a file or folder dragged from the list is extracted the moment it is dropped
- **Open:** 7z, ZIP, RAR, TAR, `.tar.gz`, `.tar.xz`, `.tar.bz2`, ISO, DMG and every other format 7-Zip can read
- **Extract:** extract everything or only the selection; choice of destination, a subfolder named after the archive, and what to do with existing files
- **Create archives:** 7z, ZIP, TAR, WIM, GZIP, BZIP2, XZ; compression level, AES-256, file name encryption (7z), split volumes
- **Edit archives (7z, ZIP, TAR, WIM):** add files to the current folder (toolbar, menu or drag and drop), delete (⌘⌫), rename; the password and file name encryption of encrypted archives are preserved
- **Finder context menu services:** "Extract Here with Arhivar" (several archives in turn, asking for a password when needed), "Open with Arhivar", "Compress with Arhivar"
- Password prompt with retry, progress indicator with cancel, notification when an operation finishes
- **Languages:** Turkish (default), English, Romanian; switch instantly inside the app
- **Appearance:** Automatic, Light, Dark
- **Settings** window (General, Compression, Advanced) and **About** window (licenses, manual, GitHub repository)
- **Arhivar update check:** offers a download link when GitHub Releases has a newer version (menu, Settings › Advanced, optional check at launch)
- **7-Zip updater** (`Scripts/update-7zip.sh`, `7-Zip-Guncelle.command`, in the app):
  - checks github.com/ip7z/7zip for the latest release and verifies it with SHA-256
  - updates `Vendor/7-Zip` in the project and/or the 7zz inside an app bundle, then re-signs the bundle
  - records the installed version in `Vendor/7-Zip/SOURCE.txt` (version, URL, SHA-256)
- **Packaging and publishing** (local; GitHub Actions is not used):
  - `Scripts/package.sh` / `Paketle.command`: tests, universal `.app`, `.dmg`, `.zip` and a SHA-256 file; 7-Zip is included in the bundle
  - `Scripts/release.sh` / `Yayimla.command`: packages, creates the `v<version>` tag and uploads to GitHub Releases
  - `Scripts/set-version.sh`: `Support/Info.plist` is the single source of the version
- 7-Zip 26.04 included in the project under `Vendor/7-Zip`
- 74 tests: core, app model and integration with the real 7zz
- Installation and first-launch (ad-hoc signature) instructions in the README
- MIT license and third-party notices (7-Zip: GNU LGPL + unRAR restriction)

### Security

- Files extracted from an archive downloaded from the internet keep the archive's quarantine (Gatekeeper) flag. The "user approved" bit is not carried over. This applies to Extract, Extract Here, Quick Look, double-click to open and drag to Finder.
- Files that can run code or change the system (`.command`, `.pkg`, `.mobileconfig`, Unix programs without an extension…) require confirmation before they are opened.
- Invisible or direction-changing characters that can hide a file's real extension (e.g. U+202E) are shown in the list as `⟦U+202E⟧`, with a warning icon.
- Preview and drag files are kept in a per-archive folder with `0700` permissions. The folder is deleted when the archive is closed, when another archive is opened and when the app quits; leftovers from earlier runs are cleaned up at launch.
- Escapes such as `../` in archive paths cannot leave the temporary folder. Selected item names are never treated as wildcards.
- The app asks for permission on first launch before connecting to GitHub; the launch check is off by default.
