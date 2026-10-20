# Uber Agentic AI Detection and Response (ADR)

- **Source:** Uber Security & AI (2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-20
- **Change Summary:** Adopted for `arhivar-mac-universal` governance.

---

## 1. Overview

Enterprise agentic security framework covering runtime containment, red-teaming, and two-tier detection.

## 2. Application in Arhivar

- Enforce defense-in-depth: kernel sandboxing (`SandboxProfile`) + Swift-level symlink verification (`secureSymlinks`) + Gatekeeper quarantine propagation (`Quarantine.propagate`).
