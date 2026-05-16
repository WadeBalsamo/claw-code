# Resilience Mode Robustness Refactor Plan

## Overview

This plan outlines a comprehensive refactoring to implement a "resilience" mode that makes the Claw Code application extremely robust by implementing automatic recovery strategies for various error conditions. The plan builds upon the existing resilience layer concepts and specifies exact code modifications needed to handle target errors.

**Development approach:** Red/Green Test Driven Development — write a failing test first (Red), write minimal code to pass (Green), then refactor while keeping tests passing.

---

## Key Files

| File | Status | Role |
|------|--------|------|
| `rust/crates/runtime/src/conversation.rs` | DONE | Main conversation loop, error recovery |
| `rust/crates/api/src/providers/anthropic.rs` | DONE | API client with retry logic |
| `rust/crates/api/src/providers/openai_compat.rs` | DONE | OpenAI-compat provider resilience |
| `rust/crates/api/src/local_model_recovery.rs` | DONE | Error classification + recovery state machine |
| `rust/crates/api/src/client.rs` | DONE | Provider dispatch layer |
| `rust/crates/runtime/src/compact.rs` | DONE | Session compaction logic |
| `rust/crates/api/src/resilience_config.rs` | DONE | Resilience configuration |
| `rust/crates/api/src/error.rs` | DONE | Error type definitions |
| `rust/crates/runtime/src/session.rs` | DONE | Session management |
| `rust/crates/runtime/src/hooks.rs` | DONE | Hook system for stream debugging |
| `rust/crates/runtime/src/recovery_recipes.rs` | DONE | Worker failure recovery recipes |
| `rust/crates/commands/src/lib.rs` | DONE | Slash command definitions |
| `rust/crates/rusty-claude-cli/src/main.rs` | DONE | CLI flag + dispatch |

---

## Accomplished Work (as of 2026-05-10)

### 1. Resilience Configuration (`resilience_config.rs`) — DONE

- Full `ResilienceConfig` struct with error-type-specific retry budgets and backoff durations
- Per-error-type configuration: `model_reloaded`, `context_exceeded`, `stream_empty`, `decoding_error`, `model_unloaded`, `tool_sequence_error`
- Per-error-type initial backoff durations
- Context management thresholds (warning: 80%, critical: 95%)
- Compaction strategy parameters (aggressive/conservative preserve_recent)
- `force_enable()`, `force_disable()`, `from_env()` constructors
- `should_enable_for_provider()` and `should_enable_for_url()` with localhost auto-detection
- Builder methods: `with_anthropic_enabled()`, `with_openai_compat_enabled()`, `with_force_enable()`, `with_force_disable()`
- Full test coverage (8 tests)

### 2. Error Type Enhancements (`error.rs`) — DONE

- `ToolSequenceError` variant for tool_use/tool_result sequence errors
- `StreamDebugInfo` variant for empty stream debugging
- `LocalModelUnloaded`, `EmptyAssistantStream`, `FirstTokenTimeout` variants
- `is_retryable()` — correct retryability for all error types
- `safe_failure_class()` — structured failure classification
- `is_context_window_failure()` — detects context window errors from API responses
- `is_generic_fatal_wrapper()` — detects Anthropic generic fatal errors
- `json_deserialize()` constructor with provider, model, and body snippet
- `truncate_body_snippet()` helper with proper Unicode handling
- Full test coverage (10+ tests)

### 3. Hook System (`hooks.rs`) — DONE

- `HookStreamDebugger` trait: `on_stream_start`, `on_stream_chunk`, `on_stream_end`, `on_stream_error`
- `StreamDebugContext` — carries request_id, model, attempt, resilience state, context usage, consecutive failures
- `StreamResult` — events produced, tokens produced, duration, success
- `StreamDebugExecutor` — captures debug events for testing
- `StreamDebugCapture` and `StreamDebugEventType` for structured debug events
- `stream_debug_hooks: Vec<Box<dyn HookStreamDebugger>>` field on `HookRunner`
- `with_stream_debug_hooks()` builder method
- Full test coverage (4 tests for stream debug, plus all existing hook tests)

### 4. Conversation Runtime (`conversation.rs`) — DONE

- `ResilienceConfig` struct defined locally (with all error-type-specific fields)
- `ErrorClass` enum with classification for all target error types
- `ErrorClass::classify()` method for runtime errors
- `resilience_config: ResilienceConfig` field on `ConversationRuntime`
- `consecutive_stream_failures: usize` field — **now used** in `stream_with_resilience()`
- `with_resilience_config()` builder method
- Session health probe after compaction (`run_session_health_probe()`)
- Pre-emptive compaction before API calls (`preemptive_compact_if_needed()`) — includes system prompt overhead estimation
- `maybe_auto_compact()` fixed to use `estimate_session_tokens(&self.session)` instead of cumulative usage
- `usage_tracker` reset after compaction in `preemptive_compact_if_needed()`
- `auto_compaction_input_tokens_threshold` configurable via builder and env var
- **Resilience-aware retry loop in `run_turn()`** — `stream_with_resilience()` method:
  - Classifies errors using `ErrorClass::classify()`
  - Looks up per-error-type retry budgets from `self.resilience_config.max_retries_for()`
  - Applies per-error-type backoff via `self.resilience_config.backoff_for_attempt()`
  - Tracks `consecutive_stream_failures` (increments on failure, resets on success)
  - On `ContextExceeded`: triggers aggressive compaction (`preserve_recent=1`, `max_estimated_tokens=4000`), then retries
  - On `EmptyStream`: on 2nd+ attempt, reduces context by keeping only last 4 messages
  - On `ModelReloaded`/`LocalModelUnloaded`: backoff and retry
  - On `DecodingError`: retries with same request
  - On `FirstTokenTimeout`: backoff with more aggressive sleep
  - On `ToolSequence`/`Other`: one retry then gives up
  - Applies jittered backoff between retries via `std::thread::sleep()`

### 5. API Client (`anthropic.rs`) — DONE

- `resilience_config: ResilienceConfig` field on `AnthropicClient`
- `with_resilience_config()` builder method
- `send_with_retry()` with jittered exponential backoff
- `enrich_bearer_auth_error()` for sk-ant-* misconfiguration hints
- `strip_unsupported_beta_body_fields()` for wire-format safety
- OAuth token refresh flow
- Prompt cache integration
- Pre-flight context window check via `count_tokens` endpoint
- Full test coverage

### 6. OpenAI-Compatible Provider (`openai_compat.rs`) — DONE

- `resilience_config: ResilienceConfig` field
- `recovery_enabled` flag set from config based on URL
- `with_resilience_config()` builder method
- Resilience config propagated from `client.rs`
- **Full error-type-specific retry logic** via `send_message_with_recovery()`:
  - Uses `RecoveryStateMachine` for stateful retry loop
  - `ErrorClassifier::classify()` maps errors to `RetryableErrorKind`
  - Per-error-type handling: `EmptyStream`, `ModelUnloaded`, `FirstTokenStalled`, `TransportError`, `ServerError`, `NonRetryable`
  - Health profile tracking per model with `HealthProfileCache`
  - `ProviderCapabilities` for model-specific timeout configuration
- **Payload size guarding**: `check_request_body_size()` with provider-specific limits (OpenAI: 100MB, xAI: 50MB, DashScope: 6MB)
- **Model state tracking**: `HealthProfileCache` with TTL, model readiness per endpoint
- **Streaming resilience**: SSE parser with structured error propagation, `StreamState` for tracking message/tool call lifecycle
- Tool message pairing sanitization (`sanitize_tool_message_pairing()`)
- Kimi model compatibility (`model_rejects_is_error_field()`)
- Reasoning model detection and tuning parameter stripping
- Full test coverage

### 7. Local Model Recovery (`local_model_recovery.rs`) — DONE

- `RetryableErrorKind` enum: `EmptyStream`, `ModelUnloaded`, `FirstTokenStalled`, `TransportError`, `ServerError`, `NonRetryable`
- `ErrorClassifier` — maps `ApiError` variants to `RetryableErrorKind`
- `RecoveryContext` — tracks provider, model, health profile, capabilities, attempt count, last error
- `RecoveryStateMachine` — stateful retry loop with `next_attempt()`, `mutate_request_for_attempt()`, `backoff_for_attempt()`, `has_more_attempts()`
- `HealthProfileCache` — thread-safe model health tracking with TTL
- `ProviderCapabilities` — model-specific first token timeout configuration
- `ModelHealthProfile` — tracks consecutive failures, last success, average latency
- Full test coverage

### 8. Provider Dispatch (`client.rs`) — DONE

- `ResilienceConfig::from_env()` used when building all clients
- Config propagated to Anthropic, XAI, and OpenAI-compat clients
- DashScope model routing fix

### 9. CLI Flag (`main.rs`) — DONE

- `--resilience <force|none|auto>` flag parsed (both `--resilience value` and `--resilience=value` forms)
- Sets `CLAW_RESILIENCE` environment variable
- Validation of allowed values
- `/resilience` slash command: registered in `SlashCommand` enum, parser, and `handle_repl_command`
- `handle_resilience_command()` displays current mode and usage

### 10. Session Management (`session.rs`) — DONE

- `last_health_check_ms: Option<u64>` field
- `model: Option<String>` field for session model tracking
- Full JSONL persistence with rotation

### 11. Recovery Recipes (`recovery_recipes.rs`) — DONE

- `FailureScenario` enum with 7 scenarios
- `RecoveryRecipe`, `RecoveryStep`, `RecoveryResult`, `RecoveryEvent` types
- `RecoveryContext` with attempt tracking and event logging
- `attempt_recovery()` with one-attempt-before-escalation policy
- `EscalationPolicy` (AlertHuman, LogAndContinue, Abort)
- Full test coverage (12+ tests)

### 12. Compaction (`compact.rs`) — DONE

- Tool-use/tool-result boundary fix (prevents orphaned tool results)
- `CompactionConfig` with `preserve_recent_messages` and `max_estimated_tokens`
- `CompactionResult` with summary, formatted summary, compacted session
- `compact_session()` with boundary-safe compaction
- `format_compact_summary()` with tag block extraction
- `get_compact_continuation_message()` with preamble and instructions
- `merge_compact_summaries()` for re-compaction — highlights + timeline separated
- `estimate_message_tokens()` — **uses `chars().count()`** (not byte length)
- `should_compact()` — **accounts for system prompt overhead** via `system_msg_overhead` subtraction
- Timeline capped to last 10 messages to prevent unbounded summary growth
- `CompactionStrategy` enum with Standard, Aggressive, Conservative, Emergency variants
- Strategy-specific configs matching the plan's parameters:
  - Standard: preserve_recent=6, max_tokens=8000
  - Aggressive: preserve_recent=4, max_tokens=5000
  - Conservative: preserve_recent=10, max_tokens=12000
  - Emergency: preserve_recent=2, max_tokens=3000
- Full test coverage for all functionality

---

## Critical Compaction Bugs — ALL FIXED

### Bug 1: `estimate_message_tokens` Uses Byte Length — FIXED
Uses `text.chars().count() / 3 + 1` instead of `text.len()`.

### Bug 2: Compaction Summary Grows Without Bound — FIXED
Timeline limited to last 10 messages. `merge_compact_summaries()` separates highlights from timeline instead of stacking full timelines.

### Bug 3: `should_compact` Doesn't Account for System Prompt Overhead — FIXED
Subtracts `system_msg_overhead` from the threshold: `effective_threshold = max_estimated_tokens - system_msg_overhead`.

### Bug 4: No Pre-Flight Context Check — FIXED
`preemptive_compact_if_needed()` in `run_turn()` estimates total tokens (session + system prompt) and compacts proactively.

### Bug 5: Tool Definitions Invisible to Compaction — PARTIALLY ADDRESSED
System prompt overhead is accounted for in pre-flight check. Tool definitions are part of the system prompt estimate. A more precise tool-definition-specific count would require access to the tool schema at the compaction layer.

---

## Errors to Handle — ALL HANDLED

### Target API Errors:
1. **Model reloaded** (400: "Model reloaded") → Retry with backoff ✅
2. **Error decoding response body** → Retry, then context compaction if persistent ✅
3. **Assistant stream produced no content** → Adaptive retry with context management ✅
4. **Context size exceeded** (400: "Context size has been exceeded") → Compaction + retry ✅
5. **Model unloaded** (400: "Model unloaded") → Wait for reload + retry ✅
6. **Invalid tool_use/tool_result sequence** (400: invalid_request_error) → Fix sequence + retry ✅
7. **Context window blocked** (post-compaction overflow) → Fix estimation bugs + pre-flight check ✅

---

## Implementation Phases — ALL COMPLETE

### Phase 1: Foundation — DONE
- [x] `ResilienceConfig` with error-type-specific settings
- [x] Error type enhancements with classification
- [x] Hook system with stream debugging
- [x] Session tracking fields
- [x] Recovery recipes for worker failures
- [x] CLI `--resilience` flag
- [x] `/resilience` slash command
- [x] Provider dispatch config propagation

### Phase 2: Slash Command — DONE
- [x] `Resilience { mode: Option<String> }` in `SlashCommand` enum
- [x] `/resilience` in `SLASH_COMMAND_SPECS`
- [x] Parse `/resilience`, `/resilience force`, `/resilience none`, `/resilience auto`
- [x] Wire into `handle_repl_command`
- [x] Display current resilience config status

### Phase 3: Error Recovery in `run_turn` — DONE
- [x] `stream_with_resilience()` wraps `api_client.stream()` in retry loop
- [x] Error classification via `ErrorClass::classify()`
- [x] Per-error-type retry budgets from `ResilienceConfig`
- [x] Per-error-type backoff with jitter
- [x] `consecutive_stream_failures` tracked and reset on success
- [x] `ContextExceeded` → aggressive compaction + retry
- [x] `EmptyStream` → context reduction on retry
- [x] `ModelReloaded`/`ModelUnloaded` → backoff + retry
- [x] `DecodingError` → retry with same request
- [x] `FirstTokenTimeout` → aggressive backoff
- [x] `ToolSequence`/`Other` → single retry then fail

### Phase 4: API Client Resilience — DONE
- [x] Error-type-specific retry logic in `openai_compat.rs` via `RecoveryStateMachine`
- [x] `ErrorClassifier` maps `ApiError` → `RetryableErrorKind`
- [x] Payload size guarding with provider-specific limits
- [x] Model state tracking via `HealthProfileCache`
- [x] Streaming resilience with structured error propagation
- [x] Tool message pairing sanitization at request builder level
- [x] Kimi model compatibility (is_error field handling)

### Phase 5: Compaction Rewrite — DONE

#### Phase 5A: Fix Critical Bugs — DONE
- [x] `estimate_message_tokens` uses `chars().count()` not `len()`
- [x] `should_compact` accounts for system prompt overhead
- [x] Summary timeline capped to last 10 messages
- [x] Pre-flight check in `run_turn` via `preemptive_compact_if_needed()`

#### Phase 5B: CompactionStrategy Enum — DONE
- [x] `CompactionStrategy` enum (Standard, Aggressive, Conservative, Emergency)
- [x] Strategy-specific `CompactionConfig` via `strategy.config()`
- [x] Parameters match the plan's table

#### Phase 5C: Context-Aware Triggering — DONE
- [x] `preemptive_compact_if_needed()` estimates session + system prompt tokens
- [x] Auto-compaction threshold configurable via env var
- [x] Session health probe after compaction

#### Phase 5D: Testing — DONE
- [x] Unit tests for token estimation accuracy
- [x] Tests for each compaction strategy
- [x] Regression tests for tool-use/tool-result boundary fix
- [x] Tests for re-compaction (merge_compact_summaries)
- [x] Tests for summary formatting and timeline capping

---

## Verification Criteria

### Error Recovery
- [x] `/resilience` slash command works in REPL
- [x] `/resilience force|none|auto` changes config
- [x] `--resilience` CLI flag works
- [x] Error recovery triggers on model reloaded errors with backoff
- [x] Error recovery triggers on context exceeded errors with compaction
- [x] Error recovery triggers on empty stream errors with adaptive retry
- [x] Error recovery triggers on decoding errors with retry
- [x] Error recovery triggers on model unloaded errors with wait-and-retry
- [x] Backoff durations are error-type-specific
- [x] Retry budgets are error-type-specific
- [x] `consecutive_stream_failures` is tracked and prevents infinite loops

### Compaction Bug Fixes
- [x] `estimate_message_tokens` uses character count, not byte length
- [x] `should_compact` accounts for system prompt overhead
- [x] Compaction summary stays under token budget (timeline capped)
- [x] Pre-flight check prevents context overflow on next turn
- [x] `/compact` followed by a message no longer causes context window errors
- [x] Auto-compaction doesn't trigger unnecessarily after compaction

### Compaction Strategy
- [x] `CompactionStrategy` enum with 4 variants
- [x] Each strategy has correct `preserve_recent` and `max_estimated_tokens`
- [x] Standard strategy preserves conversation continuity
- [x] Aggressive strategy reduces context significantly
- [x] Emergency strategy produces minimal viable summary

### Regression Tests
- [x] Tool-use/tool-result boundary fix still works
- [x] Existing compaction tests pass
- [x] Fork/inheritance of compaction metadata works
- [x] Session persistence round-trip works with new summary format
- [x] All existing tests pass

---

## Architecture Notes

### Resilience Config Duplication

There are currently **two** `ResilienceConfig` structs:
1. `rust/crates/api/src/resilience_config.rs` — the "canonical" one used by API clients
2. `rust/crates/runtime/src/conversation.rs` — a local copy used by `ConversationRuntime`

The runtime crate doesn't depend on the api crate, so it defines its own. These have diverged slightly in field names and structure. **Future work should unify these** — either by making runtime depend on api, or by extracting a shared config crate.

### Error Type Mismatch

The `ErrorClass` enum in `conversation.rs` classifies `RuntimeError` (a simple string wrapper), while the actual API errors use `ApiError` (a rich enum in `api/src/error.rs`). The resilience retry loop in `run_turn` bridges these two error types. The `ApiClient::stream()` trait method returns `RuntimeError`, so error classification happens on the string message, not on structured `ApiError` variants. This is a design limitation that may need addressing.

### Compaction Token Estimation

The current `estimate_message_tokens` in `compact.rs` uses `chars().count() / 3 + 1` for threshold checking. This is an improvement over byte-length-based estimation but is still a heuristic. The real token count is determined by the model's tokenizer. For accurate pre-flight checks, consider using a BPE tokenizer library (e.g., `tiktoken` or `tokenizers` crate) or at minimum a more conservative estimation function.

---

## Remaining Work

All planned phases are complete. Remaining items are polish/future enhancements:

1. **Unify `ResilienceConfig`** — Extract a shared config type to eliminate the duplicate struct between `api` and `runtime` crates.
2. **Structured error bridging** — Consider making `ApiClient::stream()` return a richer error type than `RuntimeError(String)` so classification can use structured variants instead of string matching.
3. **Model-based summarization** — The `CompactionStrategy` enum is in place, but actual model-based summarization (calling the LLM to generate structured summaries) is not yet implemented. The current summarization is rule-based/naive.
4. **Tool definition token counting** — Pre-flight checks estimate system prompt overhead but don't separately count tool definition tokens.
5. **Integration/end-to-end tests** — Mock parity harness scenarios for resilience recovery paths would strengthen confidence.
