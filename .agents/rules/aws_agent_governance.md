# AWS Bedrock Agentic Governance Standard

- **Source:** AWS Bedrock (2025-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-17
- **Change Summary:** Adopted for `arhivar-mac-universal` governance.

---

## 1. Overview

Covers operational controls, least-privilege execution, and observability for software agents.

## 2. Application in Arhivar

- Enforce least-privilege filesystem and network rules in `SandboxProfile`.
- Require explicit user consent (`askUpdateConsent`) before initiating launch-time GitHub API checks.
