# Plan to Maintain Resilience Feature Fork with Upstream Additions

## Objective

Selectively adopt useful upstream Rust changes from `upstream/main` (ultraworkers/claw-code) into the current `beta` branch without breaking the fork's preserved local-model, launcher, retry, or API behavior. This is a planning-only analysis — no code changes, merges, or rebases.

The fork's preservation contract is defined in two authoritative documents:
- `fork_feature_inventory_since_mod_for_local_models_backup.md`
- `plan_to_integrate_claw_code_local_patterns_into_main_claw.md`

---

## Preserved Behavior

The following features are the fork's non-negotiable differentiators and must survive any upstream adoption:

| Preserved Feature | Must Remain | Relevant Files |
|---|---|---|
| Local-model provider dispatch via `detect_provider_kind` | Routes model names to Anthropic/XAI/OpenAI clients without hardcoded Anthropic dependency | `api/src/providers/mod.rs`, `api/src/client.rs` |
| Resilience & retry with per-error-type budgets | `ResilienceConfig` in `runtime/src/conversation.rs` with `force_enable/force_disable/from_env` | `runtime/src/conversation.rs`, `api/src/resilience_config.rs` (re-export shim) |
| `CLAW_RESILIENCE` env var support | `force`, `none`, `auto` modes | `runtime/src/conversation.rs` |
| `--resilience` CLI flag | Interprets `force/none/auto` and sets `CLAW_RESILIENCE` | `rusty-claude-cli/src/main.rs` |
| `/resilience` slash command | Interactive resilience mode toggle | `commands/src/lib.rs` |
| Stream-error handling | `LocalModelUnloaded`, `EmptyAssistantStream`, `FirstTokenTimeout`, `ToolSequenceError` error variants | `api/src/error.rs` |
| `local_model_recovery.rs` module | ErrorClassifier, ModelHealthProfile, RecoveryStateMachine, HealthProfileCache | `api/src/local_model_recovery.rs` |
| `setup.rs` launcher module | `claw setup lmstudio` and `claw setup openrouter` commands | `rusty-claude-cli/src/setup.rs` |
| Compaction enhancements | `CompactionStrategy` enum, system prompt overhead in `should_compact`, timeline capping in `summarize_messages` | `runtime/src/compact.rs` |
| Stream debugging hooks | `HookStreamDebugger` trait, `StreamDebugContext`, `StreamDebugExecutor` | `runtime/src/hooks.rs` |
| Preemptive compaction | Compact before API call if token threshold exceeded | `runtime/src/conversation.rs` |
| No DashScope-specific code paths | No `DASHSCOPE_API_KEY`, `dashscope.aliyuncs.com`, `DashScope` config constants | `api/src/providers/mod.rs`, `api/src/client.rs` |
| `ResilienceConfig` re-export | API crate re-exports from runtime via shim | `api/src/resilience_config.rs` |

---

## Upstream Differences

### 1. API Layer — `api/src/providers/openai_compat.rs`

**What upstream changed:**
- Split `send_message()` into `send_message_without_recovery()` and `send_message_with_recovery()`.
- Integrated `RecoveryStateMachine` and `ErrorClassifier` from `local_model_recovery.rs` into the recovery path.
- Removed `check_request_body_size_for_base_url`, `estimate_request_body_size`, `build_chat_completion_request_for_base_url` — consolidated into simpler `check_request_body_size`, `build_chat_completion_request`.
- Removed `with_http_client()` builder.
- Removed `thinking_started`/`thinking_finished` state and all `reasoning_content` handling from `StreamState`.
- Removed `OpenAiPromptTokensDetails` and `cached_tokens` tracking from `OpenAiUsage`.
- Removed `ReasoningContent` from `ChatMessage` struct.
- Added `Clone` derive (manual `Debug` impl).

**What the fork does:**
- Has the same `send_message()` split and `RecoveryStateMachine` integration (already implemented independently).
- Keeps `check_request_body_size_for_base_url` and `build_chat_completion_request_for_base_url` for per-base-url variant handling.
- Keeps `with_http_client()` builder.
- Has already removed thinking/reasoning content handling (same as upstream on this point).
- Still has `extra_body` on `MessageRequest` in `types.rs`.

**Verdict: Upstream is more complete on the recovery integration but both branches converged on similar architecture. Fork's extra per-base-url functions add value for local model compatibility. Adopt the upstream recovery loop pattern while keeping per-base-url request building.**

### 2. API Layer — `api/src/providers/mod.rs`

**What upstream changed:**
- Removed `ProviderWireProtocol`, `ProviderFeatureSupport`, `ProviderCapabilityReport`, `ProviderDiagnostics`, `ProviderDiagnosticSeverity`, `ProviderDiagnostic` types.
- Removed `provider_diagnostics_for_model()`.
- Removed `model_family_identity_for()`, `model_family_identity_for_kind()`.
- Removed `provider_capabilities_for_model()`.
- Removed `provider_diagnostics_for_request()`.
- Simplified `max_tokens_for_model()` — removed GPT-4.1 and GPT-5.4 model limits, simplified heuristic.
- Simplified `model_token_limit()` — removed `base_model` split, uses `canonical` directly.
- Removed `kimi-k2.5` and `kimi-k1.5` token limits.
- Removed `#[derive(Serialize)]` from `ProviderKind`.

**What the fork does:**
- Already removed most of these types and functions (fork agrees with upstream's removal).
- Both branches independently converged: neither has provider diagnostics capability report.
- Fork still preserves `kimi` model token limits (canonical only, via DashScope wire format).
- Fork's `max_tokens_for_model` uses `model_token_limit` -> `heuristic.min(limit.max_output_tokens)`, upstream's is simpler optional chaining.

**Verdict: Upstream and fork are already largely aligned. Both removed provider diagnostics. The GPT model limits and kimi limits are cosmetic differences. Adopt upstream's simplified `model_token_limit` (removing `base_model` split) since the fork already doesn't use that pattern. Keep the fork's `max_tokens_for_model` heuristic fallback (it's more robust).**

### 3. API Layer — `api/src/client.rs`

**What upstream changed:**
- Added `ResilienceConfig::from_env()` usage.
- Added `with_resilience_config()` calls for all three provider branches.
- Conditional DashScope routing: `meta.auth_env == "DASHSCOPE_API_KEY"` only activates when `OPENAI_BASE_URL` is not set.
- Wired `resilience_config` through all provider clients.

**What the fork does:**
- Has the same `ResilienceConfig::from_env()` and `with_resilience_config()` pattern.
- Fork's DashScope handling is different: `meta.auth_env == "DASHSCOPE_API_KEY"` is always matched unconditionally with `OpenAiCompatConfig::dashscope()` in the provider client.

**Verdict: The fork's version is more permissive (no env guard on DashScope routing). Upstream's conditional `if OPENAI_BASE_URL not set` is more correct for the fork's local-model use case — users setting `OPENAI_BASE_URL` should override DashScope defaults. Adopt upstream's conditional DashScope routing.**

### 4. API Layer — `api/src/error.rs`

**What upstream changed:**
- Removed several `CONTEXT_WINDOW_ERROR_MARKERS` entries ("input tokens exceed", "configured limit", "messages resulted in", "completion tokens", "prompt tokens").
- Added `LocalModelUnloaded`, `EmptyAssistantStream`, `FirstTokenTimeout`, `ToolSequenceError`, `StreamDebugInfo` variants.
- Removed a test `classifies_openai_configured_limit_errors_as_context_window_failures`.

**What the fork does:**
- Fork independently added the same error variants. The error.rs diff shows these match perfectly.
- Fork independently removed the same context window markers (both branches removed the same 5 markers).
- Both agree: the OpenAI-specific wording markers were too narrow.

**Verdict: Already in sync. No action needed.**

### 5. ResilienceConfig Location — Architecture Conflict

**What upstream has:**
- `api/src/resilience_config.rs` defines `ResilienceConfig` as its own struct (7 fields, basic builder pattern).
- No per-error-type retry counts or backoffs.
- No `force_enable()`, `force_disable()`, `from_env()` methods.
- `should_enable_for_url()` and `should_enable_for_provider()` methods.

**What the fork has:**
- `runtime/src/conversation.rs` defines `ResilienceConfig` as the canonical definition (30+ fields, per-error-type retry budgets, `CompactionStrategy` integration).
- `api/src/resilience_config.rs` is a 3-line re-export shim: `pub use runtime::ResilienceConfig;`
- Has `force_enable()`, `force_disable()`, `from_env()`, `backoff_for_attempt()`, `max_retries_for()`, `initial_backoff_for()`.

**Verdict: The fork's `ResilienceConfig` is substantially more capable. Upstream's version is a minimal struct. Do not replace the fork's version. The re-export shim should remain. However, ensure the fork's `should_enable_for_provider` does not reference "dashscope" — this was removed in the fork (check `enable_for_openai_compat` matching).**

### 6. API Layer — `api/src/sse.rs`

**No diff.** Both branches are identical on this file.

### 7. API Layer — `api/src/types.rs`

**What upstream changed:**
- Removed `extra_body: BTreeMap<String, Value>` from `MessageRequest`.
- Removed `InputContentBlock::Thinking` variant.
- Removed `use std::collections::BTreeMap`.

**What the fork does:**
- Fork also removed `InputContentBlock::Thinking` (agreement).
- Fork still has `extra_body` field on `MessageRequest`.

**Verdict: The `extra_body` field is used by local-model providers to pass provider-specific parameters. Upstream may have removed it because it's not part of the Anthropic message format. The fork should keep `extra_body` for local model Qwen/kimi compatibility. Reject upstream's removal of `extra_body`.**

### 8. Runtime Layer — `runtime/src/compact.rs`

**What upstream changed:**
- Added `CompactionStrategy` enum (Standard, Aggressive, Conservative, Emergency) with per-strategy `CompactionConfig`.
- System prompt overhead accounting in `should_compact()`.
- Timeline capping in `summarize_messages()` (last 10 messages).
- Bug fix for unbounded timeline growth.

**What the fork does:**
- Fork matches perfectly — this is fork-specific enhancement.

**Verdict: Already in sync. No upstream equivalent to conflict with. Keep fork's implementation.**

### 9. Runtime Layer — `runtime/src/hooks.rs`

**What upstream changed:**
- Added `HookStreamDebugger` trait with `on_stream_start`, `on_stream_chunk`, `on_stream_end`, `on_stream_error`.
- Added `StreamDebugContext`, `StreamResult`, `StreamDebugCapture`, `StreamDebugEventType`.
- Added `StreamDebugExecutor` default implementation.

**What the fork does:**
- Fork matches perfectly — this is fork-specific enhancement.

**Verdict: Already in sync. No upstream equivalent to conflict with.**

### 10. Runtime Layer — `runtime/src/conversation.rs`

**What upstream changed:**
- Added `ResilienceConfig` struct (full definition, ~200 lines).
- Added `ErrorClass` enum with `classify()` method.
- Added `preemptive_compact_if_needed()` method.
- Added `stream_with_resilience()` method.
- Added `consecutive_stream_failures` tracking.
- Added `resilience_config` field to `ConversationRuntime`.
- Added `with_resilience_config()` builder.
- Changed `AssistantEvent::Thinking` to remove Thinking variant (match with types.rs changes).
- Added `Self::Resilience { .. }` match arms in existing pattern matches.

**What the fork does:**
- Fork matches perfectly — these are fork-specific enhancements built independently.

**Verdict: Already in sync. Keep fork's implementation.**

### 11. Runtime Layer — `runtime/src/session.rs`

**What upstream changed:**
- Removed `ContentBlock::Thinking` variant.
- Removed `SessionLiveness`, `SessionHeartbeat` types.
- Removed `record_health_check()`, `heartbeat_at()` methods.
- Removed `MAX_JSONL_FIELD_CHARS`, `JSONL_TRUNCATION_MARKER`, `JSONL_REDACTION_MARKER` constants.
- Removed `serde::Serialize`/`serde::Deserialize` import.

**What the fork does:**
- Fork already made the same removals. These are in sync.

**Verdict: Already in sync.**

### 12. Runtime Layer — `runtime/src/lib.rs` (re-exports)

**What upstream changed:**
- Removed re-exports for: `approval_tokens`, `g004_conformance`, `report_schema`.
- Removed `LaneBoard`, `LaneBoardEntry`, `LaneFreshness`, `LaneHeartbeat` from task_registry.
- Removed error-related exports from `policy_engine`.
- Removed `ModelFamilyIdentity` from prompt.
- Removed various recovery/module exports.
- Removed `SessionHeartbeat`, `SessionLiveness` from session.
- Removed `in_workspace` variants from file_ops exports.
- Added `HookStreamDebugger`, `StreamDebugCapture`, etc. to hooks exports.
- Added `ErrorClass`, `ResilienceConfig` to conversation exports.
- Added `StreamDebugExecutor` to hooks exports.

**What the fork does:**
- Fork made the same removals. Both branches independently converged.

**Verdict: Already in sync.**

### 13. Runtime Layer — `runtime/src/file_ops.rs`

**What upstream changed:**
- Simplified `glob_search_impl` — removed workspace boundary validation in the glob code path.
- Removed `GLOB_SEARCH_IGNORED_DIRS` constant.
- Changed from `glob::glob` + WalkDir to pure `glob::glob`.
- Removed `derive_glob_walk_root`, `should_skip_glob_dir` helpers.
- Removed `validate_workspace_boundary` calls from glob code path.
- Removed `HashSet` import (moved inline).

**What the fork does:**
- Fork matches upstream exactly — these changes are already applied.

**Verdict: Already in sync.**

### 14. CLI Layer — `rusty-claude-cli/src/main.rs`

**What upstream changed:**
- Added `--resilience` CLI flag parsing.
- Added `setup` module declaration and dispatch.
- Removed `model` field from `PrintSystemPrompt` action.
- Removed `output_format` from `HelpTopic` action (now just `HelpTopic(LocalHelpTopic)`).
- Removed `plugin_command_json`, `plugin_summary_json`, `plugin_load_failure_json` functions.
- Removed `"exit_code": 1` from JSON error output.
- Removed `"unsupported_acp_invocation"` error classification.
- Inline `max_tokens_for_model()` implementation instead of calling `api::max_tokens_for_model`.
- Removed `commands::PluginsCommandResult` import.
- Changed `permissions` error from `.to_string()` to `format!()`.
- Added `Self::Resilience { .. }` dispatch.
- Added `Self::ClawSetup { .. }` dispatch.

**What the fork does:**
- Fork matches upstream exactly on all of these — they are fork-specific changes.

**Verdict: Already in sync — these changes were independently implemented in the fork and match upstream's direction.**

### 15. CLI Layer — `commands/src/lib.rs`

**What upstream changed:**
- Added `/resilience` slash command spec, enum variant, parser.
- Removed `/session exists` subcommand.
- Changed `/session` `resume_supported` from `true` to `false`.
- Removed `required` field from MCP server report and JSON.
- Removed `PluginLifecycle` from plugin summary display and tests.
- Changed `split_once(' ')` to `splitn(2, ' ').nth(1)` for skills command parsing (MSRV compatibility).
- Removed `allow(clippy::unnecessary_wraps)` from several functions.
- Removed skill `-h`/`--help` detection in `classify_skills_slash_command`.

**What the fork does:**
- Fork matches upstream exactly — these changes are independently implemented.

**Verdict: Already in sync. Keep fork's implementation.**

### 16. Modules Present Only in Fork

These files exist in the fork but not in upstream:

| File | Description |
|------|-------------|
| `api/src/local_model_recovery.rs` | ErrorClassifier, ModelHealthProfile, RecoveryStateMachine, HealthProfileCache |
| `rusty-claude-cli/src/setup.rs` | LM Studio and OpenRouter launcher |
| `api/tests/local_model_recovery_integration.rs` | Tests for recovery module |
| `api/tests/resilience_mode_tests.rs` | Tests for resilience modes |
| `api/tests/resilience_tests.rs` | Additional resilience tests |

These are purely additive fork features. No upstream changes to adopt.

### 17. Modules Deleted from Fork

These files exist in upstream but were deleted from the fork:

| File | Impact |
|------|--------|
| `runtime/src/approval_tokens.rs` | Approval token ledger — removed. Fork deemed this unnecessary for local model workflow. |
| `runtime/src/g004_conformance.rs` + tests | G004 conformance verification — removed. |
| `runtime/src/report_schema.rs` | Report schema types — removed. |
| `cli/tests/compact_repl_panic.rs` | Test for compaction panic — removed. |
| `tools/tests/path_scope_enforcement.rs` | Path scope enforcement tests — removed. |

These removals are intentional. Do not re-add them.

---

## Compatibility Analysis

### Conflicting Changes

1. **DashScope routing in `client.rs`**: Upstream adds `&& std::env::var_os("OPENAI_BASE_URL").is_none()` guard. Fork matches ALL DashScope metadata unconditionally. The fork's version could route local requests through DashScope config incorrectly when user sets `OPENAI_BASE_URL`. **Adopt upstream's guard.**

2. **`extra_body` on `MessageRequest`**: Upstream removes it. Fork keeps it for local-model provider parameters. **Reject upstream's removal. Keep `extra_body`.**

3. **`ResilienceConfig` location and scope**: Upstream defines in `api` crate, fork defines in `runtime` crate. **Don't change. The re-export shim works fine.**

4. **`check_request_body_size_for_base_url` and friends**: Upstream removes per-base-url variants. Fork keeps them for LM Studio/kimi compatibility. **Reject upstream's consolidation. Keep per-base-url variants.**

### Compatible Changes (Adopt)

1. **DashScope conditional routing guard** (client.rs)
2. **Removal of thinking/reasoning content** (already done in both)
3. **Simplified `model_token_limit`** — removing `base_model` split
4. **Removal of provider diagnostics types** (already done in both)
5. **Simplified glob_search** (already done in both)
6. **Session-related removals** (already done in both)
7. **`PluginLifecycle` removal from summaries** (already done in both)
8. **`required` MCP field removal** (already done in both)
9. **Error classification context window markers** (already consistent)
10. **`split_once` → `splitn` for MSRV** (already applied)
11. **Removed `#[ignore]` tests** — verify fork also removed these (check test files)

### Incompatible Changes (Reject)

1. **Removal of `extra_body`** — needed for local model provider parameters
2. **Removal of per-base-url request building** — needed for LM Studio / local model compatibility
3. **Upstream's minimal `ResilienceConfig`** — fork's is more capable
4. **Re-introduction of `approval_tokens` or `report_schema`** — removed intentionally
5. **Re-introduction of G004 conformance** — removed intentionally

---

## Adopt / Adapt / Reject Decisions

| Change | Decision | Rationale |
|--------|----------|-----------|
| DashScope conditional guard in client.rs | **Adopt** | Prevents routing conflicts when `OPENAI_BASE_URL` is set |
| `extra_body` removal | **Reject** | Needed for local model provider params |
| Per-base-url request building removal | **Reject** | Needed for LM Studio/kimi compat |
| `ResilienceConfig` upstream version | **Reject** | Fork's version is much more capable |
| Provider diagnostics types removal | **Already in sync** | No action needed |
| `model_token_limit` simplification | **Adopt** | Remove `base_model` split |
| `max_tokens_for_model` simplification | **Adapt** | Keep fork's heuristic fallback, remove GPT-4.1/5.4 entries if desired |
| Glob_search simplification | **Already in sync** | No action needed |
| Session thinking/liveness removal | **Already in sync** | No action needed |
| Error variants addition | **Already in sync** | No action needed |
| `/resilience` slash command | **Already in sync** | No action needed |
| `--resilience` CLI flag | **Already in sync** | No action needed |
| CompactionStrategy | **Already in sync** | No action needed |
| Stream debug hooks | **Already in sync** | No action needed |
| PluginLifecycle removal | **Already in sync** | No action needed |
| MCP `required` field removal | **Already in sync** | No action needed |

---

## Exact Implementation Plan

### Step 1: DashScope conditional guard in `client.rs`

**File to modify:** `rust/crates/api/src/client.rs`

**Current fork code:**
```rust
Some(meta) if meta.auth_env == "DASHSCOPE_API_KEY" =>
    OpenAiCompatConfig::dashscope()
```

**Change:** Add the `OPENAI_BASE_URL` guard from upstream:
```rust
Some(meta)
    if meta.auth_env == "DASHSCOPE_API_KEY"
        && std::env::var_os("OPENAI_BASE_URL").is_none() =>
{
    OpenAiCompatConfig::dashscope()
}
```

**Preservation check:** This does not remove DashScope support entirely — it only prevents DashScope routing when the user has explicitly set `OPENAI_BASE_URL`, which is the common case for LM Studio, Ollama, and other local providers. When `OPENAI_BASE_URL` is unset and `DASHSCOPE_API_KEY` is set, DashScope still works.

**Interaction with setup.rs:** In `setup_lmstudio()`, `OPENAI_BASE_URL` is set explicitly. With this guard, LM Studio requests will never be routed through DashScope config — they go through the standard OpenAI-compat path. This is correct behavior.

### Step 2: Simplify `model_token_limit` — remove `base_model` split

**File to modify:** `rust/crates/api/src/providers/mod.rs`

**Current fork code:**
```rust
pub fn model_token_limit(model: &str) -> Option<ModelTokenLimit> {
    let canonical = resolve_model_alias(model);
    let base_model = canonical.rsplit('/').next().unwrap_or(canonical.as_str());
    match base_model {
```

**Change:** Replace with upstream's simplified version:
```rust
pub fn model_token_limit(model: &str) -> Option<ModelTokenLimit> {
    let canonical = resolve_model_alias(model);
    match canonical.as_str() {
```

Then remove the trailing closing bracket and ensure match arms match `canonical` directly.

**Preservation check:** The fork already references models by canonical name (e.g., `"claude-opus-4-6"`), not by path. There are no model entries that use a path prefix, so removing the `rsplit` split is safe.

**Potential regression:** If the fork has any model entries keyed by path (e.g., `"anthropic/claude-opus-4-6"`), they would stop matching. Check the MODEL_REGISTRY array. If any entries use paths, keep the `base_model` split.

### Step 3: Remove GPT-4.1 and GPT-5.4 model token limits (cosmetic)

**File to modify:** `rust/crates/api/src/providers/mod.rs`

**Current fork code:** Has GPT-4.1 family entries.

**Change:** Remove the GPT-4.1 and GPT-5.4 blocks from `model_token_limit` if they are not used (the fork focuses on local models, not the latest OpenAI models). This is optional — keeping them is harmless.

**Preservation check:** Removing upstream model limits cannot break local-model behavior. They only affect token estimation for those specific models. If no user in the fork uses GPT-4.1 or GPT-5.4, this is safe to remove. If there is concern, keep them — they don't conflict with local models.

### Step 4: Add missing upstream MSRV compatibility change

**File to modify:** `rust/crates/commands/src/lib.rs`

The upstream changed `split_once(' ').map(|(_, name)| name)` to `splitn(2, ' ').nth(1)` in `handle_skills_slash_command` and `handle_skills_slash_command_json`. The fork already has this change applied — verify by checking the diff.

**Preservation check:** Already in sync. No action needed unless the diff shows the fork still uses `split_once`.

### Step 5: Verify and preserve `extra_body` on `MessageRequest`

**File to verify:** `rust/crates/api/src/types.rs`

Ensure `extra_body` field is still present in:
```rust
pub struct MessageRequest {
    // ...
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub extra_body: BTreeMap<String, Value>,
}
```

**Preservation check:** This is required for local model providers that need custom parameters (e.g., `repetition_penalty`, `top_k`, `min_p`). Do not remove this field. If a future upstream merge removes it, restore it explicitly.

### Step 6: Reject upstream per-base-url functions consolidation

**File to verify:** `rust/crates/api/src/providers/openai_compat.rs`

The upstream consolidates `check_request_body_size_for_base_url` into `check_request_body_size` and `build_chat_completion_request_for_base_url` into `build_chat_completion_request`. The fork's per-base-url variants allow different request serialization for different local providers. Keep the fork's versions.

**Preservation check:** If the diff shows the fork still uses these functions, ensure they remain. The `check_request_body_size_for_base_url` function is what allows LM Studio to use different body formats than OpenAI.

### Step 7: Confirm /resilience parsing and dispatch are wired

**Files to verify:**
- `rust/crates/commands/src/lib.rs` — confirm `/resilience [force|none|auto]` parser
- `rust/crates/rusty-claude-cli/src/main.rs` — confirm `CliAction::Resilience` dispatch or inline handling in slash command processing

**Preservation check:** If there is a `CliAction::Resilience` variant, ensure it dispatches properly. If resilience is handled inline in the slash command handler, confirm that path works.

---

## Conflict Summary

### Critical Conflicts (must resolve before merge)

1. **ResilienceConfig canonical definition**: The fork defines it in `runtime::conversation`, upstream defines it in `api::resilience_config`. The re-export shim works but is fragile. A future upstream change that adds imports from `api::resilience_config` directly could break.

2. **client.rs DashScope routing**: The fork's unconditional DashScope match conflicts with local model workflows. Upstream's conditional guard avoids the conflict. Adopt upstream's version.

### Moderate Conflicts (design divergence)

3. **`extra_body` in MessageRequest**: Upstream removed it. Fork keeps it. This is a design decision — if the fork needs to support provider-specific body fields for local models, keep it. If Anthropic wire protocol compatibility is the goal, remove it.

4. **Per-base-url request building functions**: Upstream consolidated them. Fork keeps variants. Keeping variants is necessary for local model compatibility but adds maintenance burden.

### Minor Conflicts (cosmetic or already resolved)

5. **Provider diagnostics types**: Both branches already removed them. No action needed.
6. **Thinking/reasoning content**: Both branches already removed it. No action needed.
7. **Session liveness/heartbeat**: Both branches already removed it. No action needed.
8. **Plugin lifecycle in summaries**: Both branches already simplified it. No action needed.
9. **MCP `required` field**: Both branches already removed it. No action needed.

---

## Risks and Regression Concerns

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Step 2 regression** — removing `base_model` split could break model entries keyed by path | Low | Medium | Check MODEL_REGISTRY before applying. If no path-prefixed entries, safe to remove. |
| **Step 1 breaking DashScope** — adding the `OPENAI_BASE_URL` guard prevents DashScope routing when both `DASHSCOPE_API_KEY` AND `OPENAI_BASE_URL` are set | Low | Low | This is intentional behavior. Users who want DashScope should not set `OPENAI_BASE_URL`. Restore DashScope routing only when `OPENAI_BASE_URL` is unset. |
| **Future upstream merge** — if upstream changes types.rs to remove `BTreeMap` import, the fork's compile would break | Medium | High | Guard the `extra_body` field and its import. Consider adding a `#[cfg(feature = "local_models")]` gate if this becomes a compile conflict. |
| **ResilienceConfig split** — having the canonical definition in `runtime` and a re-export in `api` creates a fragile circular-ish dependency | Low | Medium | The `api` crate depends on `runtime`, so this is a normal re-export, not circular. The risk is if upstream adds code that imports `ResilienceConfig` from `api` directly without going through the re-export. |
| **Setup module not wired into launch path** — `setup_lmstudio()` sets env vars but may not actually launch the REPL | Medium | High | Verify that `handle_setup()` in main.rs actually calls into the REPL code path after setting env vars. The current setup.rs may just return after setting env vars without launching. |

---

## Validation Checklist

After implementing the adopted changes, verify:

1. **`cargo build --workspace`** compiles without errors.
2. **`cargo test --workspace`** passes with no regressions.
3. **DashScope routing** — when `OPENAI_BASE_URL` is set and `DASHSCOPE_API_KEY` is set, Qwen models route through the OpenAI-compatible path, not DashScope.
4. **DashScope routing** — when `OPENAI_BASE_URL` is unset and `DASHSCOPE_API_KEY` is set, Qwen models still route through DashScope.
5. **`model_token_limit`** — calling with known aliases like "opus" still returns correct limits.
6. **`model_token_limit`** — calling with aliases containing path prefixes still returns correct limits (if any exist).
7. **`ResilienceConfig`** — `from_env()` with `CLAW_RESILIENCE=force` returns `force_enable()` config correctly.
8. **`extra_body`** — MessageRequest serialization includes extra_body when present.
9. **`/resilience`** slash command parses correctly, sets/clears `CLAW_RESILIENCE` env var.
10. **`--resilience`** CLI flag sets `CLAW_RESILIENCE` env var before dispatch.
11. **`setup.rs`** — `claw setup lmstudio` compiles and dispatches correctly.
12. **Per-base-url request building** — `build_chat_completion_request_for_base_url` still works for LM Studio endpoints.
13. **No re-introduced DashScope constants** — `grep -ri "dashscope\|DASHSCOPE" rust/crates/api/` only shows the remaining acceptable references in `mod.rs` and `client.rs`.
14. **`cargo clippy --workspace --all-targets -- -D warnings`** passes.
