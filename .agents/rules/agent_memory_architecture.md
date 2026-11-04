# TencentDB Agent Memory Architecture Standard (`agent_memory_architecture.md`)

> **Memory Category:** Master Protocol Rule
> **Upstream Source:** <https://github.com/TencentCloud/TencentDB-Agent-Memory> (MIT)
> **Version / Date:** v2.0.0 (the README gives no release date)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream definitions and tier names (`L0 Conversation`, `L1 Atom`, `L2 Scenario`, `L3 Core / Persona`) carried over without a new fetch; asset and tier mapping rewritten for Arhivar files.
> **Scope:** Four Memory Assets (Chat Memory, Skill, LLM-Wiki, Code-Graph) and L0–L3 Memory Tiers.

---

## 1. Upstream Summary

- TencentDB Agent Memory is a team-level memory hub for AI agents that turns conversations, docs, and code into four reusable memory assets: **Chat Memory** (preferences, facts, decisions, interaction history), **Skill** (reusable expertise with versions, resource files, trigger boundaries, execution steps, and validation rules), **Wiki / LLM-Wiki** (docs, specs, and runbooks as structured, linked pages), and **CodeGraph / Code-Graph** (code symbols, files, call relationships, and impact paths).
- Chat Memory is layered: **L0 Conversation** (raw conversations with full context), **L1 Atom** (facts, preferences, constraints, and events extracted from them), **L2 Scenario** (knowledge blocks organized around projects or scenarios), **L3 Core / Persona** (long-term profiles, stable patterns, high-level cognition).
- Arhivar uses the layout as a file convention only; it does not run the Memory Core, Proxy, Panel, or Hub services.

## 2. Four Memory Assets in Arhivar

1. **Chat Memory:** Session context and user intent; the user's standing decisions live in `.agents/context/user_rejected_spec.md` and `.agents/context/roadmap.md`.
2. **Skill (`skills/`):** Test and bundle validation (`sentinel_test_skill.md`), 7-Zip engine update and parser performance (`engine_maintenance_skill.md`), and settings, session, and `Info.plist` compatibility audits (`snapshot_audit_skill.md`). Format for new skills: `agent_skills_specification.md`.
3. **LLM-Wiki (`context/domain_wiki.md`):** The `7zz` command contract (`SevenZipCommand`) and its quirks, the sandbox and quarantine architecture, Finder integration and document icons, and release signing.
4. **Code-Graph (`context/code_graph_wiki.md`):** Symbols, module dependencies, and impact paths, regenerated from Graphify (`graphify_knowledge_graph.md`).

## 3. Four-Tier Hierarchy (L0–L3) in Arhivar

The global `CLAUDE.md` extends the upstream conversation tiers to project state; this repository follows that mapping (see also the table in `.agents/AGENTS.md`):

- **L0 Conversation / Execution Logs:** Session transcripts, `swift test` output, and command traces. Inside the app: `AppLog` entries (unified log subsystem `com.babadogantech.arhivar` and the user-only file `~/Library/Logs/Arhivar/Arhivar.log`).
- **L1 Atom:** Constants and switches such as `DiskSpace.reserve` (1 GiB), `DiskSpaceGuard.floor`, `CommandRunner.maxOutputBytes`, `SevenZipCommand.maxPasswordInputBytes`, the 2-second `killGracePeriod` in `CommandRunner.swift`, `FileIcons.maxCachedPaths` (256), and format and compression options in `ArchiveOptions.swift`.
- **L2 Scenario:** `AppModel` runtime state (`EngineStatus`, `UpdateState`, `AppUpdateState`, `archiveStack`, `PendingAction`) and `AppSettings` preferences in `UserDefaults`, documented in `.agents/context/symbolic_memory_graph.md`.
- **L3 Core / Persona:** `.agents/AGENTS.md` constitutional invariants, the rules in `.agents/rules/`, and `user_rejected_spec.md`.
