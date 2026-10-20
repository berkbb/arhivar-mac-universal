# Symbolic Memory Graph — State Topology & Node Lookup

> **Memory Category:** TencentDB Symbolic Short-Term Memory Topo-Graph  
> **Scope:** State machines, execution pipelines, and symbolic `node_id` lookup for `Arhivar`.

---

## 1. Symbolic Node Lookup Table (`node_id`)

| `node_id` | Symbol / Component | File | Role |
| :--- | :--- | :--- | :--- |
| `N_APP_MODEL` | `AppModel` | `Sources/Arhivar/AppModel.swift` | Central `@Observable` coordinator for UI state and `7zz` tasks |
| `N_SETTINGS` | `AppSettings` | `Sources/Arhivar/AppSettings.swift` | `UserDefaults` persistence and trilingual `StringTable` formatter |
| `N_RUNNER` | `CommandRunner` | `Sources/ArhivarCore/CommandRunner.swift` | Async process runner with `stdin` pipe, progress, timeout, and `SIGKILL` |
| `N_SANDBOX` | `SandboxProfile` | `Sources/ArhivarCore/Sandbox.swift` | Per-operation `sandbox-exec` SBPL policy generator |
| `N_CMD` | `SevenZipCommand` | `Sources/ArhivarCore/ArchiveOptions.swift` | Pure CLI argument builder (`l`, `t`, `x`, `a`, `d`, `rn`, `h`) |
| `N_PARSER` | `ListingParser` | `Sources/ArhivarCore/ArchiveListing.swift` | Byte-level `7zz l -slt` parser and path normalizer |
| `N_TREE` | `ArchiveTree` | `Sources/ArhivarCore/ArchiveTree.swift` | Hierarchical folder synthesizer, `.localizedStandard` sorter, search |
| `N_STAGED` | `StagedExtraction` | `Sources/ArhivarCore/StagedExtraction.swift` | Atomic staging directory, `secureSymlinks`, `removeLinkPlaceholders`, `installArchive`, `removeTree`, `OwnerAccess`, smart subfolder, merge |
| `N_QUARANTINE` | `Quarantine` | `Sources/ArhivarCore/Quarantine.swift` | `com.apple.quarantine` sanitizer and recursive propagator |
| `N_SAFETY` | `OpenSafety` | `Sources/ArhivarCore/OpenSafety.swift` | Risky UTI / execute-bit detector and Unicode spoof sanitizer |
| `N_STACK` | `AppModel.archiveStack` | `Sources/Arhivar/AppModel.swift` | LIFO stack of `ArchiveContext` frames for nested archive browsing |
| `N_UPDATE_SIG` | `UpdateSignature` / `UpdateChecksums` | `Sources/ArhivarCore/AppUpdate.swift` | Ed25519 release signature and SHA-256 release checksum verifier |

---

## 2. Archive Extraction & Security Pipeline (`N_STAGED`)

```mermaid
flowchart TD
    A["User / Finder Service Triggers Extract"] --> B["Ensure Listing & Password (N_APP_MODEL)"]
    B --> C["Pre-Flight Disk Space Check (DiskSpace.requiredBytes)"]
    C --> D["Create Same-Volume Staging Dir (StagedExtraction.makeStagingDirectory)"]
    D --> E["Run 7zz x Inside sandbox-exec (N_RUNNER + N_SANDBOX)"]
    E --> F{"7zz Exit Code Check (SevenZipError.check)"}
    F -- "Cancelled / Fatal Error" --> G["Defer Removes Staging Dir via removeTree (Destination Untouched)"]
    F -- "Wrong Password" --> H["Present PasswordSheet With PendingAction.extract"]
    F -- "Success or Dangerous-Link Warning" --> I["Resolve Moved Content Root (StagedExtraction.contentRoot)"]
    I --> J["Remove 0-Byte Link Placeholders & Validate Symlinks Against Content Root"]
    J --> K["Propagate Gatekeeper Quarantine (Quarantine.propagate + OwnerAccess)"]
    K --> L["Resolve Target Dir via SubfolderMode (.smart / .always / .never)"]
    L --> M["Merge Into Destination (.replace / .skip / .rename)"]
    M --> N["Show Toast / Warning Alert & Reveal in Finder"]
```

---

## 3. Nested Archive Stack Lifecycle (`N_STACK`)

```mermaid
stateDiagram-v2
    [*] --> Idle: Launch / Close Archive
    Idle --> OuterOpen: openArchive(outerURL)
    OuterOpen --> ExtractingNested: primaryAction / browseArchive(path)
    ExtractingNested --> PasswordPromptOuter: Outer Entry Encrypted & No Password
    PasswordPromptOuter --> ExtractingNested: submitPassword(outerPassword)
    ExtractingNested --> OpeningNested: ItemExtractor.extract into Outer sessionRoot
    OpeningNested --> PasswordPromptInner: Inner Headers Encrypted (-mhe=on)
    PasswordPromptInner --> OpeningNested: submitPassword(innerPassword) (.openNested)
    OpeningNested --> NestedOpen: Push Outer ArchiveContext to archiveStack (isEditable = false)
    NestedOpen --> NestedOpen: Browse Deeper Archive (push to archiveStack)
    NestedOpen --> OuterOpen: goUp() at Root or PathBar Crumb (returnToArchive, discard inner sessionRoot)
    NestedOpen --> Idle: closeArchive() or App Quit (discardAllSessions)
    OuterOpen --> Idle: closeArchive() or App Quit (discardAllSessions)
```
