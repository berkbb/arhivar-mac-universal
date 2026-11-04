# Snapshot & Compatibility Audit Skill

> **Memory Category:** TencentDB Procedural Memory (Skill Asset)
> **Trigger:** Modifying `AppSettings` (`UserDefaults` keys), the legacy identity migration, temporary session handling, `Info.plist` UTI and service declarations, or archive format compatibility.
> **Last Reviewed:** 2026-11-04 (structure aligned with the other skills; each check now names the test that covers it).

---

## 1. Purpose

Audits backward compatibility of persisted user preferences (`UserDefaults`), the one-time bundle identifier migration, temporary session directory cleanup, and macOS LaunchServices (`Info.plist`) document and service type declarations.

---

## 2. Audit Checklist

1. **`UserDefaults` Migration & Reset Completeness (`AppSettings.swift`):**
   - Legacy boolean `extractIntoSubfolder` (`1.0.x`) must migrate cleanly via `AppSettings.loadSubfolderMode`: `false` → `.never`, `true` or absent → `.smart`.
   - Every persisted key must be listed in `AppSettings.Key.all` (including `browserMode`) so `AppSettings.resetAll()` removes it; `AppleLanguages` is removed last, after the properties are reset.
   - Check: `swift test --filter resetRemovesAllPreferences`.
2. **Legacy Identity Migration (`LegacyIdentityMigration.swift`):**
   - The one-time `net.babadogan.arhivar` → `com.babadogantech.arhivar` migration moves Launch Services default-app choices, re-runs `AppSettings.migrateLegacyDefaults`, removes the legacy records once, and marks itself done with `legacyIdentityMigrated`.
   - Check: `swift test --filter legacyPreferencesMigrateSeamlessly`, `swift test --filter legacyRecordsAreRemovedOnce`, and `swift test --filter legacyDefaultHandlersAreFound`.
3. **Temporary Session Directory Hygiene (`ItemExtractor` & `AppModel`):**
   - Session directories under `$TMPDIR/Arhivar/session-<UUID>` must be created with `0o700` permissions.
   - `closeArchive()` and `discardTemporaryFiles()` (from `applicationWillTerminate`) must call `discardAllSessions()` so the active `sessionRoot` and every parent `context.sessionRoot` in `archiveStack` are deleted immediately.
   - Check: `swift test --filter quittingInsideNestedArchiveRemovesAllSessions`.
4. **Launch-Time Privacy:**
   - No connection to GitHub before the first-launch consent (`updateConsentAsked`, `checkUpdatesAtLaunch`).
   - Check: `swift test --filter launchAsksForUpdateConsentWithoutNetwork`.
5. **`Support/Info.plist` & Version Single Source of Truth:**
   - Version strings are updated only through `./Scripts/set-version.sh <major.minor.patch>`, which sets `CFBundleShortVersionString`, increments `CFBundleVersion` in `Support/Info.plist` and `Support/QuickLook-Info.plist`, and reminds you to add the `## [<version>]` section to `CHANGELOG.md`.
   - Every custom UTI used in `CFBundleDocumentTypes` and `NSServices` must have a matching entry in `UTImportedTypeDeclarations` conforming to `public.data` and `public.archive`, and must belong to exactly one document icon family.
   - Check: `swift test --filter DocumentIconTests`.
