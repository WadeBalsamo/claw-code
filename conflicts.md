# conflicts.md — Implementation Conflicts Between upstream/main and the Fork (beta)

## Overview

This document catalogs every meaningful implementation conflict between upstream/main and the current branch, focusing on Rust code where the same feature exists in both branches but is implemented differently. It is intended for a developer who needs to either adopt upstream changes into the fork or understand the divergence.

Analysis date: 2026-05-10
Upstream HEAD: 63ce483c
Fork HEAD: 7222f74f

---

## Conflict Inventory

### Conflict 1: DashScope Routing in `client.rs`

**File:** `rust/crates/api/src/client.rs`

**Upstream implementation:**
```rust
ProviderKind::OpenAi => {
    let config = match providers::metadata_for_model(&resolved_model) {
        Some(meta)
            if meta.auth_env == "DASHSCOPE_API_KEY"
                && std::env::var_os("OPENAI_BASE_URL").is_none() =>
        {
            OpenAiCompatConfig::dashscope()
        }
        _ => OpenAiCompatConfig::openai(),
    };
    let client = OpenAiCompatClient::from_env(config)?;
    Ok(Self::OpenAi(client.with_resilience_config(resilience_config)))
}
```

**Fork implementation:**
```rust
ProviderKind::OpenAi => {
    // DashScope models (qwen-*) also return ProviderKind::OpenAi because they
    // speak the OpenAI wire format, but they need the DashScope config which
    // reads DASHSCOPE_API_KEY and points at dashscope.aliyuncs.com.
    let config = match providers::metadata_for_model(&resolved_model) {
        Some(meta) if meta.auth_env == "DASHSCOPE_API_KEY" =>
            OpenAiCompatConfig::dashscope()
        _ => OpenAiCompatConfig::openai(),
    };
    let client = OpenAiCompatClient::from_env(config)?;
    Ok(Self::OpenAi(client.with_resilience_config(resilience_config)))
}
```

**Behavioral difference:**
- Upstream: DashScope config is only used when `OPENAI_BASE_URL` is NOT set. If the user has set `OPENAI_BASE_URL`, all models (including those with DashScope metadata) go through the standard OpenAI-compat config.
- Fork: DashScope config is used whenever the model's metadata says `auth_env == "DASHSCOPE_API_KEY"`, regardless of whether `OPENAI_BASE_URL` is set.

**Tradeoffs:**
- Upstream approach: More robust for mixed-provider scenarios. Users who set `OPENAI_BASE_URL` explicitly want all traffic through that base URL.
- Fork approach: More faithful to the original DashScope routing for models like Qwen that naturally speak the OpenAI wire format but have DashScope-specific auth.

**Which is better:** The upstream approach with the `OPENAI_BASE_URL` guard is better for the fork's local-model use case. When using LM Studio (`claw setup lmstudio`), the system sets `OPENAI_BASE_URL` explicitly, and local requests must NOT be routed through DashScope config. The fork's unconditional match could cause local Qwen models to hit the wrong endpoint.

**Recommendation:** **Adopt upstream** — add the `&& std::env::var_os("OPENAI_BASE_URL").is_none()` guard.

---

### Conflict 2: `ResilienceConfig` Canonical Definition

**Files:** `rust/crates/api/src/resilience_config.rs`, `rust/crates/runtime/src/conversation.rs`

**Upstream implementation:**
- `api/src/resilience_config.rs` defines `ResilienceConfig` as a standalone struct with ~7 fields:
  - `force_enable`, `force_disable`, `auto_enable_for_local`, `enable_for_anthropic`, `enable_for_openai_compat`
  - Basic `should_enable_for_url()` and `should_enable_for_provider()` methods
  - No per-error-type retry counts or backoff durations
  - No `force_enable()` or `force_disable()` constructors
  - No `from_env()` method

**Fork implementation:**
- `runtime/src/conversation.rs` defines `ResilienceConfig` with ~30 fields:
  - All upstream fields plus:
  - Per-error-type retry counts: `model_reloaded_max_retries`, `context_exceeded_max_retries`, `stream_empty_max_retries`, `decoding_error_max_retries`, `model_unloaded_max_retries`, `tool_sequence_error_max_retries`
  - Per-error-type backoffs (corresponding `*_initial_backoff: Duration` fields)
  - Context thresholds: `context_warning_threshold: f32`, `context_critical_threshold: f32`
  - Compaction strategy: `aggressive_compaction_preserve_recent`, `conservative_compaction_preserve_recent`
  - Backoff tuning: `backoff_multiplier: f64`, `max_backoff: Duration`
- Full builder methods: `force_enable()`, `force_disable()`, `from_env()`, `with_anthropic_enabled()`, etc.
- Decision methods: `is_enabled()`, `should_enable_for_provider()`, `should_enable_for_url()`, `max_retries_for()`, `initial_backoff_for()`, `backoff_for_attempt()`
- `api/src/resilience_config.rs` is a 3-line re-export: `pub use runtime::ResilienceConfig;`

**Behavioral difference:**
- Upstream: Minimal config, no error-specific retry tuning. Retry behavior is coarse-grained.
- Fork: Per-error-type retry budgets enable precise recovery strategies:
  - Model unloaded → 10 retries with 3s initial backoff
  - Context exceeded → 2 retries with 2s initial backoff
  - Empty stream → 5 retries with 1s initial backoff
  - Decoding error → 3 retries with 1s initial backoff

**Tradeoffs:**
- Upstream: Simpler, less code, easier to reason about. Minimalist API surface.
- Fork: More capable for local-model recovery where different error types need different strategies. Per-error budgets prevent one failure mode from exhausting retries for other modes. The re-export pattern adds indirection but works.

**Which is better:** The fork's implementation is substantially better for local-model workflows. Local models (LM Studio, Ollama) produce different failure modes than cloud APIs, requiring error-specific retry strategies. The upstream version would give too many retries for context errors and too few for model-unloaded errors.

**Recommendation:** **Reject upstream's minimal implementation.** Keep the fork's comprehensive `ResilienceConfig` in `runtime/src/conversation.rs`. Keep the `api/src/resilience_config.rs` re-export shim.

**Potential concern:** The fork's `should_enable_for_provider` includes `"dashscope"` in the match arm that routes to `enable_for_openai_compat`. This is acceptable — DashScope uses the OpenAI wire format so OpenAI-compat resilience settings apply correctly. Verify this arm exists and is not causing issues.

---

### Conflict 3: `extra_body` on `MessageRequest`

**File:** `rust/crates/api/src/types.rs`

**Upstream implementation:**
```rust
pub struct MessageRequest {
    // No extra_body field
    // ...
}
```
The field was removed entirely, along with `use std::collections::BTreeMap`.

**Fork implementation:**
```rust
pub struct MessageRequest {
    // ...
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub extra_body: BTreeMap<String, Value>,
    // ...
}
```

**Behavioral difference:**
- Upstream: No provider-specific body parameters. Only protocol-standard fields are sent.
- Fork: Supports arbitrary extra JSON body fields that get merged into the final request payload. These can include provider-specific parameters like `repetition_penalty`, `top_k`, `min_p` for local models.

**Tradeoffs:**
- Upstream: Strict protocol conformance. Cleaner API for Anthropic-only users. Less JSON serialization overhead.
- Fork: Enables local-model parameter passthrough. Qwen, DeepSeek, and other local models often require or benefit from provider-specific fields like `repetition_penalty`, `min_p`, `top_k` that are not in the Anthropic message format.

**Which is better:** The fork's version is better for local-model compatibility. The `extra_body` field is the mechanism that allows local model parameters to flow through without first-class typed fields for every possible provider parameter. Removing it would break local Qwen/DeepSeek usage.

**Recommendation:** **Reject upstream's removal.** Keep the `extra_body` field in the fork. If a future merge from upstream removes it, restore it explicitly with a comment noting "Required for local model provider parameters."

---

### Conflict 4: Per-Base-URL Request Building Functions

**File:** `rust/crates/api/src/providers/openai_compat.rs`

**Upstream implementation:**
- Single `check_request_body_size(request, config)` — no base URL parameter
- Single `build_chat_completion_request(request, config)` — no base URL parameter
- Removed `check_request_body_size_for_base_url`, `estimate_request_body_size`, `build_chat_completion_request_for_base_url`

**Fork implementation:**
- Retains per-base-url variants:
  - `check_request_body_size_for_base_url(request, config, base_url)`
  - `estimate_request_body_size(request, config)` (separate from check)
  - `build_chat_completion_request_for_base_url(request, config, base_url)`
- These allow different request serialization for different provider endpoints.

**Behavioral difference:**
- Upstream: One-size-fits-all request building. Every provider gets the same serialization.
- Fork: Can customize request serialization per base URL. For example, LM Studio may need different `stop` formatting than OpenAI.

**Tradeoffs:**
- Upstream: Simpler code, fewer maintenance surfaces.
- Fork: More flexible for local model providers that deviate from the OpenAI spec.

**Which is better:** The fork's approach is better for local-model compatibility. Different local inference servers (LM Studio, Ollama, text-gen-webui) have slightly different OpenAI-compatible API implementations. Per-base-url variants allow adapting to these differences without adding complexity to every call site.

**Recommendation:** **Reject upstream's consolidation.** Keep the fork's per-base-url functions. If a future merge replaces them, restore the fork's versions.

---

### Conflict 5: `openai_compat.rs` StreamState — Thinking/Reasoning Content Handling

**File:** `rust/crates/api/src/providers/openai_compat.rs`

**Upstream implementation:**
- Removed `thinking_started`, `thinking_finished` fields from `StreamState`
- Removed `reasoning_content` field from `ChatMessage`
- Removed all `close_thinking()`, `text_block_index()`, `tool_index_offset()` helper methods
- Index handling simplified: text block is always index 0, tool blocks start at index 1
- Removed `OpenAiPromptTokensDetails` with `cached_tokens`

**Fork implementation:**
- Same removals applied. Matches upstream exactly.

**Behavioral difference:** None. Both branches converged on the same implementation.

**Tradeoffs:** Not applicable — no conflict.

**Which is better:** Both branches agree. The simplified approach is correct — since there's no thinking content in OpenAI-compatible responses handled by either branch, the thinking state machine was dead code.

**Recommendation:** **Already in sync.** No action needed.

---

### Conflict 6: `mod.rs` Provider Diagnostics Types

**File:** `rust/crates/api/src/providers/mod.rs`

**Upstream implementation:**
- Removed `ProviderWireProtocol`, `ProviderFeatureSupport`, `ProviderCapabilityReport`, `ProviderDiagnostics`, `ProviderDiagnosticSeverity`, `ProviderDiagnostic`
- Removed `provider_diagnostics_for_model()`, `model_family_identity_for()`, `provider_capabilities_for_model()`, `provider_diagnostics_for_request()`
- Simplified `model_token_limit` — removed `base_model` split
- Removed `kimi-k2.5` and `kimi-k1.5` token limits
- Added `#[allow(clippy::cast_possible_truncation)]` (removed `#[allow(dead_code)]`)

**Fork implementation:**
- Same removals applied. Matches upstream exactly on the removal of provider diagnostics.
- Still has `kimi` model token limits.
- Still has `base_model` split in `model_token_limit`.

**Behavioral difference:** The fork still uses `base_model = canonical.rsplit('/').next().unwrap_or(canonical.as_str())` to extract the model name from paths like `"provider/model-name"`. Upstream matches on canonical directly.

**Tradeoffs:**
- Upstream: Simpler, less code. No support for path-prefixed model aliases.
- Fork: More flexible — can handle both `"claude-opus-4-6"` and `"anthropic/claude-opus-4-6"`.

**Which is better:** Upstream's version is simpler, but the fork's version is more robust for the local-model use case where users may specify models with path prefixes (e.g., `"openai/gpt-4"`). However, since the fork's MODEL_REGISTRY likely uses canonical names only (no path prefixes), the `base_model` split is effectively dead code.

**Recommendation:** **Adopt upstream's simplification** — remove the `base_model` split. Verify the MODEL_REGISTRY does not contain path-prefixed entries first. If it does, keep the split.

---

### Conflict 7: GPT-4.1, GPT-5.4, and kimi Model Token Limits

**File:** `rust/crates/api/src/providers/mod.rs`

**Upstream implementation:**
- Removed GPT-4.1 family (gpt-4.1, gpt-4.1-mini, gpt-4.1-nano)
- Removed GPT-5.4 family (gpt-5.4, gpt-5.4-mini, gpt-5.4-nano)
- Removed kimi-k2.5 and kimi-k1.5 entries

**Fork implementation:**
- Still has GPT-4.1 family entries
- Still has kimi-k2.5 and kimi-k1.5 entries
- Removed GPT-5.4 family (matches upstream on this)

**Behavioral difference:**
- Fork: Supports token limit lookups for GPT-4.1 models (32,768 max output, 1,047,576 context) and kimi-k2.5/k1.5 models
- Upstream: These return the heuristic fallback instead of precise limits

**Tradeoffs:**
- Upstream: Less code to maintain. Users of those models get heuristic token limits, which are usually fine.
- Fork: Precise limits for those models. Better user experience for those users.

**Which is better:** For the fork's local-model focus, precise limits for kimi models matter. GPT-4.1 limits are harmless to keep. The kimi limits should be retained for Qwen/Moonshot compatibility.

**Recommendation:** **Adapt** — keep the kimi model limits. Optionally remove GPT-4.1 limits if they are unused. They are harmless to keep.

---

### Conflict 8: `max_tokens_for_model` Heuristic

**File:** `rust/crates/api/src/providers/mod.rs`

**Upstream implementation:**
```rust
pub fn max_tokens_for_model(model: &str) -> u32 {
    model_token_limit(model).map_or_else(
        || {
            let canonical = resolve_model_alias(model);
            if canonical.contains("opus") { 32_000 } else { 64_000 }
        },
        |limit| limit.max_output_tokens,
    )
}
```

**Fork implementation:**
```rust
pub fn max_tokens_for_model(model: &str) -> u32 {
    let canonical = resolve_model_alias(model);
    let heuristic = if canonical.contains("opus") { 32_000 } else { 64_000 };
    model_token_limit(model).map_or(heuristic, |limit| heuristic.min(limit.max_output_tokens))
}
```

**Behavioral difference:**
- Upstream: Direct optional chaining — `model_token_limit(model).map_or_else(heuristic, |limit| limit.max_output_tokens)`. If a model has a token limit entry, uses it directly. Otherwise, uses heuristic.
- Fork: Caps the model's `max_output_tokens` at the heuristic value: `heuristic.min(limit.max_output_tokens)`. So even if the model's limit says 128,000, the fork returns at most 64,000 (or 32,000 for opus).

**Tradeoffs:**
- Upstream: Trusts the model registry. Models with high limits (e.g., claude-opus at 128k context) get their full output budget.
- Fork: Conservative. Caps output at the heuristic even if the model supports more. Prevents accidentally requesting too many tokens from a local model that may struggle with long outputs.

**Which is better:** The fork's version is more conservative and better for local models that may have advertised high limits but degrade at long outputs. The upstream version is better for cloud models where the advertised limit is accurate. For the fork's use case, the conservative cap is correct.

**Recommendation:** **Keep fork's version** (heuristic cap). Reject upstream's simplification if it removes the cap. The `main.rs` inlining (`if model.contains("opus") { 32_000 } else { 64_000 }`) already bypasses these functions for the CLI path.

---

### Conflict 9: `content_block.rs` — Thinking variant

**File:** `rust/crates/runtime/src/session.rs`

**Upstream implementation:**
- Removed `ContentBlock::Thinking { thinking, signature }` variant
- Removed `SessionLiveness`, `SessionHeartbeat` types
- Removed `record_health_check()`, `heartbeat_at()` methods
- Removed JSONL truncation constants

**Fork implementation:**
- Same removals applied. Matches upstream exactly.

**Behavioral difference:** None. Both branches converged.

**Tradeoffs:** Not applicable — no conflict.

**Recommendation:** **Already in sync.** No action needed.

---

### Conflict 10: `commands/src/lib.rs` — `/session exists` Subcommand

**File:** `rust/crates/commands/src/lib.rs`

**Upstream implementation:**
- Removed `/session exists <id>` parser pattern and handler
- Updated usage string: removed "exists <session-id>" from documentation
- Removed test case for the `exists` subcommand

**Fork implementation:**
- Same removals applied. Matches upstream exactly.

**Behavioral difference:** None. Both branches removed the `exists` subcommand.

**Tradeoffs:** Not applicable — no conflict.

**Recommendation:** **Already in sync.** No action needed.

---

### Conflict 11: `commands/src/lib.rs` — `/session resume_supported` Flag

**File:** `rust/crates/commands/src/lib.rs`

**Upstream implementation:**
- Changed `session` spec `resume_supported` from `true` to `false`

**Fork implementation:**
- Same change applied. Matches upstream exactly.

**Behavioral difference:** None. Both branches agree this is not safe to resume.

**Tradeoffs:** Not applicable — no conflict.

**Recommendation:** **Already in sync.** No action needed.

---

### Conflict 12: `commands/src/lib.rs` — MCP `required` Field Removal

**File:** `rust/crates/commands/src/lib.rs`

**Upstream implementation:**
- Removed `"required"` field and `server.required` from MCP server report rendering and JSON output
- Removed `format!("  Required          {}", server.required)` from text report

**Fork implementation:**
- Same removal applied. Matches upstream exactly.

**Behavioral difference:** None. Both branches removed the `required` field from MCP display.

**Tradeoffs:** Not applicable — no conflict.

**Recommendation:** **Already in sync.** No action needed.

---

### Conflict 13: `commands/src/lib.rs` — PluginLifecycle Removal from Summaries

**File:** `rust/crates/commands/src/lib.rs`

**Upstream implementation:**
- Removed `PluginLifecycle` from `PluginSummary` used in test assertions
- Removed `lifecycle: PluginLifecycle::default()` from test plugin summaries

**Fork implementation:**
- Same removal applied. Matches upstream exactly.

**Behavioral difference:** None. Both branches removed PluginLifecycle from the summary display.

**Tradeoffs:** Not applicable — no conflict.

**Recommendation:** **Already in sync.** No action needed.

---

### Conflict 14: `runtime/src/lib.rs` — Module Re-exports

**File:** `rust/crates/runtime/src/lib.rs`

**Upstream implementation:**
- Removed re-exports for modules: `approval_tokens`, `g004_conformance`, `report_schema`
- Removed `LaneBoard`, `LaneBoardEntry`, `LaneFreshness`, `LaneHeartbeat` from task_registry
- Removed `ModelFamilyIdentity` from prompt
- Removed various error-related policy_engine types
- Removed session liveness/heartbeat types
- Changed file_ops exports from `_in_workspace` variants to basic variants
- Added `HookStreamDebugger`, `StreamDebugContext`, etc. to hooks

**Fork implementation:**
- Same changes applied. Matches upstream exactly.

**Behavioral difference:** None. Both branches converged on re-export simplification.

**Tradeoffs:** Not applicable — no conflict.

**Recommendation:** **Already in sync.** No action needed.

---

### Conflict 15: Context Window Error Markers in `error.rs`

**File:** `rust/crates/api/src/error.rs`

**Upstream implementation:**
- Removed 5 markers from `CONTEXT_WINDOW_ERROR_MARKERS`:
  - `"input tokens exceed"`, `"configured limit"`, `"messages resulted in"`, `"completion tokens"`, `"prompt tokens"`
- Removed test `classifies_openai_configured_limit_errors_as_context_window_failures`

**Fork implementation:**
- Same removals applied. Matches upstream exactly.

**Behavioral difference:** None. Both branches removed the same markers.

**Tradeoffs:** Not applicable — no conflict.

**Recommendation:** **Already in sync.** No action needed.

---

### Conflict 16: `compact.rs` — Compaction Enhancements

**File:** `rust/crates/runtime/src/compact.rs`

**Upstream implementation:**
- Does NOT have `CompactionStrategy`, system prompt overhead, or timeline capping
- (These are fork-specific enhancements with no upstream equivalent)

**Fork implementation:**
- Has `CompactionStrategy` enum (Standard, Aggressive, Conservative, Emergency)
- System prompt overhead in `should_compact()`
- Timeline capped to last 10 messages in `summarize_messages()`
- Bug fix for unbounded timeline growth

**Behavioral difference:** These are purely additive fork features. Upstream has no corresponding implementation.

**Tradeoffs:** Not applicable — no conflict.

**Recommendation:** **Keep fork's implementation.** These are not upstream changes — they are local improvements that have no upstream equivalent to conflict with.

---

### Conflict 17: `hooks.rs` — Stream Debug Hooks

**File:** `rust/crates/runtime/src/hooks.rs`

**Upstream implementation:**
- Does NOT have `HookStreamDebugger`, `StreamDebugContext`, `StreamResult`, `StreamDebugCapture`, `StreamDebugEventType`, or `StreamDebugExecutor`
- (These are fork-specific enhancements with no upstream equivalent)

**Fork implementation:**
- Has all the above types and the `HookStreamDebugger` trait
- Four callback hooks: `on_stream_start`, `on_stream_chunk`, `on_stream_end`, `on_stream_error`
- Default `StreamDebugExecutor` for testing

**Behavioral difference:** Purely additive. No upstream equivalent.

**Tradeoffs:** Not applicable — no conflict.

**Recommendation:** **Keep fork's implementation.**

---

## Branch-by-Branch Behavior

### Upstream Branch Behavior
- Standard Claude Code CLI focused on Anthropic API and basic OpenAI compat
- Minimal resilience config (no per-error-type tuning)
- No launcher commands (no `setup` subcommand)
- No `extra_body` — strict protocol conformance
- Basic compaction (no CompactionStrategy, no timeline capping)
- No stream debugging hooks
- Only deleted modules (approval_tokens, g004_conformance, report_schema align with fork)

### Fork Branch Behavior
- Local-model-first: LM Studio, Ollama, Qwen support
- Comprehensive resilience with per-error-type retry budgets and backoff
- Native launcher: `claw setup lmstudio` and `claw setup openrouter`
- `extra_body` support for local model parameters
- Enhanced compaction with CompactionStrategy, timeline capping
- Stream debugging hooks for diagnosing empty-stream errors
- Preemptive compaction before API calls

---

## Tradeoff Analysis

| Dimension | Upstream | Fork | Winner |
|-----------|----------|------|--------|
| **Correctness** | Standard Anthropic protocol | Correct for both Anthropic and local providers | Fork (broader coverage) |
| **Maintainability** | Less code, fewer branches | More code, more features | Upstream (simpler) |
| **Local-model compatibility** | None | Full (LM Studio, Ollama, Qwen) | Fork |
| **Stream robustness** | Basic retry | Per-error-type recovery, debug hooks | Fork |
| **Simplicity** | Minimal config | Comprehensive config with fine-tuning | Upstream |
| **Future extensibility** | Easy to add typed fields | Extra_body for untyped expansion | Fork (flexible) |
| **Resilience configurability** | One-size-fits-all | Per-error-type budgets, backoff, compaction | Fork |
| **DashScope handling** | Guarded (only without OPENAI_BASE_URL) | Unconditional | Upstream (safer) |

---

## Recommended Direction

1. **Adopt from upstream** (3 items):
   - DashScope conditional guard in `client.rs` (`&& std::env::var_os("OPENAI_BASE_URL").is_none()`)
   - Remove `base_model` split from `model_token_limit()` in `mod.rs` (verify MODEL_REGISTRY first)
   - Optionally remove GPT-4.1 model token limits (cosmetic)

2. **Reject from upstream** (5 items):
   - `extra_body` removal from `types.rs` — keep for local model params
   - Per-base-url request building consolidation — keep for LM Studio compat
   - Upstream's minimal `ResilienceConfig` — fork's is more capable
   - Re-introduction of deleted modules (`approval_tokens`, `g004_conformance`, `report_schema`)
   - Removal of heuristic cap in `max_tokens_for_model` — keep the cap for conservative local model behavior

3. **Already in sync** (11 items):
   - Session thinking/liveness removal
   - Error classification markers
   - Provider diagnostics type removal
   - Thinking/reasoning content removal
   - Glob search simplification
   - Plugin lifecycle removal
   - MCP `required` field removal
   - `/session exists` removal
   - `/session resume_supported` flag
   - Error variant additions
   - CliAction/CLI re-exports
