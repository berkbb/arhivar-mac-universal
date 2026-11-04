# Chain-of-Thought Prompting Standard (`chain_of_thought_prompting.md`)

> **Upstream Source:** <https://arxiv.org/abs/2201.11903> — "Chain-of-Thought Prompting Elicits Reasoning in Large Language Models", Jason Wei, Xuezhi Wang, Dale Schuurmans, Maarten Bosma, Brian Ichter, Fei Xia, Ed Chi, Quoc Le, Denny Zhou (Google Research, Brain Team)
> **Version / Date:** arXiv v6, 2023-01-10 (v1 2022-01-28); the v6 PDF carries the NeurIPS 2022 conference footer
> **Last Reviewed:** 2026-11-04
> **Change Summary:** 2026-11-04: rewritten from the 2026-11-03 standards review; upstream summary carried over without a new fetch; Arhivar requirements rewritten for byte arithmetic and extraction-safety decisions (the reasoning–action–observation loop stays in `react_agent_methodology.md`).

---

## Upstream Summary

- A chain of thought is a series of intermediate reasoning steps. Giving a model a few chain-of-thought demonstrations as exemplars improved arithmetic, commonsense, and symbolic reasoning on three large language models.
- The authors report that this ability emerges in sufficiently large models. PaLM 540B with eight exemplars reached state-of-the-art accuracy on GSM8K, ahead of finetuned GPT-3 with a verifier.
- Limitation stated by the authors: nothing guarantees a correct reasoning path, so a chain can lead to a wrong answer as well as a right one.
- Not stated on the canonical page, so not adopted here: "intermediate verification practices". The paper elicits intermediate steps but defines no way to verify them; the checks below are this repository's own.

## Core Requirements

1. **Write Out Byte Arithmetic:** Size totals, required-space checks, compression ratios, and progress scaling are worked step by step with each intermediate value written down, using the helpers named in `math_rules.md` (`Int64.saturatingAdding`, `saturatingSum`, `DiskSpace.hasRoom`, `DiskSpace.requiredForWriting`).
2. **Decompose Extraction-Safety Decisions:** Before changing how entries are extracted, edited, or exposed to `7zz`, write the chain for a sample entry: raw `archivePath` → normalized `path` → staging directory → `SevenZipError.check` → `secureSymlinks` and `removeLinkPlaceholders` → `Quarantine.propagate` → `SubfolderMode` target → merge with the chosen `OverwriteMode` (the pipeline in `symbolic_memory_graph.md`). A step that cannot be filled in stops the change.
3. **A Chain Is Not Proof:** Each step a conclusion depends on is checked against the source, a test, or a read-only command (`react_agent_methodology.md`), and the result is confirmed with `swift test`, not by the chain reading well.
4. **Assumptions Are Labelled:** A step that rests on something not yet checked (a `7zz` output line or exit code, a `sandbox-exec` path rule) is marked as an assumption in the plan until it is verified.
