# Task: Strengthen the 11-Discipline Matrix Tests

## Background

Arhivar is a Swift 6.2 / SwiftUI macOS app (repo `berkbb/arhivar-mac-universal`, local checkout at `/Users/berkbabadogan/Documents/GitHub/arhivar-mac-universal`) that wraps an unmodified `7zz` binary (`Vendor/7-Zip/7zz`) under `sandbox-exec`. `ArhivarCore` is the testable core; tests use Swift Testing (`@Test`, `#expect`).

An adversarially verified audit (2026-10-19) graded `Tests/ArhivarCoreTests/ChaosAndSecurityMatrixTests.swift` discipline by discipline: 9 of 11 disciplines only partially prove the claim they are named after, 04 quarantine proves nothing (string math only), 09 parser fuzz was tautological. The per-discipline strengthening list is recorded in `.agents/context/roadmap.md` under "Open / In Progress > Test-Quality Items > 2."

Real coverage of the same claims already lives in `SandboxTests`, `AuditFixesTests`, `SecurityHardeningTests`, `FuzzTests`, `HardeningIntegrationTests` (has a `TarBuilder`) and `AppModelTests`, so reuse their helpers (`tempDir`, `engineURL`, `Fixture`) instead of duplicating.

## Rules

- Commit directly to `main` (no feature branches).
- Commit messages in English in the format `modify type @ scope: 'sentence' - [tag]`, one change per line, ending with the Co-Authored-By line the app gives.
- Never report completion without building and running the full suite (`swift build --build-tests`, then `swift test --skip-build`).
- No hardcoded wall-clock bounds in tests (repo convention, see `ListingPerformanceTests`).
- Seeded randomness only (SplitMix64 in `FuzzTests`).
- Another assistant (Gemini) sometimes edits this checkout concurrently: check `git status` before staging and stage explicit files only.

## Work per discipline

- **01 Sandbox:** live stdin password delivery through `CommandRunner` with `/bin/cat`; an argv-wide secret scan over every `SevenZipCommand` builder plus `SandboxProfile.launchArguments`; live read-deny and network-deny runs using the `home:` injection point of `SandboxProfile.forOperation`; an `ArhivarAppTests` case that `AppModel.confined` wires the profile when the sandbox setting is on and returns the plain runner when off.
- **02 Hierarchy:** assert the built tree structurally (`ArchiveTree.index` / `search` / `sorted` / `contents`, depth equal to `ArchiveTree.maxDepth` for an over-deep listing) and delete the `< 1.0 s` wall-clock assertion.
- **03 Malformed data:** assert exact error cases (`SevenZipError.notArchive`, `needsPassword == false`); replace unseeded `UInt8.random` with the seeded SplitMix64 generator from `FuzzTests`; add truncated and bit-flipped real archives created with the vendored `7zz` (expect `.failed` with 7-Zip's reason text); run through the sandboxed runner; use `.enabled(if: engineURL != nil)` instead of a silent early return.
- **04 Quarantine:** set a real `com.apple.quarantine` on a source archive, extract through `StagedExtraction` + `Quarantine.propagate` and read the derived value back from extracted items, including a `._*` file, a read-only item and a symlinked archive.
- **05 Saturating arithmetic:** drive `DiskSpace.requiredBytes` and the parsed `Physical Size` with `Int64.max`-scale values.
- **06 Endurance:** repeat extraction cycles and assert no staging folders and no growth in open file descriptors (count entries of `/dev/fd`).
- **07 Input sanitization:** push hostile names through `OpenSafety.visibleName` / `hasDeceptiveCharacters`, `ArchiveTree.isValidName` and `CreateArchiveSheet.sanitizedName`.
- **08, 09, 10:** keep as they are now unless a gap is obvious.
- **11 Atomic extraction:** prove that a cancel between 7-Zip exit and merge leaves the destination untouched and that the cross-type replace rollback works.

## Definition of done

- Every new or changed test fails if the fix or guarantee it covers is removed (verify at least the key ones by temporarily breaking the code locally, then restoring it).
- The whole suite passes.
- Test counts updated in `README.md`, `DEVELOPMENT.md`, `CHANGELOG.md` and `.agents/skills/sentinel_test_skill.md`.
- Roadmap item 2 removed from `.agents/context/roadmap.md`.
- Committed to `main` in English in the user's commit format (one commit per discipline, then a docs commit) and pushed to origin.
