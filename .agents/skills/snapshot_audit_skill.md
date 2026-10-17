# Snapshot & Compatibility Audit Skill

> **Memory Category:** TencentDB Procedural Memory (Skill Asset)  
> **Trigger:** Modifying `AppSettings` (`UserDefaults` keys), `Info.plist` UTI declarations, or archive format compatibility.

---

## 1. Purpose

Audits backward compatibility of persisted user preferences (`UserDefaults`), temporary session directory cleanup, and macOS LaunchServices (`Info.plist`) document/service type declarations.

---

## 2. Audit Checklist

1. **`UserDefaults` Migration & Reset Completeness (`AppSettings.swift`):**
   - Legacy boolean `extractIntoSubfolder` (`1.0.x`) must migrate cleanly via `AppSettings.loadSubfolderMode`: `false` → `.never`, `true` or absent → `.smart`.
   - Every persisted key (including `browserMode` and `AppleLanguages`) must be removed by `AppSettings.resetAll()`, with `AppleLanguages` removed **after** resetting `language = .tr` (`resetRemovesAllPreferences` test).
2. **Temporary Session Directory Hygiene (`ItemExtractor` & `AppModel`):**
   - Session directories under `$TMPDIR/Arhivar/session-<UUID>` must be created with `0o700` permissions.
   - `closeArchive()` and `discardTemporaryFiles()` (`applicationWillTerminate`) must invoke `discardAllSessions()` so both the active `sessionRoot` and all parent `context.sessionRoot` folders in `archiveStack` are deleted immediately.
3. **`Support/Info.plist` & Version Single Source of Truth:**
   - Version strings are updated exclusively via `./Scripts/set-version.sh <version>`.
   - Every custom UTI in `CFBundleDocumentTypes` and `NSServices` must have a matching entry in `UTImportedTypeDeclarations` conforming to `public.data` and `public.archive`.
