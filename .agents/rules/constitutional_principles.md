# Anthropic Claude Constitution Standard (`constitutional_principles.md`)

> **Upstream Source:** <https://www.anthropic.com/constitution>
> **Version / Date:** January 2026 Revision (supersedes the 2023 principle list)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards set, whose file for this standard was last checked upstream on 2026-10-31 and carries no upstream summary; no new fetch, so none is added; Arhivar requirements rewritten.

---

## Core Requirements

1. **Reasoning-Based Alignment:** Evaluate extraction, archive editing, engine, and release changes by their reversibility, blast radius, and respect for user autonomy rather than brittle keyword heuristics alone.
2. **User Data Integrity First:** Never let an operation leave user files half-written. Extraction stages on the target volume and merges only after `7zz` succeeds; a cancellation or error removes the staging folder and leaves the destination untouched. New archives are written in a staging folder and installed only on success (`StagedExtraction.installArchive`), and a same-named folder is never replaced by an archive; for in-place edits `7zz` writes its temporary copy in a work folder on the same volume (`-w`) before it replaces the archive. The default overwrite rule is `.rename`, adding or deleting entries inside an archive waits for a confirmation dialog (`EditDialogs`), and renaming waits for the rename prompt.
3. **Never Bypass Security Controls:** Do not weaken or route around `SandboxProfile`, `Quarantine`, `OpenSafety`, or `StagedExtraction.secureSymlinks`, and never put a password on a command line; passwords reach `7zz` only through stdin (`SevenZipCommand.passwordInput`).
