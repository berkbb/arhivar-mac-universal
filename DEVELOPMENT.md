# Development

## Requirements

- macOS 26 or later
- Xcode 26 or later (Swift 6.2+). The universal build needs full Xcode; the Command Line Tools are not enough.

## Folder layout

```
Arhivar/
├── Package.swift
├── Sources/
│   ├── ArhivarCore/          UI-independent, tested logic
│   │   ├── CommandRunner.swift     Process execution, progress, timeout, cancellation, error classification
│   │   ├── ArchiveOptions.swift    Formats, levels, 7zz arguments (l, t, x, a)
│   │   ├── ArchiveEditing.swift    Edit commands (a, d, rn), AddPlan, ItemExtractor, drag-out, navigation helpers
│   │   ├── ArchiveListing.swift    `7zz l -slt` parser and statistics
│   │   ├── ArchiveTree.swift       Folder tree from the flat list, sorting, search
│   │   ├── Engine.swift            Finding 7zz and choosing a version, updater wrapper, naming helpers
│   │   └── Localization.swift      AppLanguage, StringTable, LKey (all string keys)
│   └── Arhivar/              SwiftUI app (default isolation: MainActor)
│       ├── ArhivarApp.swift        Scenes, menu commands, AppDelegate
│       ├── AppModel.swift          App state and every 7zz operation
│       ├── AppSettings.swift       UserDefaults preferences, appearance, localization and formatting
│       ├── FinderServices.swift    Finder context menu services
│       └── Views/                  Views
├── Resources/                {tr,en,ro}.lproj/Localizable.strings, ServicesMenu.strings, AppIcon.icns
├── Support/Info.plist        Bundle info, document types, NSServices
├── Scripts/                  build_app.sh, package.sh, update-7zip.sh, make_icon.swift
├── Vendor/7-Zip/             The 7zz bundled into the app, with its license and manual
├── Tests/ArhivarCoreTests/   Core unit and integration tests
├── Tests/ArhivarAppTests/    App model (AppModel) flow tests
├── Paketle.command           Double-click to package
├── Yayimla.command           Double-click to publish to GitHub Releases
└── 7-Zip-Guncelle.command    Double-click to update 7-Zip
```

## Architecture

- Arhivar does not link against 7-Zip. It runs the unmodified `7zz` program as a separate process (this is also how it stays LGPL compliant).
- All 7zz arguments are produced and tested by `SevenZipCommand`. File names always come after the `--` separator. When working on selected items, `-spd` is passed so that `*` and `?` in names are not treated as wildcards.
- `CommandRunner`:
  - leaves stdin empty: if a password is requested, 7zz stops instead of hanging, and the error is classified as `wrongPassword`.
  - reads the percentages in the `-bsp1` output and reports them as progress.
  - terminates the process when its task is cancelled.
- The archive listing is read by `ListingParser`. `ArchiveTree` also creates intermediate folders that have no entry of their own in the archive.
- **Editing:**
  - `7zz rn` and `7zz d` match a folder path as a prefix, so a single command covers every child item even when the folder has no entry of its own (verified by tests).
  - Adding into a subfolder: `AddPlan` copies the files into the target path structure inside a temporary folder (instant on APFS) and runs 7zz there with relative paths.
- **Quarantine:** `Quarantine.propagate` applies the archive's `com.apple.quarantine` value to the items written after the extraction started (by ctime). The "user approved" bit (0x40) is cleared. 7zz does not do this by itself.
- **Safe opening:** `OpenSafety.executableKind` detects risky types and the execute bit; `hasDeceptiveCharacters` detects invisible and direction-changing characters.
- **Temporary files:** `$TMPDIR/Arhivar/session-<UUID>` (0700) is kept per archive and deleted when the archive is closed. `ItemExtractor.sweepStale` removes folders older than 6 hours at launch.
- **Listing parser:** lines are split at the byte level, block fields are kept as `Substring`s, and dates are read with `ListingParser.parseTimestamp` (no DateFormatter). Across daylight saving transitions the result matches DateFormatter; tests check this.
- **Passwords:** never passed as arguments. `SevenZipCommand.passwordInput` writes the password to 7zz's stdin; `l`, `t`, `x`, `d` and `rn` prompt for it themselves, and `a` gets a bare `-p`. If the password is unknown, stdin is empty and 7zz stops with `Break signaled`; this is classified as "password required".
- **Staged extraction:** `StagedExtraction` creates a folder on the same volume as the destination (`itemReplacementDirectory`, or a hidden `.arhivar-staging-*` folder as a fallback). 7zz extracts into it, then the overwrite policy is applied in Swift while moving the items into the destination. It never writes through symbolic links in the destination.
- **Disk space:** `DiskSpace` / `InsufficientSpaceError` compare the unpacked size of the selection with `volumeAvailableCapacityForImportantUsage` minus a 1 GB reserve.
- **Sandbox:** `SandboxProfile.forOperation` generates SBPL rules for each operation, and `CommandRunner` starts 7zz with `/usr/bin/sandbox-exec -p … -D W0=…`. Paths are resolved with `realpath(3)`, because `URL.resolvingSymlinksInPath()` strips the `/private` prefix and the rule would not match. Personal folders are blocked only while an archive is being read (list, test, extract, delete, rename); they are not blocked for create and add, because the user chooses the sources there.
- **Cold launch:** Finder services and "Open With" can arrive while the app is still starting. If the engine has not been checked yet, `perform` shows "Opening…" and waits for `ensureEngine()`.
- **Engine selection:** a custom 7zz chosen in Settings always wins. Otherwise the copies in the app bundle, in the fallback folder (`~/Library/Application Support/Arhivar/engine`) and in Homebrew are run, and the **newest version** is picked.

## Adding strings (localization)

1. Add the key to the `LKey` enum in `Sources/ArhivarCore/Localization.swift`.
2. Add the same key to **all three** files: `Localizable.strings` under `Resources/tr.lproj`, `en.lproj` and `ro.lproj`.
3. Format specifiers (`%@`, `%ld`, `%1$@`) must be the same in all three languages. If the order changes between languages, use positional specifiers (`%1$…`).

`swift test` catches missing or extra keys and mismatched specifiers. Views always get text through `settings.t(.key)`; no hard-coded strings.

## Build, test, package

```bash
swift build                      # quick development build
swift test                       # 89 tests (ArhivarCoreTests + ArhivarAppTests); real-7zz tests use Vendor/7-Zip/7zz
./Scripts/build_app.sh           # universal build/Arhivar.app (ARCHS=native for this Mac only)
./Scripts/package.sh             # tests + .app + dist/Arhivar-<version>.{dmg,zip,sha256}
./Scripts/package.sh --update-7zip   # update Vendor/7-Zip first, then package
```

The same tasks can be run from Finder by double-clicking `Paketle.command` and `7-Zip-Guncelle.command`.

The version number is read from `CFBundleShortVersionString` in `Support/Info.plist`. For a new release, update that field and `CHANGELOG.md`.

## Publishing a release (locally)

Releases are distributed only through GitHub Releases. GitHub Actions is not used; releases are published from this Mac with `Scripts/release.sh` or `Yayimla.command`.

1. `./Scripts/set-version.sh 1.1.0`: changes the version in Info.plist and increments the build number.
2. In `CHANGELOG.md`, add a `## [1.1.0] — <date>` heading below `## [Unreleased]` and move the entries under it. The script takes the release notes from this section.
3. Commit the changes and `git push`.
4. Run `./Scripts/release.sh --dry-run`, then `./Scripts/release.sh` (or `--draft`).

`release.sh` does the following:
- checks that the working copy is clean, that you are on `main`, that the local branch matches `origin/main` and that the tag has not been used yet;
- runs `package.sh`;
- creates and pushes the `v<version>` tag;
- uploads the `.dmg`, `.zip` and `.sha256` files with `gh release create`.

The single source of the repository name is the `ArhivarRepository` key in Info.plist. The About window and the app's update check use it too.

**Privacy:** the app asks for permission on first launch. If allowed, at launch it requests only the public release lists from the GitHub API (`api.github.com/repos/<repo>/releases/latest` and `ip7z/7zip`). While the repository is private, the Arhivar check reports that there is no public release yet.

## 7-Zip update flow

`update-7zip.sh` picks its target as follows:

| Run from | Updated |
| --- | --- |
| The project (`Scripts/`) | `Vendor/7-Zip/` |
| Inside the app (`Arhivar.app/Contents/Resources/`) | That app's `Contents/MacOS/7zz`; the bundle is then ad-hoc re-signed |
| The app bundle is not writable | `~/Library/Application Support/Arhivar/engine/` |
| `--dest` / `--app` given | The given targets (more than one is allowed) |

Verification steps:
1. The SHA-256 digest reported by the GitHub API is compared with the downloaded file.
2. The file is checked to be Mach-O.
3. The version reported by the downloaded `7zz` is compared with the tag.
4. The file is first copied under a temporary name, then moved into place in a single step, so a half-finished install is never left behind.

## Finder services

The services are defined under `NSServices` in `Support/Info.plist`; their titles come from the `ServicesMenu.strings` files. They are registered with `NSUpdateDynamicServices()` when the app first launches. In Finder they appear under right-click › **Quick Actions** or **Services**. If they are missing, they can be enabled in System Settings › Keyboard › Keyboard Shortcuts › Services.

## Known limitations and unverified points

- The UI could not be checked with screenshots in this environment; it was verified that the app launches and runs without errors. Drag to Finder, Quick Look and the services menu should be tried by hand.
- `update-7zip.sh install --force` was run on 2026-10-17 with 26.04 against both a folder target and an app copy. Download, SHA-256, installation and re-signing were verified. An upgrade to a genuinely newer version has not happened yet.
- The app is ad-hoc signed and not notarized. On another Mac, Gatekeeper approval is required on first launch. For distribution, a Developer ID signature and notarization should be added.
- RAR can only be extracted; the unRAR license forbids creating RAR archives.
- In-place editing is limited to 7z, ZIP, TAR and WIM; split archives cannot be edited.
