# Mistral AI Tool Binding Standard

- **Source:** Mistral AI (2025-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-17
- **Change Summary:** Adopted for `arhivar-mac-universal` governance.

---

## 1. Overview

Defines strongly typed schemas and contracts for binding external tools and CLI binaries.

## 2. Application in Arhivar

- Encapsulate all `7zz` command-line switch generation in `SevenZipCommand` (`Sources/ArhivarCore/`).
- Parse structured CLI outputs (`7zz l -slt`, `7zz h`, `update-7zip.sh`) through dedicated, unit-tested parsers.
