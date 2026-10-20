# UI Rules, Localization & SwiftUI Table Safety Standards

- **Source:** Project UI & Localization Governance (`Arhivar`)
- **Version:** 1.0.4
- **Last Review Date:** 2026-10-20
- **Change Summary:** Added macOS MenuBar & in-app language switching restart warning standard (aligned with `aptreceipt`), codified mandatory 1:1 exact translation rule across all supported languages, trilingual `LKey` rules, SwiftUI `Table` `@Environment` ban in cells, and responder-aware Edit menu commands.

---

## 1. Strict Ban on Hardcoded UI Strings, Mandatory 1:1 Exact Translation & Dedicated File per Language

- **Mandatory 1:1 Exact Translation (No Language Exceptions):** Whichever language is supported or added (`tr`, `en`, `ro`, or future additions), every single string key must have an authentic, idiomatic, and exact 1:1 translation across all language tables.
- **Dedicated File per Language:** Each supported language must possess its own separate, dedicated localization file/table (`Resources/<lang>.lproj/Localizable.strings`). Languages must never be mixed into shared monolithic files or omitted, and each file must mirror the complete key set 1:1.
- **Zero Fallback Tolerance:** Leaving placeholder text, English strings inside non-English tables, or missing keys is strictly prohibited. Every new feature, button, dialog, or menu item must be simultaneously translated into all active languages before merging or releasing.
- Every user-visible string in `Sources/Arhivar/` must be retrieved via `settings.t(.key)` (or `model.t(.key)`) using a case of `LKey` (`Sources/ArhivarCore/Localization.swift`).
- Every `LKey` case must exist in all three localization tables:
  - `Resources/tr.lproj/Localizable.strings` (Turkish — default language)
  - `Resources/en.lproj/Localizable.strings` (English)
  - `Resources/ro.lproj/Localizable.strings` (Romanian)
- Format specifiers (`%@`, `%ld`, `%1$@`, `%2$@`) and argument counts must match 1:1 identically across all three languages.

---

## 2. SwiftUI Hierarchical `Table` Cell Safety

- **Never** use `@Environment(AppModel.self)` or `@Environment(AppSettings.self)` inside cell views rendered inside `Table(model.displayNodes, children: \.children, ...)` (such as `NameCell` in `ArchiveBrowserView.swift`).
- **Reason:** When navigating out of a subfolder back to the root, AppKit/SwiftUI re-inserts table rows without propagating environment objects to cell hosting views, causing an immediate fatal crash (`"No Observable object of type AppModel found"`).
- **Requirement:** Always pass `model: AppModel` and `settings: AppSettings` explicitly to table cell structs, and test navigation changes in `BrowserViewTests`.

---

## 3. Deceptive Filename & Accessibility Presentation

- Always render entry file names through `OpenSafety.visibleName(_:)` so invisible format/control characters and blank fillers (`U+202E`, `U+2800`, `U+3164`, `U+115F`, `U+1160`, `U+FFA0`) are visibly shown as `⟦U+XXXX⟧` accompanied by an orange warning icon (`exclamationmark.triangle.fill`).
- Honor `@Environment(\.accessibilityReduceMotion)` in `ProgressOverlay` (`isActive: !reduceMotion` on `.symbolEffect`).
- Bound `FileIcons.byPath` cache at `FileIcons.maxCachedPaths` (`256`) so `NSImage` instances do not grow unbounded across sessions.

---

## 4. macOS MenuBar, System Dialogs & In-App Language Switching Restart Warning Standard

- **The macOS Platform Constraint:** When an application provides an in-app language picker independent of macOS System Settings, dynamic string lookups (`settings.t(...)` or `L10n`) immediately update SwiftUI views and custom windows. However, system-level Cocoa controls (`NSApp.mainMenu` top-level menus, system file panels `NSOpenPanel`/`NSSavePanel`, system alert buttons, and standard Services) evaluate language bundles upon process initialization or via `AppleLanguages` in `UserDefaults`.
- **Mandatory Restart Warning Rule (AptReceipt Standard):**
  1. Whenever the user changes the application language in Preferences / Settings, the UI **must** trigger an informative alert (`restartWarningTitle`: *"Application Restart Recommended"* / *"Uygulamanın Yeniden Başlatılması Önerilir"* / *"Repornirea Aplicației Recomandată"*) and display an explanatory footer notice (`restartMenuBarNotice`: *"Menubar and interface are dynamically translated. Restarting the application is recommended to also reload system-level dialogs."* / *"Menü çubuğu ve arayüz dinamik olarak çevrilir. Sistem düzeyindeki iletişim kutularının da güncellenmesi için uygulamanın yeniden başlatılması önerilir."*).
  2. The application must write the selected language code to the `"AppleLanguages"` key in `UserDefaults` (`defaults.set([code], forKey: "AppleLanguages")`), ensuring the next cold launch opens with the selected locale at the Cocoa/AppKit level.
  3. No app may claim instantaneous complete system dialog translation without surfacing this restart warning to the user.
