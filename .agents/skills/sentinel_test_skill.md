# Sentinel Test Skill — Test Execution & Bundle Validation

> **Memory Category:** TencentDB Procedural Memory (Skill Asset)
> **Trigger:** Before committing, packaging, or completing any code or resource change in Arhivar.
> **Last Reviewed:** 2026-11-04 (structure aligned with the other skills; every command, flag, and test name checked against `Scripts/` and `swift test list`).

---

## 1. Purpose

Validates `ArhivarCore`, `Arhivar`, and `ArhivarQuickLook` across unit tests, real `7zz` integration tests, off-screen `NSWindow` SwiftUI rendering tests, trilingual (`tr`, `en`, `ro`) localization parity, and the built app bundle.

---

## 2. Standard Execution Procedure

### Step 1: Ensure the Bundled `7zz` Engine Is Present
```bash
test -x Vendor/7-Zip/7zz && cat Vendor/7-Zip/SOURCE.txt
```
- Real-engine suites (`EngineIntegrationTests`, `RoadmapIntegrationTests`, `HardeningIntegrationTests`, `AuditFixesTests`, and others) use `$ARHIVAR_7ZZ` or `Vendor/7-Zip/7zz` and are skipped when neither is executable, so a missing engine silently shrinks coverage.
- If it is missing, `./Scripts/update-7zip.sh install --dest Vendor/7-Zip` restores it. It downloads from GitHub, so ask the user first (`engine_maintenance_skill.md`).

### Step 2: Run the Full Swift Test Suite
```bash
swift test > /tmp/arhivar-swift-test.log 2>&1; echo "swift test exit: $?"
grep -E 'Test run with|✘|error:' /tmp/arhivar-swift-test.log
```
- Take the exit code from `swift test` itself, never from a pipe (`swift test | tail` reports the exit code of `tail`). A run passes only when the exit code is 0 and both `Test run with` lines (`ArhivarCoreTests` and `ArhivarAppTests`) say passed; see `reflexion_memory_log.md` Episode 25.
- **Expected Result:** All **396 tests** (the `swift test list` count on 2026-11-04) pass across `ArhivarCoreTests` and `ArhivarAppTests`, including `FuzzTests`, `ArchiveTreeDepthTests`, `SecurityHardeningTests`, `AuditFixesTests`, `ChaosAndSecurityMatrixTests`, `SandboxTests`, `StagedExtractionTests`, `DocumentIconTests`, `QuickLookTests`, `PreviewListingTests`, `RoadmapTests`, `RoadmapIntegrationTests`, `HardeningTests`, `HardeningIntegrationTests`, `EdgeCaseTests`, `ReadOnlyTreeTests`, `LocationAndVolumeTests`, `AppleDoubleTests`, `EngineIntegrationTests`, `AppLogTests`, `AppModelTests`, `BrowserViewTests`, `LogViewTests`, and `LicenseViewerTests`.
- `BundleVerificationTests` checks the bundle only when `build/Arhivar.app` exists (see Step 4).
- A focused run takes a test file, suite, or function name, for example `swift test --filter SandboxTests` or `swift test --filter resetRemovesAllPreferences`. A focused run never replaces the full run before completion.

### Step 3: Verify Localization, Hardcoded Text & Document Icon Parity
Included in Step 2; to rerun only these:
```bash
swift test --filter RunnerAndLocalizationTests
swift test --filter HardcodedTextGuardTests
swift test --filter DocumentIconTests
```
- **Mandatory 1:1 Exact Translation (No Language Exceptions):** Every `LKey` case in `Sources/ArhivarCore/Localization.swift` must exist with an authentic, non-fallback, exact 1:1 translation in `Resources/tr.lproj/Localizable.strings`, `Resources/en.lproj/Localizable.strings`, and `Resources/ro.lproj/Localizable.strings` (`everyKeyIsTranslated`, `eachSupportedLanguageHasDedicatedFile`), and every visible `Info.plist` name is covered by `InfoPlist.strings` for the app and the Quick Look extension (`infoPlistStringsCoverEveryVisibleName`).
- Zero tolerance for missing keys, untranslated English text in non-English tables, or format specifier mismatches (`formatSpecifiersMatchEnglish`): `%@`, `%ld`, `%1$@`, `%2$@` and argument counts match 1:1 across all three languages.
- Views contain no hardcoded user-visible text and icon-only buttons carry accessibility labels (`HardcodedTextGuardTests`).
- Every document type in `Support/Info.plist` maps to one of the six `Resources/DocumentIcons/{zip,7z,rar,tar,disk,archive}.icns` files with `LSHandlerRank = Alternate`, and every imported or service archive UTI belongs to exactly one family (`DocumentIconTests`).

### Step 4: Build & Verify the Universal App Bundle (When Packaging or Changing Bundle Contents)
```bash
./Scripts/build_app.sh && ./Scripts/verify_bundle.sh
lipo -archs build/Arhivar.app/Contents/MacOS/Arhivar
```
- `build_app.sh` builds `arm64` and `x86_64` by default (`ARCHS=native` builds for this Mac only), copies `Vendor/7-Zip/7zz`, the `.lproj` tables, document icons, `update-7zip.sh`, and license files, packages `ArhivarQuickLook.appex`, and signs ad hoc unless `SIGN_IDENTITY` is set.
- `verify_bundle.sh` checks that `Arhivar`, `7zz`, and the Quick Look extension are executable, that every language's `.strings` files are in the app and the extension, that the extension's display name differs from the app's, that the extension links `/usr/lib/libarchive`, and `codesign --verify --deep --strict`.
- **Expected Result:** `verify_bundle.sh` exits with code 0 after its success line, and `lipo -archs` prints both `x86_64` and `arm64`.

### Step 5 (Before a Release, Run by the User): Real-App Stress Round
```bash
./Scripts/stress-test.sh            # options: --app PATH, --files N, --skip-quicklook, --skip-app
```
- Drives the installed `/Applications/Arhivar.app` and Finder Quick Look through accessibility identifiers; it needs the Accessibility permission for the app that runs it and temporarily changes three Arhivar settings (restored at exit). Ask the user before running it.
