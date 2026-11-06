# Domain Wiki — Arhivar Knowledge Asset

> **Memory Category:** TencentDB LLM-Wiki Knowledge Asset  
> **Scope:** Domain workflows, `7zz` CLI contract, security boundaries, extraction staging, and macOS system integration.

---

## 1. System Overview

**Arhivar** is a universal macOS archive manager (`arm64` + `x86_64`, macOS 26 Tahoe+) split into two Swift Package Manager targets:
- **`ArhivarCore`** (`Sources/ArhivarCore`): Pure, UI-independent library containing `7zz` command generation, `7zz l -slt` technical listing parser, folder tree builder, staged atomic extraction, symlink security, Gatekeeper quarantine propagation, `sandbox-exec` profile generation, checksum calculation (`7zz h`), engine discovery/updating, and trilingual localization tables (`tr`, `en`, `ro`).
- **`Arhivar`** (`Sources/Arhivar`): `@MainActor`-isolated SwiftUI application containing `AppModel`, `AppSettings`, Finder `NSServices` integration (`FinderServices`), and Liquid Glass views (`WelcomeView`, `ArchiveBrowserView`, `CreateArchiveSheet`, `SettingsView`, `AboutView`, `SidebarView`, `ContentView`).

---

## 2. `7zz` Command Contract (`SevenZipCommand`)

All arguments passed to `7zz` include `-sccUTF-8` and place file/archive paths after `--` so paths starting with `-` are never interpreted as switches.

| Operation | Subcommand & Switches | Notes |
| :--- | :--- | :--- |
| **List** | `l -slt -bd -spd -sccUTF-8 -- <archive>` | Technical machine-readable listing parsed by `ListingParser`. |
| **Test** | `t -bsp1 -bb0 -spd -sccUTF-8 -- <archive>` | Streams progress percentages to `stdout` (`ProgressParser`). |
| **Extract** | `x -o<dest> -aoa -bsp1 -bb0 -y -spd -sccUTF-8 -- <archive> [items...]` | Extracts into a staging directory. Always passes `-spd`. If `dest` contains `*`, runs with `workingDirectory = dest` and `-o.`. |
| **Create** | `a -t<type> -bsp1 -bb0 -y [-mx=N] [-mmt=on\|1] [-p] [-mhe=on] [-mem=AES256] [-vNm] [-spd] [-snl] [-xr!...] [-x!...] -sccUTF-8 -- <dest> <sources...>` | Runs in a same-volume staging directory (`StagedExtraction.installArchive`); two-step staging used for `.tar.gz`, `.tar.xz`, `.tar.bz2`. |
| **Add** | `a -bsp1 -bb0 -y [-p] [-mhe=on] [-mem=AES256] [-spd] [-snl] [-xr!...] [-x!...] -sccUTF-8 -- <archive> <names...>` | Preserves `headersEncrypted` (`-mhe=on`) for `7z` and `-mem=AES256` for encrypted `zip`. |
| **Delete** | `d -bsp1 -bb0 -y -spd -sccUTF-8 -- <archive> <rawItems...>` | Uses raw `archivePath` values. |
| **Rename** | `rn -bb0 -y -spd -sccUTF-8 -- <archive> <rawOldPath> <rawNewPath>` | Uses raw `archivePath` values. |
| **Hash** | `h -bd -spd -scrcCRC32 -scrcSHA256 -scrcBLAKE2sp -sccUTF-8 -- <file>` | Computes CRC32, SHA-256, and BLAKE2sp without external dependencies. |

### Crucial `7zz` Quirks & Mitigations

1. **`-spd` vs. `-xr!._*` Exclusion Patterns:**
   - `7zz` treats the archive path argument itself as a wildcard glob unless `-spd` is passed. Commands without wildcard exclusions (`list`, `test`, `extract`, `delete`, `rename`, `hash`) always pass `-spd`.
   - On `create`, `compressTarStage`, and `add`, `-spd` also disables wildcards inside `-x` exclusion switches (`-xr!._*`), so `SevenZipCommand.wildcardSafety(for:)` passes `-spd` only when a source path, archive/output path, or excluded special-file path contains `*` or `?`.
2. **Password Handling via `stdin`:**
   - When `input` is `nil`, `CommandRunner` attaches `FileHandle.nullDevice` to `standardInput`. If `7zz` encounters an encrypted archive/entry, it prints `Enter password` and aborts with `Break signaled` (`exitCode == 255`), which `SevenZipError.check` classifies as `.wrongPassword`.
   - External `SIGINT`/`SIGTERM` also causes `7zz` to print `Break signaled`, so `SevenZipError.check` requires **both** `"Break signaled"` and `"Enter password"` in the output to classify as `.wrongPassword`.
3. **Dangerous Symlink Exit Code (`exitCode == 2`) & 0-Byte Placeholders:**
   - `7zz` refuses to extract symlinks with `..` escaping the destination and exits with code `2` (`ERROR: Dangerous link path was ignored`), leaving behind a 0-byte regular file at the symlink path.
   - `SevenZipError.check` treats `Dangerous link path was ignored` as a warning rather than a fatal error, and `StagedExtraction.removeLinkPlaceholders` deletes those 0-byte regular files (identified via `ArchiveEntry.isSymbolicLink`) so they never overwrite target files or appear in previews/checksums.
4. **Multi-Line Archive Comments (`Comment = \n{\n...\n}`):**
   - `7zz l -slt` prints multi-line archive comments verbatim inside `{ ... }` before the final `----------` entry separator, whereas newlines inside entry fields are replaced with `_`. `ListingParser.parse` therefore splits the header on the **last** `----------` line and `parseInfo` reads brace-delimited values up to the last `}` in the header.
5. **FIFO Named Pipes, Sockets & Device Nodes (`SpecialFiles`):**
   - `7zz a` opens FIFOs (`mkfifo`) without `O_NONBLOCK` and hangs forever in the kernel, while `FileManager.copyItem` fails with `ENOTSUP` on FIFOs and Unix sockets. `SpecialFiles` skips them during `AddPlan.make` staging and excludes them via `-x!<archivePath>`.

---

## 3. Security & Isolation Architecture

1. **Kernel Sandbox (`SandboxProfile`):**
   - Generates Scheme-like SBPL rules (`(version 1) (allow default) (deny network*) (deny file-write*) ...`) passed to `/usr/bin/sandbox-exec` with `-D W0=...` and `-D R0=...` parameters (preventing quote/injection issues).
   - Blocks read access to 25+ personal data, container, shell history, and browser profile paths (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gh`, `~/.netrc`, `~/.kube`, `~/.docker`, `~/.npmrc`, `~/.pypirc`, `~/.git-credentials`, `~/.zsh_history`, `~/.bash_history`, `~/Library/Keychains`, `Cookies`, `Mail`, `Messages`, `AddressBook`, `Safari`, `Accounts`, `Containers`, `Group Containers`, `HTTPStorages`, Chrome, Firefox, Brave, Edge, Arc, Vivaldi, Opera) across all operations (including `create` and `add`), opening only directories that contain the archive or user-selected `readable` sources.
2. **Gatekeeper Quarantine (`Quarantine` & `OwnerAccess`):**
   - Reads `com.apple.quarantine` via `getxattr(..., XATTR_NOFOLLOW)`, clears the `0x0040` user-approved bit (`derivedValue`), and applies it via `setxattr(..., XATTR_NOFOLLOW)` to every extracted item.
   - Temporarily grants missing owner permission bits (`S_IRUSR` / `S_IWUSR` / `S_IXUSR` via `OwnerAccess`) on read-only or execute-only files and folders (`0555` `.app` binaries, `0444`, `0111`, `0000`) so `com.apple.quarantine` cannot be bypassed and `.replace` / `removeTree` never fail with `EACCES`.
3. **Executable & Deceptive Filename Detection (`OpenSafety`):**
   - Checks UTIs and extensions for executables, scripts, `.pkg`, `.mobileconfig`, `.terminal`, `.workflow`, `.action`, `.osax`, `.url`, `.webloc`, `.scpt`, `.scptd`, `.applescript`, `.shortcut`, `.prefpane`, `.qlgenerator`, and POSIX execute bits (`0o111`).
   - Detects Unicode format/control characters (such as `U+202E` RTL override), default-ignorable code points (`U+034F`, `U+17B4`, `U+17B5`, etc., except emoji variation selectors `U+FE0E`/`U+FE0F` immediately following an emoji), and invisible blank fillers (`U+2800` Braille blank, `U+3164` Hangul filler, `U+115F`, `U+1160`, `U+FFA0`), rendering them visibly as `⟦U+XXXX⟧` in the table and requiring confirmation before opening.

---

## 4. Finder Integration & Document Icons

- **Six Document Icon Families (`Support/Info.plist` & `Resources/DocumentIcons/`):**
  - `CFBundleDocumentTypes` groups all supported archive UTIs into six distinct families (`zip`, `7z`, `rar`, `tar`, `disk`, `archive`), each with its own `CFBundleTypeIconFile` and `LSHandlerRank = Alternate` (so Arhivar never takes over default file associations unless the user explicitly selects Arhivar in Finder's Get Info › Open with › Change All).
  - Icons are drawn purely in CoreGraphics by `Scripts/make_document_icons.swift` (no SF Symbols, up to 512 px to keep all six `.icns` files around ~1.7 MB total).
  - `DocumentIconTests` enforces that every family has its `.icns` file, every entry has `LSHandlerRank == "Alternate"`, no UTI belongs to more than one family, and all `UTImportedTypeDeclarations` and `NSServices` archive UTIs are mapped to a family.
- **Background Extract Here for other apps (`ExtractHandoff`, contract version 1, added 2026-11-06 for Descarcator item 76):**
  - **Request:** a standard open-documents Apple event (`aevt`/`odoc`, direct object = list of file references) carrying one extra parameter, keyword `'ArXh'` (`ExtractHandoff.requestKeyword`), whose string value is the caller's opaque request ID (1–64 ASCII letters, digits or `-`). The caller builds the whole event itself (`ExtractHandoff.openEvent(for:requestID:)` shows the shape) and hands it over with `NSWorkspace.OpenConfiguration.appleEvent` through `NSWorkspace.openApplication(at:configuration:)`, so Launch Services sends that one event and no second, plain `odoc`. `AppDelegate.application(_:open:)` reads the parameter from `NSAppleEventManager.currentAppleEvent`. A browser, Finder or "Open With" cannot add it, so plain opens keep opening the first archive in a window (`handleOpenRequest`), and there is deliberately no URL scheme (`CFBundleURLTypes` absent, checked by `ExtractHandoffTests`). An event with a malformed ID is a plain open.
  - **Work:** `AppModel.extractHereInBackground` reads the files from the event (not from the URLs AppKit passes, so results keep the caller's order and count; non-file items, such as text that `fileURLValue` would coerce into a path, are `skipped`), maps split volumes to their first part and feeds the existing Extract Here queue: each archive goes next to itself with the subfolder, same-name (`overwriteMode`) and quarantine rules of `runExtract`. No window is opened; errors and warnings are not shown as alerts but logged, except that a password question opens the window exactly as Extract Here does. Cancelling (the operation or the password sheet) marks the archive, and every archive still queued, `cancelled`.
  - **Result:** one distributed notification per request, `com.babadogantech.arhivar.extractHandoffFinished`, object = the request ID, `userInfo` = `version` (1) and `results` (one code per file in event order: `extracted`, `warnings`, `failed`, `cancelled`, `skipped`). Distributed notifications are visible to every process in the session, so the payload never carries paths, names or error text; the App Log line "Background extract request finished: …" holds only counts.
  - **Lifetime (`HandoffAutoQuit`, added 2026-11-06 for Descarcator item 506):** a launch whose first event is a marked request is background-only (`Launch.handoffOnly`). When the last request's notification has been posted and the Extract Here queue is empty (`AppModel.onHandoffsSettled`, called at the end of `reportFinishedHandoffs`), Arhivar waits `defaultGracePeriod` (4 s) and quits with `NSApp.terminate` if it is still idle; a request arriving in that window cancels the quit and reuses the process. The decision (`shouldQuit`) is re-taken after the wait and refuses when any request is pending, the queue or an operation is busy (`serviceTask`, `serviceQueue`, `operation`, `pendingOpen`), a question is on screen (`passwordRequest`, `alert`, create/rename/delete/add sheets, Quick Look) or any window is visible. User activity makes the launch `Launch.user` for good: a default launch (`NSApplication.launchIsDefaultUserInfoKey`), a plain `odoc`, `applicationShouldHandleReopen` (Dock click), `NSApplication.didBecomeActiveNotification` (observed directly, not through SwiftUI's delegate forwarding) and Finder services (`FinderServices.onUserRequest`). The hooks are wired in `AppDelegate.init`, because a launch-time `odoc` reaches `application(_:open:)` before `applicationDidFinishLaunching`. Same-name conflicts never ask a question: `overwriteMode` decides.
  - **No window (fixed 2026-11-06 after the real test of 1.6.0 build 21):** a background-only launch must not show a window, or the `windowVisible` blocker keeps it running. The main `Window` scene (and the About and Log scenes) use `.defaultLaunchBehavior(.suppressed)`, so SwiftUI never presents a window at launch; `AppDelegate.launchFinished(isDefaultLaunch:)` opens the main window with `AppModel.openMainWindow()` (no activation) at the end of every launch that is not `Launch.handoffOnly`, and `applicationShouldHandleReopen` opens it when no window is visible. `AppModel.mainWindowRequested` is set only by `presentMainWindow()` (open, Finder service, password question). In a background-only launch with no such request, any visible main-capable window (one macOS state restoration brings back) is closed at the first request, at the end of the launch and when the main window's content appears (`AppDelegate.mainWindowAppeared`), with a path-free App Log line. While the launch is background-only, `applicationShouldTerminateAfterLastWindowClosed` returns `HandoffAutoQuit.lastWindowClosed()` = false and re-runs the delayed quit check, so closing that window never stops a running request. The `windowVisible` blocker counts only user windows (`HandoffAutoQuit.isUserWindow`: visible and main-capable, a sheet, or `NSApp.modalWindow`), not AppKit's internal windows.
  - **Discovery:** `Support/Info.plist` › `ArhivarExtractHandoff` = 1 (integer, contract version); callers read it from the bundle without launching Arhivar and fall back to the "Extract Here with Arhivar" service when it is missing.

---

## 5. Release Packaging & Cryptographic Integrity (`Scripts/update_signing.swift` & `AppUpdate.swift`)

- **Ed25519 Cryptographic Release Signing:**
  - Distribution `.dmg` packages are signed with an Ed25519 private key securely stored in macOS login keychain (`keychainService = "com.babadogantech.arhivar.update-signing"`).
  - The public key is bundled inside `Support/Info.plist` under `ArhivarUpdatePublicEDKey`.
  - Releases generate `Arhivar-<version>.dmg.sig` (base64 raw 64-byte Ed25519 signature) and `SHA256SUMS.txt` (`package.sh` deletes a stale `Arhivar-<version>.sha256` left by older builds).
  - `UpdateSignature` and `UpdateChecksums` in `AppUpdate.swift` verify the release using Apple's `CryptoKit.Curve25519.Signing.PublicKey` and `CryptoKit.SHA256`.

