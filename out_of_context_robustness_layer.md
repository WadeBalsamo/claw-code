# Out of Context Robustness Layer

## Problem Statement
The Claw Code Rust application crashes when running local models due to context overflow errors:
- `Context size has been exceeded`
- `Model unloaded`
✘ ❌ Request failed
[error-kind: api_http_error]
error: api returned 400 Bad Request: {"error":{"message":"Context size has been exceeded."},"message":"Context size has been exceeded."}

These errors currently cause the process to terminate instead of being handled gracefully. The application should be self-healing by automatically compacting conversation history and retrying operations when context limits are reached or models become temporarily unavailable.

## Root Cause Analysis
1. **Context Overflow Handling**: In `src/conversation.rs`, the `run_turn` method directly propagates API errors without attempting recovery when the provider returns context size exceeded errors.

2. **Resilience Configuration**: The default `ResilienceConfig` does not automatically enable recovery for local model endpoints, so the resilience layer is not activated for the typical local model use case.

3. **Missing Retry Logic**: There is no built-in mechanism to:
   - Detect context overflow conditions
   - Trigger conversation compaction
   - Implement exponential backoff for model reloads
   - Retry operations after compaction

## High-Level Solution
Introduce a self-healing layer that:
1. Catches context overflow and model unload errors
2. Automatically compacts conversation history when thresholds are approached
3. Implements configurable retry logic with backoff
4. Enables resilience automatically for local model endpoints
5. Provides health monitoring and recovery mechanisms

## Key Modules to Modify
- `src/conversation.rs` - Add error handling and retry logic in `run_turn`
- `src/resilience_config.rs` - Adjust default settings to enable local model resilience
- `src/api/client.rs` - Ensure proper error classification and propagation
- `src/runtime/config.rs` - Configure default resilience behavior

## Implementation Plan
1. Modify `run_turn` to detect and handle context overflow errors
2. Implement automatic session compaction when overflow detected
3. Add retry mechanism with exponential backoff
4. Adjust `ResilienceConfig::default` to enable local model resilience
5. Add health check and model reinitialization on persistent failures
6. Add comprehensive tests to verify self-healing behavior