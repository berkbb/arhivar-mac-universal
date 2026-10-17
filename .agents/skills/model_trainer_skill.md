# Engine & Performance Calibration Skill

> **Memory Category:** TencentDB Procedural Memory (Skill Asset)  
> **Trigger:** Updating the bundled `7zz` engine (`Vendor/7-Zip`) or modifying `ListingParser` / `ArchiveTree` performance-critical paths.

---

## 1. Purpose

Maintains the bundled `7-Zip` (`7zz`) engine provenance (`Vendor/7-Zip/SOURCE.txt`) and validates zero-regression parsing throughput on 200,000-entry archive listings (`ListingPerformanceTests`).

---

## 2. Standard Execution Procedure

### Step 1: Check or Update the Bundled `7zz` Engine
```bash
./Scripts/update-7zip.sh check
./Scripts/update-7zip.sh install --dest Vendor/7-Zip
```
- Verifies the GitHub Release asset against its `sha256:` digest, confirms Mach-O universal binary format, checks the reported version against the release tag, and records `version`, `asset`, `url`, and `sha256` in `Vendor/7-Zip/SOURCE.txt`.

### Step 2: Run the 200,000-Entry Parser & Tree Benchmark
```bash
swift test --filter ListingPerformanceTests
```
- **Invariants:**
  - `ListingParser.parse` must iterate over `output.utf8` lazily (`forEachLine`) without allocating an intermediate `[Substring]` array of lines.
  - `ListingParser.parseTimestamp` must parse `yyyy-MM-dd HH:mm:ss` at the byte level using `daysFromCivil` without instantiating `DateFormatter`.
  - `ListingParser.normalizedPath` must use the single-pass `needsNormalization` fast path so already-normalized paths incur zero extra allocations.
