# IBM Granite Enterprise Agent Standard

- **Source:** IBM Research (2025-2026)
- **Version / Publication Date:** 2026.04
- **Last Review Date:** 2026-10-17
- **Change Summary:** Adopted for `arhivar-mac-universal` governance.

---

## 1. Overview

Applies enterprise-grade supply-chain verification, license compliance, and auditability.

## 2. Application in Arhivar

- Verify downloaded `7zz` releases via SHA-256 digest, Mach-O check, and version tag match in `Scripts/update-7zip.sh`.
- Record engine provenance in `Vendor/7-Zip/SOURCE.txt` and preserve `THIRD_PARTY_NOTICES.md`.
