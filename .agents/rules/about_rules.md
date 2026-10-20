# Domain Rules Index & Governance Structure Standard

- **Source:** TencentDB Agent Memory & Core AI Standards Governance
- **Version:** 2026.10
- **Last Review Date:** 2026-10-20
- **Change Summary:** Expanded Core AI Standards from 38 to 42 SOTA standards, incorporating AAIF, Apple AIAP, OWASP Agentic Security, and Hugging Face Actions-as-Code.

---

## 1. Purpose

Defines the index of declarative domain rules and the 42 Core AI Company, Research Lab, and Approved Academic Standards governing AI agents in this repository.

## 2. Project Domain Rules

1. [`math_rules.md`](math_rules.md) — Saturating `Int64` byte arithmetic, compression ratio calculation, disk space reserve math, civil-calendar timestamp math, and financial rounding invariants.
2. [`ui_rules.md`](ui_rules.md) — Trilingual (`tr`, `en`, `ro`) `LKey` localization enforcement, dedicated localization file per language, hardcoded string ban, SwiftUI hierarchical `Table` cell safety, and macOS 26 Liquid Glass UI conventions.
3. [`agent_memory_architecture.md`](agent_memory_architecture.md) — TencentDB Agent Memory Four-Tier Pyramid (L0–L3) and 4 Memory Assets.
4. [`github_spec_kit.md`](github_spec_kit.md) — GitHub Spec Kit (Spec-Driven Development / SDD) lifecycle protocol.

## 3. Core AI Lab & Industry Standards Index

- Alignment & Safety: `constitutional_principles.md`, `openai_model_spec.md`, `openai_tool_calling_safety.md`, `meta_fair_safety.md`, `agentic_detection_response.md`, `uber_adr_research_paper.md`, `owasp_agentic_security.md`
- Memory & Reflection: `agent_memory_architecture.md`, `memgpt_os_memory.md`, `generative_agents_reflection.md`
- Reasoning & Execution: `grok_reasoning_trace.md`, `react_agent_methodology.md`, `chain_of_thought_prompting.md`, `retrieval_augmented_generation.md`, `qwen_agent_interpreter.md`, `cognition_devin_workflow.md`, `autogpt_autonomous_loop.md`, `dspy_declarative_signatures.md`, `openai_harmony_response_format.md`, `huggingface_codeagent_actions.md`
- Multi-Agent & State Machines: `multi_agent_orchestration.md`, `langgraph_state_machine.md`, `crewai_task_delegation.md`, `camel_ai_inception.md`, `agent2agent_protocol.md`, `aaif_agentic_foundation.md`
- Tooling, UI & Enterprise Protocols: `model_context_protocol.md`, `agent_skills_specification.md`, `mcp_apps_extension.md`, `mcp_enterprise_managed_authorization.md`, `mistral_tool_binding.md`, `agent_to_ui_protocol.md`, `agent_user_interaction_protocol.md`, `apple_app_intents_agent.md`, `aws_agent_governance.md`, `ibm_granite_enterprise.md`, `openinference_specification.md`
- Agentic Commerce & Payments: `agentic_commerce_protocol.md`, `agent_payments_protocol.md`, `universal_commerce_protocol.md`
