# LangChain / LangGraph Cyclic State Machine Standard

- **Source:** LangChain / LangGraph (2025-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-17
- **Change Summary:** Adopted for `arhivar-mac-universal` governance.

---

## 1. Overview

Models stateful workflows as explicit, recoverable state transitions.

## 2. Application in Arhivar

- Represent `AppModel` operations (`OperationState`), password retries (`PendingAction`), and nested archives (`archiveStack`) as explicit state machines.
- Ensure cancellation or error recovery leaves `AppModel` and disk destinations in a clean, consistent state.
