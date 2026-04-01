# PARITY Gap Analysis

Date: 2026-04-01

Scope compared:
- Upstream TypeScript: `/home/bellman/Workspace/claude-code/src/`
- Rust port: `rust/crates/`

Method:
- Read-only comparison only.
- No upstream source was copied into this repo.
- This is a focused feature-gap report for `tools`, `hooks`, `plugins`, `skills`, `cli`, `assistant`, and `services`.

## Executive summary

The Rust port has a solid core for:
- basic prompt/REPL flow
- session/runtime state
- Anthropic API/OAuth plumbing
- a compact MVP tool registry
- CLAUDE.md discovery
- MCP config parsing/bootstrap primitives

But it is still materially behind the TypeScript implementation in six major areas:
1. **Tools surface area** is much smaller.
2. **Hook execution** is largely missing; Rust mostly loads hook config but does not run a TS-style PreToolUse/PostToolUse pipeline.
3. **Plugins** are effectively absent in Rust.
4. **Skills** are only partially implemented in Rust via direct `SKILL.md` loading; there is no comparable skills command/discovery/registration surface.
5. **CLI** breadth is much narrower in Rust.
6. **Assistant/tool orchestration** lacks the richer streaming concurrency, hook integration, and orchestration behavior present in TS.
7. **Services** in Rust cover API/auth/runtime basics, but many higher-level TS services are missing.

## Critical bug status on this branch

Targeted critical items requested by the user:
- **Prompt mode tools enabled**: fixed in `rust/crates/rusty-claude-cli/src/main.rs:75-82`
- **Default permission mode = danger-full-access**: fixed in `rust/crates/rusty-claude-cli/src/args.rs:12-16`, `rust/crates/rusty-claude-cli/src/main.rs:348-353`, and starter config `rust/crates/rusty-claude-cli/src/init.rs:4-9`
- **Tool input `{}` prefix bug**: fixed/guarded in streaming vs non-stream paths at `rust/crates/rusty-claude-cli/src/main.rs:2211-2256`
- **Unlimited max_iterations**: already present at `rust/crates/runtime/src/conversation.rs:143-148` with `usize::MAX` initialization at `rust/crates/runtime/src/conversation.rs:119`

Build/test/manual verification is tracked separately below and must pass before the branch is considered done.

---

## 1) tools/

### Upstream TS has
- Large per-tool module surface under `src/tools/`, including agent/task tools, AskUserQuestion, MCP tools, plan/worktree tools, REPL, schedule/task tools, synthetic output, brief/upload, and more.
- Evidence:
  - `src/tools/AgentTool/AgentTool.tsx`
  - `src/tools/AskUserQuestionTool/AskUserQuestionTool.tsx`
  - `src/tools/ListMcpResourcesTool/ListMcpResourcesTool.ts`
  - `src/tools/ReadMcpResourceTool/ReadMcpResourceTool.ts`
  - `src/tools/EnterPlanModeTool/EnterPlanModeTool.ts`
  - `src/tools/ExitPlanModeTool/ExitPlanModeV2Tool.ts`
  - `src/tools/EnterWorktreeTool/EnterWorktreeTool.ts`
  - `src/tools/ExitWorktreeTool/ExitWorktreeTool.ts`
  - `src/tools/RemoteTriggerTool/RemoteTriggerTool.ts`
  - `src/tools/ScheduleCronTool/*`
  - `src/tools/TaskCreateTool/*`, `TaskGetTool/*`, `TaskListTool/*`, `TaskOutputTool/*`

### Rust currently has
- A single MVP registry in `rust/crates/tools/src/lib.rs:53-371`.
- Implemented tools include `bash`, `read_file`, `write_file`, `edit_file`, `glob_search`, `grep_search`, `WebFetch`, `WebSearch`, `TodoWrite`, `Skill`, `Agent`, `ToolSearch`, `NotebookEdit`, `Sleep`, `SendUserMessage`, `Config`, `StructuredOutput`, `REPL`, `PowerShell`.

### Missing or broken in Rust
- **Missing large chunks of the upstream tool catalog**: I did not find Rust equivalents for AskUserQuestion, MCP resource listing/reading tools, plan/worktree entry/exit tools, task management tools, remote trigger, synthetic output, or schedule/cron tools.
- **Tool decomposition is much coarser**: TS isolates tool-specific validation/security/UI behavior per tool module; Rust centralizes almost everything in one file (`rust/crates/tools/src/lib.rs`).
- **Likely parity impact**: lower fidelity tool prompting, weaker per-tool behavior specialization, and fewer native tool choices exposed to the model.

---

## 2) hooks/

### Upstream TS has
- A full permission and tool-hook system with **PermissionRequest**, **PreToolUse**, **PostToolUse**, and failure/cancellation handling.
- Evidence:
  - `src/hooks/toolPermission/PermissionContext.ts:25,222`
  - `src/hooks/toolPermission/handlers/coordinatorHandler.ts:32-38`
  - `src/hooks/toolPermission/handlers/interactiveHandler.ts:412-429`
  - `src/services/tools/toolHooks.ts:39,435`
  - `src/services/tools/toolExecution.ts:800,1074,1483`
  - `src/commands/hooks/index.ts:5-8`

### Rust currently has
- Hook data is **loaded/merged from config** and visible in reports:
  - `rust/crates/runtime/src/config.rs:786-797,829-838`
  - `rust/crates/rusty-claude-cli/src/main.rs:1665-1669`
- The system prompt acknowledges user-configured hooks:
  - `rust/crates/runtime/src/prompt.rs:452-459`

### Missing or broken in Rust
- **No comparable hook execution pipeline found** in the Rust runtime conversation/tool execution path.
- `rust/crates/runtime/src/conversation.rs:151-208` goes straight from assistant tool_use -> permission check -> tool execute -> tool_result, without TS-style PreToolUse/PostToolUse processing.
- I did **not** find Rust counterparts to TS files like `toolHooks.ts` or `PermissionContext.ts` that execute hook callbacks and alter/block tool behavior.
- Result: Rust appears to support **hook configuration visibility**, but not full **hook behavior parity**.

---

## 3) plugins/

### Upstream TS has
- Built-in and bundled plugin registration plus CLI/service support for validate/list/install/uninstall/enable/disable/update flows.
- Evidence:
  - `src/plugins/builtinPlugins.ts:7-17,149-150`
  - `src/plugins/bundled/index.ts:7-22`
  - `src/cli/handlers/plugins.ts:51,101,157,668`
  - `src/services/plugins/pluginOperations.ts:16,54,306,435,713`
  - `src/services/plugins/pluginCliCommands.ts:7,36`

### Rust currently has
- I did **not** find a dedicated plugin crate/module/handler under `rust/crates/`.
- The Rust crate layout is only `api`, `commands`, `compat-harness`, `runtime`, `rusty-claude-cli`, and `tools`.

### Missing or broken in Rust
- **Plugin loading/install/update/validation is missing.**
- **No plugin CLI surface found** comparable to `claude plugin ...`.
- **No plugin runtime refresh/reconciliation layer found**.
- This is one of the largest parity gaps.

---

## 4) skills/

### Upstream TS has
- Bundled skills registry and loader integration, plus a `skills` command.
- Evidence:
  - `src/commands/skills/index.ts:6`
  - `src/skills/bundledSkills.ts:44,99,107,114`
  - `src/skills/loadSkillsDir.ts:65`
  - `src/skills/mcpSkillBuilders.ts:4-21,40`

### Rust currently has
- A `Skill` tool that loads local `SKILL.md` files directly:
  - `rust/crates/tools/src/lib.rs:1244-1255`
  - `rust/crates/tools/src/lib.rs:1288-1323`
- CLAUDE.md / instruction discovery exists in runtime prompt loading:
  - `rust/crates/runtime/src/prompt.rs:203-208`

### Missing or broken in Rust
- **No Rust `/skills` slash command** in `rust/crates/commands/src/lib.rs:41-166`.
- **No visible bundled-skill registry equivalent** to TS `bundledSkills.ts` / `loadSkillsDir.ts` / `mcpSkillBuilders.ts`.
- Current Rust skill support is closer to **direct file loading** than full upstream **skill discovery/registration/command integration**.

---

## 5) cli/

### Upstream TS has
- Broad CLI handler and transport surface.
- Evidence:
  - `src/cli/handlers/agents.ts:2-32`
  - `src/cli/handlers/auth.ts`
  - `src/cli/handlers/autoMode.ts:24,35,73`
  - `src/cli/handlers/plugins.ts:2-3,101,157,668`
  - `src/cli/remoteIO.ts:25-35,118-127`
  - `src/cli/transports/SSETransport.ts`
  - `src/cli/transports/WebSocketTransport.ts`
  - `src/cli/transports/HybridTransport.ts`
  - `src/cli/transports/SerialBatchEventUploader.ts`
  - `src/cli/transports/WorkerStateUploader.ts`

### Rust currently has
- Minimal top-level subcommands in `rust/crates/rusty-claude-cli/src/args.rs:29-39` and `rust/crates/rusty-claude-cli/src/main.rs:67-90,242-261`.
- Slash command surface is 15 commands total in `rust/crates/commands/src/lib.rs:41-166,389`.

### Missing or broken in Rust
- **Missing major CLI subcommand families**: agents, plugins, mcp management, auto-mode tooling, and many other TS commands.
- **Missing remote/transport stack parity**: I did not find Rust equivalents to TS remote structured IO / SSE / websocket / CCR transport layers.
- **Slash command breadth is much narrower** than TS command inventory under `src/commands/`.
- **Prompt-mode parity bug** was present and is now fixed for this branch’s prompt path.

---

## 6) assistant/

### Upstream TS has
- Rich tool orchestration and streaming execution behavior, including concurrency/cancellation/fallback logic.
- Evidence:
  - `src/services/tools/StreamingToolExecutor.ts:35-214`
  - `src/services/tools/toolExecution.ts:455-569,800-918,1483`
  - `src/services/tools/toolOrchestration.ts:134-167`
  - `src/assistant/sessionHistory.ts`

### Rust currently has
- A straightforward agentic loop in `rust/crates/runtime/src/conversation.rs:130-214`.
- Streaming API adaptation in `rust/crates/rusty-claude-cli/src/main.rs:1998-2058`.
- Tool-use block assembly and non-stream fallback handling in `rust/crates/rusty-claude-cli/src/main.rs:2211-2256`.

### Missing or broken in Rust
- **No TS-style streaming tool executor** with sibling cancellation / fallback discard semantics.
- **No integrated PreToolUse/PostToolUse hook participation** in assistant execution.
- **No comparable orchestration layer for richer tool event semantics** found.
- Historically broken parity items in prompt mode were:
  - prompt tool enablement (`main.rs:75-82`) — now fixed on this branch
  - streamed `{}` tool-input prefix behavior (`main.rs:2211-2256`) — now fixed/guarded on this branch

---

## 7) services/

### Upstream TS has
- Very broad service layer, including API, analytics, compact/session memory, prompt suggestions, plugin services, MCP service helpers, LSP management, policy limits, team memory sync, notifier/tips, etc.
- Evidence:
  - `src/services/api/client.ts`, `src/services/api/claude.ts`, `src/services/api/withRetry.ts`
  - `src/services/oauth/client.ts`, `src/services/oauth/index.ts`
  - `src/services/mcp/*`
  - `src/services/plugins/*`
  - `src/services/lsp/*`
  - `src/services/compact/*`
  - `src/services/SessionMemory/*`
  - `src/services/PromptSuggestion/*`
  - `src/services/analytics/*`
  - `src/services/teamMemorySync/*`

### Rust currently has
- Core service equivalents for:
  - API client + SSE: `rust/crates/api/src/client.rs`, `rust/crates/api/src/sse.rs`, `rust/crates/api/src/types.rs`
  - OAuth: `rust/crates/runtime/src/oauth.rs`
  - MCP config/bootstrap primitives: `rust/crates/runtime/src/mcp.rs`, `rust/crates/runtime/src/mcp_client.rs`, `rust/crates/runtime/src/mcp_stdio.rs`, `rust/crates/runtime/src/config.rs`
  - prompt/context loading: `rust/crates/runtime/src/prompt.rs`
  - session compaction/runtime usage: `rust/crates/runtime/src/compact.rs`, `rust/crates/runtime/src/usage.rs`

### Missing or broken in Rust
- **Missing many higher-level services**: analytics, plugin services, prompt suggestion, team memory sync, richer LSP service management, notifier/tips ecosystem, and much of the surrounding product/service scaffolding.
- Rust is closer to a **runtime/API core** than a full parity implementation of the TS service layer.

---

## Highest-priority parity gaps after the critical bug fixes

1. **Hook execution parity**
   - Config exists, execution does not appear to.
   - This affects permissions, tool interception, and continuation behavior.

2. **Plugin system parity**
   - Entire install/load/manage surface appears missing.

3. **CLI breadth parity**
   - Missing many upstream command families and remote transports.

4. **Tool surface parity**
   - MVP tool registry exists, but a large number of upstream tool types are absent.

5. **Assistant orchestration parity**
   - Core loop exists, but advanced streaming/execution behaviors from TS are missing.

## Recommended next work after current critical fixes

1. Finish build/test/manual verification of the critical bug patch.
2. Implement **hook execution** before broadening the tool surface further.
3. Decide whether **plugins** are in-scope for parity; if yes, this likely needs dedicated design work, not a small patch.
4. Expand the CLI/tool matrix deliberately rather than adding one-off commands without shared orchestration support.
