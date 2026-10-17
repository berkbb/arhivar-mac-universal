# OpenAI Swarm Tool Safety Protocol

- **Source:** OpenAI (2025-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-17
- **Change Summary:** Adopted for `arhivar-mac-universal` governance.

---

## 1. Overview

Sets strict safeguards for validating arguments, sandboxing subprocesses, and executing tool calls.

## 2. Application in Arhivar

- All `7zz` arguments must place file paths after `--` to prevent option injection.
- Pass `-spd` when operating on selected archive entries or when source names contain `*` or `?`.
- Execute external binaries inside `/usr/bin/sandbox-exec` with explicit `-D` parameter bindings.
