# Changelog

This file follows the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Smart subfolder extraction:** "Folder named after the archive" is now *When there is more than one item* (default), *Always* or *Never*. An archive with a single top-level item is extracted directly (no `Name/Name/…` nesting); an archive with several top-level items ("tarbomb") is gathered in a folder named after it. The old on/off preference is migrated (off → Never).
- **Exclude macOS metadata** (`.DS_Store`, `._*`, `__MACOSX`) when creating or adding to archives: an option in the New Archive sheet and in Settings › Compression.
- **Finder-style shortcuts:** ⌘↓ enters the selected folder or opens the selected file, ⌘I toggles the archive info, ⌘C copies the selected items as files (paste them in Finder while the archive is open), ⌘V adds the files on the clipboard to an editable archive. "Copy" is also in the context menu.
- **One-step `.tar.gz`, `.tar.xz` and `.tar.bz2`** creation for folders and multiple files. (The official 7-Zip engine can extract `.zst` but cannot create it, so Zstandard creation is not offered.)
- **Nested archives:** double-clicking an archive inside an archive (or "Open in Arhivar" in the context menu) opens it in the browser; the path bar shows the enclosing archives, and clicking one or pressing ⌘↑ at the root returns to it. Nested archives are read-only.
- **Checksums:** "Checksums…" in the context menu and the Archive menu shows the CRC32, SHA-256 and BLAKE2sp of a file (`7zz h`) with a Copy button.
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

### Fixed

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
- Reloading an archive after an edit removes stale preview files; "Reset All Settings" no longer leaves the language or browser mode preference behind.

### Changed

- The archive listing is parsed without building an intermediate array of lines, and cached path icons are bounded.
- The `.dmg` is staged with `ditto` so bundle metadata is preserved.

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
