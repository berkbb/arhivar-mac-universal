# Engine Maintenance Skill — 7-Zip Engine Update & Parser Performance

> **Memory Category:** TencentDB Procedural Memory (Skill Asset)
> **Trigger:** Checking or updating the bundled `7zz` engine (`Vendor/7-Zip`, or the copy inside `build/Arhivar.app`), or changing `ListingParser` / `ArchiveTree` performance-critical paths.
> **Last Reviewed:** 2026-11-04 (renamed from `model_trainer_skill.md`; every command and flag checked against `Scripts/update-7zip.sh`).

---

## 1. Purpose

Keeps the bundled, unmodified 7-Zip (`7zz`) engine current with recorded provenance (`Vendor/7-Zip/SOURCE.txt`) and guards parsing throughput on 200,000-entry archive listings (`ListingPerformanceTests`).

---

## 2. Standard Execution Procedure

### Step 1: Check for a Newer `7zz` (Read-Only, Network)
```bash
./Scripts/update-7zip.sh check
```
- Queries `https://api.github.com/repos/ip7z/7zip/releases/latest` and prints `KEY=value` lines (`LATEST`, `CURRENT`, `SOURCE`, `TARGET`, `STATUS=up-to-date` or `update-available`); human messages go to stderr. With no target it checks `Vendor/7-Zip` when run from the project.

### Step 2: Install the Update (Needs the User's Approval)
```bash
./Scripts/update-7zip.sh install --dest Vendor/7-Zip
./Scripts/update-7zip.sh install --dest Vendor/7-Zip --app build/Arhivar.app   # also update a built app
```
- `7-Zip-Guncelle.command` does the same from Finder (both targets when `build/Arhivar.app` exists).
- Downloads the `7zNNNN-mac.tar.xz` release asset over HTTPS only, rejects URLs outside `https://github.com/ip7z/7zip/releases/download/`, verifies the GitHub `sha256:` digest, checks that `7zz` is a Mach-O binary whose reported version matches the release tag, replaces the binary atomically, and signs it ad hoc. For `--dest` it copies `License.txt`, `History.txt`, `readme.txt`, and `MANUAL` and records `version`, `asset`, `url`, and `sha256` in `SOURCE.txt`; for `--app` it updates `Contents/MacOS/7zz`, `7-Zip-License.txt`, and `Manual` and re-signs the app ad hoc.
- `--force` reinstalls the current version. Never use `--no-verify` (skips the SHA-256 check) without the user's explicit decision.

### Step 3: Re-Verify the Engine Contract After an Update
```bash
swift test
```
- The real-engine suites exercise listing, extraction, editing, passwords, and the sandbox with the new `7zz`. Read `Vendor/7-Zip/History.txt` for changes to the switches and output formats in the `7zz` command contract (`.agents/context/domain_wiki.md`, `mistral_function_calling.md`), then rebuild and verify the bundle with `sentinel_test_skill.md` Step 4.

### Step 4: Run the 200,000-Entry Parser Benchmark
```bash
swift test --filter ListingPerformanceTests
```
- `parsesLargeListingQuickly` parses a synthetic 200,000-entry `7zz l -slt` listing and prints the elapsed time; compare it before and after a change. Deep trees are covered by `swift test --filter ArchiveTreeDepthTests`.
- **Invariants:**
  - `ListingParser.parse` walks lines with `forEachLine`, which scans the UTF-8 view without building an intermediate array of lines.
  - `ListingParser.parseTimestamp` reads `yyyy-MM-dd HH:mm:ss` at the byte level and uses `daysFromCivil`, never `DateFormatter`.
  - `ListingParser.normalizedPath` returns already-normalized paths through the single-pass `needsNormalization` fast path without extra allocations.
