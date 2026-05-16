# Fork Feature Inventory – Changes Since `mod-for-local-models-backup`

**Purpose**  
This document provides a structured inventory of all *meaningful* Rust‑level changes introduced after the `mod-for-local-models-backup` branch. It is intended for later agents who must preserve these modifications while merging upstream updates. The inventory focuses exclusively on **Rust (`*.rs`) files** and excludes documentation, scripts, CI configs, or non‑code assets.

---

## Overview
The changes below represent a substantial evolution of the claw‑code Rust port, moving beyond simple local‑model fallback to a full‑featured, multi‑provider, resilient runtime with:

1. **Local‑model integration** (LM Studio, Ollama, Qwen)  
2. **Resilience & retry logic** with provider‑level opt‑in  
3. **API‑layer refactor** – removal of DashScope‑specific code  
4. **Tool & MCP lifecycle bridges** – richer runtime‑plugin state  
5. **Structural refactors** that affect future merges (e.g., `runtime` module split, `BuiltRuntime` wrapper)  

Each entry lists:
- **What changed** (concrete file/function)
- **Why it matters** (behavioural impact)
- **Where it lives** (file path)
- **Preservation risk** (tight coupling, external assumptions)

---

## Feature Inventory

### 1. Local Model Loading & Provider Dispatch
| Change | Why it matters | Files |
|--------|----------------|-------|
| **`AnthropicClient::new` now builds provider‑specific wrappers via `detect_provider_kind`** – routes to `APIProviderClient::Anthropic`, `APIProviderClient::OpenAI`, `APIProviderClient::Xai`, or `APIProviderClient::DashScope` (removed). | Enables single binary to talk to Anthropic, OpenAI‑compatible, xAI, Ollama, Qwen, etc., without code duplication. | `rust/crates/api/src/providers/anthropic.rs` (core client), `rust/crates/api/src/lib.rs` (enum dispatch), `rust/crates/api/src/provider_client.rs` (removed DashScope stub). |
| **`ProviderClient::from_model_with_anthropic_auth()` refactored to auto‑detect provider from model name and environment variables** (`OPENAI_*`, `XAI_*`, `DASHSCOPE_*`). | Removes hard‑coded Anthropic dependency; any OpenAI‑compatible endpoint can be used simply by setting the appropriate `BASE_URL` env var. | `rust/crates/api/src/provider_client.rs` |
| **Prompt‑cache and token‑estimation guards now work for non‑Anthropic providers** – local token estimation (`model_token_limit`) applied before network request. | Guarantees consistent context‑window enforcement across providers; prevents oversized requests to any provider. | `rust/crates/api/src/providers/anthropic.rs` (function `preflight_message_request`) |
| **`build_runtime` now constructs a `BuiltRuntime` wrapper that holds `ConversationRuntime<AnthropicRuntimeClient, CliToolExecutor>` with hooks for abort signals and progress reporters.** | Provides a single entry point for future resilience / progress hooks; ensures clean shutdown of plugins, MCP, and progress UI. | `rust/crates/runtime/src/lib.rs` (`BuiltRuntime` struct), `rust/crates/runtime/src/hooks.rs` (hook‑abort infrastructure). |

### 2. Resilience & Retry Layer
| Change | Why it matters | Files |
|--------|----------------|-------|
| **`ResilienceConfig` enum & builder** – `force_enable()`, `force_disable()`, selective per‑provider enables (`enable_for_anthropic`, `enable_for_openai_compat`). | Gives operators deterministic control over where automatic retries happen; earlier only “auto‑detect localhost” existed. | `rust/crates/api/src/resilience_config.rs` |
| **`AnthropicClient::with_resilience_config`** now propagates config through every request. | Guarantees retry behaviour is applied uniformly, even for streaming calls. | `rust/crates/api/src/providers/anthropic.rs` |
| **Retry loop** uses exponential back‑off with jitter (`backoff_for_attempt`, `jittered_backoff_for_attempt`). | Prevents thundering‑herd and respects rate limits; back‑off caps at `max_backoff`. | Same file as above (`backoff_for_attempt`, `jittered_backoff_for_attempt`). |
| **`ProviderFuture` now returns `Result<MessageResponse, ApiError>` with retry‑aware wrapper**. | Makes error handling uniform across sync/async calls; callers need not repeat retry logic. | `rust/crates/api/src/provider_client.rs` (`ProviderFuture` alias). |

### 3. API‑Layer Clean‑up – Removal of DashScope Logic
| Change | Why it matters | Files |
|--------|----------------|-------|
| **All DashScope‑specific code (`model_token_limit`, `resolve_model_alias`, related constants) deleted** – replaced by generic `model_token_limit` that consults provider‑specific limits via `detect_provider_kind`. | Eliminates dead code path that only served an upstream provider that is no longer supported; reduces binary size and maintenance burden. | `rust/crates/api/src/providers/dashscope.rs` (removed), `rust/crates/api/src/providers/anthropic.rs` (no longer references DashScope). |
| **`DEFAULT_BASE_URL` now derived from `ANTHROPIC_BASE_URL` env var** – fallback removed. | Simplifies configuration; users now explicitly set the endpoint they want. | `rust/crates/api/src/providers/anthropic.rs` (`read_base_url`). |

### 4. MCP & Plugin System Enhancements
| Change | Why it matters | Files |
|--------|----------------|-------|
| **`RuntimeMcpState` now stores `pending_servers`, `degraded_report`, and provides `call_tool`, `list_resources_for_server`, `read_resource` wrappers.** | Enables fine‑grained introspection and error handling for each MCP server without crashing the whole runtime. | `rust/crates/runtime/src/mcp_tool_bridge.rs` |
| **`CliToolExecutor` merged with `CliToolExecutor` struct** – adds `execute_runtime_tool` and `execute_search_tool`. | Allows unified execution of both builtin runtime tools and MCP‑wrapped tools through the same executor interface. | `rust/crates/runtime/src/lib.rs` (tool executor struct), `rust/crates/runtime/src/hooks.rs` (tool registration). |
| **Plugin registration now uses `GlobalToolRegistry::with_runtime_tools`** – central registry of runtime‑aware tools. | Guarantees plugins are discovered before any tool execution; preserves state across sessions. | `rust/crates/runtime/src/plugin_manager.rs` (not directly listed but used by `build_runtime_plugin_state`). |
| **`HookAbortMonitor` introduced** – spawns a thread that listens for cancellation signals and aborts the runtime gracefully. | Prevents orphaned async tasks when the user aborts a turn; improves stability during interactive use. | `rust/crates/runtime/src/hooks.rs` |

### 5. Structural Rust Refactors Impacting Future Merges
| Change | Why it matters | Files |
|--------|----------------|-------|
| **Split `runtime` crate into sub‑modules (`runtime::conversation`, `runtime::tool_executor`, `runtime::plugin_state`)** – reduces compile time and eases isolated testing. | Future changes can target a smaller subset of files; reduces risk of accidental breakage in unrelated features. | `rust/crates/runtime/src/conversation.rs`, `rust/crates/runtime/src/compact.rs`, `rust/crates/runtime/src/hooks.rs`. |
| **Introduced `BuiltRuntime` wrapper** – isolates runtime lifecycle (`ConversationRuntime`, plugin state, MCP state) from `LiveCli`. | Prevents `LiveCli` from becoming a god‑object; makes it trivial to swap out runtime back‑ends (e.g., future non‑Anthropic provider). | `rust/crates/rusty-claude-cli/src/main.rs` (`LiveCli::new` → `run_repl`), `rust/crates/runtime/src/lib.rs` (`BuiltRuntime`). |
| **`CliAction` enum expanded** – now handles new subcommands (`export`, `session fork`, `compact`, `doctor`, `stats`) without routing through the REPL. | Makes CLI self‑contained; future extensions can be added without touching the prompt‑loop dispatch. | `rust/crates/rusty-claude-cli/src/main.rs` (`parse_args`). |
| **Removed `CliApp` prototype remnants** – all references deleted, replacing them with the new `LiveCli` flow. | Eliminates legacy code that caused confusing error paths; cleans up dead code that would otherwise cause merge conflicts. | Various deleted files (`rust/crates/rusty-claude-cli/src/app.rs`, `src/args.rs`). |
| **`unwrap()` safety hardened** – many places now guard with explicit error messages and fallback handling (see `format_user_visible_api_error`). | Improves observability for downstream automation; prevents obscure panics that previously broke CI. | `rust/crates/api/src/error.rs` (`format_user_visible_api_error`). |

---

## Rust File Map (Key Entry Points)

| File | Primary Responsibility |
|------|------------------------|
| `rust/crates/api/src/providers/anthropic.rs` | Core Anthropic client; now generic provider wrapper; resilience hooks; prompt‑cache integration. |
| `rust/crates/api/src/lib.rs` | Provider‑client enum and factory (`ProviderClient::from_model_with_anthropic_auth`). |
| `rust/crates/api/src/resilience_config.rs` | `ResilienceConfig` definition, builder, and default auto‑detect logic. |
| `rust/crates/runtime/src/lib.rs` | `BuiltRuntime` struct, plugin/MCP state wiring, `CliToolExecutor` implementation. |
| `rust/crates/runtime/src/conversation.rs` | Turn‑level conversation loop (`run_turn`, `run_turn_with_output`). |
| `rust/crates/runtime/src/hooks.rs` | Abort monitoring, progress reporter, hook registration for plugins/MCP. |
| `rust/crates/runtime/src/compact.rs` | Session compaction, auto‑retry, and resilience integration. |
| `rust/crates/commands/src/lib.rs` | Slash‑command parser and dispatch; now includes `export`, `session fork`, `doctor`, `stats`, etc. |
| `rust/crates/rusty-claude-cli/src/main.rs` | Entry point; `parse_args` now handles new flags (`--resilience`, `--compact`, `--allowedTools`, etc.). |
| `rust/crates/tools/src/lib.rs` (via `tools::mvp_tool_specs`) | Tool specifications, including new MCP‑compatible wrappers. |
| `rust/crates/runtime/src/mcp_tool_bridge.rs` | MCP server lifecycle, tool dispatch bridge, resource reading. |
| `rust/crates/api/tests/*` (not part of production but listed for completeness) | Test coverage for resilience modes and API error handling. |

---

## Preservation Risks

| Area | Risk | Mitigation for Future Integration |
|------|------|-----------------------------------|
| **ResilienceConfig coupling** | The `ResilienceConfig` is now baked into `AnthropicClient` and propagated through every request. | Preserve the builder pattern; avoid removing builder methods; guard against future removal by marking the field as `#[deprecated]` if needed. |
| **MCP state & pending server list** | `RuntimeMcpState` holds mutable collections (`pending_servers`, `degraded_report`) that are not versioned. | When introducing new MCP servers, extend `McpFailedServer` and `McpDegradedReport` schemas rather than renaming fields. |
| **BuiltRuntime wrapper** | Future providers may need additional dependencies (e.g., new auth scheme). | Keep `BuiltRuntime` constructor signature stable; add optional generic parameters with defaults. |
| **Tool registry expansion** | Adding new builtin tools changes `GlobalToolRegistry` registration order. | When adding a tool, append to the registration list rather than inserting at arbitrary positions; document the order in this inventory. |
| **Removal of DashScope code** | Any external dependency on `DashScope` was eliminated. | Ensure no remnants remain in CI scripts or build files; keep a comment marker (`// Removed DashScope support – see fork_feature_inventory...`) for auditability. |
| **Plugin and MCP lifecycle hooks** | New abort and progress hooks are now part of the runtime. | Future hooks must be registered via `runtime::HookAbortSignal`; do not call blocking code directly from plugin callbacks. |

---

## Notes for Later Agents

1. **Preserve the `ResilienceConfig` API** – it is the public contract that governs retry behavior. Adding new modes (e.g., per‑provider timeout overrides) should extend `ResilienceConfig` rather than altering its semantics.  
2. **When adding a new provider**, register it in `detect_provider_kind` and provide a corresponding `ProviderKind` enum variant. The generic `ProviderClient` factory will automatically dispatch the correct client.  
3. **MCP server discovery** now relies on `RuntimeMcpState::discover_tools_best_effort`. New servers must emit the same JSON‑RPC signals (`initialize`, `shutdown`) to be reflected in `degraded_report`.  
4. **Tool execution** now goes through `CliToolExecutor`. If you introduce a new tool, implement `CliToolExecutor::execute_runtime_tool` (or `execute_search_tool` for ad‑hoc searches) rather than adding a free‑standing function in the `tools` crate.  
5. **BuiltRuntime shutdown order matters** – plugins must be shut down **before** MCP state, otherwise pending RPC calls may reference dangling data.  
6. **Version bump policy** – any breaking change to `ResilienceConfig`, `RuntimeMcpState`, or `BuiltRuntime` should be accompanied by a new major version bump in `Cargo.toml` to signal the incompatibility to downstream agents.  

---

### Closing Reminder
All items listed above are **already merged into the current working tree** (as of the latest commit visible to this agent). When you later merge upstream changes, treat this inventory as the *source of truth* for what *must* be preserved. If a new upstream commit removes or renames a symbol that appears here, update the upstream code to restore the symbol *or* adjust the invariant (e.g., replace the use with the new API) **before** allowing the merge to proceed.Whenever making additions from upstream, if upstream code conflicts with these features, write a conflicts.md file analyzing what conflicts and how this is implemented differently on each branch, evaluating the better implementation without taking the upstram code.

---  

*End of Document*  
