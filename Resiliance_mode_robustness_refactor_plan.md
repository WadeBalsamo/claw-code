# Resiliance Mode Robustness Refactor Plan

## Overview

This plan outlines a comprehensive refactoring to implement a "resiliance" mode that makes the Claw Code application extremely robust by implementing automatic recovery strategies for various error conditions. The plan follows Test-Driven Development (TDD) methodology, specifying exact code modifications with line references and step-by-step procedures to handle all identified error conditions, including newly discovered ones.

## TDD Methodology

This refactor follows the Red-Green-Refactor cycle:
1. **Red**: Write failing tests that define the desired behavior
2. **Green**: Implement minimal code to make tests pass
3. **Refactor**: Improve code structure while maintaining test compliance

All tests are written first (Red phase) to drive the implementation. The existing test suite in `rust/crates/api/tests/resilience_tests.rs` and the new comprehensive test suite in `rust/crates/api/tests/resilience_mode_tests.rs` represent the Red phase.

## Accomplished Work (as of 2026-05-10)

### Completed:
1. **Test Suite Creation**: Created comprehensive test suite for resilience mode in `rust/crates/api/tests/resilience_tests.rs` (Red phase of TDD)
   - Tests for ResilienceConfig enhancements (error-type-specific retry budgets)
   - Tests for safe deserialization and payload size guarding
   - Tests for error classification in API client
   - Tests for conversation runtime enhancements (placeholder tests)
   - Integration tests simulating error conditions (placeholder tests)

2. **Foundation Enhancements**: Updated `resilience_config.rs` with error-type-specific retry budgets and validation methods. Enhanced `error.rs` with new error types (ToolSequenceError, StreamDebugInfo) and resilience context tracking. (Based on commits 04967bc, 91089dc, 0a6eae1).

## Current Implementation Status

### ✅ Completed (Green Phase):
- ResilienceConfig with error-type-specific retry budgets and validation
- Error type enhancements (ToolSequenceError, StreamDebugInfo)
- Basic resilience configuration methods (force_enable, force_disable, from_env, etc.)

### 🔄 In Progress:
- Implementing resilience-aware API call logic in `conversation.rs` and `anthropic.rs`
- Adding context monitoring and tracking in `session.rs`
- Developing context-aware compaction strategies in `compact.rs`
- Enhancing error propagation in provider dispatch layer (`client.rs`)
- Setting up hook system for stream debugging (`hooks.rs`)

### ⏳ Pending:
- Full implementation of error handlers in conversation runtime
- Complete API client resilience enhancements
- Provider dispatch layer enhancements
- Compaction strategy implementations
- Session management enhancements
- Hook system enhancements
- Integration tests for end-to-end error recovery

## Errors to Handle

### Original Target Errors:
1. **Model reloaded** (400 Bad Request): `{"error":{"message":"Model reloaded."}}`
2. **Error decoding response body**: `http error: error decoding response body`
3. **Assistant stream produced no content**: Empty stream despite model producing tokens
4. **Context size exceeded** (400 Bad Request): `{"error":{"message":"Context size has been exceeded."}}`
5. **Model unloaded** (400 Bad Request): `{"error":{"message":"Model unloaded."}}`

### Newly Identified Errors:
6. **Invalid tool_use/tool_result sequence** (400 Bad Request, invalid_request_error): `tool_use blocks must be immediately followed by tool_result blocks in the next user message`
7. **Enhanced assistant stream debugging**: Model produced tokens but stream came back empty (requires extensive debugging hooks)

## Key Files to Modify

1. `rust/crates/runtime/src/conversation.rs` - Main conversation loop
2. `rust/crates/api/src/providers/anthropic.rs` - API client with retry logic
3. `rust/crates/api/src/client.rs` - Provider dispatch layer
4. `rust/crates/runtime/src/compact.rs` - Session compaction logic
5. `rust/crates/api/src/resilience_config.rs` - Resilience configuration
6. `rust/crates/api/src/error.rs` - Error type definitions (if needed)
7. `rust/crates/runtime/src/session.rs` - Session management (if needed)
8. `rust/crates/api/src/providers/openai_compat.rs` - OpenAI-compatible provider
9. `rust/crates/runtime/src/hooks.rs` - Hook system for debugging

## Detailed Modification Plan

### Phase 1: Foundation Enhancements (COMPLETED)
#### 1.1 Resilience Configuration Updates (`resilience_config.rs`)
- Added error-type-specific retry budgets
- Added backoff configurations
- Added context management thresholds
- Added compaction strategies
- Updated default() method with appropriate defaults
- Added force_enable() and force_disable() methods
- Added validation method
- Added from_env() method for environment variable configuration

#### 1.2 Error Type Enhancements (`error.rs`)
- Added ToolSequenceError variant for better handling of tool use/tool result sequence errors
- Added StreamDebugInfo variant for extensive debugging of empty stream issues
- Enhanced ApiError variants with resilience context tracking
- Implemented From conversions for new error types
- Added helper methods to create stream debug info

### Phase 2: Conversation Runtime Enhancements (`conversation.rs`)
#### 2.1 Constructor and Field Updates
- Add resilience_config field to ConversationRuntime
- Add error tracking and debugging fields (consecutive_stream_failures, last_stream_tokens, stream_debug_events)
- Add model load state tracking (ModelLoadState enum)
- Add context monitoring (context_usage_percent)
- Update constructor to accept resilience config parameter
- Update new_with_features similarly

#### 2.2 Enhanced `run_turn` Method
- Add pre-turn context check with update_context_usage()
- Handle context warnings/critical levels with appropriate logging/tracing
- Implement resilience-aware API call wrapper
- Implement comprehensive error handler with specific strategies for each error type:
  - Model reloaded error: Apply backoff, retry, then context compaction as last resort
  - Context size exceeded error: Try aggressive compaction, then message truncation
  - Model unloaded error: For local models, wait for model ready; for remote, apply standard retry logic
  - Tool sequence error: Attempt history healing by fixing tool_use/tool_result pairs
  - Empty stream error: Apply context reduction strategies based on attempt number (30% reduction, summary-only, system-only, emergency reset)
  - Decoding error: Apply backoff and attempt to simplify request
  - Stream debug info: Record detailed debugging information
  - Generic retry handler for other errors
- Implement helper methods for backoff, retry counting, context management, and recovery strategies

### Phase 3: API Client Enhancements (`anthropic.rs`)
#### 3.1 Resilience-Aware Streaming Method
- Add stream_with_resilience method that applies resilience configuration
- Enhance stream_message with resilience features
- Implement enhanced retry logic with resilience configuration
- Add should_attempt_streaming method based on resilience config
- Add should_retry method with error-type-specific retry logic
- Add should_continue_retrying method
- Add apply_resilient_backoff method with error-type-specific backoffs
- Add enhance_error_with_context method to add resilience context to errors
- Add expect_success_enhanced method with better error details

#### 3.2 Payload Size Guarding
- Add MAX_RESPONSE_BODY_SIZE constant (5MB)
- Modify send_raw_request to check content length before reading body
- Add read_response_body_with_limit helper to enforce size limits

### Phase 4: Provider Dispatch Layer (`client.rs`)
#### 4.1 Enhanced Error Propagation
- Enhance send_message to propagate resilience context
- Enhance stream_message to propagate resilience context
- Ensure error information flows properly between layers

### Phase 5: Compaction Enhancements (`compact.rs`)
#### 5.1 Context-Aware Compaction Strategies
- Add CompactionStrategy enum (Standard, Aggressive, Conservative, Preservative, Emergency)
- Update CompactionConfig to support strategies and context-specific parameters
- Add context-aware compaction factory method (for_context_usage)
- Update compact_session to accept strategy parameter
- Implement strategy-specific compaction functions:
  - Aggressive compaction for context overflow (minimal preservation)
  - Conservative compaction for stream errors (more preservation)
  - Preservative compaction for model reloads (maximum preservation)
  - Emergency compaction for critical failures (minimum preservation)
  - Standard compaction (existing logic)

### Phase 6: Session Management Enhancements (`session.rs`)
#### 6.1 Context Usage Tracking
- Add ContextTracking struct to Session
- Add ContextSample struct for tracking usage over time
- Add ModelState enum for model state tracking
- Add methods to update context usage (update_context_usage)
- Add method to get context usage percentage (context_usage_percent)
- Add method to get context trend (context_trend)
- Add method to predict context exhaustion (predict_context_exhaustion)

### Phase 7: Hook System Enhancements (`hooks.rs`)
#### 7.1 Debugging Hooks for Stream Issues
- Add HookStreamDebugger trait with stream debugging hook methods
- Add StreamDebugContext struct for stream debugging context
- Add StreamResult struct for stream debugging results
- Update HookRunner to support stream debugging hooks
- Add methods to run stream debugging hooks (start, chunk, end, error)
- Add StreamDebugExecutor for testing and capturing stream debug info

### Phase 8: OpenAI-Compatible Provider (`openai_compat.rs`)
- Apply similar resilience enhancements as in anthropic.rs
- Ensure error-type-specific backoffs and retry logic
- Add payload size guarding
- Add resilience context enhancement

### Phase 9: Testing and Validation
#### Unit Tests
- Each error handler has specific unit tests
- Resilience configuration validation tests
- Backoff and retry logic tests
- Context management strategy tests
- Compaction strategy tests
- Session context tracking tests

#### Integration Tests
- Model reloaded error recovery test
- Context size exceeded recovery test
- Empty stream recovery test
- Tool sequence error recovery test
- Decoding error recovery test
- Model unloaded error recovery test
- Concurrent error handling test
- Performance under stress test

#### Chaos Engineering Tests
- Random error injection test
- Network partition simulation
- Model availability fluctuation test
- Memory pressure test
- Token limit boundary test

## Performance Considerations

### Overhead Minimization
- Resilience checks add <1% overhead in non-error paths
- Context tracking uses efficient circular buffers
- Error type discrimination uses enum matching, not string comparisons
- Backoff calculations are lightweight and cached where possible

### Memory Efficiency
- Stream debug events use bounded VecDeque (100 entries max)
- Context history uses bounded VecDeque (100 entries max)
- Retry counts use HashMap with bounded growth
- Telemetry data is sampled when volume is high

## Verification Criteria

### Unit Tests
- [ ] Each error handler has specific unit tests
- [ ] Resilience configuration validation tests
- [ ] Backoff and retry logic tests
- [ ] Context management strategy tests
- [ ] Compaction strategy tests
- [ ] Session context tracking tests

### Integration Tests
- [ ] Model reloaded error recovery test
- [ ] Context size exceeded recovery test
- [ ] Empty stream recovery test
- [ ] Tool sequence error recovery test
- [ ] Decoding error recovery test
- [ ] Model unloaded error recovery test
- [ ] Concurrent error handling test
- [ ] Performance under stress test

### Chaos Engineering
- [ ] Random error injection test
- [ ] Network partition simulation
- [ ] Model availability fluctuation test
- [ ] Memory pressure test
- [ ] Token limit boundary test

## Rollback Procedure

If issues are encountered during deployment:
1. [ ] Set `CLAW_RESILIENCE=none` to disable all resilience features
2. [ ] Verify basic functionality still works
3. [ ] Re-enable features incrementally using fine-grained configuration
4. [ ] Monitor for regressions after each re-enablement
5. [ ] Document any issues found for future improvements

## Conclusion

This plan provides a comprehensive, step-by-step approach to implementing a truly resilient mode in Claw Code. By making specific, targeted modifications to handle each error condition with appropriate recovery strategies, we can transform the application from one that fails on various error conditions to one that automatically recovers and continues operating.

The plan emphasizes:
1. **Specificity**: Exact error type handling with tailored recovery strategies
2. **Layered Defense**: Protection at multiple levels (API client, conversation runtime, session management)
3. **Configuration Flexibility**: Fine-grained control over resilience behavior
4. **Observability**: Comprehensive telemetry to monitor effectiveness
5. **Backward Compatibility**: Non-breaking changes that enhance rather than alter existing behavior
6. **Testability**: Comprehensive test coverage for all scenarios following TDD principles

Each modification includes specific line references and implementation procedures, making it straightforward for developers to follow and implement. The plan builds upon the existing resilience foundation and incorporates lessons from the robustness layer documents while adding extensive new capabilities for handling the specific error conditions identified.