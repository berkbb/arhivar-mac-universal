# OpenAI Agents SDK Guardrails & Tool Safety Standard (`openai_agents_sdk_safety.md`)

> **Upstream Source:** <https://github.com/openai/openai-agents-python>
> **Version / Date:** 2026 Stable
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards set (formerly `openai_tool_calling_safety.md`), whose file for this standard was last checked upstream on 2026-10-31 and carries no upstream summary; no new fetch, so none is added; Arhivar requirements rewritten.

---

## Core Requirements

1. **Pre-Execution Tripwires:** Every `7zz` invocation is built by `SevenZipCommand` (`-sccUTF-8`, every path after `--`, `-spd` whenever wildcards could be misread, per `wildcardSafety`), receives passwords only through stdin (`SevenZipCommand.passwordInput`), runs under the operation's `SandboxProfile` through `AppModel.confined(...)` with paths bound as `-D` parameters. Extraction and archive writing are preceded by a free-space check (`InsufficientSpaceError.check`, `DiskSpace.requiredForWriting`). If `sandbox-exec` cannot start, the run fails closed (`SevenZipError.sandboxUnavailable`); `7zz` is never launched unprotected while the sandbox setting is on.
2. **Post-Execution Validation:** `SevenZipError.check` classifies the result (success, warning, wrong password, not an archive, cancelled, or failure) before anything is used. Staged output passes `secureSymlinks`, `removeLinkPlaceholders`, and `Quarantine.propagate` before `StagedExtraction.merge` touches the destination, and an edited archive is listed again (`relistAfterEdit`) so the UI shows what `7zz` actually wrote.
