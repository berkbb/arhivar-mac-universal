# Meta Purple Llama Agentic Safety Standard (`meta_purple_llama_safety.md`)

> **Upstream Source:** <https://github.com/meta-llama/PurpleLlama> (Llama Guard 4, LlamaFirewall, Prompt Guard 2, CyberSecEval 4)
> **Version / Date:** 2026 Stable
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards set (formerly `meta_fair_safety.md`), whose file for this standard was last checked upstream on 2026-10-31 and carries no upstream summary; no new fetch, so none is added; Arhivar requirements rewritten.

---

## Core Requirements

1. **Credential & Personal Data Firewall:** Every sandboxed `7zz` run denies reads of `SandboxProfile.personalDataDirectories` (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.docker`, `~/.netrc`, shell histories, `~/Library/Keychains`, Mail, Messages, `Containers`, browser profiles, and more). An archive or a user-selected source inside one of those folders opens only that file or folder, never the whole protected folder. Hard links to files in `SandboxProfile.secretDirectories` are skipped with a warning when creating or adding (`SecretLinks`).
2. **Symlink Escape Prevention:** `StagedExtraction.secureSymlinks(in:extractionRoot:)` removes every symbolic link that resolves outside the staging root and rewrites `7zz`-written absolute staging links as relative links; `removeLinkPlaceholders` deletes the 0-byte files `7zz` leaves for dangerous links; `ItemExtractor` applies the same containment per target.
3. **Deceptive Names & Risky Files:** `OpenSafety.hasDeceptiveCharacters` and `visibleName` expose bidirectional overrides and invisible fillers as `⟦U+XXXX⟧`, and `OpenSafety.executableKind` flags executables, scripts, and installers; opening either kind needs the user's confirmation.
4. **Resource Exhaustion:** Archive sizes are summed with saturating arithmetic (`math_rules.md`), free space is checked before writing (`DiskSpace`) and watched while extracting (`DiskSpaceGuard`), and `CommandRunner.maxOutputBytes` stops a run whose output would exhaust memory.
