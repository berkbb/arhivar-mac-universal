# Sentinel Test Skill — Test Execution & Static Validation

> **Memory Category:** TencentDB Procedural Memory (Skill Asset)  
> **Trigger:** Before committing, packaging, or completing any code/resource change in `Arhivar`.

---

## 1. Purpose

Validates `ArhivarCore` and `Arhivar` across unit tests, real `7zz` integration tests, off-screen `NSWindow` SwiftUI table rendering tests, and trilingual (`tr`, `en`, `ro`) localization parity checks.

---

## 2. Standard Execution Procedure

### Step 1: Run the Full Swift Test Suite
```bash
swift test
```
- **Expected Result:** All **285 tests** pass across `ArhivarCoreTests` and `ArhivarAppTests` (including `FuzzTests`, `ArchiveTreeDepthTests`, `SecurityHardeningTests`, `AuditFixesTests`, `ChaosAndSecurityMatrixTests`, `DocumentIconTests`, `QuickLookTests`, `RoadmapTests`, `RoadmapIntegrationTests`, `HardeningTests`, `HardeningIntegrationTests`, `EdgeCaseTests`, `ReadOnlyTreeTests`, `LocationAndVolumeTests`, `AppleDoubleTests`, `EngineIntegrationTests`, `AppModelTests`, `BrowserViewTests`, and `LicenseViewerTests`).
- **Real Engine Requirement:** Integration suites automatically use `Vendor/7-Zip/7zz` (or `$ARHIVAR_7ZZ`). Ensure `Vendor/7-Zip/7zz` is executable (`chmod +x Vendor/7-Zip/7zz`) so no integration suite is skipped.

### Step 2: Verify Localization & Document Icon Parity
Included automatically in `RunnerAndLocalizationTests` and `DocumentIconTests`:
- **Mandatory 1:1 Exact Translation (No Language Exceptions):** Whichever language is supported (`tr`, `en`, `ro`, or future additions), every `LKey` case in `Sources/ArhivarCore/Localization.swift` must exist with an authentic, non-fallback, exact 1:1 translation in all language tables (`Resources/tr.lproj/Localizable.strings`, `Resources/en.lproj/Localizable.strings`, and `Resources/ro.lproj/Localizable.strings`).
- Zero tolerance for missing keys, untranslated English text in non-English tables, or format specifier mismatches.
- Positional and typed format specifiers (`%@`, `%ld`, `%1$@`, `%2$@`) and argument counts must match 1:1 identically across all three languages.
- Every document type in `Support/Info.plist` must map to one of the six `Resources/DocumentIcons/{zip,7z,rar,tar,disk,archive}.icns` files with `LSHandlerRank = Alternate`, and every imported/service archive UTI must belong to exactly one family.

### Step 3: Verify Universal App Bundle & Code Signature (When Packaging)
```bash
./Scripts/build_app.sh
codesign --verify --deep --strict build/Arhivar.app
lipo -archs build/Arhivar.app/Contents/MacOS/Arhivar
```
- **Expected Result:** Valid signature and universal `arm64 x86_64` architectures.
