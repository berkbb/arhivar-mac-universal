# Changelog

This file follows the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
