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
| **List** | `l -slt -bd -sccUTF-8 -- <archive>` | Technical machine-readable listing parsed by `ListingParser`. |
| **Test** | `t -bsp1 -bb0 -sccUTF-8 -- <archive>` | Streams progress percentages to `stdout` (`ProgressParser`). |
| **Extract** | `x -o<dest> -aoa -bsp1 -bb0 -y [-spd] -sccUTF-8 -- <archive> [items...]` | Extracts into a staging directory. Passes `-spd` when `items` is non-empty. If `dest` contains `*`, runs with `workingDirectory = dest` and `-o.`. |
| **Create** | `a -t<type> -bsp1 -bb0 -y [-mx=N] [-mmt=on\|1] [-p] [-mhe=on] [-mem=AES256] [-vNm] [-spd] [-snl] [-xr!...] -sccUTF-8 -- <dest> <sources...>` | Two-step staging used for `.tar.gz`, `.tar.xz`, `.tar.bz2`. |
| **Add** | `a -bsp1 -bb0 -y [-p] [-mhe=on] [-mem=AES256] [-spd] [-snl] [-xr!...] -sccUTF-8 -- <archive> <names...>` | Preserves `headersEncrypted` (`-mhe=on`) for `7z` and `-mem=AES256` for encrypted `zip`. |
| **Delete** | `d -bsp1 -bb0 -y -spd -sccUTF-8 -- <archive> <rawItems...>` | Uses raw `archivePath` values. |
| **Rename** | `rn -bb0 -y -spd -sccUTF-8 -- <archive> <rawOldPath> <rawNewPath>` | Uses raw `archivePath` values. |
| **Hash** | `h -bd -scrcCRC32 -scrcSHA256 -scrcBLAKE2sp -sccUTF-8 -- <file>` | Computes CRC32, SHA-256, and BLAKE2sp without external dependencies. |

### Crucial `7zz` Quirks & Mitigations

1. **`-spd` vs. `-xr!._*` Exclusion Patterns:**
   - Passing `-spd` (disable wildcard matching for file names) also disables wildcards inside `-x` exclusion switches (`-xr!._*`).
   - Therefore, `SevenZipCommand.wildcardSafety(for:)` only passes `-spd` on `create`/`add` when at least one source path actually contains `*` or `?`.
2. **Password Handling via `stdin`:**
   - When `input` is `nil`, `CommandRunner` attaches `FileHandle.nullDevice` to `standardInput`. If `7zz` encounters an encrypted archive/entry, it prints `Enter password` and aborts with `Break signaled` (`exitCode == 255`), which `SevenZipError.check` classifies as `.wrongPassword`.
   - External `SIGINT`/`SIGTERM` also causes `7zz` to print `Break signaled`, so `SevenZipError.check` requires **both** `"Break signaled"` and `"Enter password"` in the output to classify as `.wrongPassword`.
3. **Dangerous Symlink Exit Code (`exitCode == 2`):**
   - `7zz` refuses to extract symlinks with `..` escaping the destination and exits with code `2` (`ERROR: Dangerous link path was ignored`). If all `ERROR:` lines in `7zz` output are `Dangerous link path was ignored`, `SevenZipError.check` treats the result as a warning rather than a fatal error so the remaining extracted files are preserved.

---

## 3. Security & Isolation Architecture

1. **Kernel Sandbox (`SandboxProfile`):**
   - Generates Scheme-like SBPL rules (`(version 1) (allow default) (deny network*) (deny file-write*) ...`) passed to `/usr/bin/sandbox-exec` with `-D W0=...` and `-D R0=...` parameters (preventing quote/injection issues).
   - Blocks read access to 20+ personal data and browser profile paths (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gh`, `~/.netrc`, `~/.kube`, `~/.docker`, `~/.npmrc`, `~/.pypirc`, `~/.git-credentials`, `~/Library/Keychains`, `Cookies`, `Mail`, `Messages`, `Safari`, Chrome, Firefox, Brave, Edge, Arc, Vivaldi, Opera) during archive read operations unless the user explicitly opened an archive inside one of those directories.
2. **Gatekeeper Quarantine (`Quarantine`):**
   - Reads `com.apple.quarantine` via `getxattr`, clears the `0x0040` user-approved bit (`sanitizedValue`), and applies it via `setxattr(..., XATTR_NOFOLLOW)` to every extracted item.
3. **Executable & Deceptive Filename Detection (`OpenSafety`):**
   - Checks UTIs and extensions for executables, scripts, `.pkg`, `.mobileconfig`, `.terminal`, `.workflow`, `.scpt`, `.scptd`, `.applescript`, `.shortcut`, `.prefpane`, `.qlgenerator`, and POSIX execute bits (`0o111`).
   - Detects Unicode format/control characters (such as `U+202E` RTL override) and invisible blank fillers (`U+2800` Braille blank, `U+3164` Hangul filler, `U+115F`, `U+1160`, `U+FFA0`), rendering them visibly as `⟦U+XXXX⟧` in the table and requiring confirmation before opening.

---

## 4. Finder Integration & Document Icons

- **Six Document Icon Families (`Support/Info.plist` & `Resources/DocumentIcons/`):**
  - `CFBundleDocumentTypes` groups all supported archive UTIs into six distinct families (`zip`, `7z`, `rar`, `tar`, `disk`, `archive`), each with its own `CFBundleTypeIconFile` and `LSHandlerRank = Alternate` (so Arhivar never takes over default file associations unless the user explicitly selects Arhivar in Finder's Get Info › Open with › Change All).
  - Icons are drawn purely in CoreGraphics by `Scripts/make_document_icons.swift` (no SF Symbols, up to 512 px to keep all six `.icns` files around ~1.7 MB total).
  - `DocumentIconTests` enforces that every family has its `.icns` file, every entry has `LSHandlerRank == "Alternate"`, no UTI belongs to more than one family, and all `UTImportedTypeDeclarations` and `NSServices` archive UTIs are mapped to a family.
