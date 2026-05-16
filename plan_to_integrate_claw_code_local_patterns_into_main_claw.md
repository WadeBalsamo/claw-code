# Plan to Integrate claw-code-local Patterns into Main `claw`

## Objective

Integrate the shell‑script shortcut behavior from `codetwentyfive/claw-code-local` (`localfork/main`) into the current fork's main `claw` Rust binary, so that the functionality of `scripts/setup_lmcode.sh` and `scripts/setup_opencode_shortcut.sh` becomes available as native CLI subcommands, while preserving all features documented in `fork_feature_inventory_since_mod_for_local_models_backup.md`.

Key principles:
- No wholesale copying of `localfork/main` code
- Every pattern adopted must be evaluated against the preservation inventory
- When there is a conflict, the inventory document wins
- Focus only on launcher and shortcut integration — defer MCP/plugin/boot-protocol additions

---

## Preserved Behavior

The inventory document (`fork_feature_inventory_since_mod_for_local_models_backup.md`) locks down these features:

| Feature | Must Remain | Relevant Files |
|---------|-------------|----------------|
| Local-model provider dispatch | `detect_provider_kind` routes model names to Anthropic/XAI/OpenAI clients | `api/src/providers/mod.rs` |
| Resilience & retry | `ResilienceConfig`, exponential backoff, jitter | `api/src/resilience_config.rs` |
| Stream-error handling | `StreamError` enum, line-break integrity in streaming | `api/src/sse.rs`, `api/src/error.rs` |
| Modern API surface | All provider interactions through `ProviderClient`/`AnthropicClient` | `api/src/client.rs` |
| DashScope removal | No DashScope-specific code paths | `api/src/providers/mod.rs`, `api/src/lib.rs` |
| BuiltRuntime wrapper | Runtime lifecycle isolated from `LiveCli` | `runtime/src/lib.rs` |
| Event & session model | Worker boot handshake, trust-gate, ready-handshake | Various |

**Hard boundary:** The `setup lmcode` and `setup opencode` commands must integrate with—not replace—these patterns. In particular:
- Do NOT reintroduce DashScope constants (`DASHSCOPE_API_KEY`, `dashscope.aliyuncs.com`)
- Do NOT bypass `ResilienceConfig` when routing local-model requests
- Do NOT change the `.claude/` → `.claw/` directory naming (that decision is deferred)

---

## Current Shortcut Behavior

### `scripts/setup_lmcode.sh`
Creates `~/bin/lmcode` which:
1. Probes a default LM Studio address (`host:port`), then known candidates (`127.0.0.1:1234`, `localhost:1234`), then a recent-address file (`~/.lmstudio_recent_ips`), and finally an interactive fallback
2. Fetches the model list from LM Studio's `/v1/models` endpoint
3. If no `--model` arg given, prompts for model selection
4. Exports environment variables: `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, `OPENAI_API_KEY=local-model`, `CLAW_RESILIENCE=force`
5. Executes `claw --model <model> --permission-mode danger-full-access`

### `scripts/setup_opencode_shortcut.sh`
Creates `~/bin/opencode` which:
1. Reads/stores OpenRouter API key in `~/.config/opencode/.env`
2. Fetches tool-capable model catalog from `openrouter.ai/api/v1/models`
3. Caches catalog in `~/.config/opencode/openrouter_models_cache.tsv`
4. Provides TUI or fzf browser for model selection
5. Exports environment variables: `OPENAI_BASE_URL=https://openrouter.ai/api/v1`, `OPENAI_API_KEY`, `HTTP_REFERER`, `X_TITLE`, `CLAW_RESILIENCE=none`
6. Executes `claw --model <model> --permission-mode danger-full-access`

---

## Relevant Patterns from `localfork/main`

Based on diff analysis (`git diff localfork/main -- '*.rs'`), these patterns from localfork are architecturally relevant:

### P1. Expanded CliAction enum with `output_format`
`localfork/main` adds `output_format` to every CLI action, enabling structured JSON output for automation consumption. The `CliAction` enum grows from ~20 to ~65 variants.

**Location**: `rust/crates/rusty-claude-cli/src/main.rs`

### P2. `ResilienceConfig` with env-var override (`CLAW_RESILIENCE`)
`localfork/main` implements `ResilienceConfig::from_env()` reading `CLAW_RESILIENCE=force|none|auto`. Per-error-type retry counts and backoff durations differ from the current branch's simpler implementation.

**Location**: `rust/crates/api/src/resilience_config.rs` (new file in localfork)

### P3. `ErrorClassifier` + `RecoveryStateMachine` + `ModelHealthProfile`
New module `local_model_recovery.rs` provides:
- `RetryableErrorKind`: classifies errors into `ModelUnloaded`, `EmptyStream`, `FirstTokenStalled`, `TransportError`, `ServerError`, `NonRetryable`
- `ErrorClassifier::classify()`: maps `ApiError` to `RetryableErrorKind`
- `ModelHealthProfile`: per-model failure tracking with adaptive streaming/retry strategy
- `ProviderCapabilities`: per-provider (LM Studio, cloud, generic local) timeout/retry profiles
- `RecoveryStateMachine`: manages retry loop with request mutation per attempt

**Location**: `rust/crates/api/src/local_model_recovery.rs` (new file in localfork)

### P4. HTTP Proxy Support (`http_client.rs`)
`localfork/main` adds `build_http_client()` that reads `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` env vars, and `build_http_client_or_default()` infallible fallback.

**Location**: `rust/crates/api/src/http_client.rs` (new file in localfork)

### P5. `SseParser::with_context()` for enriched stream errors
`localfork/main` attaches provider+model context to stream deserialization errors via `parse_frame_with_context()`.

**Location**: `rust/crates/api/src/sse.rs`

### P6. Piped stdin reading (`read_piped_stdin`, `merge_prompt_with_stdin`)
`localfork/main` reads piped stdin content when not in interactive mode, merging it with the prompt argument.

**Location**: `rust/crates/rusty-claude-cli/src/main.rs`

### P7. `model_provenance` tracking
`localfork/main` tracks where the resolved model string came from (`flag`/`env`/`config`/`default`) for auditability.

**Location**: `rust/crates/rusty-claude-cli/src/main.rs`

### P8. `/resilience` and `/history` slash commands
`localfork/main` removes `/login`/`/logout`, adds `/resilience [force|none|auto]` and `/history [count]`.

**Location**: `rust/crates/commands/src/lib.rs`

### P9. `slash_name()` canonical command method
`localfork/main` adds `SlashCommand::slash_name()` returning the canonical name (e.g., `"/doctor"`).

**Location**: `rust/crates/commands/src/lib.rs`

### P10. `OpenAiCompatClient` split into recovery/non-recovery paths
`localfork/main` splits `send_message()` into `send_message_without_recovery()` and `send_message_with_recovery()`. The recovery path integrates `RecoveryStateMachine`. Retry parameters: 1s initial backoff, 128s max, 8 max retries.

**Location**: `rust/crates/api/src/providers/openai_compat.rs`

---

## Compatibility Analysis

| Pattern | Fits Current Architecture? | Conflicts with Inventory? | Verdict |
|---------|---------------------------|---------------------------|---------|
| P1. Expanded CliAction + output_format | Yes — additive pattern | No | **Adopt** |
| P2. `CLAW_RESILIENCE` env var override | Yes — inventory mentions `ResilienceConfig` must be preserved | No — extends existing contract | **Adopt** |
| P3. ErrorClassifier + RecoveryStateMachine | Yes — localfork's approach is more modular | Must avoid DashScope coupling | **Adapt** |
| P4. HTTP proxy support | Yes — additive, no existing proxy code to conflict | No | **Adopt** |
| P5. SseParser::with_context | Yes — additive enrichment | No | **Adopt** |
| P6. Piped stdin reading | Yes — additive CLI feature | No | **Adopt** |
| P7. Model provenance tracking | Yes — additive debugging | No | **Adopt** |
| P8. /resilience + /history commands | Yes — additive slash commands | No — but `/login`/`/logout` removal must not break existing skill that depends on it | **Adapt** |
| P9. slash_name() method | Yes — additive utility | No | **Adopt** |
| P10. Split send_message paths | Yes — necessary for resilience integration | Must reject DashScope constants | **Adapt** |

**Rejected patterns (explicitly):**
- DashScope-specific config and routing (per inventory, "All DashScope-specific code deleted")
- `.claw/` directory naming (per conflict analysis, would break existing installations)
- New runtime modules (`mcp_server.rs`, `worker_boot.rs`, `trust_resolver.rs`, etc.) — deferred to later upstream-merge pass
- Direct shell-script spawning (the entire point is to move this into Rust)

---

## Adopt / Adapt / Reject Decisions

| Decision | Rationale |
|----------|-----------|
| **Adopt** `ResilienceConfig::from_env()` reading `CLAW_RESILIENCE` | Directly needed by both LM Studio (`CLAW_RESILIENCE=force`) and OpenRouter (`CLAW_RESILIENCE=none`) scripts |
| **Adopt** `output_format` field on all `CliAction` variants | Enables structured output that claws can consume without scraping terminal text |
| **Adopt** `read_piped_stdin()` and `merge_prompt_with_stdin()` | Enables pipe-based usage: `echo "summarize" | claw prompt` |
| **Adopt** `ModelProvenance` tracking | Enables deterministic audit of model resolution — critical for debugging launcher behavior |
| **Adopt** `SseParser::with_context()` | Enriched stream errors directly serve local-model debugging |
| **Adopt** `build_http_client()` / `ProxyConfig` | Required for enterprise deployments behind proxy |
| **Adopt** `slash_name()` method | Clean logging for slash command dispatch |
| **Adopt** `/resilience` and `/history` commands | Directly support the launcher goal |
| **Adopt** Enhanced retry parameters (1s/128s/8 retries) | Local models need slower, longer retries than cloud APIs |
| **Adopt** Tool message sanitization (`sanitize_tool_message_pairing`) | Prevents API 400 errors from orphaned tool messages |
| **Adapt** `ErrorClassifier` / `RecoveryStateMachine` / `ModelHealthProfile` | Adopt the general architecture but wire it through the current branch's `ResilienceConfig` type, not localfork's version |
| **Adapt** `OpenAiCompatClient::send_message_with_recovery()` | Adopt the recovery loop pattern but reject DashScope constants |
| **Adapt** Removal of `/login` and `/logout` | Replace with error suggesting env-vars, but add a transition period notice |
| **Adapt** Simplified command categories | Use localfork's 4-category system (Session/Tools/Config/Debug) instead of current branch's more fragmented structure |
| **Reject** DashScope routing in `detect_provider_kind` | Per inventory: "All DashScope-specific code deleted" |
| **Reject** `.claw/` naming | Would break existing user installations; defer decision |
| **Reject** New runtime modules (mcp_server, worker_boot, trust_resolver, etc.) | Out of scope for this launcher integration task |
| **Reject** Direct shell-script spawning | The entire point is to move this into Rust |

---

## Exact Implementation Plan

### Phase 1: Foundation — API Layer Enhancements

These changes must happen first because Phase 2 and Phase 3 depend on them.

---

#### Step 1.1: Add `http_client.rs` with proxy support

**Files to modify:**
- `rust/crates/api/src/http_client.rs` — NEW FILE
- `rust/crates/api/src/lib.rs` — add `mod http_client;` and `pub use http_client::*;`

**Exact logic to add:**
1. Create `rust/crates/api/src/http_client.rs` containing:
   - `ProxyConfig` struct with fields: `http_proxy: Option<String>`, `https_proxy: Option<String>`, `no_proxy: Option<String>`, `proxy_url: Option<String>`
   - `ProxyConfig::from_env()` reads `HTTP_PROXY`, `http_proxy`, `HTTPS_PROXY`, `https_proxy`, `NO_PROXY`, `no_proxy` from process environment (upper/lower case both checked)
   - `ProxyConfig::from_proxy_url(url)` constructor for config-file path
   - `ProxyConfig::is_empty()` returns `true` when no proxy config is set
   - `build_http_client()` -> `Result<reqwest::Client, ApiError>` — builds a client that honors proxy env vars via `reqwest::Client::builder().no_proxy()` then selectively adding proxies from config
   - `build_http_client_or_default()` -> `reqwest::Client` — infallible wrapper that falls back to `reqwest::Client::new()` on proxy build failure
   - `build_http_client_with(config: &ProxyConfig)` — builds from explicit config (for testing)

2. In `rust/crates/api/src/lib.rs`:
   - Add `mod http_client;`
   - Add `pub use http_client::{build_http_client, build_http_client_or_default, ProxyConfig};`

**Preservation check:** This is additive — no existing code is modified. Refer to `fork_feature_inventory_since_mod_for_local_models_backup.md` Section 4 for the pattern source.

---

#### Step 1.2: Expand `ResilienceConfig` with env-var override and per-error settings

**Files to modify:**
- `rust/crates/api/src/resilience_config.rs` — MODIFY
- `rust/crates/api/src/lib.rs` — MODIFY (ensure `ResilienceConfig` is re-exported)

**Exact logic to add:**
In `rust/crates/api/src/resilience_config.rs`:

1. Add these fields to `ResilienceConfig`:
   - `force_enable: bool`
   - `force_disable: bool`
   - `auto_enable_for_local: bool`
   - `enable_for_anthropic: bool`
   - `enable_for_openai_compat: bool`
   - Per-error-type retry counts: `model_reloaded_max_retries`, `context_exceeded_max_retries`, `stream_empty_max_retries`, `decoding_error_max_retries`, `model_unloaded_max_retries`, `tool_sequence_error_max_retries`
   - Per-error-type backoffs: corresponding `*_initial_backoff: Duration` fields
   - Context thresholds: `context_warning_threshold: f32`, `context_critical_threshold: f32`

2. Add associated functions:
   - `ResilienceConfig::force_enable()` — sets `force_enable: true`, `force_disable: false`, all retry counts to high defaults (5/3/5/3/10/3), all backoffs to 1-3s
   - `ResilienceConfig::force_disable()` — sets `force_enable: false`, `force_disable: true`, all retry counts to 0
   - `ResilienceConfig::from_env()` — reads `CLAW_RESILIENCE` env var: `"force"` -> `force_enable()`, `"none"` -> `force_disable()`, anything else -> default

3. Add builder methods:
   - `with_anthropic_enabled(self, enabled: bool)`
   - `with_openai_compat_enabled(self, enabled: bool)`
   - `with_force_enable(self, enabled: bool)`

4. Add decision methods:
   - `should_enable_for_url(&self, url: &str) -> bool` — checks localhost/127.0.0.1 patterns
   - `should_enable_for_provider(&self, provider: &str) -> bool`

**Preservation check:** The inventory says "Preserve the `ResilienceConfig` API — it is the public contract that governs retry behavior." This extension adds new fields but does not change the existing API shape. The `from_env()` reads `CLAW_RESILIENCE` for the first time, matching the scripts' usage.

---

#### Step 1.3: Add `local_model_recovery.rs` (ErrorClassifier + RecoveryStateMachine + ModelHealthProfile)

**Files to modify:**
- `rust/crates/api/src/local_model_recovery.rs` — NEW FILE
- `rust/crates/api/src/lib.rs` — add `mod local_model_recovery;` and `pub use local_model_recovery::*;`

**Exact logic to add:**

1. `RetryableErrorKind` enum (as in localfork/main section 2): variants `ModelUnloaded`, `EmptyStream`, `FirstTokenStalled`, `TransportError`, `ServerError`, `NonRetryable`

2. `ErrorClassifier` struct with static method `classify(error: &ApiError, provider: &str, response_body: Option<&str>) -> RetryableErrorKind`:
   - `ApiError::Api { status: 400 }` with body containing "Model unloaded" -> `ModelUnloaded`
   - `ApiError::EmptyAssistantStream` -> `EmptyStream`
   - `ApiError::FirstTokenTimeout` -> `FirstTokenStalled`
   - `ApiError::Http` with connect/timeout/request errors -> `TransportError`
   - `ApiError::Api` with status `500|502|503|504` -> `ServerError`
   - `ApiError::Api` with status `429` -> `ServerError`
   - `ApiError::LocalModelUnloaded` -> `ModelUnloaded`
   - Everything else -> `NonRetryable`

3. `ModelHealthProfile` struct with fields: `model_name`, `recent_empty_streams`, `recent_model_unloads`, `recent_first_token_timeouts`, `streaming_degraded`, `streaming_degraded_until`, `force_non_streaming`, `first_token_timeout_ms`
   - `new(model, initial_timeout)` constructor
   - `should_use_streaming() -> bool` — checks degradation window
   - `mark_empty_stream()`, `mark_model_unload()`, `mark_first_token_timeout()` — update counters, degrade streaming after threshold
   - `mark_success(used_streaming)` — decrement counters, record success

4. `ProviderCapabilities` struct with constructors:
   - `lm_studio()` — `is_local: true`, `first_token_timeout_ms: 45_000`, `max_recovery_attempts: 3`, `default_backoff_ms: 500`, `supports_streaming: Some(false)`, `cold_start_likely: true`
   - `cloud_provider()` — `is_local: false`, `first_token_timeout_ms: 5_000`, `max_recovery_attempts: 1`
   - `for_provider(provider_name, model)` — match on name containing "lm studio" or "localhost" to pick profile

5. `RecoveryContext` struct: `provider`, `model`, `attempt`, `last_error_kind`, `health_profile`, `capabilities`

6. `RecoveryStateMachine`:
   - `new(context)` constructor
   - `context()` / `context_mut()` accessors
   - `next_attempt()` increments attempt counter
   - `has_more_attempts() -> bool` checks against capabilities.max_recovery_attempts
   - `backoff_for_attempt(attempt) -> Duration` exponential with jitter
   - `mutate_request_for_attempt(request, attempt) -> MessageRequest` — if attempt > 1 and `model_unloaded` or `empty_stream` was seen, set `stream: false`
   - `handle_empty_stream()`, `handle_model_unloaded()`, `handle_first_token_timeout()` — delegate to health profile
   - `record_success(used_streaming)` — delegate to health profile

**IMPORTANT ADAPTATION:** Do NOT import `ResilienceConfig` from localfork's version. Instead, import it from the current fork's `rust/crates/api/src/resilience_config.rs` (which was already modified in Step 1.2). The `RecoveryStateMachine` should accept a reference to `ResilienceConfig` to retrieve per-error retry counts.

**Preservation check:** The inventory says resilience + retry is preserved. This module formalizes the existing inline retry logic into a testable state machine. It must not re-introduce DashScope-proper references.

---

#### Step 1.4: Add error variants to `error.rs`

**Files to modify:**
- `rust/crates/api/src/error.rs` — MODIFY

**Exact logic to add:**

1. Add to `ApiError` enum:
   - `ContextWindowExceeded { model, estimated_input_tokens, requested_output_tokens, estimated_total_tokens, context_window_tokens }`
   - `Json { provider: String, model: String, body_snippet: String, source: serde_json::Error }`
   - `Api { ..., request_id: Option<String>, suggested_action: Option<String> }`
   - `RequestBodySizeExceeded { estimated_bytes: usize, max_bytes: usize, provider: &'static str }`
   - `LocalModelUnloaded { provider: String, model: String, attempt: u32 }`
   - `EmptyAssistantStream { provider: String, model: String, attempt: u32 }`
   - `FirstTokenTimeout { provider: String, model: String, timeout_ms: u64 }`
   - `ToolSequenceError { request_id: Option<String>, body: String }`
   - `StreamDebugInfo { message: String, tokens_produced: Option<u32>, stream_events: Vec<String> }`

2. Add to `ApiError::is_retryable()`:
   - `ToolSequenceError` -> true
   - `LocalModelUnloaded` -> true
   - `EmptyAssistantStream` -> true
   - `FirstTokenTimeout` -> true

3. Add methods:
   - `ApiError::request_id(&self) -> Option<&str>`
   - `ApiError::json_deserialize(provider, model, body, source) -> Self`
   - `ApiError::missing_credentials_with_hint(provider, env_vars, hint) -> Self`

**Preservation check:** Purely additive — no existing error variants are modified.

---

#### Step 1.5: Enhance SSE parser with provider context

**Files to modify:**
- `rust/crates/api/src/sse.rs` — MODIFY

**Exact logic to add:**

1. Add fields to `SseParser`: `provider: Option<String>`, `model: Option<String>`

2. Add `SseParser::with_context(provider: impl Into<String>, model: impl Into<String>) -> Self` — sets provider+model fields

3. Add private method `parse_frame_with_context(&self, frame: &str) -> Result<Option<StreamEvent>, ApiError>`:
   - Wraps `parse_frame(frame)` calls
   - On `ApiError::Json` or `ApiError::Api` errors, enriches the error with provider+model from self
   - Falls through to `parse_frame` for success path

4. Update `push()` and `finish()` to call `parse_frame_with_context()` instead of `parse_frame()`

**Preservation check:** Purely additive enrichment. No existing callers are affected.

---

#### Step 1.6: Add body size pre-flight to OpenAiCompatClient

**Files to modify:**
- `rust/crates/api/src/providers/openai_compat.rs` — MODIFY

**Exact logic to add:**

1. Add constants:
   - `OPENAI_MAX_REQUEST_BODY_BYTES: usize = 104_857_600` (100MB)
   - `XAI_MAX_REQUEST_BODY_BYTES: usize = 52_428_800` (50MB)
   - Update `OpenAiCompatConfig` to include `max_request_body_bytes: usize`
   - Set `max_request_body_bytes` in `xai()`, `openai()` constructors

   IMPORTANT: Do NOT add `DASHSCOPE_MAX_REQUEST_BODY_BYTES` or `dashscope()` constructor — per inventory, DashScope is removed.

2. Add functions:
   - `estimate_request_body_size(request: &MessageRequest, config: OpenAiCompatConfig) -> usize` — serializes request body and measures
   - `check_request_body_size(request: &MessageRequest, config: OpenAiCompatConfig) -> Result<(), ApiError>` — returns `RequestBodySizeExceeded` error if exceeding config.max_request_body_bytes

3. Add `sanitize_tool_message_pairing(messages: Vec<Value>) -> Vec<Value>`:
   - Removes orphaned tool messages (those without preceding assistant `tool_calls` with matching id)
   - Returns sanitized messages

4. Add `model_rejects_is_error_field(model: &str) -> bool`:
   - Returns `true` for models known to reject `is_error` (generalize beyond kimi: check for "kimi" as the key case)
   - Used in `translate_message()` to conditionally include/exclude `is_error`

5. Update retry constants:
   - `DEFAULT_INITIAL_BACKOFF: Duration = Duration::from_secs(1)` (was 200ms)
   - `DEFAULT_MAX_BACKOFF: Duration = Duration::from_secs(128)` (was 2s)
   - `DEFAULT_MAX_RETRIES: u32 = 8` (was 2)

6. Add `with_resilience_config()` builder method to `OpenAiCompatClient`

7. Split `send_message()`:
   - `send_message_without_recovery()` — current logic but with pre-flight checks
   - `send_message_with_recovery()` — wraps `RecoveryStateMachine` around the send logic
   - `send_message()` — dispatches based on `self.recovery_enabled`

8. Update `from_env()` to accept `ResilienceConfig` parameter or call `ResilienceConfig::from_env()` internally

**Preservation check:** DashScope constants MUST NOT be added. The body size limits are for OpenAI and xAI only.

---

### Phase 2: CLI Entry Point Expansion

These changes add the command infrastructure that Phase 3 will use for the launcher integration.

---

#### Step 2.1: Add `CliOutputFormat` to all CLI actions

**Files to modify:**
- `rust/crates/rusty-claude-cli/src/main.rs` — MODIFY

**Exact logic to add:**

1. Ensure `CliOutputFormat` enum exists (with `Text` and `Json` variants) — likely already present

2. Add `output_format: CliOutputFormat` field to every variant of `CliAction` that doesn't already have it:
   - `DumpManifests { output_format }`
   - `BootstrapPlan { output_format }`
   - `Agents { args, output_format }`
   - `Mcp { args, output_format }`
   - `Skills { args, output_format }`
   - `Plugins { action, target, output_format }`
   - `PrintSystemPrompt { cwd, date, output_format }`
   - `Version { output_format }`
   - `ResumeSession { session_path, commands, output_format }`
   - `Status { model, permission_mode, output_format, allowed_tools }`
   - `Sandbox { output_format }`
   - `Doctor { output_format }`
   - `Acp { output_format }`
   - `State { output_format }`
   - `Init { output_format }`
   - `Config { section, output_format }`
   - `Diff { output_format }`
   - `Export { session_reference, output_path, output_format }`
   - `Help { output_format }`

3. For each match arm in `run()`:
   - Pass `output_format` to the handler function
   - Handler writes JSON when `CliOutputFormat::Json`, text when `CliOutputFormat::Text`

---

#### Step 2.2: Add `read_piped_stdin()` and `merge_prompt_with_stdin()`

**Files to modify:**
- `rust/crates/rusty-claude-cli/src/main.rs` — MODIFY

**Exact logic to add:**

1. Add `use std::io::IsTerminal;` import

2. Add function `read_piped_stdin() -> Option<String>`:
   - Check `io::stdin().is_terminal()` — if terminal, return None
   - Try `io::stdin().read_to_string(&mut buffer)` — if error, return None
   - If `buffer.trim().is_empty()`, return None
   - Return `Some(buffer)`

3. Add function `merge_prompt_with_stdin(prompt: &str, stdin_content: Option<&str>) -> String`:
   - If stdin_content is None or empty trim, return prompt
   - If prompt is empty, return trimmed stdin
   - Otherwise return `format!("{prompt}\n\n{trimmed}")`

4. In `CliAction::Prompt` handler:
   - Call `read_piped_stdin()` only when `permission_mode` is `DangerFullAccess` (to avoid consuming stdin needed for interactive prompts)
   - Call `merge_prompt_with_stdin()` with the result
   - Use the merged prompt instead of the raw prompt for the turn

---

#### Step 2.3: Add `ModelProvenance` tracking

**Files to modify:**
- `rust/crates/rusty-claude-cli/src/main.rs` — MODIFY

**Exact logic to add:**

1. Add `ModelSource` enum: `Flag`, `Env`, `Config`, `Default` variants with `as_str()` method

2. Add `ModelProvenance` struct:
   - `resolved: String` — final model string after alias resolution
   - `raw: Option<String>` — raw user input before alias resolution
   - `source: ModelSource` — where the model came from

3. Add constructors:
   - `ModelProvenance::default_fallback()` — sets resolved to `DEFAULT_MODEL`, source to `Default`
   - `ModelProvenance::from_flag(raw)` — resolves alias, sets source to `Flag`
   - `ModelProvenance::from_env_or_config_or_default(cli_model)` — probes `ANTHROPIC_MODEL` env var, then config file, then default

4. In `CliAction::Status`, add `model_flag_raw: Option<String>` field to carry the raw `--model` flag (if any) separately from the resolved model string.

---

#### Step 2.4: Add new CliAction variants (Config, Diff, Export, Doctor)

**Files to modify:**
- `rust/crates/rusty-claude-cli/src/main.rs` — MODIFY
- `rust/crates/runtime/src/config.rs` — MODIFY (if needed for Config diff)

**Exact logic to add:**

1. Add `CliAction::Config { section: Option<String>, output_format: CliOutputFormat }`:
   - Text mode: call `render_config_report(section)` and print
   - JSON mode: call `render_config_json(section)` and serialize

2. Add `CliAction::Diff { output_format: CliOutputFormat }`:
   - Text mode: call `render_diff_report()` and print
   - JSON mode: get `env::current_dir()`, call `render_diff_json_for(&cwd)` and serialize

3. Add `CliAction::Export { session_reference: String, output_path: Option<PathBuf>, output_format: CliOutputFormat }`:
   - Calls `run_export(&session_reference, output_path, output_format)`

4. Add `CliAction::Doctor { output_format: CliOutputFormat }`:
   - Calls `run_doctor(output_format)` — verifies API key, model access, tool configuration

5. Add `CliAction::Plugins { action: Option<String>, target: Option<String>, output_format: CliOutputFormat }`:
   - Calls `LiveCli::print_plugins(action, target, output_format)`

**IMPORTANT:** For `Config`, `Diff`, and `Export`, ensure the handler functions exist in the current branch or add them as lightweight implementations. Do NOT depend on localfork's `session_control.rs`, `stale_base.rs`, or `policy_engine.rs` modules — these should remain stubs or simple implementations that don't pull in new module files.

---

### Phase 3: Launcher Integration

These changes replace the shell scripts with native Rust commands.

---

#### Step 3.1: Add `ClawSetup` subcommand for launcher shortcuts

**Files to modify:**
- `rust/crates/rusty-claude-cli/src/main.rs` — MODIFY
- `rust/crates/rusty-claude-cli/src/setup.rs` — NEW FILE

**Exact logic to add:**

1. In `main.rs`, add to `CliAction` enum:
   ```rust
   ClawSetup {
       provider: ClawSetupKind,
       model: Option<String>,
       output_format: CliOutputFormat,
   }
   ```

2. Define `ClawSetupKind` enum:
   ```rust
   #[derive(Debug, Clone, Copy, PartialEq, Eq)]
   enum ClawSetupKind {
       LmStudio,
       OpenRouter,
   }
   ```

3. In `parse_args()`, match `"setup"` subcommand:
   ```
   "setup" => match args.get(1).map(|s| s.as_str()) {
       Some("lmstudio") | Some("lm") => Ok(CliAction::ClawSetup {
           provider: ClawSetupKind::LmStudio,
           model: args.get(2).cloned(),
           output_format,
       }),
       Some("openrouter") | Some("or") => Ok(CliAction::ClawSetup {
           provider: ClawSetupKind::OpenRouter,
           model: args.get(2).cloned(),
           output_format,
       }),
       _ => Err("Usage: claw setup <lmstudio|openrouter> [model]".to_string()),
   },
   ```

4. In `run()` dispatch:
   ```rust
   CliAction::ClawSetup { provider, model, output_format } => {
       setup::handle_setup(provider, model, output_format)?;
   }
   ```

5. Create `rust/crates/rusty-claude-cli/src/setup.rs` with module contents:

```rust
use std::path::PathBuf;
use anyhow::Result;

pub enum SetupProvider {
    LmStudio,
    OpenRouter,
}

pub fn handle_setup(
    provider: SetupProvider,
    model: Option<String>,
    output_format: CliOutputFormat, // from main.rs — may need to be in its own module
) -> Result<()> {
    match provider {
        SetupProvider::LmStudio => setup_lmstudio(model),
        SetupProvider::OpenRouter => setup_openrouter(model),
    }
}

fn setup_lmstudio(model_hint: Option<String>) -> Result<()> {
    // See Step 3.2 for full implementation
    unimplemented!()
}

fn setup_openrouter(model_hint: Option<String>) -> Result<()> {
    // See Step 3.3 for full implementation
    unimplemented!()
}
```

---

#### Step 3.2: Implement `setup_lmstudio()` — LM Studio launcher

**Files to modify:**
- `rust/crates/rusty-claude-cli/src/setup.rs` — MODIFY

**Exact logic to add:**

Replace the `setup_lmstudio()` stub with:

1. **Address discovery** (mirroring the shell script's probing):
   ```rust
   fn discover_lmstudio_address() -> Result<String> {
       let recent_file = get_recent_file_path();
       let configured_host = env::var("LM_STUDIO_HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
       let configured_port = env::var("LM_STUDIO_PORT")
           .ok()
           .and_then(|p| p.parse::<u16>().ok())
           .unwrap_or(1234u16);

       // 1. Try configured host:port directly
       let addr = format!("{}:{}", configured_host, configured_port);
       if probe_address(&addr).await? {
           save_recent_address(&addr)?;
           return Ok(addr);
       }

       // 2. Try recent addresses (most recent first)
       if let Some(recent_addrs) = load_recent_addresses()? {
           for addr in recent_addrs {
               if probe_address(&addr).await? {
                   save_recent_address(&addr)?;
                   return Ok(addr);
               }
           }
       }

       // 3. Try localhost candidates
       for candidate in &["127.0.0.1:1234", "localhost:1234"] {
           if probe_address(candidate).await? {
               save_recent_address(candidate)?;
               return Ok(candidate.to_string());
           }
       }

       Err(anyhow::anyhow!(
           "Could not find LM Studio server. Is it running?\n\
            Tried: {}:{}, recent addresses, localhost:1234\n\
            Set LM_STUDIO_HOST and LM_STUDIO_PORT env vars to configure.",
           configured_host, configured_port
       ))
   }
   ```

2. **Address probing**:
   ```rust
   async fn probe_address(host_port: &str) -> Result<bool> {
       let url = format!("http://{}/v1/models", host_port);
       let client = reqwest::Client::new();
       match client.get(&url).timeout(Duration::from_secs(3)).send().await {
           Ok(resp) if resp.status().is_success() => Ok(true),
           _ => Ok(false),
       }
   }
   ```

3. **Recent address persistence** (using `~/.lmstudio_recent_ips` file):
   ```rust
   fn get_recent_file_path() -> PathBuf {
       dirs::home_dir().unwrap_or_default().join(".lmstudio_recent_ips")
   }

   fn load_recent_addresses() -> Result<Option<Vec<String>>> {
       let path = get_recent_file_path();
       if !path.exists() { return Ok(None); }
       let content = fs::read_to_string(&path)?;
       let addrs: Vec<String> = content.lines()
           .map(|l| l.trim().to_string())
           .filter(|l| !l.is_empty())
           .rev()  // most recent first
           .collect();
       Ok(Some(addrs))
   }

   fn save_recent_address(addr: &str) -> Result<()> {
       let path = get_recent_file_path();
       let mut addrs = load_recent_addresses()?.unwrap_or_default();
       // Remove duplicate, insert at front
       addrs.retain(|a| a != addr);
       addrs.insert(0, addr.to_string());
       // Keep max 10 entries
       addrs.truncate(10);
       fs::write(&path, addrs.join("\n"))?;
       Ok(())
   }
   ```

4. **Model list fetching**:
   ```rust
   async fn fetch_models(host_port: &str) -> Result<Vec<String>> {
       let url = format!("http://{}/v1/models", host_port);
       let client = reqwest::Client::new();
       let resp = client.get(&url).send().await?;
       let data: serde_json::Value = resp.json().await?;
       let models: Vec<String> = data["data"]
           .as_array()
           .ok_or_else(|| anyhow::anyhow!("Unexpected response format"))?
           .iter()
           .filter_map(|item| item["id"].as_str().map(|s| s.to_string()))
           .collect();
       Ok(models)
   }
   ```

5. **Environment setup and launch** (uses `ResilienceConfig::force_enable()`):
   ```rust
   fn launch_claw_with_lmstudio(model: &str, host_port: &str) -> Result<()> {
       let (host, port) = host_port.split_once(':').unwrap_or((host_port, "1234"));
       
       // Set env vars matching the shell script's behavior
       std::env::set_var("ANTHROPIC_BASE_URL", format!("http://{}:{}", host, port));
       std::env::set_var("OPENAI_BASE_URL", format!("http://{}:{}/v1", host, port));
       std::env::set_var("OPENAI_API_KEY", "local-model");
       // CLAW_RESILIENCE=force is read by ResilienceConfig::from_env()
       std::env::set_var("CLAW_RESILIENCE", "force");
       
       // Build the provider client with force-enabled resilience
       let resilience_config = ResilienceConfig::force_enable();
       let provider_client = ProviderClient::from_model_with_anthropic_auth(
           model, None, None
       )?;
       // The provider client reads CLAW_RESILIENCE internally via from_env()
       
       // Launch the REPL with the configured client
       // (Reuses the existing run_repl path)
       Ok(())
   }
   ```

**IMPORTANT:** The env-var approach mirrors the shell script's behavior. `CLAW_RESILIENCE=force` is read by `ResilienceConfig::from_env()` (which is called inside `ProviderClient::from_model_with_anthropic_auth()` when that function is implemented as in Step 1.6).

**Key behavioral differences from the shell script:**
- Instead of executing `claw` as a subprocess, call the Rust functions directly within the same process (use the existing `LiveCli::new()` or `run_repl()` code path)
- The model list is fetched via `reqwest` (Rust native) instead of `python3` subprocess
- Address probing uses `reqwest::Client::get()` with timeout instead of `urllib.request`

---

#### Step 3.3: Implement `setup_openrouter()` — OpenRouter launcher

**Files to modify:**
- `rust/crates/rusty-claude-cli/src/setup.rs` — MODIFY

**Exact logic to add:**

Replace the `setup_openrouter()` stub with:

1. **API key management** (using file and env):
   ```rust
   fn get_openrouter_config_dir() -> PathBuf {
       dirs::home_dir().unwrap_or_default().join(".config").join("opencode")
   }

   fn load_openrouter_api_key() -> Result<String> {
       // 1. Check env
       if let Ok(key) = std::env::var("OPENROUTER_API_KEY") {
           if !key.is_empty() { return Ok(key); }
       }
       // 2. Check config file
       let env_file = get_openrouter_config_dir().join(".env");
       if env_file.exists() {
           let content = fs::read_to_string(&env_file)?;
           for line in content.lines() {
               if let Some(value) = line.strip_prefix("OPENROUTER_API_KEY=") {
                   return Ok(value.trim().to_string());
               }
           }
       }
       Err(anyhow::anyhow!(
           "OPENROUTER_API_KEY not found. Set it in your environment or run:\n\
            claw setup openrouter --set-key <your_key>"
       ))
   }

   fn save_openrouter_api_key(key: &str) -> Result<()> {
       let config_dir = get_openrouter_config_dir();
       fs::create_dir_all(&config_dir)?;
       let env_file = config_dir.join(".env");
       let content = format!("OPENROUTER_API_KEY={}\n", key);
       fs::write(&env_file, &content)?;
       // Set restrictive permissions on Unix
       #[cfg(unix)]
       {
           use std::os::unix::fs::PermissionsExt;
           fs::set_permissions(&env_file, std::fs::Permissions::from_mode(0o600))?;
       }
       Ok(())
   }
   ```

2. **Model catalog fetching** (simplified — no TUI/fzf browser, use a cached TSV or simple selection):
   ```rust
   async fn fetch_openrouter_models() -> Result<Vec<ModelInfo>> {
       let url = "https://openrouter.ai/api/v1/models?supported_parameters=tools";
       let client = reqwest::Client::new();
       let resp = client.get(url)
           .header("Authorization", format!("Bearer {}", load_openrouter_api_key()?))
           .send()
           .await?;
       let data: serde_json::Value = resp.json().await?;
       let models: Vec<ModelInfo> = data["data"]
           .as_array()
           .ok_or_else(|| anyhow::anyhow!("Unexpected response format"))?
           .iter()
           .filter(|m| {
               m.get("supported_parameters")
                   .and_then(|p| p.as_array())
                   .map(|arr| arr.iter().any(|v| v == "tools"))
                   .unwrap_or(false)
           })
           .map(|m| {
               ModelInfo {
                   id: m["id"].as_str().unwrap_or("").to_string(),
                   name: m["name"].as_str().unwrap_or("").to_string(),
                   context_length: m["context_length"].as_u64().unwrap_or(0),
                   pricing_prompt: m["pricing"]["prompt"].as_f64().unwrap_or(0.0),
                   pricing_completion: m["pricing"]["completion"].as_f64().unwrap_or(0.0),
               }
           })
           .collect();
       Ok(models)
   }
   ```

3. **Environment setup and launch** (uses `ResilienceConfig::force_disable()`):
   ```rust
   fn launch_claw_with_openrouter(model: &str) -> Result<()> {
       let api_key = load_openrouter_api_key()?;
       
       std::env::set_var("OPENAI_BASE_URL", "https://openrouter.ai/api/v1");
       std::env::set_var("OPENAI_API_KEY", &api_key);
       std::env::set_var("HTTP_REFERER", "https://localhost");
       std::env::set_var("X_TITLE", "claw-code");
       // CLAW_RESILIENCE=none — OpenRouter is cloud, no retry needed
       std::env::set_var("CLAW_RESILIENCE", "none");
       
       // Reuse existing run_repl path
       Ok(())
   }
   ```

4. **CLI for key management** — add to `ClawSetup`:
   ```rust
   // In setup_openrouter handler:
   pub fn handle_setup_openrouter_set_key(key: String) -> Result<()> {
       save_openrouter_api_key(&key)?;
       println!("OpenRouter API key saved to {}", 
                get_openrouter_config_dir().join(".env").display());
       Ok(())
   }
   ```

**Key behavioral differences from the shell script:**
- NO TUI/fzf browser for model selection — use a simpler CLI flag like `claw setup openrouter <model>` to specify directly, OR print a numbered list to stdout
- The shell script's 500-line TUI browser code is NOT replicated in Rust; instead provide a `--list-models` flag that prints models in a machine-readable format (JSON or text table)
- Recent models are tracked in-memory or via a simple file, not through the shell script's `RECENTS_FILE` format

---

#### Step 3.4: Add `/resilience` slash command with display

**Files to modify:**
- `rust/crates/commands/src/lib.rs` — MODIFY

**Exact logic to add:**

1. In the `SLASH_COMMAND_SPECS` table, add:
   ```rust
   SlashCommandSpec {
       name: "resilience",
       aliases: &[],
       summary: "Show or set resilience mode (force|none|auto)",
       argument_hint: Some("[force|none|auto]"),
       resume_supported: true,
   },
   ```

2. In the `SlashCommand` enum, add:
   ```rust
   Resilience {
       mode: Option<String>,
   },
   ```

3. In `validate_slash_command_input()`, add parser:
   ```rust
   "resilience" => SlashCommand::Resilience {
       mode: optional_single_arg(command, &args, "[force|none|auto]")?,
   },
   ```

4. In `slash_name()`, add:
   ```rust
   Self::Resilience { .. } => "/resilience",
   ```

5. In the calling code (main.rs where slash commands are dispatched), handle `Resilience`:
   ```rust
   SlashCommand::Resilience { mode } => {
       match mode.as_deref() {
           Some("force") => {
               std::env::set_var("CLAW_RESILIENCE", "force");
               println!("Resilience mode set to: force (enabled on all providers)");
           }
           Some("none") => {
               std::env::set_var("CLAW_RESILIENCE", "none");
               println!("Resilience mode set to: none (disabled on all providers)");
           }
           Some("auto") | None => {
               std::env::remove_var("CLAW_RESILIENCE");
               println!("Resilience mode set to: auto (auto-detect localhost)");
           }
           _ => {
               println!("Usage: /resilience [force|none|auto]");
           }
       }
   }
   ```

---

#### Step 3.5: Add model presentation to status output

**Files to modify:**
- `rust/crates/rusty-claude-cli/src/main.rs` — MODIFY

**Exact logic to add:**

In the `print_status_snapshot()` function (or wherever model info is printed), include:

```rust
// Show the model provenance
let provenance = ModelProvenance::from_env_or_config_or_default(&model);
match output_format {
    CliOutputFormat::Text => {
        println!("Model:  {}  (source: {})", provenance.resolved, provenance.source.as_str());
        if let Some(raw) = &provenance.raw {
            println!("        raw input: {}", raw);
        }
    }
    CliOutputFormat::Json => {
        println!("{}", serde_json::json!({
            "model": {
                "resolved": provenance.resolved,
                "source": provenance.source.as_str(),
                "raw": provenance.raw,
            }
        }));
    }
}
```

---

### Phase 4: Testing

#### Step 4.1: Unit tests for `local_model_recovery.rs`

**Files to modify:**
- `rust/crates/api/tests/local_model_recovery_integration.rs` — NEW FILE

**Tests to add:**
- `error_classifier_identifies_model_unloaded_from_400_body()` — provide `ApiError::Api { status: 400 }` with body containing "Model unloaded", assert returns `RetryableErrorKind::ModelUnloaded`
- `error_classifier_identifies_transport_error()` — provide `ApiError::Http` with connect error, assert returns `TransportError`
- `error_classifier_returns_non_retryable_for_auth()` — provide `ApiError::MissingCredentials`, assert returns `NonRetryable`
- `health_profile_degrades_streaming_after_two_empty_streams()` — call `mark_empty_stream()` twice, assert `should_use_streaming()` returns false
- `health_profile_increases_timeout_after_first_token_stall()` — call `mark_first_token_timeout()`, assert `first_token_timeout_ms` increased
- `recovery_state_machine_stops_after_max_attempts()` — create with `max_recovery_attempts: 3`, call `next_attempt()` 3 times, assert `has_more_attempts()` returns false
- `recovery_state_machine_mutates_request_to_non_streaming_after_recovery()` — simulate model-unloaded, call `mutate_request_for_attempt(attempt=2)`, assert `stream: false`

#### Step 4.2: Unit tests for setup module

**Files to modify:**
- `rust/crates/rusty-claude-cli/tests/setup_integration.rs` — NEW FILE

**Tests to add:**
- `probe_address_returns_true_for_local_server()` — start minimal HTTP server on random port, probe it
- `probe_address_returns_false_for_unreachable_port()` — probe a closed port, assert false
- `recent_address_roundtrip()` — save an address, load it, assert it matches
- `model_parsing_from_json_response()` — provide a mock JSON body matching LM Studio's `/v1/models` format, assert parsed correctly

#### Step 4.3: Unit tests for `/resilience` command

**Files to modify:**
- `rust/crates/commands/src/lib.rs` — existing test module

**Tests to add:**
- `parse_resilience_with_force()` — assert `parse("/resilience force")` returns `SlashCommand::Resilience { mode: Some("force") }`
- `parse_resilience_with_none()` — assert `parse("/resilience none")` returns mode `Some("none")`
- `parse_resilience_without_args()` — assert `parse("/resilience")` returns mode `None`
- `resilience_in_slash_command_specs()` — assert spec table includes resilience entry

---

## Risks and Regression Concerns

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Accidental DashScope re-introduction** — copying localfork's `openai_compat.rs` wholesale includes `dashscope()` constructor and constants | Medium | High — breaks inventory contract | Code review gate: grep for "dashscope", "DASHSCOPE", "kimi" after implementation. The plan explicitly excludes DashScope. |
| **CLI behavior change** — adding `CliOutputFormat` to existing actions changes their return type | Low | Medium — existing callers might break | Default `output_format` to `Text` via `Default` trait. Existing subcommands remain text-only unless explicitly passed `--json`. |
| **Env var conflicts** — `setup_lmstudio()` sets `CLAW_RESILIENCE=force` which could override user's explicit `none` setting | Medium | Low — user env vars are read at startup, not after | `setup_lmstudio()` should check if `CLAW_RESILIENCE` is already set by the user and warn if override occurs. |
| **Windows path issues** — `~/.config/opencode/.env` and `~/.lmstudio_recent_ips` are Unix conventions | Low | Medium — OpenRouter API key storage | For MVP, add a `#[cfg(windows)]` path that uses `%APPDATA%` instead of `~/.config`. Document this limitation. |
| **Model list fetch failures** — LM Studio or OpenRouter may be unreachable | Medium | Medium — launcher fails gracefully | Use `timeout` on HTTP requests (3s probe, 10s catalog fetch). Wrap in `ResilienceConfig` retry for transient failures. |
| **Removal of `/login` or `/logout` breaks external tools** — tools that depend on these slash commands | Low | Low — these are rarely used programmatically | Replace with a stub that prints a deprecation notice for one release cycle, pointing to `ANTHROPIC_API_KEY` env var. |
| **`output_format` on `CliAction::Help`** — changes help output structure | Low | Low — help is human-readable | When output_format is Json, render help as structured JSON (categories as arrays of objects). When Text, use existing format. |

---

## Validation Checklist

After implementation, verify:

1. **`claw setup lmstudio qwen3:14b`** probes localhost:1234, fetches model list (or uses the provided model), sets env vars (`OPENAI_BASE_URL`, `OPENAI_API_KEY`, `CLAW_RESILIENCE=force`), and launches REPL
2. **`claw setup openrouter deepseek/deepseek-v4-pro`** reads/loads API key, sets env vars (`OPENAI_BASE_URL=https://openrouter.ai/api/v1`, `CLAW_RESILIENCE=none`), and launches REPL
3. **`claw setup openrouter --set-key sk-or-...`** saves the key to `~/.config/opencode/.env` with restrictive permissions
4. **`claw doctor --json`** prints structured JSON output with model, auth, and tool configuration
5. **`echo "hello" | claw prompt`** reads piped stdin, merges with prompt, and processes
6. **`/resilience force`** sets `CLAW_RESILIENCE=force`; **`/resilience`** shows current mode
7. **`claw status --json`** shows model provenance `{ "resolved": "...", "source": "flag|env|config|default" }`
8. **`claw setup openrouter --list-models`** fetches and prints tool-capable OpenRouter models
9. **LM Studio address auto-discovery** — when `LM_STUDIO_HOST` is unreachable but `localhost:1234` responds, it auto-selects localhost
10. **Recent address persistence** — after successful LM Studio connection, address is saved to `~/.lmstudio_recent_ips` and tried first on subsequent runs
11. **Error handling** — when LM Studio or OpenRouter are unreachable, user gets a clear error message suggesting next steps
12. **Resilience layer integration** — local models use `force_enable` retry config, OpenRouter uses `force_disable` (no retries)
13. **No DashScope references** — `grep -ri "dashscope\|DASHSCOPE\|kimi" rust/crates/api/` returns empty
14. **Existing tests pass** — `cargo test --workspace` with no regressions
