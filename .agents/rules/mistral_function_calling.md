# Mistral AI Function Calling, Agents SDK & Managed Agents Standard (`mistral_function_calling.md`)

> **Upstream Source:** <https://docs.mistral.ai/capabilities/function_calling/> (Agents SDK `mistralai-agents` and Managed Agents, public preview: <https://docs.mistral.ai/studio/agents/overview>; migration guide: <https://docs.mistral.ai/studio/agents/getting-started/from-agents-api>; the former Agents and Conversations API (`client.beta.agents`) is deprecated: <https://docs.mistral.ai/studio/agents/deprecated/overview>)
> **Version / Date:** Undated documentation pages (footer "Mistral AI © 2026"), content as read on 2026-11-06; Managed Agents and the Agents SDK are marked public preview
> **Last Reviewed:** 2026-11-07
> **Change Summary:** 2026-11-07: brought in line with Descarcator's 2026-11-06 source check (no new fetch): the function calling page is unchanged (five steps, tool format, `tool_choice`, `parallel_tool_calls`, `role: "tool"` results), but the agents documentation now describes the Agents SDK (`mistralai-agents`) and Managed Agents in public preview, the migration guide says the Agents SDK replaces the Agents and Conversations API, and the former Agents API overview sits in a deprecated section; the title, the upstream sources and the Agents API bullet were rewritten to match; the Core Requirements are unchanged. 2026-11-04: rewritten from the 2026-11-03 standards review (formerly `mistral_tool_binding.md`); upstream summary carried over without a new fetch; Arhivar requirements rewritten for tool calls and the `7zz` tool contract (Arhivar makes no model calls).

---

## Upstream Summary

- Function calling has five steps: the developer defines tools, the user asks, the model generates function arguments, the developer executes the function, and the model answers from the result. The model may chain another tool call before answering.
- Each tool is a JSON object with `"type": "function"` and a `function` block holding `name`, `description`, and a JSON Schema `parameters` object with `properties` and `required`.
- The docs say "the function execution lies on the user/developer side"; the model does not run the function itself.
- `tool_choice` is `auto` (default), `any` (forces tool use), or `none`. `parallel_tool_calls` defaults to `true`; `false` forces single calls. Results go back as a `role: "tool"` message with the function `name`, `content`, and a `tool_call_id` matching the call's `id`.
- Managed Agents and the Agents SDK (`mistralai-agents`, public preview, so the API and limits may change) run an agent on its own for long periods in a stateful session that keeps every message, tool call, and result; after a crash, a turn continues from its last finished model or tool call.
- The migration guide says the Agents SDK replaces the Agents and Conversations API (`client.beta.agents`, `client.beta.conversations`): an agent becomes an `agents.Agent` object in the caller's process, conversations become sessions, handoffs become subagents (`agents.Subagent`), connectors are added by name, code execution uses `agents.MistralSandbox()`, and tool approval is set with `permission_mode` or `permission_policy`.
- The earlier Agents API overview (built-in code execution, web search, image generation, and document library tools, persistent conversations, and handoffs between agents) is kept in a deprecated section for existing integrations; no removal date is given.

## Core Requirements

1. **Proposals Are Not Executions:** Arhivar has no model tool binding. For coding agents, a planned tool call is a proposal; deleting files, rewriting archives, engine installs, and releases stay with the user.
2. **External Contracts Are Checked:** The `7zz` switches built by `SevenZipCommand` and the output formats Arhivar decodes (the `l -slt` technical listing in `ListingParser`, `-bsp1` progress in `ProgressParser`, `h` checksums in `ChecksumParser`, exit codes and messages in `SevenZipError.check`), plus the `KEY=value` output of `update-7zip.sh` read by `EngineUpdateResult.parse`, are this repository's tool contracts. After `Scripts/update-7zip.sh` brings a new 7-Zip version, check them against `Vendor/7-Zip/MANUAL`, `Vendor/7-Zip/History.txt`, or a read-only run and the real-engine suites, never from memory.
3. **Every Result Traces to Its Call:** Each reported outcome names the command or test that produced it, the way `tool_call_id` ties a result to its call.
4. **Parallel Calls Only for Independent Work:** Run tool calls in parallel only when they are independent reads; dependent edits and checks run in order.
