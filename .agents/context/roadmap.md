# SOTA Roadmap & Project Enhancement Checklist

> **Memory Category:** TencentDB Context & SOTA Roadmap Asset  
> **Canonical Source:** Synchronized with [`/ROADMAP.md`](../../ROADMAP.md) and [`/CHANGELOG.md`](../../CHANGELOG.md).

---

## 1. Open / Upstream-Dependent Items

- [ ] **Zstandard (`.zst` / `.tar.zst`) Archive Creation:**
  - One-step `.tar.gz`, `.tar.xz`, and `.tar.bz2` creation is **completed** (`✅`).
  - Official `7zz` 26.04 supports extracting `.zst` / `.tzst` (`K` flag in `7zz i`) but returns `E_NOTIMPL` on `7zz a -tzstd` (no `C` flag).
  - Once upstream `ip7z/7zip` enables `zstd` creation (or when a custom engine with `zstd` write support is configured), add `.zst` and `.tar.zst` cases to `ArchiveFormat` in `Sources/ArhivarCore/ArchiveOptions.swift` reusing `SevenZipCommand.tarStage` and `compressTarStage`.

---

## 2. Completed Audit & Feature Milestones (28 / 29 Done)

### P0 — Security, Crash Prevention & Data Integrity
- [x] **P0-1:** Fix `encryptedHeaders` false positive in `AppModel.fetchListing` via `SevenZipError.needsPassword(_:)`.
- [x] **P0-2:** Saturating `Int64` arithmetic (`saturatingAdding`, `saturatingSum`) across `DiskSpace`, `ArchiveStatistics`, and `ArchiveTree`.
- [x] **P0-3:** Preserve `-mem=AES256` when adding files to encrypted `.zip` archives (`SevenZipCommand.add`).
- [x] **P0-4:** Symlink escape validation & relative rewriting (`StagedExtraction.secureSymlinks`), `.usingNewMetadataOnly` + `Quarantine.ensure` on replace, and `0o700` permissions on `AddPlan` staging.
- [x] **P0-5:** Preserve symbolic links (`-snl`) when archiving `.app` bundles and frameworks.
- [x] **P0-6:** Conditional `-spd` wildcard safety on `create` and `add` when source names contain `*` or `?`.
- [x] **P0-7:** Require `"Enter password"` alongside `"Break signaled"` for `.wrongPassword`, and escalate hung `terminate()` to `SIGKILL` after 2 seconds.

### P1 — Functional & UX Accuracy
- [x] **P1-8:** Normalize entry paths (`./`, `//`, trailing `/`) in `ListingParser` while preserving raw `archivePath` for `7zz` commands.
- [x] **P1-9:** Pass `--current` version to `EngineUpdater` and fall back to bundled `7zz` version in `update-7zip.sh` on read-only app bundles.
- [x] **P1-10:** Finder-style `.localizedStandard` sorting in `ArchiveTree.nameComparator` and `ArchiveBrowserView`.
- [x] **P1-11:** Multi-volume split archive support (`CreateOptions.firstOutput`, `ArchiveNaming.firstVolume`, `Total Physical Size`).
- [x] **P1-12:** Surface automatic Arhivar release updates in `WelcomeView.UpdateBanner`.
- [x] **P1-13:** Clear `serviceQueue` on `cancelOperation()`.
- [x] **P1-14:** Duplicate basename detection in `CreateArchiveSheet`, `AddPlan.make`, and `AppModel.createArchive`.
- [x] **P1-15:** Strip active subfolder prefix (`StagedExtraction.contentRoot`) when extracting selected items in Folder View.
- [x] **P1-16:** Carry target folder in `AddRequest.folder` on PathBar drop and show password confirmation hint when confirmation is empty.

### P2 & P3 — Hardening, System Integration & Hygiene
- [x] **P2-17:** Expand `SandboxProfile.personalDataDirectories` (`~/.kube`, `~/.docker`, `~/.npmrc`, `~/.pypirc`, `~/.git-credentials`, browser profiles) and `OpenSafety` (`.scpt`, `.shortcut`, `.prefPane`, `.qlgenerator`, Braille/Hangul blank fillers).
- [x] **P2-18:** Count implicit intermediate folders in `ArchiveStatistics.folderCount`.
- [x] **P2-19:** Pre-flight disk space checks (`DiskSpace.requiredForWriting`) before archive creation and in-place edits.
- [x] **P2-20:** Defer first-launch update consent alert until cold-start operations finish.
- [x] **P2-21:** Align multi-file `handleOpenRequest` with `handleDrop` and declare 14 imported archive UTIs in `Support/Info.plist`.
- [x] **P3-22:** Clean up stale previews on reload, clean up entire `archiveStack` on app exit (`discardTemporaryFiles` → `discardAllSessions`), fix `resetAll()` key removal order, bound `FileIcons.byPath` at 256, and iterate `ListingParser` lines lazily.
- [x] **P3-23:** Use `ditto` in `package.sh` and support `SIGN_IDENTITY` with hardened runtime in `build_app.sh`.

### Completed Features
- [x] **Feature 1:** Smart Subfolder Extraction (`SubfolderMode`: `.smart`, `.always`, `.never`).
- [x] **Feature 2:** Exclude macOS Metadata Files (`-xr!.DS_Store`, `-xr!._*`, `-xr!__MACOSX`).
- [x] **Feature 3:** Finder-Style Shortcuts (`⌘↓`, `⌘I`, `⌘C`, `⌘V`, `⌘A`).
- [x] **Feature 4 (Partial):** One-step `.tar.gz`, `.tar.xz`, and `.tar.bz2` creation.
- [x] **Feature 5:** Nested Archive Navigation (`AppModel.archiveStack`, PathBar parent archive crumbs).
- [x] **Feature 6:** Built-in Checksum Inspector (`7zz h`: CRC32, SHA-256, BLAKE2sp) and archive comment/block/volume display.
