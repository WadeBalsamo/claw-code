# Resiliance Mode Robustness Refactor Plan

## Overview

This plan outlines a comprehensive refactoring to implement a "resiliance" mode that makes the Claw Code application extremely robust by implementing automatic recovery strategies for various error conditions. The plan builds upon the existing resilience layer concepts and specifies exact code modifications needed to handle the target errors:

1. Model reloaded (400 Bad Request) → Retry with backoff
2. Error decoding response body → Retry, then context compaction if persistent
3. Assistant stream produced no content → Adaptive retry with context management
4. Context size exceeded → Automatic compaction/truncation and retry
5. Model unloaded → Wait for model reload and retry

## Key Files to Modify

Based on codebase analysis, the following files require modifications:

1. `rust/crates/runtime/src/conversation.rs` - Main conversation loop
2. `rust/crates/api/src/providers/anthropic.rs` - API client with retry logic
3. `rust/crates/api/src/client.rs` - Provider dispatch layer
4. `rust/crates/runtime/src/compact.rs` - Session compaction logic
5. `rust/crates/api/src/resilience_config.rs` - Resilience configuration
6. `rust/crates/api/src/error.rs` - Error type definitions (if needed)
7. `rust/crates/runtime/src/session.rs` - Session management (if needed)

## Detailed Modification Plan

### 1. Conversation Runtime Enhancements (`conversation.rs`)

**Current Issue**: The `run_turn` method propagates API errors directly without attempting recovery strategies.

**Planned Modifications**:

#### A. Enhanced Error Handling in `run_turn` (Lines ~200-250)
- Wrap the `self.api_client.stream(request)` call in a resilience-aware retry loop
- Implement error classification for the five target error types
- Add context-aware retry limits based on error type and resilience config

#### B. Context Management Integration
- Add methods to check context usage before API calls
- Implement automatic compaction triggering when context > 80% threshold
- Add context truncation strategies for specific error scenarios

#### C. Model State Awareness
- Track model load/unload state per conversation
- Implement model readiness checks before API calls
- Add wait-and-retry logic for model unloaded errors

#### D. Specific Error Handlers
1. **Model Reloaded Error** (400 with "Model reloaded"):
   - Implement exponential backoff retry (max 3 attempts)
   - Log model reload event for telemetry

2. **Context Size Exceeded** (400 with "Context size has been exceeded"):
   - Trigger immediate compaction with aggressive settings
   - If compaction fails, implement last-message truncation strategy
   - Retry with compacted context

3. **Assistant Stream No Content**:
   - Implement adaptive retry with varying context reduction strategies
   - Try: empty context, then reduced context, then summary-only context
   - Track consecutive failures to prevent infinite loops

4. **Error Decoding Response Body**:
   - Implement payload size validation before deserialization
   - Add fallback to raw error extraction when JSON parsing fails
   - Retry with simplified request payload on decoding failures

5. **Model Unloaded** (400 with "Model unloaded"):
   - Implement model readiness polling with timeout
   - Add exponential backoff between readiness checks
   - Fallback to context compaction if model remains unavailable

#### E. Configuration Integration
- Reference `self.resilience_config` (to be passed via constructor) for all retry decisions
- Implement resilience-aware timeouts and backoff values
- Add metrics collection for resilience mode effectiveness

### 2. API Client Enhancements (`anthropic.rs`)

**Current Issue**: Retry logic in `send_with_retry` doesn't distinguish between error types for context-aware recovery.

**Planned Modifications**:

#### A. Enhanced Error Classification (Lines ~500-550 in `send_with_retry`)
- Add specific error type detection for the five target errors
- Implement resilience-mode-specific retry budgets per error type
- Add jittered backoff with error-type-specific parameters

#### B. Payload Size Guarding (New Helper Function)
- Implement `read_response_body_with_limit` to prevent OOM from large responses
- Add configurable maximum response size (default 5MB)
- Return truncated payload with error indicator when limit exceeded

#### C. Decoding Robustness Integration (Based on error_decoding_robustness_layer.md)
- Implement `safe_deserialize` helper that never panics
- Add structural JSON validation before deserialization
- Provide fallback error enrichment with raw payload context

#### D. Streaming Resilience Enhancements (Based on no_stream_tokens_robustness_layer.md)
- Add pre-stream token limit validation
- Implement empty chunk handling with heartbeat mechanism
- Add structured error propagation for streaming failures
- Implement resilience-aware retry logic for stream initialization

#### E. Model State Tracking
- Add model readiness tracking per endpoint
- Implement health check endpoint polling for local models
- Cache model state with TTL to reduce polling overhead

### 3. Provider Dispatch Layer (`client.rs`)

**Current Issue**: Limited error context propagation between layers.

**Planned Modifications**:

#### A. Error Context Enrichment
- Add contextual information to errors (attempt count, resilience mode status, etc.)
- Implement error chaining to preserve original error details
- Add resilience mode flags to error types for upstream handling

#### B. Configuration Propagation
- Ensure `ResilienceConfig` is properly passed to all provider clients
- Implement runtime configuration updates without client recreation
- Add validation for resilience configuration values

### 4. Compaction Enhancements (`compact.rs`)

**Current Issue**: Compaction is triggered only by token threshold, not by specific error conditions.

**Planned Modifications**:

#### A. Error-Driven Compaction Triggers
- Add public API to force compaction with specific configuration
- Implement error-specific compaction strategies:
  * Aggressive compaction for context overflow
  * Conservative compaction for stream failures
  * Preservation-focused compaction for model reloads

#### B. Context Analysis Utilities
- Add helper to estimate context usage percentage
- Implement token counting for specific message ranges
- Add utility to identify safe compaction boundaries

#### C. Truncation Strategies
- Implement last-message truncation for overflow recovery; try adding the last message back after compaction
- Add summary-only mode for extreme context reduction after multiple crashes, add 

### 5. Resilience Configuration (`resilience_config.rs`)

**Current Issue**: Default settings may not be optimal for all resilience scenarios.

**Planned Modifications**:

#### A. Error-Type Specific Configuration
- Add retry budget configuration per error type
- Implement backoff strategy customization
- Add context management thresholds and ratios

#### B. Dynamic Configuration Updates
- Allow runtime updates to resilience configuration
- Implement configuration validation with sensible defaults
- Add environment variable override for specific parameters

#### C. Provider-Specific Defaults
- Tune defaults for local model endpoints (more aggressive retries)
- Adjust timeouts based on provider characteristics
- Implement endpoint health-aware configuration

## Cross-Cutting Concerns

### A. Telemetry and Observability
- Add structured logging for all resilience mode decisions
- Implement metrics collection for:
  * Retry attempts per error type
  * Context compaction frequency and effectiveness
  * Model reload/unload recovery times
  * Success rates after resilience interventions
- Add tracing spans for resilience mode operations

### B. Testing Strategy
- Implement unit tests for each error handler
- Create integration tests simulating error conditions
- Add chaos engineering tests for concurrent failure scenarios
- Develop performance benchmarks to ensure resilience mode doesn't degrade normal operation

### C. Performance Considerations
- Ensure resilience checks add minimal overhead in non-error paths
- Implement efficient error type detection (avoid string matching where possible)
- Cache frequently accessed configuration values
- Use asynchronous primitives where appropriate to avoid blocking

## Implementation Phases

### Phase 1: Foundation
1. Enhance `ResilienceConfig` with error-type-specific settings
2. Implement safe deserialization and payload size guarding
3. Add basic error classification in API client
4. Update conversation runtime to accept resilience config

### Phase 2: Core Error Handling
1. Implement model reloaded error handling
2. Add context size exceeded recovery
3. Implement assistant stream no content recovery
4. Add error decoding response body recovery

### Phase 3: Advanced Features
1. Implement model unloaded recovery
2. Add context analysis and prediction utilities
3. Implement dynamic configuration updates
4. Add comprehensive telemetry

### Phase 4: Testing and Validation
1. Write unit tests for all new functionality
2. Create integration test suites for error scenarios
3. Perform chaos testing with fault injection
4. Validate performance impact and optimize as needed

## Specific Error Handling Procedures

### Model Reloaded (400: "Model reloaded")
1. Detect error in API client response handling
2. Check resilience mode enabled for provider
3. Apply jittered exponential backoff (start 1s, max 8s)
4. Retry request up to 3 times
5. If persistent, trigger context compaction and retry
6. Log model reload event with timestamp

### Error Decoding Response Body
1. Before deserialization, check response size against limit (5MB)
2. If oversized, return truncated payload error with hint
3. Attempt safe deserialization with panic protection
4. On failure, return structured error with raw payload preview (first 200 chars)
5. In resilience mode, retry with simplified request (remove non-essential fields)
6. If retry fails, fallback to context-aware error handling

### Assistant Stream Produced No Content
1. Detect empty stream in `MessageStream.next_event()`
2. Check resilience mode and retry budget
3. Attempt recovery strategies in order:
   a. Retry with same parameters (1 attempt)
   b. Retry with reduced context (remove oldest 50% messages)
   c. Retry with context summary only (keep system + last 2 exchanges)
   d. Return structured error with context reduction suggestion
4. Track consecutive empty streams to prevent infinite loops

### Context Size Exceeded (400: "Context size has been exceeded")
1. Detect error in API response handling
2. Check resilience mode and compaction eligibility
3. Trigger immediate compaction with:
   * preserve_recent_messages = 2
   * max_estimated_tokens = 4000 (adjustable)
4. If compaction succeeds, retry with compacted session
5. If compaction fails or not eligible:
   a. Truncate last user message by 50%
   b. Retry request
   c. If still fails, truncate further and retry (max 3 attempts)
6. If all fails, return error with context reduction recommendation

### Model Unloaded (400: "Model unloaded")
1. Detect error in API response handling
2. Check resilience mode and model endpoint type
3. For local models:
   a. Poll model readiness endpoint every 2s (max 30s)
   b. Implement exponential backoff between polls
   c. On readiness, retry original request
4. For remote models:
   a. Apply standard retry with backoff (max 3 attempts)
   b. If persistent, suggest checking model availability
5. Log model state transitions for telemetry

## Configuration Interface

Resilience mode is controlled via:
- Environment variable `CLAW_RESILIENCE`:
  * `force` - Enable resilience everywhere
  * `none` - Disable resilience everywhere
  * `auto`/unset - Auto-detect localhost (default)
- Fine-grained control via `ResilienceConfig` struct:
  * `force_enable`/`force_disable` - Override auto-detection
  * `auto_enable_for_local` - Default localhost behavior
  * `enable_for_anthropic`/`enable_for_openai_compat` - Provider-specific
  * Error-type-specific retry budgets and backoff parameters
  * Context management thresholds and ratios

## Conclusion

This plan provides a comprehensive roadmap for implementing a truly resilient mode in Claw Code. By making specific, targeted modifications to the conversation runtime, API client, and supporting layers, we can transform the application from one that fails on various error conditions to one that automatically recovers and continues operating. The plan emphasizes:

1. **Specificity**: Exact error type handling with tailored recovery strategies
2. **Layered Defense**: Protection at multiple levels (API client, conversation runtime, session management)
3. **Configuration Flexibility**: Fine-grained control over resilience behavior
4. **Observability**: Comprehensive telemetry to monitor effectiveness
5. **Backward Compatibility**: Non-breaking changes that enhance rather than alter existing behavior

The implementation will require careful coordination between layers but follows established patterns in the codebase and builds upon the existing resilience foundation.