# Apple App Intents & Native macOS Integration Standard (`apple_app_intents_agent.md`)

> **Upstream Source:** <https://developer.apple.com/documentation/appintents> & <https://security.apple.com/documentation/private-cloud-compute>
> **Version / Date:** macOS 26 (Tahoe) / 2026
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards set, whose file for this standard was last checked upstream on 2026-10-31 and carries no upstream summary; no new fetch, so none is added; Arhivar requirements rewritten (Arhivar ships no App Intents).

---

## Core Requirements

1. **Local On-Device Execution:** Listing, testing, extraction, creation, in-place editing, checksums (`7zz h`), and Quick Look previews run on the Mac with no telemetry or uploads, and `7zz` runs with `(deny network*)`. The only connections are GitHub release checks: at launch only after the first-launch consent (`updateConsentAsked` and `checkUpdatesAtLaunch`), or when the user picks a "Check for … Updates" command. `AppUpdateChecker` reads the public release list and the Download button only opens the download link in the browser; `Scripts/update-7zip.sh` downloads a new `7zz` only on the user's request.
2. **Safe Finder Services (`NSServices`):** The `extractHere`, `openArchive`, and `compress` services are declared under `NSServices` in `Support/Info.plist` (titles from `ServicesMenu.strings` in each `.lproj`), registered with `NSUpdateDynamicServices()`, and handled by `FinderServices`. Incoming files go through the same `AppModel` flows as in-app actions (sandboxed `7zz`, staged extraction, quarantine propagation); a service never bypasses them.
3. **Sandboxed Quick Look Extension:** `ArhivarQuickLook.appex` lists archives with `7zz` when it can launch and otherwise in process through the read-only system `libarchive` (`LibArchiveReader`), because the Quick Look sandbox forbids child processes. `PreviewListing.content` returns `.locked` for password-protected archives so their names are never shown.
4. **No App Intents Without a Decision:** Arhivar declares no `AppIntent` types and uses no Apple Intelligence or Private Cloud Compute features. Adding App Intents, Shortcuts actions, or any system agent surface needs an explicit user decision first.
