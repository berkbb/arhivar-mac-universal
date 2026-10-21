# User-Rejected Specs & Anti-Feature Redlines

> **Memory Category:** TencentDB L3 Persona & Redline Constraints  
> **Scope:** Architectural redlines, license boundaries, and UX anti-patterns that agents must never introduce.

---

## Redline Specifications (Strictly Forbidden)

1. **No Direct C/C++ Linking to 7-Zip or unRAR:**
   - **Rule:** Never link `7-Zip` or `unRAR` source code into the Swift binary.
   - **Rationale:** `7-Zip` is licensed under GNU LGPL with the `unRAR` restriction. Invoking the unmodified standalone `7zz` binary as a separate subprocess keeps it a separate work from the GPL-3.0-licensed `Arhivar` (relicensed in 1.4.2), so the bundled engine stays under its own LGPL and unRAR terms instead of being combined into the Swift binary.
2. **No RAR Archive Creation:**
   - **Rule:** Never add `.rar` to `ArchiveFormat` or generate `a -trar` commands.
   - **Rationale:** Prohibited by the `unRAR` license restriction and unsupported by `7zz`.
3. **No Passwords in CLI Arguments:**
   - **Rule:** Never pass `-p<password>` on the `7zz` command line.
   - **Rationale:** Command-line arguments are world-readable to other processes via `ps` / `sysctl`. Always pass bare `-p` (when required) and feed the password through `stdin` (`SevenZipCommand.passwordInput`).
4. **No Unsolicited Network Connections Before User Consent:**
   - **Rule:** Never connect to `api.github.com` at launch unless `settings.updateConsentAsked == true && settings.checkUpdatesAtLaunch == true`.
   - **Rationale:** Privacy guarantee documented in `README.md` and `DEVELOPMENT.md`, enforced by `launchAsksForUpdateConsentWithoutNetwork`.
5. **No Editing of Nested Archives:**
   - **Rule:** When `archiveStack` is non-empty, `isEditable` must remain `false`.
   - **Rationale:** A nested archive is extracted to a temporary session directory; modifying it in place would not update the enclosing parent archive and would silently lose user changes on close.
6. **No Unchecked `Int64` Addition on Archive Sizes:**
   - **Rule:** Never use `+` to sum entry `size` or `packedSize` values from untrusted archive listings.
   - **Rationale:** Prevents integer overflow crashes (`EXC_BAD_INSTRUCTION`) on zip bombs.
7. **No GitHub Actions Dependency for Releases:**
   - **Rule:** Do not add `.github/workflows` release pipelines unless explicitly requested by the user.
   - **Rationale:** Packaging and release publishing are intentionally local-first via `Scripts/package.sh` (`Paketle.command`) and `Scripts/release.sh` (`Yayimla.command`).
