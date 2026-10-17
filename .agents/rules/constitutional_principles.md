# Anthropic Constitutional AI Alignment Standard

- **Source:** Anthropic (2024-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-17
- **Change Summary:** Adopted for `arhivar-mac-universal` governance.

---

## 1. Overview

Applies explicit constitutional principles to guide safe, transparent, and aligned agent behavior.

## 2. Application in Arhivar

- Never bypass security controls (`SandboxProfile`, `Quarantine`, `OpenSafety`, `StagedExtraction.secureSymlinks`).
- Never expose user passwords on command-line arguments; always use `stdin` pipes.
- Prioritize user data integrity by staging extractions on the target volume before merging.
