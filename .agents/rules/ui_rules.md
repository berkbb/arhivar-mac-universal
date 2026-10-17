# UI Rules, Localization & SwiftUI Table Safety Standards

- **Source:** Project UI & Localization Governance (`Arhivar`)
- **Version:** 1.0.2
- **Last Review Date:** 2026-10-17
- **Change Summary:** Codified trilingual `LKey` rules, SwiftUI `Table` `@Environment` ban in cells, and responder-aware Edit menu commands.

---

## 1. Strict Ban on Hardcoded UI Strings

- Every user-visible string in `Sources/Arhivar/` must be retrieved via `settings.t(.key)` (or `model.t(.key)`) using a case of `LKey` (`Sources/ArhivarCore/Localization.swift`).
- Every `LKey` case must exist in all three localization tables:
  - `Resources/tr.lproj/Localizable.strings` (Turkish — default language)
  - `Resources/en.lproj/Localizable.strings` (English)
  - `Resources/ro.lproj/Localizable.strings` (Romanian)
- Format specifiers (`%@`, `%ld`, `%1$@`, `%2$@`) must match across all three languages.

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
