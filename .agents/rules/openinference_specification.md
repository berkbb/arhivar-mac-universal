# Arize AI OpenInference Specification

- **Source:** Arize AI / OpenTelemetry (2024-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-20
- **Change Summary:** Adopted for `arhivar-mac-universal` governance.

---

## 1. Overview

Defines observable state transitions and diagnostic error reporting.

## 2. Application in Arhivar

- Summarize subprocess failures cleanly via `SevenZipError.diagnostic(from:)` without leaking sensitive stdin data.
