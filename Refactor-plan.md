# Resiliance Mode Robustness Refactor Plan

## Overview
This plan outlines a comprehensive refactoring to implement a "resiliance" mode that makes the Claw Code application extremely robust by implementing automatic recovery strategies for various error conditions.
## NEW 

need to add to the plan an automatic fix for this: ✘ ❌ Request failed
[error-kind: unknown]
error: Context window blocked
  Failure class    context_window_blocked
  Session          session-1778876800738-0
  Detail           This endpoint's maximum context length is 1048756 tokens. However, you requested about 1137313 tokens (1069447 of text i…

Recovery
  Compact          /compact
  Resume compact   claw --resume session-1778876800738-0 /compact
  
## Accomplished Work (as of 2026-05-10)

### Completed Foundation
1. **Resilience Configuration** (`resilience_config.rs`):
   - Error-type-specific retry budgets and backoff configurations
   - Context management thresholds (warning: 80%, critical: 95%)
   - `force_enable()`, `force_disable()`, `from_env()` methods
   - `should_enable_for_provider()` and `should_enable_for_url()` methods
   - Full test coverage

2. **Error Type Enhancements** (`error.rs`):
   - `ToolSequenceError` variant for tool_use/tool_result sequence errors
   - `StreamDebugInfo` variant for empty stream debugging
   - `LocalModelUnloaded`, `EmptyAssistantStream`, `FirstTokenTimeout` variants
   - `is_retryable()`, `safe_failure_class()`, `is_context_window_failure()` methods

3. **Hook System Enhancements** (`hooks.rs`):
   - `HookStreamDebugger` trait with on_stream_start/chunk/end/error
   - `StreamDebugContext` and `StreamResult` structs
   - `StreamDebugExecutor` for testing and capturing debug info
   - `StreamDebugEventType` and `StreamDebugCapture` types
   - `stream_debug_hooks` field on `HookRunner`
   - All types exported from `lib.rs`

4. **Conversation Runtime** (`conversation.rs`):
   - `resilience_config: ResilienceConfig` field added
   - `new_with_features()` accepts `ResilienceConfig` parameter
   - Session health probe after compaction (`run_session_health_probe`)
   - `ResilienceConfig::default()` passed in `new()` constructor

5. **API Client** (`anthropic.rs`):
   - `resilience_config: ResilienceConfig` field on `AnthropicClient`
   - `with_resilience_config()` builder method
   - `rand::Rng` import added for jitter

6. **Provider Dispatch** (`client.rs`):
   - `ResilienceConfig::from_env()` used when building clients
   - Config propagated to Anthropic, XAI, and OpenAI-compat clients

7. **CLI Flag** (`main.rs`):
   - `--resilience <force|none|auto>` flag parsed
   - Sets `CLAW_RESILIENCE` environment variable
   - Validation of allowed values

8. **Session Management** (`session.rs`):
   - `last_health_check_ms: Option<u64>` field added

9. **Compaction** (`compact.rs`):
   - Tool-use/tool-result boundary fix to prevent orphaned tool results

### In Progress
1. **Slash Command**: `/resilience` command needs to be registered and wired
2. **Error Recovery Logic**: `run_turn` needs resilience-aware error handling
3. **Resilience Methods**: anthropic.rs needs stream_with_resilience, should_retry, etc.
4. **Compaction Strategies**: Need CompactionStrategy enum for context-aware compaction

### Pending
1. Full implementation of error handlers in conversation runtime
2. Complete API client resilience enhancements (all providers)
3. Compaction strategy implementations
4. Integration tests for end-to-end error recovery

## Errors to Handle

### Original Target Errors:
1. **Model reloaded** (400 Bad Request): `{"error":{"message":"Model reloaded."}}`
2. **Error decoding response body**: `http error: error decoding response body`
3. **Assistant stream produced no content**: Empty stream despite model producing tokens
4. **Context size exceeded** (400 Bad Request): `{"error":{"message":"Context size has been exceeded."}}`
5. **Model unloaded** (400 Bad Request): `{"error":{"message":"Model unloaded."}}`

### Newly Identified Errors:
6. **Invalid tool_use/tool_result sequence** (400 Bad Request, invalid_request_error)
7. **Enhanced assistant stream debugging**: Model produced tokens but stream came back empty

## Key Files Modified
1. `rust/crates/runtime/src/conversation.rs` - Main conversation loop (IN PROGRESS)
2. `rust/crates/api/src/providers/anthropic.rs` - API client (IN PROGRESS)
3. `rust/crates/api/src/client.rs` - Provider dispatch (COMPLETED)
4. `rust/crates/runtime/src/compact.rs` - Session compaction (IN PROGRESS)
5. `rust/crates/api/src/resilience_config.rs` - Resilience configuration (COMPLETED)
6. `rust/crates/api/src/error.rs` - Error type definitions (COMPLETED)
7. `rust/crates/runtime/src/session.rs` - Session management (COMPLETED)
8. `rust/crates/api/src/providers/openai_compat.rs` - OpenAI-compatible provider (PENDING)
9. `rust/crates/runtime/src/hooks.rs` - Hook system for debugging (COMPLETED)
10. `rust/crates/commands/src/lib.rs` - Slash command definitions (IN PROGRESS)
11. `rust/crates/rusty-claude-cli/src/main.rs` - CLI flag + dispatch (IN PROGRESS)

## Detailed Implementation Plan

### Phase 1: Foundation (COMPLETED)
- ResilienceConfig with all error-type-specific settings
- Error type enhancements with classification
- Hook system with stream debugging
- Session tracking fields

### Phase 2: Slash Command (IN PROGRESS)
- Add `Resilience { mode: Option<String> }` to `SlashCommand` enum
- Add `/resilience` to `SLASH_COMMAND_SPECS`
- Parse `/resilience`, `/resilience force`, `/resilience none`, `/resilience auto`
- Wire into `handle_repl_command` in main.rs
- Wire into `run_resume_command` for `--resume` support
- Display current resilience config status

### Phase 3: Error Recovery in run_turn (IN PROGRESS)
- Add `consecutive_stream_failures`, `last_stream_tokens`, `stream_debug_events` to ConversationRuntime
- Classify API errors by type (model_reloaded, context_exceeded, empty_stream, etc.)
- Apply error-type-specific retry budgets from ResilienceConfig
- Apply error-type-specific backoff durations
- On context exceeded: trigger aggressive compaction
- On empty stream: reduce context and retry
- On model reloaded/unloaded: backoff and retry

### Phase 4: API Client Resilience (IN PROGRESS)
- `stream_with_resilience()` method on AnthropicClient
- `should_retry()` with error-type-specific logic
- `apply_resilient_backoff()` with per-error-type durations
- `enhance_error_with_context()` for better error messages
- Payload size guarding (MAX_RESPONSE_BODY_SIZE)

### Phase 5: Compaction Strategies (PENDING)
- `CompactionStrategy` enum (Standard, Aggressive, Conservative, Preservative, Emergency)
- Strategy-specific compaction functions
- Context-aware compaction factory method

## Verification Criteria
- [ ] `/resilience` slash command works in REPL
- [ ] `/resilience force|none|auto` changes config
- [ ] `--resilience` CLI flag works
- [ ] Error recovery triggers on model reloaded errors
- [ ] Error recovery triggers on context exceeded errors
- [ ] Error recovery triggers on empty stream errors
- [ ] Backoff durations are error-type-specific
- [ ] Compaction strategies work correctly
- [ ] All existing tests pass
