# AGENTS.md — Primary Constitution & L3 Persona Governance

> **Language Mandate:** All files inside `.agents/` (`AGENTS.md`, `context/`, `rules/`, `skills/`) **MUST** be written exclusively in English. Inline comments and docstrings inside `Sources/`, `Tests/`, and `Scripts/` may remain in Turkish as part of the developer's native workflow.

---

## 1. Project Identity & Mission

**Arhivar** (`arhivar-mac-universal`) is a native macOS 26 (Tahoe) universal (`arm64` + `x86_64`) archive manager built with Swift 6.2 and SwiftUI, powered by the official 7-Zip command-line engine (`7zz`) running in an isolated kernel sandbox (`sandbox-exec`).

### Constitutional Invariants (Non-Negotiable)

1. **Process Boundary & LGPL Compliance:**
   - Arhivar **never** links against 7-Zip or unRAR source code or libraries. It invokes the unmodified `7zz` executable via `CommandRunner` (`Foundation.Process`).
   - RAR archives are strictly **extract-only** (`unRAR` license restriction forbids RAR creation).
2. **Zero Command-Line Password Exposure:**
   - Passwords must **never** be passed on the `7zz` command line (where `ps` or `sysctl` could expose them to other local processes).
   - Always pass passwords via standard input (`SevenZipCommand.passwordInput(_:)`) using a pre-closed `Pipe` in `CommandRunner`.
3. **Kernel Sandbox Isolation (`SandboxProfile`):**
   - All `7zz` invocations run under `/usr/bin/sandbox-exec` by default (`settings.sandboxEngine == true`): network access is denied (`(deny network*)`), file writes are restricted to `/dev` and explicit target/staging directories, and sensitive user directories (`~/.ssh`, `~/.aws`, `~/.kube`, `~/.docker`, Keychains, browser profiles, etc.) are read-blocked when inspecting or extracting archives.
   - Always resolve paths with `realpath(3)` (`SandboxProfile.resolved(_:)` and `StagedExtraction.resolvedPath(_:)`), never `URL.resolvingSymlinksInPath()` alone, because macOS `sandbox-exec` evaluates real paths with the `/private` prefix (`/private/var`, `/private/tmp`).
4. **Atomic Staged Extraction & Symlink Containment:**
   - Extractions must go to a same-volume staging directory (`StagedExtraction.makeStagingDirectory(for:)`) and only merge into the final destination after `7zz` succeeds.
   - Before merging, `StagedExtraction.secureSymlinks(in:)` must remove any symbolic link resolving outside the staging root and rewrite `7zz`-rewritten absolute staging links into relative links.
   - Propagate `com.apple.quarantine` extended attributes (with the `0x0040` user-approved bit cleared) to extracted, previewed, and dragged files, and preserve quarantine across `.replace` (`FileManager.replaceItemAt(..., options: .usingNewMetadataOnly)` + `Quarantine.ensure`).
5. **Saturating Size Arithmetic (Zip-Bomb Immunity):**
   - Never sum archive entry sizes (`size` or `packedSize`) with unchecked `+`. Always use `Int64.saturatingAdding(_:)` or `Sequence<Int64>.saturatingSum()` to prevent `EXC_BAD_INSTRUCTION` integer overflow traps on maliciously crafted archives.
6. **Dual Path Representation (`path` vs. `archivePath`):**
   - Use normalized paths (`ListingParser.normalizedPath`: no leading `./`, no duplicate `//`, no trailing `/`) for `ArchiveEntry.path`, `ArchiveNode.id`, breadcrumbs, and UI selection.
   - Always pass the raw `archivePath` (`AppModel.archivePath(for:)`) to `7zz` commands (`x`, `d`, `rn`) so archives with `./`-prefixed entries match accurately.
7. **Complete Trilingual Localization (`tr`, `en`, `ro`) & Hardcoded Text Ban:**
   - Every user-facing string in `Sources/Arhivar` must be defined in `LKey` (`Sources/ArhivarCore/Localization.swift`) and have matching entries and positional format specifiers in `Resources/tr.lproj/Localizable.strings`, `Resources/en.lproj/Localizable.strings`, and `Resources/ro.lproj/Localizable.strings`.
8. **SwiftUI Hierarchical `Table` Safety:**
   - Cells inside a hierarchical `Table` (`ArchiveBrowserView.NameCell`) must **never** read `@Observable` objects (`AppModel`, `AppSettings`) via `@Environment`. Pass them as explicit properties to prevent `"No Observable object of type AppModel found"` crashes when SwiftUI re-inserts rows upon folder navigation.

---

## 2. TencentDB Agent Memory Four-Tier Pyramid (L0–L3)

| Tier | Category | Scope in Arhivar | Storage / Artifact |
| :--- | :--- | :--- | :--- |
| **L0** | **Conversation / Execution Logs** | Raw conversation turns, `swift test` outputs, and command traces | Session transcript logs & temporary build outputs |
| **L1** | **Atom (Atomic Parameters)** | Format switches, compression levels, reserve constants (`DiskSpace.reserve = 1 GiB`, `FileIcons.maxCachedPaths = 256`, `killGracePeriod = 2s`) | `ArchiveOptions.swift`, `StagedExtraction.swift`, `CommandRunner.swift` |
| **L2** | **Scenario (Engine & Runtime States)** | `AppModel` state machine (`EngineStatus`, `UpdateState`, `AppUpdateState`, `archiveStack`, `PendingAction`), `AppSettings` (`UserDefaults`) | `.agents/context/symbolic_memory_graph.md`, `.agents/context/domain_wiki.md` |
| **L3** | **Persona (Governance & Invariants)** | Constitutional principles, security redlines, SDD lifecycle gates, localization rules | `.agents/AGENTS.md`, `.agents/rules/`, `.agents/context/user_rejected_spec.md` |

---

## 3. Mandatory Agent Workflow

1. **Constitutional Alignment:** Read `.agents/AGENTS.md` before modifying any source file, script, or resource.
2. **Context & Symbol Lookup:** Consult `.agents/context/domain_wiki.md`, `.agents/context/code_graph_wiki.md`, `.agents/context/symbolic_memory_graph.md`, and `.agents/context/reflexion_memory_log.md` before changing command generation, path handling, extraction staging, or UI state flows.
3. **Rule Verification:** Check `.agents/rules/about_rules.md`, `.agents/rules/math_rules.md`, `.agents/rules/ui_rules.md`, and `.agents/rules/github_spec_kit.md`.
4. **Skill Execution:** Use `.agents/skills/sentinel_test_skill.md` to validate changes with `swift test` and localization checks before completing any task.
