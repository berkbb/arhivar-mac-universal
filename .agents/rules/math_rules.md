# Mathematical, Byte-Counting & Physical Invariants (`math_rules.md`)

> **Memory Category:** Declarative Domain Rule
> **Source:** Project domain invariants (`ArhivarCore`)
> **Version / Date:** 1.0.2 (content of 2026-10-20)
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: header aligned with the standard rule files and every cited symbol re-checked against `Sources/`; rule content unchanged from 1.0.2.
> **Scope:** Saturating `Int64` size summation, disk space reserve formulas, compression ratio and progress bounds, and civil date conversion.

---

## 1. Saturating `Int64` Byte Arithmetic (Zip-Bomb Protection)

Untrusted archive headers can declare arbitrary 64-bit unpacked or packed sizes per entry whose sum exceeds `Int64.max` ($2^{63} - 1$).
- **Rule:** Never use unchecked `+` when summing entry sizes, folder sizes, or required disk bytes.
- **Formula:**
  $$\text{saturatingAdd}(a, b) = \min(\max(a + b, \text{Int64.min}), \text{Int64.max})$$
- **Implementation:** Always use `Int64.saturatingAdding(_:)` and `Sequence<Int64>.saturatingSum()` (`Sources/ArhivarCore/ArchiveListing.swift`).

---

## 2. Pre-Flight Disk Space Invariants (`DiskSpace`)

1. **System Safety Reserve:**
   $$\text{Reserve} = 2^{30}\text{ bytes } (1\text{ GiB})$$
2. **Available Room Check:**
   $$\text{hasRoom}(\text{required}, \text{available}) \iff \text{required} \le \max(0, \text{available} - \text{Reserve})$$
   If `available` is `nil` (unknown volume capacity), `hasRoom` returns `true` so extraction is not falsely blocked.
3. **Required Bytes for Archive Writing (`requiredForWriting`):**
   $$\text{Required}_{\text{write}} = \text{saturatingAdd}\!\left(\text{ExistingArchiveBytes},\; \begin{cases} 0 & \text{if compresses} \\ \text{SourceBytes} & \text{if uncompressed or two-step } \texttt{.tar.*} \end{cases}\right)$$

---

## 3. Compression Ratio & Progress Bounds

- **Compression Ratio (`ArchiveStatistics.ratio`):**
  $$\text{ratio} = \begin{cases} \dfrac{\text{Double}(\text{packedSize})}{\text{Double}(\text{totalSize})} & \text{if } \text{totalSize} > 0 \\ \text{nil} & \text{if } \text{totalSize} \le 0 \end{cases}$$
- **Two-Step `.tar.*` Progress Scaling:**
  - Step 1 (`.tar` creation): $p_{\text{total}} = 0.5 \times p_1$
  - Step 2 (`.gz`/`.xz`/`.bz2` compression): $p_{\text{total}} = 0.5 + 0.5 \times p_2$
- **Howard Hinnant Civil Calendar Algorithm (`ListingParser.daysFromCivil`):**
  - Converts `(year, month, day)` directly to days since `1970-01-01` in $O(1)$ integer arithmetic without `DateFormatter`, resolving DST transitions by comparing `timeZone.secondsFromGMT` at $t - 86400$ and $t + 86400$.
