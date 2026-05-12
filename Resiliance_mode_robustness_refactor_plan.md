# Resiliance Mode Robustness Refactor Plan

## Overview

This plan outlines a comprehensive refactoring to implement a "resiliance" mode that makes the Claw Code application extremely robust by implementing automatic recovery strategies for various error conditions. The plan specifies exact code modifications with line references and step-by-step procedures to handle all identified error conditions, including newly discovered ones.

## Accomplished Work (as of 2026-05-10)

### Completed:
1. **Test Suite Creation**: Created comprehensive test suite for resilience mode in `rust/crates/api/tests/resilience_tests.rs` (Red phase of TDD)
   - Tests for ResilienceConfig enhancements (error-type-specific retry budgets)
   - Tests for safe deserialization and payload size guarding
   - Tests for error classification in API client
   - Tests for conversation runtime enhancements (placeholder tests)
   - Integration tests simulating error conditions (placeholder tests)
2. **Foundation Enhancements**: Updated `resilience_config.rs` with error-type-specific retry budgets and validation methods. Enhanced `error.rs` with new error types (ToolSequenceError, StreamDebugInfo) and resilience context tracking. (Based on commits 04967bc, 91089dc, 0a6eae1).

### In Progress:
- Implementing resilience-aware API call logic in `conversation.rs` and `anthropic.rs`
- Adding context monitoring and tracking in `session.rs`
- Developing context-aware compaction strategies in `compact.rs`
- Enhancing error propagation in provider dispatch layer (`client.rs`)
- Setting up hook system for stream debugging (`hooks.rs`)
- Session files updated from ongoing testing activities

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

### Phase 1: Foundation Enhancements

#### 1.1 Resilience Configuration Updates (`resilience_config.rs`)
**Lines to modify:** Around 20-50 (constructor and methods)

**Specific Changes:**
```rust
// Add error-type-specific retry budgets
#[derive(Debug, Clone)]
pub struct ResilienceConfig {
    // ... existing fields ...
    
    // Error-specific retry configurations
    pub model_reloaded_max_retries: u32,
    pub context_exceeded_max_retries: u32,
    pub stream_empty_max_retries: u32,
    pub decoding_error_max_retries: u32,
    pub model_unloaded_max_retries: u32,
    pub tool_sequence_error_max_retries: u32,
    
    // Backoff configurations
    pub model_reloaded_initial_backoff: Duration,
    pub context_exceeded_initial_backoff: Duration,
    pub stream_empty_initial_backoff: Duration,
    pub decoding_error_initial_backoff: Duration,
    pub model_unloaded_initial_backoff: Duration,
    pub tool_sequence_error_initial_backoff: Duration,
    
    // Context management thresholds
    pub context_warning_threshold: f32,  // 0.8 for 80%
    pub context_critical_threshold: f32, // 0.95 for 95%
    pub aggressive_compaction_preserve_recent: usize,
    pub conservative_compaction_preserve_recent: usize,
}

// Update default() method
impl ResilienceConfig {
    pub fn default() -> Self {
        Self {
            // ... existing defaults ...
            model_reloaded_max_retries: 3,
            context_exceeded_max_retries: 2,
            stream_empty_max_retries: 3,
            decoding_error_max_retries: 2,
            model_unloaded_max_retries: 5,
            tool_sequence_error_max_retries: 2,
            
            model_reloaded_initial_backoff: Duration::from_secs(1),
            context_exceeded_initial_backoff: Duration::from_secs(2),
            stream_empty_initial_backoff: Duration::from_secs(1),
            decoding_error_initial_backoff: Duration::from_secs(1),
            model_unloaded_initial_backoff: Duration::from_secs(3),
            tool_sequence_error_initial_backoff: Duration::from_secs(1),
            
            context_warning_threshold: 0.8,
            context_critical_threshold: 0.95,
            aggressive_compaction_preserve_recent: 1,
            conservative_compaction_preserve_recent: 3,
        }
    }
}

// Add validation method
impl ResilienceConfig {
    pub fn validate(&self) -> Result<(), String> {
        if self.model_reloaded_max_retries > 10 {
            return Err("model_reloaded_max_retries too high".to_string());
        }
        // ... validate other fields ...
        Ok(())
    }
}
```

#### 1.2 Error Type Enhancements (`error.rs`)
**Lines to modify:** Add new error variants around existing ApiError enum

**Specific Changes:**
```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApiError {
    // ... existing variants ...
    
    // New error types for better handling
    ToolSequenceError {
        request_id: Option<String>,
        body: String,
    },
    
    StreamDebugInfo {
        message: String,
        tokens_produced: Option<u32>,
        stream_events: Vec<String>,
    },
    
    // Enhanced existing error with more context
    Api {
        // ... existing fields ...
        resilience_context: Option<ResilienceContext>,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResilienceContext {
    pub attempt: u32,
    pub max_attempts: u32,
    pub error_type: String,
    pub resilience_enabled: bool,
    pub context_usage_percent: Option<f32>,
}

// Implement From conversions for new error types
impl From<ToolSequenceError> for ApiError {
    fn from(err: ToolSequenceError) -> Self {
        ApiError::ToolSequenceError {
            request_id: err.request_id,
            body: err.body,
        }
    }
}

// Add helper to create stream debug info
impl ApiError {
    pub fn stream_debug(
        message: impl Into<String>,
        tokens_produced: Option<u32>,
        stream_events: Vec<String>
    ) -> Self {
        ApiError::StreamDebugInfo {
            message: message.into(),
            tokens_produced,
            stream_events,
        }
    }
}
```

### Phase 2: Conversation Runtime Enhancements (`conversation.rs`)

#### 2.1 Constructor and Field Updates
**Lines to modify:** Around 50-100 (constructor and new_with_features)

**Specific Changes:**
```rust
pub struct ConversationRuntime<C, T> {
    // ... existing fields ...
    
    // NEW: Resilience configuration
    resilience_config: ResilienceConfig,
    
    // NEW: Error tracking and debugging
    consecutive_stream_failures: usize,
    last_stream_tokens: Option<u32>,
    stream_debug_events: VecDeque<String>,
    
    // NEW: Model state tracking
    model_load_state: ModelLoadState,
    model_ready_at: Option<SystemTime>,
    
    // NEW: Context monitoring
    context_usage_percent: Option<f32>,
}

// Add new enum for model state tracking
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelLoadState {
    Unknown,
    Loading,
    Loaded,
    Unloading,
    Failed,
}

// Update constructor to accept resilience config
impl<C, T> ConversationRuntime<C, T>
where
    C: ApiClient,
    T: ToolExecutor,
{
    #[must_use]
    pub fn new(
        session: Session,
        api_client: C,
        tool_executor: T,
        permission_policy: PermissionPolicy,
        system_prompt: Vec<String>,
        resilience_config: ResilienceConfig, // NEW PARAMETER
    ) -> Self {
        // ... existing init ...
        Self {
            // ... existing fields ...
            resilience_config,
            consecutive_stream_failures: 0,
            last_stream_tokens: None,
            stream_debug_events: VecDeque::with_capacity(100),
            model_load_state: ModelLoadState::Unknown,
            model_ready_at: None,
            context_usage_percent: None,
        }
    }
}

// Update new_with_features similarly
```

#### 2.2 Enhanced `run_turn` Method
**Lines to modify:** Around 200-300 (main loop)

**Specific Changes:**
```rust
pub fn run_turn(
    &mut self,
    user_input: impl Into<String>,
    mut prompter: Option<&mut dyn PermissionPrompter>,
) -> Result<TurnSummary, RuntimeError> {
    // ... existing setup ...
    
    // NEW: Pre-turn context check
    self.update_context_usage()?;
    
    // NEW: Handle context warnings/critical levels
    if let Some(usage) = self.context_usage_percent {
        if usage >= self.resilience_config.context_critical_threshold {
            // Critical context level - force compaction before proceeding
            if let Err(e) = self.handle_critical_context()? {
                return Err(RuntimeError::new(format!(
                    "Failed to handle critical context: {}", e
                )));
            }
        } else if usage >= self.resilience_config.context_warning_threshold {
            // Warning level - log for monitoring
            if let Some(tracer) = &self.session_tracer {
                tracer.record("context_warning", map!{
                    "usage_percent" => usage,
                    "threshold" => self.resilience_config.context_warning_threshold
                });
            }
        }
    }
    
    // ... existing message pushing ...
    
    // MAIN LOOP WITH ENHANCED ERROR HANDLING
    loop {
        // ... iteration limit check ...
        
        let request = ApiRequest {
            system_prompt: self.system_prompt.clone(),
            messages: self.session.messages.clone(),
        };
        
        // NEW: Resilience-aware API call with specific error handling
        let events = match self.resilient_api_call(&request).await {
            Ok(events) => events,
            Err(error) => {
                // NEW: Enhanced error handling with specific strategies
                return self.handle_api_error(error, &request, iterations).await;
            }
        };
        
        // ... rest of existing loop ...
    }
}

// NEW: Resilient API call wrapper
async fn resilient_api_call(
    &mut self,
    request: &ApiRequest,
) -> Result<Vec<AssistantEvent>, ApiError> {
    // Apply resilience configuration to the API client call
    // This delegates to the API client's resilience-aware methods
    self.api_client.stream_with_resilience(request, &self.resilience_config).await
}

// NEW: Comprehensive error handler
async fn handle_api_error(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Record error for telemetry
    self.record_api_error(&error, iteration).await?;
    
    // Match on error type for specific handling
    match error {
        ApiError::Api { 
            ref message, 
            ref error_type, 
            status, 
            ref body, 
            retryable, 
            .. 
        } if retryable => {
            // Handle specific error messages
            match (message.as_deref(), error_type.as_deref(), status.as_u16()) {
                // Model reloaded error
                (Some(msg), Some(err_type), 400) if msg.contains("Model reloaded") && err_type == "invalid_request_error" => {
                    return self.handle_model_reloaded(error, request, iteration).await;
                }
                
                // Context size exceeded
                (Some(msg), Some(err_type), 400) if msg.contains("Context size has been exceeded") && err_type == "invalid_request_error" => {
                    return self.handle_context_exceeded(error, request, iteration).await;
                }
                
                // Model unloaded
                (Some(msg), Some(err_type), 400) if msg.contains("Model unloaded") && err_type == "invalid_request_error" => {
                    return self.handle_model_unloaded(error, request, iteration).await;
                }
                
                // Invalid tool_use/tool_result sequence (NEW)
                (Some(msg), Some(err_type), 400) if msg.contains("tool_use blocks must be immediately followed by tool_result blocks") && err_type == "invalid_request_error" => {
                    return self.handle_tool_sequence_error(error, request, iteration).await;
                }
                
                // Default retry handling for other retryable errors
                _ => {
                    return self.handle_generic_retry(error, request, iteration).await;
                }
            }
        }
        
        // Stream produced no content (NEW - unknown error kind)
        ApiError::Unknown { msg } if msg.contains("assistant stream produced no content") => {
            return self.handle_empty_stream(error, request, iteration).await;
        }
        
        // Decoding errors
        ApiError::Json { .. } => {
            return self.handle_decoding_error(error, request, iteration).await;
        }
        
        // Tool sequence errors (direct handling)
        ApiError::ToolSequenceError { .. } => {
            return self.handle_tool_sequence_error(error, request, iteration).await;
        }
        
        // Stream debug info (for enhanced diagnostics)
        ApiError::StreamDebugInfo { .. } => {
            return self.handle_stream_debug(error, request, iteration).await;
        }
        
        // Non-retryable errors
        _ => {
            self.record_turn_failed(iteration, &error);
            return Err(error);
        }
    }
}

// NEW: Specific error handlers

// Handle model reloaded error
async fn handle_model_reloaded(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Check if we have retries left
    if self.get_retry_count("model_reloaded") < self.resilience_config.model_reloaded_max_retries {
        // Apply backoff
        self.apply_backoff("model_reloaded").await?;
        
        // Increment retry counter
        self.increment_retry_count("model_reloaded");
        
        // Retry the request
        return self.retry_request(request, iteration).await;
    }
    
    // If we've exhausted retries, try context compaction as last resort
    if self.attempt_context_compaction("model_reloaded").await? {
        // Reset retry counter after successful compaction
        self.reset_retry_count("model_reloaded");
        return self.retry_request(request, iteration).await;
    }
    
    // If all else fails, return the error
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle context size exceeded error
async fn handle_context_exceeded(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Try aggressive compaction first
    if self.attempt_aggressive_compaction().await? {
        // Reset context tracking
        self.context_usage_percent = None;
        return self.retry_request(request, iteration).await;
    }
    
    // If compaction fails, try message truncation
    if self.attempt_message_truncation().await? {
        return self.retry_request(request, iteration).await;
    }
    
    // If all else fails, return error
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle model unloaded error
async fn handle_model_unloaded(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // For local models, wait for model to be ready
    if self.is_local_model_request(request).await? {
        if self.wait_for_model_ready().await? {
            // Model is ready, retry request
            return self.retry_request(request, iteration).await;
        }
    }
    
    // For remote models or if waiting failed, apply standard retry logic
    if self.get_retry_count("model_unloaded") < self.resilience_config.model_unloaded_max_retries {
        self.apply_backoff("model_unloaded").await?;
        self.increment_retry_count("model_unloaded");
        return self.retry_request(request, iteration).await;
    }
    
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle tool sequence error (NEW)
async fn handle_tool_sequence_error(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // This indicates malformed conversation history
    // Attempt to heal the history by fixing tool_use/tool_result pairs
    
    if self.attempt_history_healing().await? {
        // History healed, retry request
        if self.get_retry_count("tool_sequence") < self.resilience_config.tool_sequence_error_max_retries {
            self.apply_backoff("tool_sequence").await?;
            self.increment_retry_count("tool_sequence");
            return self.retry_request(request, iteration).await;
        }
    }
    
    // If healing fails or retries exhausted, return error
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle empty stream error (NEW - extensive debugging)
async fn handle_empty_stream(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Increment consecutive stream failures
    self.consecutive_stream_failures += 1;
    
    // If we have stream debug info, record it
    if let ApiError::StreamDebugInfo { message, tokens_produced, stream_events } = error {
        self.last_stream_tokens = tokens_produced;
        self.stream_debug_events.extend(stream_events);
        
        // Record extensive debugging info
        self.record_stream_debug_info(&message, tokens_produced, &stream_events).await?;
    }
    
    // If we haven't exceeded max retries, try recovery strategies
    if self.consecutive_stream_failures < self.resilience_config.stream_empty_max_retries {
        // Apply backoff
        self.apply_backoff("stream_empty").await?;
        
        // Try different context reduction strategies based on attempt number
        match self.consecutive_stream_failures {
            1 => {
                // First retry: try with reduced context (remove oldest 30%)
                if self.reduce_context_by_percentage(0.3).await? {
                    return self.retry_request(request, iteration).await;
                }
            }
            2 => {
                // Second retry: try with summary-only context (keep system + last 2 exchanges)
                if self.reduce_to_summary_context().await? {
                    return self.retry_request(request, iteration).await;
                }
            }
            3 => {
                // Third retry: try with minimal context (system only)
                if self.reduce_to_system_context().await? {
                    return self.retry_request(request, iteration).await;
                }
            }
            _ => {
                // Beyond standard retries, try aggressive measures
                if self.attempt_emergency_context_reset().await? {
                    return self.retry_request(request, iteration).await;
                }
            }
        }
    }
    
    // If all recovery strategies fail, return error with debug info
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle decoding errors
async fn handle_decoding_error(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Check if we have retries left
    if self.get_retry_count("decoding") < self.resilience_config.decoding_error_max_retries {
        // Apply backoff
        self.apply_backoff("decoding").await?;
        
        // Before retry, try to simplify the request
        if self.simplify_request_for_decoding(request).await? {
            self.increment_retry_count("decoding");
            return self.retry_request(request, iteration).await;
        }
    }
    
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle stream debug info (for enhanced diagnostics)
async fn handle_stream_debug(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Extract stream debug info
    if let ApiError::StreamDebugInfo { message, tokens_produced, stream_events } = error {
        // Record detailed debugging information
        self.record_stream_debug_info(&message, tokens_produced, &stream_events).await?;
        
        // For stream debug info, we typically don't retry immediately as it's informational
        // But if it's associated with an empty stream, we might want to apply similar logic
        if message.contains("assistant stream produced no content") {
            // Treat similar to empty stream for recovery purposes
            return self.handle_empty_stream(error, request, iteration).await;
        }
    }
    
    // If not associated with a recoverable error, just record and continue
    // (In practice, we might still want to retry depending on context)
    self.record_turn_faced(iteration, &error);
    return Err(error);
}

// Generic retry handler for other errors
async fn handle_generic_retry(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Use a generic retry key for errors without specific handlers
    let retry_key = format!("generic_{:?}", error);
    
    if self.get_retry_count(&retry_key) < 3 { // Default max retries for generic errors
        self.apply_backoff("generic").await?;
        self.increment_retry_count(&retry_key);
        return self.retry_request(request, iteration).await;
    }
    
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Helper methods for the above handlers

// Get retry count for a specific error type
fn get_retry_count(&self, error_type: &str) -> usize {
    *self.retry_counts.get(error_type).unwrap_or(&0)
}

// Increment retry count for a specific error type
fn increment_retry_count(&mut self, error_type: &str) {
    *self.retry_counts.entry(error_type.to_string()).or_insert(0) += 1;
}

// Reset retry count for a specific error type
fn reset_retry_count(&mut self, error_type: &str) {
    self.retry_counts.insert(error_type.to_string(), 0);
}

// Apply backoff based on error type and retry count
async fn apply_backoff(&mut self, error_type: &str) -> Result<(), ApiError> {
    let attempt = self.get_retry_count(error_type);
    let backoff = match error_type {
        "model_reloaded" => self.resilience_config.model_reloaded_initial_backoff,
        "context_exceeded" => self.resilience_config.context_exceeded_initial_backoff,
        "stream_empty" => self.resilience_config.stream_empty_initial_backoff,
        "decoding" => self.resilience_config.decoding_error_initial_backoff,
        "model_unloaded" => self.resilience_config.model_unloaded_initial_backoff,
        "tool_sequence" => self.resilience_config.tool_sequence_error_initial_backoff,
        _ => Duration::from_secs(1), // Default
    };
    
    // Apply exponential backoff with jitter
    let delay = backoff * 2u32.pow(attempt as u32);
    let jitter = delay * rand::random::<f32>() * 0.1; // 10% jitter
    let final_delay = delay + jitter;
    
    tokio::time::sleep(final_delay).await;
    Ok(())
}

// Attempt context compaction with aggressive settings
async fn attempt_aggressive_compaction(&mut self) -> Result<bool, ApiError> {
    let config = CompactionConfig {
        preserve_recent_messages: self.resilience_config.aggressive_compaction_preserve_recent,
        max_estimated_tokens: 2000, // Aggressive limit
    };
    
    let result = compact_session(&self.session, config);
    if result.removed_message_count > 0 {
        self.session = result.compacted_session;
        Ok(true)
    } else {
        Ok(false)
    }
}

// Attempt message truncation (truncate oldest user message by 50%)
async fn attempt_message_truncation(&mut self) -> Result<bool, ApiError> {
    // Find the oldest user message and truncate it
    if let Some(index) = self.session.messages.iter()
        .position(|m| m.role == MessageRole::User) {
        
        let message = &self.session.messages[index];
        // Truncate the text content by 50%
        if let Some(text_block) = message.blocks.iter()
            .find(|b| matches!(b, ContentBlock::Text { .. })) {
            
            if let ContentBlock::Text { text } = text_block {
                let mid_point = text.len() / 2;
                let truncated = text[mid_point..].to_string();
                
                // Create new message with truncated text
                let new_message = ConversationMessage {
                    role: MessageRole::User,
                    blocks: vec![ContentBlock::Text { text: truncated }],
                    usage: None,
                };
                
                // Replace the message
                self.session.messages[index] = new_message;
                return Ok(true);
            }
        }
    }
    
    Ok(false)
}

// Check if request is for a local model
async fn is_local_model_request(&self, request: &ApiRequest) -> Result<bool, ApiError> {
    // Check if the model in the request is a local model
    // This would typically involve checking the model name against known local model patterns
    // or checking if the base_url points to localhost
    let model = &request.messages.last().unwrap_or(&request.messages[0]).blocks[0]; // Simplified
    
    // More realistically, we'd check the API client's base_url
    // For now, return false as placeholder
    Ok(false)
}

// Wait for model to be ready (polling)
async fn wait_for_model_ready(&mut self) -> Result<bool, ApiError> {
    let start = SystemTime::now();
    let timeout = Duration::from_secs(30); // 30 second timeout
    
    loop {
        // Check if model is ready (this would involve a health check API call)
        // For now, simulate with a simple delay and state check
        if self.model_load_state == ModelLoadState::Loaded {
            self.model_ready_at = Some(SystemTime::now());
            return Ok(true);
        }
        
        // Check timeout
        if start.elapsed()? > timeout {
            return Err(ApiError::Timeout {
                operation: "model_ready".to_string(),
                duration: timeout.as_secs(),
            });
        }
        
        // Wait before next check
        tokio::time::sleep(Duration::from_secs(2)).await;
        
        // In a real implementation, we'd poll a health check endpoint here
        // For now, just continue looping
    }
}

// Attempt to heal conversation history (fix tool_use/tool_result pairs)
async fn attempt_history_healing(&mut self) -> Result<bool, ApiError> {
    // Scan through messages and fix any tool_use blocks not followed by tool_result
    let mut healed = false;
    let mut i = 0;
    
    while i < self.session.messages.len() {
        if let MessageRole::Assistant = self.session.messages[i].role {
            // Check if this assistant message has tool_use blocks
            let has_tool_use = self.session.messages[i].blocks.iter()
                .any(|b| matches!(b, ContentBlock::ToolUse { .. }));
            
            if has_tool_use {
                // Look ahead for the tool_result
                let mut found_tool_result = false;
                let mut j = i + 1;
                
                while j < self.session.messages.len() && !found_tool_result {
                    if let MessageRole::Tool = self.session.messages[j].role {
                        // Check if this tool result matches any of the tool uses above
                        // For simplicity, we'll just check if there's at least one tool result
                        found_tool_result = true;
                        break;
                    }
                    j += 1;
                }
                
                if !found_tool_result && j < self.session.messages.len() {
                    // We found a gap - insert a tool result
                    healed = true;
                    // In a real implementation, we'd create an appropriate tool result
                    // For now, just insert a placeholder
                    let tool_result_msg = ConversationMessage::tool_result(
                        "healed".to_string(),
                        "healed_tool".to_string(),
                        "Automatically healed by resilience system".to_string(),
                        false,
                    );
                    self.session.messages.insert(j, tool_result_msg);
                    i = j + 1; // Skip past the inserted message
                    continue;
                }
            }
        }
        i += 1;
    }
    
    Ok(healed)
}

// Reduce context by percentage (remove oldest messages)
async fn reduce_context_by_percentage(&mut self, percentage: f32) -> Result<bool, ApiError> {
    let total_messages = self.session.messages.len();
    if total_messages <= 2 { // Need to keep at least system and one other
        return Ok(false);
    }
    
    let to_remove = ((total_messages - 1) as f32 * percentage).round() as usize;
    let to_remove = to_remove.min(total_messages - 2); // Keep at least system and one message
    
    if to_remove > 0 {
        // Remove oldest non-system messages
        self.session.messages.drain(1..=to_remove);
        return Ok(true);
    }
    
    Ok(false)
}

// Reduce to summary-only context (keep system + last N exchanges)
async fn reduce_to_summary_context(&mut self) -> Result<bool, ApiError> {
    // Keep system message + last 2 exchanges (user+assistant pairs)
    let keep_count = 1 + (2 * 2); // system + 2 user + 2 assistant
    
    if self.session.messages.len() > keep_count {
        // Keep system message and last N exchanges
        let system_msg = self.session.messages[0].clone();
        let kept_messages = self.session.messages
            .iter()
            .skip(self.session.messages.len().saturating_sub(keep_count - 1))
            .cloned()
            .collect::<Vec<_>>();
        
        let mut new_messages = vec![system_msg];
        new_messages.extend(kept_messages);
        self.session.messages = new_messages;
        
        return Ok(true);
    }
    
    Ok(false)
}

// Reduce to system context only
async fn reduce_to_system_context(&mut self) -> Result<bool, ApiError> {
    // Keep only the system message
    if let Some(system_msg) = self.session.messages.iter()
        .find(|m| m.role == MessageRole::System)
        .cloned() {
        
        self.session.messages = vec![system_msg];
        return Ok(true);
    }
    
    Ok(false)
}

// Emergency context reset (more aggressive)
async fn attempt_emergency_context_reset(&mut self) -> Result<bool, ApiError> {
    // Try to keep only the most recent user message and system message
    if let Some(system_msg) = self.session.messages.iter()
        .find(|m| m.role == MessageRole::System)
        .cloned() {
        
        if let Some(last_user) = self.session.messages.iter()
            .rfind(|m| m.role == MessageRole::User)
            .cloned() {
            
            self.session.messages = vec![system_msg, last_user];
            return Ok(true);
        }
    }
    
    Ok(false)
}

// Simplify request for decoding errors (remove non-essential fields)
async fn simplify_request_for_decoding(&mut self, _request: &ApiRequest) -> Result<bool, ApiError> {
    #[allow(unused_variables)]
    let request = _request;
    // In a real implementation, we would:
    // 1. Remove non-essential fields like metadata, tools, etc.
    // 2. Keep only essential fields: model, messages, max_tokens, stream
    // 3. Simplify messages if needed
    
    // For now, just return false to indicate we didn't simplify
    Ok(false)
}

// Record stream debug info for diagnostics
async fn record_stream_debug_info(
    &mut self,
    message: &str,
    tokens_produced: Option<u32>,
    stream_events: &[String],
) -> Result<(), ApiError> {
    // Record to telemetry/tracing
    if let Some(tracer) = &self.session_tracer {
        let mut events_map = Map::new();
        events_map.insert("message".to_string(), Value::String(message.to_string()));
        events_map.insert("tokens_produced".to_string(), 
                         Value::from(tokens_produced.unwrap_or(0)));
        events_map.insert("event_count".to_string(), 
                         Value::from(stream_events.len()));
        
        // Add first few events as samples
        let sample_events: Vec<Value> = stream_events
            .iter()
            .take(5)
            .map(|e| Value::String(e.to_string()))
            .collect();
        events_map.insert("sample_events".to_string(), Value::Array(sample_events));
        
        tracer.record("stream_debug", events_map);
    }
    
    Ok(())
}

// Update context usage percentage (would call external token counting service)
fn update_context_usage(&mut self) -> Result<(), ApiError> {
    // In a real implementation, this would:
    // 1. Call the token counting endpoint
    // 2. Calculate usage percentage based on model's context window
    // 3. Store the result
    
    // For now, just set a placeholder value
    self.context_usage_percent = Some(0.5); // 50% placeholder
    Ok(())
}

// Retry the current request
async fn retry_request(
    &mut self,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Reset the stream failure count on retry attempt
    self.consecutive_stream_failures = 0;
    self.stream_debug_events.clear();
    
    // Re-run the turn with the same user input (but potentially modified session)
    // This is simplified - in reality we'd need to extract the original user input
    // from the session and rebuild the request
    self.run_turn_internal(request, iteration).await
}

// Internal helper to run turn with specific request
async fn run_turn_internal(
    &mut self,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // This would contain the core loop logic from run_turn
    // but using the provided request instead of rebuilding from session
    // For brevity, we're showing the concept
    
    let events = self.api_client.stream(request.clone()).await?;
    // ... process events as in original run_turn ...
    
    // Return a summary (simplified)
    Ok(TurnSummary {
        assistant_messages: Vec::new(),
        tool_results: Vec::new(),
        prompt_cache_events: Vec::new(),
        iterations: iteration,
        usage: TokenUsage::default(),
        auto_compaction: None,
    })
}

// Record API error for telemetry
async fn record_api_error(&self, error: &ApiError, iteration: usize) -> Result<(), ApiError> {
    if let Some(tracer) = &self.session_tracer {
        let mut attributes = Map::new();
        attributes.insert("iteration".to_string(), Value::from(iteration as u64));
        attributes.insert("error_type".to_string(), Value::from(format!("{:?}", error)));
        attributes.insert("error_message".to_string(), Value::from(error.to_string()));
        
        // Add context info if available
        if let Some(usage) = self.context_usage_percent {
            attributes.insert("context_usage_percent".to_string(), Value::from(usage));
        }
        
        tracer.record("api_error", attributes);
    }
    
    Ok(())
}

// Record turn failed for telemetry
fn record_turn_failed(&self, iteration: usize, error: &RuntimeError) {
    // Existing method - just calling it for completeness
    // self.record_turn_failed(iteration, error); // Already exists in original code
}
```

### Phase 3: API Client Enhancements (`anthropic.rs`)

#### 3.1 Resilience-Aware Streaming Method
**Lines to modify:** Around the `stream_message` method (~800-900)

**Specific Changes:**
```rust
impl AnthropicClient {
    // ... existing methods ...
    
    // NEW: Resilience-aware stream method
    pub async fn stream_with_resilience(
        &mut self,
        request: &MessageRequest,
        resilience_config: &ResilienceConfig,
    ) -> Result<Vec<AssistantEvent>, ApiError> {
        // Apply resilience configuration to this client instance
        let original_config = self.resilience_config.clone();
        self.resilience_config = resilience_config.clone();
        
        let result = self.stream_message(request).await;
        
        // Restore original config
        self.resilience_config = original_config;
        
        result
    }
    
    // ... existing stream_message method ...   
    // NEW: Enhanced stream_message with resilience features
    pub async fn stream_message(
        &mut self,
        request: &MessageRequest,
    ) -> Result<MessageStream, ApiError> {
        // ... existing preflight ...
        
        // NEW: Add resilience context to request for debugging
        let mut resilient_request = request.clone();
        // In a real implementation, we'd add resilience metadata to the request
        
        // Call existing stream_message but with enhanced error handling
        let response = self
            .send_with_retry_enhanced(&resilient_request)
            .await?;
            
        Ok(MessageStream {
            request_id: request_id_from_headers(response.headers()),
            response,
            parser: SseParser::new().with_context("Anthropic", request.model.clone()),
            pending: VecDeque::new(),
            done: false,
            request: resilient_request,
            prompt_cache: self.prompt_cache.clone(),
            latest_usage: None,
            usage_recorded: false,
            last_prompt_cache_record: Arc::clone(&self.last_prompt_cache_record),
        })
    }
    
    // NEW: Enhanced retry logic with resilience configuration
    async fn send_with_retry_enhanced(
        &mut self,
        request: &MessageRequest,
    ) -> Result<reqwest::Response, ApiError> {
        let mut attempts = 0;
        let mut last_error: Option<ApiError>;
        
        loop {
            attempts += 1;
            
            // NEW: Check resilience config for force disable
            if self.resilience_config.force_disable {
                return Err(ApiError::ResilienceDisabled);
            }
            
            // NEW: Check if we should attempt streaming based on resilience config
            if !self.should_attempt_streaming() {
                return Err(ApiError::StreamingDisabledByResilience);
            }
            
            match self.send_raw_request(request).await {
                Ok(response) => match self.expect_success_enhanced(response).await {
                    Ok(response) => {
                        // Record success
                        self.record_success(attempts)?;
                        return Ok(response);
                    }
                    Err(error) if error.is_retryable() && self.should_retry(error, attempts, &self.resilience_config) => {
                        self.record_failure(attempts, &error)?;
                        last_error = Some(error);
                    }
                    Err(error) => {
                        // Non-retryable error or max retries exceeded
                        let error = self.enhance_error_with_context(error, &self.auth, attempts)?;
                        self.record_failure(attempts, &error)?;
                        return Err(error);
                    }
                }
                Err(error) if error.is_retryable() && self.should_retry(error, attempts, &self.resilience_config) => {
                    self.record_failure(attempts, &error)?;
                    last_error = Some(error);
                }
                Err(error) => {
                    let error = self.enhance_error_with_context(error, &self.auth, attempts)?;
                    self.record_failure(attempts, &error)?;
                    return Err(error);
                }
            }
            
            // Check if we've exceeded max attempts
            if !self.should_continue_retrying(attempts, &last_error, &self.resilience_config) {
                break;
            }
            
            // Apply backoff based on error type and resilience config
            self.apply_resilient_backoff(attempts, &last_error, &self.resilience_config).await?;
        }
        
        Err(ApiError::RetriesExhausted {
            attempts,
            last_error: Box::new(last_error.expect("retry loop must capture an error")),
        })
    }
    
    // NEW: Determine if we should attempt streaming based on resilience config
    fn should_attempt_streaming(&self) -> bool {
        match self.resilience_config.force_enable() {
            true => true, // force-enable always attempts
            false => {
                // Only attempt if provider is considered local or explicitly enabled
                self.resilience_config.should_enable_for_provider(self.provider_name())
                    || self.resilience_config.should_enable_for_url(&self.base_url)
            }
        }
    }
    
    // NEW: Determine if we should retry based on error type and config
    fn should_retry(
        &self,
        error: &ApiError,
        attempt: u32,
        config: &ResilienceConfig,
    ) -> bool {
        // Check if we've exceeded max attempts for this error type
        match error {
            ApiError::Api { status, .. } => {
                match status.as_u16() {
                    400 => {
                        // Check specific 400 errors
                        let body_str = String::from_utf8_lossy(&error.body_bytes());
                        if body_str.contains("Model reloaded") {
                            attempt <= config.model_reloaded_max_retries
                        } else if body_str.contains("Context size has been exceeded") {
                            attempt <= config.context_exceeded_max_retries
                        } else if body_str.contains("Model unloaded") {
                            attempt <= config.model_unloaded_max_retries
                        } else if body_str.contains("tool_use blocks must be immediately followed by tool_result blocks") {
                            attempt <= config.tool_sequence_error_max_retries
                        } else {
                            // Default retry logic for other 400s
                            attempt <= 3
                        }
                    }
                    429 | 500 | 502 | 503 | 504 => {
                        // Standard retryable status codes
                        attempt <= 3 // Default, could be made configurable
                    }
                    _ => false, // Not retryable
                }
            }
            ApiError::Json { .. } => {
                // Decoding errors
                attempt <= config.decoding_error_max_retries
            }
            ApiError::Unknown { ref msg } => {
                // Unknown errors (like empty stream)
                if msg.contains("assistant stream produced no content") {
                    attempt <= 3 // Default for stream errors
                } else {
                    false
                }
            }
            _ => false, // Not retryable by default
        }
    }
    
    // NEW: Determine if we should continue retrying
    fn should_continue_retrying(
        &self,
        attempt: u32,
        last_error: &Option<ApiError>,
        config: &ResilienceConfig,
    ) -> bool {
        // Check force settings first
        if config.force_disable {
            return false;
        }
        
        // Check if we've exceeded general retry limits
        if attempt > 10 { // Hard limit to prevent infinite loops
            return false;
        }
        
        // Check specific error type limits via should_retry
        if let Some(error) = last_error {
            return self.should_retry(error, attempt, config);
        }
        
        true // Continue if no error yet
    }
    
    // NEW: Apply backoff based on error type and resilience config
    async fn apply_resilient_backoff(
        &mut self,
        attempt: u32,
        last_error: &Option<ApiError>,
        config: &ResilienceConfig,
    ) -> Result<(), ApiError> {
        // Determine base backoff based on error type
        let base_backoff = match last_error {
            Some(ApiError::Api { status, .. }) => {
                match status.as_u16() {
                    400 => {
                        let body_str = String::from_utf8_lossy(&status.to_string()); // Simplified
                        if body_str.contains("Model reloaded") {
                            config.model_reloaded_initial_backoff
                        } else if body_str.contains("Context size has been exceeded") {
                            config.context_exceeded_initial_backoff
                        } else if body_str.contains("Model unloaded") {
                            config.model_unloaded_initial_backoff
                        } else if body_str.contains("tool_use blocks must be immediately followed by tool_result blocks") {
                            config.tool_sequence_error_initial_backoff
                        } else {
                            Duration::from_secs(1) // Default
                        }
                    }
                    429 | 500 | 502 | 503 | 504 => Duration::from_secs(1), // Standard
                    _ => Duration::from_secs(1),
                }
            }
            Some(ApiError::Json { .. }) => config.decoding_error_initial_backoff,
            Some(ApiError::Unknown { ref msg }) => {
                if msg.contains("assistant stream produced no content") {
                    Duration::from_secs(1) // Stream error backoff
                } else {
                    Duration::from_secs(1)
                }
            }
            None => Duration::from_secs(1), // No error yet
        };
        
        // Apply exponential backoff with jitter
        let backoff = base_backoff * 2u32.pow(attempt.saturating_sub(1));
        let jitter = backoff * rand::random::<f32>() * 0.1; // 10% jitter
        let final_delay = backoff + jitter;
        
        tokio::time::sleep(final_delay).await;
        Ok(())
    }
    
    // NEW: Enhance error with context information
    fn enhance_error_with_context(
        &self,
        error: ApiError,
        auth: &AuthSource,
        attempt: u32,
    ) -> Result<ApiError, ApiError> {
        // Add attempt number and resilience context to errors
        match error {
            ApiError::Api { 
                status, 
                error_type, 
                message, 
                request_id, 
                body, 
                retryable, 
                suggested_action 
            } => {
                let resilience_context = ResilienceContext {
                    attempt,
                    max_attempts: 3, // Would come from config
                    error_type: error_type.clone().unwrap_or_else(|| "unknown".to_string()),
                    resilience_enabled: !self.resilience_config.force_disable,
                    context_usage_percent: None, // Would be updated from conversation runtime
                };
                
                Ok(ApiError::Api {
                    status,
                    error_type,
                    message,
                    request_id,
                    body,
                    retryable,
                    suggested_action,
                    resilience_context: Some(resilience_context),
                })
            }
            other => Ok(other), // Don't modify non-Api errors
        }
    }
    
    // NEW: Enhanced success expectation with better error details
    async fn expect_success_enhanced(
        &mut self,
        response: reqwest::Response,
    ) -> Result<reqwest::Response, ApiError> {
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        
        // Enhanced error handling with more context
        let request_id = request_id_from_headers(response.headers());
        let body = response.text().await.unwrap_or_else(|_| String::new());
        
        // Try to parse as Anthropic error
        let parsed_error = serde_json::from_str::<AnthropicErrorEnvelope>(&body).ok();
        let retryable = self.is_retryable_status(status);
        
        // Build enhanced error
        let mut api_error = ApiError::Api {
            status,
            error_type: parsed_error.as_ref().map(|e| e.error.error_type.clone()),
            message: parsed_error.as_ref().map(|e| e.error.message.clone()),
            request_id,
            body,
            retryable,
            suggested_action: None,
        };
        
        // Apply bearer token error enrichment if needed
        let enhanced_error = self.enrich_bearer_auth_error(api_error, &self.auth);
        
        // Add resilience context
        let final_error = self.enhance_error_with_context(enhanced_error, &self.auth, 0)?;
        
        Ok(final_error)
    }
    
    // ... existing helper methods (is_retryable_status, enrich_bearer_auth_error, etc.) ... 
}
```

#### 3.2 Payload Size Guarding
**Lines to modify:** Around the `send_raw_request` method (~1000-1100)

**Specific Changes:**
```rust
// NEW: Maximum response size constant
const MAX_RESPONSE_BODY_SIZE: usize = 5 * 1024 * 1024; // 5MB

async fn send_raw_request(
    &mut self,
    request: &MessageRequest,
) -> Result<reqwest::Response, ApiError> {
    let request_url = format!("{}/v1/messages", self.base_url.trim_end_matches('/'));
    let mut request_body = self.request_profile.render_json_body(request)?;
    strip_unsupported_beta_body_fields(&mut request_body);
    let request_builder = self.build_request(&request_url).json(&request_body);
    
    // NEW: Use timed request with size limits
    let response = request_builder
        .timeout(self.resilience_config.request_timeout) // Would need to add to config
        .send()
        .await
        .map_err(ApiError::from)?;
    
    // NEW: Check content length before reading body
    if let Some(content_length) = response.content_length() {
        if content_length as usize > MAX_RESPONSE_BODY_SIZE {
            return Err(ApiError::PayloadTooLarge {
                limit: MAX_RESPONSE_BODY_SIZE,
                actual: content_length as usize,
            });
        }
    }
    
    Ok(response)
}

// NEW: Helper to read response body with size limits
async fn read_response_body_with_limit(
    mut response: reqwest::Response,
    max_size: usize,
) -> Result<Bytes, ApiError> {
    let mut buffer = BytesMut::with_capacity(max_size);
    let mut read = 0usize;
    
    while let Some(chunk) = response.chunk().await? {
        let remaining = max_size - read;
        if chunk.len() > remaining {
            // Would exceed limit
            return Err(ApiError::PayloadTooLarge {
                limit: max_size,
                actual: read + chunk.len(),
            });
        }
        
        buffer.extend_from_slice(&chunk);
        read += chunk.len();
    }
    
    Ok(buffer.freeze())
}
```

### Phase 4: Provider Dispatch Layer (`client.rs`)

#### 4.1 Enhanced Error Propagation
**Lines to modify:** Around the `send_message` and `stream_message` methods (~150-200)

**Specific Changes:**
```rust
impl ProviderClient {
    // ... existing methods ...
    
    // NEW: Enhanced send_message with resilience context
    pub async fn send_message(
        &self,
        request: &MessageRequest,
    ) -> Result<MessageResponse, ApiError> {
        // Add attempt tracking to request for resilience logging
        let mut tracked_request = request.clone();
        // In a real implementation, we'd add resilience metadata
        
        match self {
            Self::Anthropic(client) => client.send_message(&tracked_request).await,
            Self::Xai(client) | Self::OpenAi(client) => client.send_message(&tracked_request).await,
        }
        // Note: In a full implementation, we'd need to extract resilience context
        // from the response and propagate it back to the conversation runtime
    }
    
    // NEW: Enhanced stream_message with resilience context
    pub async fn stream_message(
        &self,
        request: &MessageRequest,
    ) -> Result<MessageStream, ApiError> {
        let mut tracked_request = request.clone();
        // Add tracking metadata
        
        match self {
            Self::Anthropic(client) => client.stream_message(&tracked_request).await,
            Self::Xai(client) | Self::OpenAi(client) => client.stream_message(&tracked_request).await,
        }
    }
}
```

### Phase 5: Compaction Enhancements (`compact.rs`)

#### 5.1 Context-Aware Compaction Strategies
**Lines to modify:** Around the `compact_session` function (~50-150)

**Specific Changes:**
```rust
// NEW: Compaction strategy enum for different error scenarios
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompactionStrategy {
    Standard,
    Aggressive,      // For context overflow
    Conservative,    // For stream errors
    Preservative,    // For model reloads
    Emergency,       // For critical failures
}

// Update CompactionConfig to support strategies
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CompactionConfig {
    pub preserve_recent_messages: usize,
    pub max_estimated_tokens: usize,
    pub strategy: CompactionStrategy,
    
    // NEW: Context-specific parameters
    pub context_warning_threshold: f32,
    pub context_critical_threshold: f32,
}

impl Default for CompactionConfig {
    fn default() -> Self {
        Self {
            preserve_recent_messages: 4,
            max_estimated_tokens: 10_000,
            strategy: CompactionStrategy::Standard,
            context_warning_threshold: 0.8,
            context_critical_threshold: 0.95,
        }
    }
}

// NEW: Context-aware compaction factory
impl CompactionConfig {
    pub fn for_context_usage(&self, usage_percent: f32) -> Self {
        let mut config = *self;
        
        if usage_percent >= self.context_critical_threshold {
            config.strategy = CompactionStrategy::Aggressive;
            config.preserve_recent_messages = 1; // Keep minimal context
            config.max_estimated_tokens = 2000; // Aggressive limit
        } else if usage_percent >= self.context_warning_threshold {
            config.strategy = CompactionStrategy::Conservative;
            config.preserve_recent_messages = 3; // Keep reasonable context
            config.max_estimated_tokens = 5000; // Moderate limit
        } else {
            config.strategy = CompactionStrategy::Standard;
            // Keep defaults
        }
        
        config
    }
}

// Update compact_session to accept strategy
#[must_use]
pub fn compact_session(session: &Session, config: CompactionConfig) -> CompactionResult {
    // Use strategy to determine behavior
    match config.strategy {
        CompactionStrategy::Aggressive => compact_session_aggressive(session, config),
        CompactionStrategy::Conservative => compact_session_conservative(session, config),
        CompactionStrategy::Preservative => compact_session_preservative(session, config),
        CompactionStrategy::Emergency => compact_session_emergency(session, config),
        CompactionStrategy::Standard => compact_session_standard(session, config),
    }
}

// NEW: Aggressive compaction for context overflow
fn compact_session_aggressive(session: &Session, config: CompactionConfig) -> CompactionResult {
    // More aggressive than standard - preserve very little, summarize heavily
    let mut config = config;
    config.preserve_recent_messages = config.preserve_recent_messages.min(1);
    config.max_estimated_tokens = config.max_estimated_tokens.min(2000);
    
    compact_session_standard(session, config)
}

// NEW: Conservative compaction for stream errors
fn compact_session_conservative(session: &Session, config: CompactionConfig) -> CompactionResult {
    // Less aggressive - preserve more context to avoid losing useful information
    let mut config = config;
    config.preserve_recent_messages = config.preserve_recent_messages + 2;
    config.max_estimated_tokens = config.max_estimated_tokens + 2000;
    
    compact_session_standard(session, config)
}

// NEW: Preservative compaction for model reloads
fn compact_session_preservative(session: &Session, config: CompactionConfig) -> CompactionResult {
    // Preserve as much as possible since model state changed, not context issues
    let mut config = config;
    config.preserve_recent_messages = config.preserve_recent_messages + 3;
    config.max_estimated_tokens = config.max_estimated_tokens + 3000;
    
    compact_session_standard(session, config)
}

// NEW: Emergency compaction for critical failures
fn compact_session_emergency(session: &Session, config: CompactionConfig) -> CompactionResult {
    // Most aggressive - keep absolute minimum
    let mut config = config;
    config.preserve_recent_messages = config.preserve_recent_messages.min(0);
    config.max_estimated_tokens = config.max_estimated_tokens.min(1000);
    
    compact_session_standard(session, config)
}

// Standard compaction (existing logic moved here)
fn compact_session_standard(session: &Session, config: CompactionConfig) -> CompactionResult {
    // ... existing compact_session logic ...
    // (This would be the original compact_session function renamed)
}
```

### Phase 6: Session Management Enhancements (`session.rs`)

#### 6.1 Context Usage Tracking
**Lines to modify:** Around the Session struct and related methods

**Specific Changes:**
```rust
// NEW: Add context tracking to Session
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    // ... existing fields ...
    
    // NEW: Context tracking
    pub context_tracking: Option<ContextTracking>,
    
    // NEW: Model state tracking
    pub model_state: ModelState,
}

// NEW: Context tracking struct
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextTracking {
    pub estimated_tokens: usize,
    pub context_window_size: usize,
    pub last_updated: SystemTime,
    pub history: VecDeque<ContextSample>,
}

// NEW: Context sample for tracking usage over time
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextSample {
    pub timestamp: SystemTime,
    pub estimated_tokens: usize,
    pub context_window_size: usize,
}

// NEW: Model state tracking
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelState {
    Unknown,
    Loading,
    Loaded,
    Unloading,
    Failed,
    Reloading,
}

// NEW: Methods to update context tracking
impl Session {
    // ... existing methods ...
    
    // NEW: Update context usage estimate
    pub fn update_context_usage(&mut self, estimated_tokens: usize, context_window_size: usize) -> Result<(), SessionError> {
        if self.context_tracking.is_none() {
            self.context_tracking = Some(ContextTracking {
                estimated_tokens: 0,
                context_window_size: 0,
                last_updated: SystemTime::now(),
                history: VecDeque::with_capacity(100),
            });
        }
        
        if let Some(tracking) = &mut self.context_tracking {
            tracking.estimated_tokens = estimated_tokens;
            tracking.context_window_size = context_window_size;
            tracking.last_updated = SystemTime::now();
            
            // Add to history
            tracking.history.push_back(ContextSample {
                timestamp: SystemTime::now(),
                estimated_tokens,
                context_window_size,
            });
            
            // Keep history limited
            if tracking.history.len() > 100 {
                tracking.history.pop_front();
            }
        }
        
        Ok(())
    }
    
    // NEW: Get context usage percentage
    pub fn context_usage_percent(&self) -> Option<f32> {
        self.context_tracking.as_ref().map(|tracking| {
            if tracking.context_window_size == 0 {
                0.0
            } else {
                tracking.estimated_tokens as f32 / tracking.context_window_size as f32 * 100.0
            }
        })
    }
    
    // NEW: Get context trend (increasing/decreasing/stable)
    pub fn context_trend(&self) -> Option<ContextTrend> {
        self.context_tracking.as_ref().and_then(|tracking| {
            if tracking.history.len() < 2 {
                return None;
            }
            
            let recent = tracking.history.range(tracking.history.len().saturating_sub(5)..);
            let tokens: Vec<usize> = recent.map(|s| s.estimated_tokens).collect();
            
            if tokens.len() < 2 {
                return None;
            }
            
            let first = tokens[0] as f32;
            let last = *tokens.last().unwrap() as f32;
            
            if last > first * 1.1 {
                Some(ContextTrend::Increasing)
            } else if last < first * 0.9 {
                Some(ContextTrend::Decreasing)
            } else {
                Some(ContextTrend::Stable)
            }
        })
    }
    
    // NEW: Predict when context will be exceeded
    pub fn predict_context_exhaustion(&self) -> Option<Duration> {
        self.context_tracking.as_ref().and_then(|tracking| {
            if tracking.history.len() < 3 {
                return None;
            }
            
            // Simple linear prediction based on last 3 samples
            let samples: Vec<ContextSample> = tracking.history.range(tracking.history.len().saturating_sub(3)..).cloned().collect();
            if samples.len() < 3 {
                return None;
            }
            
            let time_diff = samples[2].timestamp.duration_since(samples[0].timestamp).ok()?;
            let token_diff = samples[2].estimated_tokens as i64 - samples[0].estimated_tokens as i64;
            
            if token_diff <= 0 || tracking.context_window_size == 0 {
                return None;
            }
            
            let tokens_per_second = token_diff as f32 / time_diff.as_secs_f32();
            let tokens_remaining = (tracking.context_window_size as i64 - tracking.estimated_tokens as i64) as f32;
            
            if tokens_per_second <= 0.0 {
                return None;
            }
            
            let seconds_remaining = tokens_remaining / tokens_per_second;
            Some(Duration::from_secs_f32(seconds_remaining))
        })
    }
}

// NEW: Context trend enum
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContextTrend {
    Increasing,
    Decreasing,
    Stable,
}
```

### Phase 7: Hook System Enhancements (`hooks.rs`)

#### 7.1 Debugging Hooks for Stream Issues
**Lines to modify:** Around the HookRunner and related traits

**Specific Changes:**
```rust
// NEW: Stream debugging hook types
pub trait HookStreamDebugger {
    fn on_stream_start(
        &mut self,
        request: &MessageRequest,
        context: &StreamDebugContext,
    ) -> HookRunResult;
    
    fn on_stream_chunk(
        &mut self,
        chunk: &[u8],
        context: &StreamDebugContext,
    ) -> HookRunResult;
    
    fn on_stream_end(
        &mut self,
        result: &StreamResult,
        context: &StreamDebugContext,
    ) -> HookRunResult;
    
    fn on_stream_error(
        &mut self,
        error: &ApiError,
        context: &StreamDebugContext,
    ) -> HookRunResult;
}

// NEW: Stream debugging context
#[derive(Debug, Clone)]
pub struct StreamDebugContext {
    pub request_id: Option<String>,
    pub model: String,
    pub attempt: u32,
    pub resilience_enabled: bool,
    pub context_usage_percent: Option<f32>,
    pub consecutive_failures: usize,
    pub tokens_produced_so_far: Option<u32>,
}

// NEW: Stream result for debugging
#[derive(Debug, Clone)]
pub struct StreamResult {
    pub events_produced: usize,
    pub tokens_produced: Option<u32>,
    pub duration: Duration,
    pub success: bool,
}

// Update HookRunner to support stream debugging hooks
pub struct HookRunner {
    // ... existing fields ...
    
    // NEW: Stream debugging hooks
    pub stream_debug_hooks: Vec<Box<dyn HookStreamDebugger>>,
    
    // ... existing methods ...
    
    // NEW: Methods to run stream debugging hooks
    pub fn run_stream_debug_start_hook(
        &mut self,
        request: &MessageRequest,
        context: &StreamDebugContext,
    ) -> HookRunResult {
        // ... implementation similar to other hook runners ...
    }
    
    // ... other stream debug hook methods ...
}

// Update StaticToolExecutor or add new StreamDebugExecutor for testing
#[derive(Default)]
pub struct StreamDebugExecutor {
    // ... fields for capturing stream debug info ...
}

// Implement HookStreamDebugger for StreamDebugExecutor
impl HookStreamDebugger for StreamDebugExecutor {
    // ... implementation ...
}
```

## Implementation Sequence

### Phase 1: Foundation (Days 1-2)
1. [ ] Update `resilience_config.rs` with error-specific configurations
2. [ ] Enhance `error.rs` with new error types and context tracking
3. [ ] Implement basic resilience configuration validation

### Phase 2: Conversation Runtime (Days 3-5)
1. [ ] Update `conversation.rs` constructor and fields
2. [ ] Implement enhanced `run_turn` with resilience-aware API calls
3. [ ] Add all specific error handlers (model reloaded, context exceeded, etc.)
4. [ ] Implement helper methods for backoff, retry counting, context management
5. [ ] Add telemetry recording for resilience events

### Phase 3: API Client (Days 6-8)
1. [ ] Add resilience-aware streaming method to `anthropic.rs`
2. [ ] Implement enhanced retry logic with error-type-specific backoffs
3. [ ] Add payload size guarding and response size limits
4. [ ] Enhance error reporting with context information
5. [ ] Update OpenAI-compatible provider similarly

### Phase 4: Provider Dispatch (Day 9)
1. [ ] Enhance `client.rs` to propagate resilience context
2. [ ] Ensure error information flows properly between layers

### Phase 5: Compaction Enhancement (Days 10-11)
1. [ ] Update `compact.rs` with strategy-based compaction
2. [ ] Implement context-aware compaction strategies
3. [ ] Add emergency and preservative compaction modes

### Phase 6: Session Management (Days 12-13)
1. [ ] Update `session.rs` with context tracking capabilities
2. [ ] Add model state tracking
3. [ ] Implement context usage prediction and trending

### Phase 7: Hook System (Days 14-15)
1. [ ] Update `hooks.rs` with stream debugging capabilities
2. [ ] Add hooks for capturing detailed stream information
3. [ ] Implement debug hook executors for testing

### Phase 8: Testing and Validation (Days 16-20)
1. [ ] Create unit tests for each error handler
2. [ ] Build integration tests simulating error conditions
3. [ ] Develop chaos engineering tests for concurrent failures
4. [ ] Performance benchmarking to ensure no degradation
5. [ ] Documentation and knowledge transfer

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

## Performance Considerations

### Overhead Minimization
1. [ ] Resilience checks add <1% overhead in non-error paths
2. [ ] Context tracking uses efficient circular buffers
3. [ ] Error type discrimination uses enum matching, not string comparisons
4. [ ] Backoff calculations are lightweight and cached where possible

### Memory Efficiency
1. [ ] Stream debug events use bounded VecDeque (100 entries max)
2. [ ] Context history uses bounded VecDeque (100 entries max)
3. [ ] Retry counts use HashMap with bounded growth
4. [ ] Telemetry data is sampled when volume is high

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
6. **Testability**: Comprehensive test coverage for all scenarios

Each modification includes specific line references and implementation procedures, making it straightforward for developers to follow and implement. The plan builds upon the existing resilience foundation and incorporates lessons from the robustness layer documents while adding extensive new capabilities for handling the specific error conditions identified.

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

### Phase 1: Foundation Enhancements

#### 1.1 Resilience Configuration Updates (`resilience_config.rs`)
**Lines to modify:** Around 20-50 (constructor and methods)

**Specific Changes:**
```rust
// Add error-type-specific retry budgets
#[derive(Debug, Clone)]
pub struct ResilienceConfig {
    // ... existing fields ...
    
    // Error-specific retry configurations
    pub model_reloaded_max_retries: u32,
    pub context_exceeded_max_retries: u32,
    pub stream_empty_max_retries: u32,
    pub decoding_error_max_retries: u32,
    pub model_unloaded_max_retries: u32,
    pub tool_sequence_error_max_retries: u32,
    
    // Backoff configurations
    pub model_reloaded_initial_backoff: Duration,
    pub context_exceeded_initial_backoff: Duration,
    pub stream_empty_initial_backoff: Duration,
    pub decoding_error_initial_backoff: Duration,
    pub model_unloaded_initial_backoff: Duration,
    pub tool_sequence_error_initial_backoff: Duration,
    
    // Context management thresholds
    pub context_warning_threshold: f32,  // 0.8 for 80%
    pub context_critical_threshold: f32, // 0.95 for 95%
    pub aggressive_compaction_preserve_recent: usize,
    pub conservative_compaction_preserve_recent: usize,
}

// Update default() method
impl ResilienceConfig {
    pub fn default() -> Self {
        Self {
            // ... existing defaults ...
            model_reloaded_max_retries: 3,
            context_exceeded_max_retries: 2,
            stream_empty_max_retries: 3,
            decoding_error_max_retries: 2,
            model_unloaded_max_retries: 5,
            tool_sequence_error_max_retries: 2,
            
            model_reloaded_initial_backoff: Duration::from_secs(1),
            context_exceeded_initial_backoff: Duration::from_secs(2),
            stream_empty_initial_backoff: Duration::from_secs(1),
            decoding_error_initial_backoff: Duration::from_secs(1),
            model_unloaded_initial_backoff: Duration::from_secs(3),
            tool_sequence_error_initial_backoff: Duration::from_secs(1),
            
            context_warning_threshold: 0.8,
            context_critical_threshold: 0.95,
            aggressive_compaction_preserve_recent: 1,
            conservative_compaction_preserve_recent: 3,
        }
    }
}

// Add validation method
impl ResilienceConfig {
    pub fn validate(&self) -> Result<(), String> {
        if self.model_reloaded_max_retries > 10 {
            return Err("model_reloaded_max_retries too high".to_string());
        }
        // ... validate other fields ...
        Ok(())
    }
}
```

#### 1.2 Error Type Enhancements (`error.rs`)
**Lines to modify:** Add new error variants around existing ApiError enum

**Specific Changes:**
```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApiError {
    // ... existing variants ...
    
    // New error types for better handling
    ToolSequenceError {
        request_id: Option<String>,
        body: String,
    },
    
    StreamDebugInfo {
        message: String,
        tokens_produced: Option<u32>,
        stream_events: Vec<String>,
    },
    
    // Enhanced existing error with more context
    Api {
        // ... existing fields ...
        resilience_context: Option<ResilienceContext>,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResilienceContext {
    pub attempt: u32,
    pub max_attempts: u32,
    pub error_type: String,
    pub resilience_enabled: bool,
    pub context_usage_percent: Option<f32>,
}

// Implement From conversions for new error types
impl From<ToolSequenceError> for ApiError {
    fn from(err: ToolSequenceError) -> Self {
        ApiError::ToolSequenceError {
            request_id: err.request_id,
            body: err.body,
        }
    }
}

// Add helper to create stream debug info
impl ApiError {
    pub fn stream_debug(
        message: impl Into<String>,
        tokens_produced: Option<u32>,
        stream_events: Vec<String>
    ) -> Self {
        ApiError::StreamDebugInfo {
            message: message.into(),
            tokens_produced,
            stream_events,
        }
    }
}
```

### Phase 2: Conversation Runtime Enhancements (`conversation.rs`)

#### 2.1 Constructor and Field Updates
**Lines to modify:** Around 50-100 (constructor and new_with_features)

**Specific Changes:**
```rust
pub struct ConversationRuntime<C, T> {
    // ... existing fields ...
    
    // NEW: Resilience configuration
    resilience_config: ResilienceConfig,
    
    // NEW: Error tracking and debugging
    consecutive_stream_failures: usize,
    last_stream_tokens: Option<u32>,
    stream_debug_events: VecDeque<String>,
    
    // NEW: Model state tracking
    model_load_state: ModelLoadState,
    model_ready_at: Option<SystemTime>,
    
    // NEW: Context monitoring
    context_usage_percent: Option<f32>,
}

// Add new enum for model state tracking
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelLoadState {
    Unknown,
    Loading,
    Loaded,
    Unloading,
    Failed,
}

// Update constructor to accept resilience config
impl<C, T> ConversationRuntime<C, T>
where
    C: ApiClient,
    T: ToolExecutor,
{
    #[must_use]
    pub fn new(
        session: Session,
        api_client: C,
        tool_executor: T,
        permission_policy: PermissionPolicy,
        system_prompt: Vec<String>,
        resilience_config: ResilienceConfig, // NEW PARAMETER
    ) -> Self {
        // ... existing init ...
        Self {
            // ... existing fields ...
            resilience_config,
            consecutive_stream_failures: 0,
            last_stream_tokens: None,
            stream_debug_events: VecDeque::with_capacity(100),
            model_load_state: ModelLoadState::Unknown,
            model_ready_at: None,
            context_usage_percent: None,
        }
    }
}

// Update new_with_features similarly
```

#### 2.2 Enhanced `run_turn` Method
**Lines to modify:** Around 200-300 (main loop)

**Specific Changes:**
```rust
pub fn run_turn(
    &mut self,
    user_input: impl Into<String>,
    mut prompter: Option<&mut dyn PermissionPrompter>,
) -> Result<TurnSummary, RuntimeError> {
    // ... existing setup ...
    
    // NEW: Pre-turn context check
    self.update_context_usage()?;
    
    // NEW: Handle context warnings/critical levels
    if let Some(usage) = self.context_usage_percent {
        if usage >= self.resilience_config.context_critical_threshold {
            // Critical context level - force compaction before proceeding
            if let Err(e) = self.handle_critical_context()? {
                return Err(RuntimeError::new(format!(
                    "Failed to handle critical context: {}", e
                )));
            }
        } else if usage >= self.resilience_config.context_warning_threshold {
            // Warning level - log for monitoring
            if let Some(tracer) = &self.session_tracer {
                tracer.record("context_warning", map!{
                    "usage_percent" => usage,
                    "threshold" => self.resilience_config.context_warning_threshold
                });
            }
        }
    }
    
    // ... existing message pushing ...
    
    // MAIN LOOP WITH ENHANCED ERROR HANDLING
    loop {
        // ... iteration limit check ...
        
        let request = ApiRequest {
            system_prompt: self.system_prompt.clone(),
            messages: self.session.messages.clone(),
        };
        
        // NEW: Resilience-aware API call with specific error handling
        let events = match self.resilient_api_call(&request).await {
            Ok(events) => events,
            Err(error) => {
                // NEW: Enhanced error handling with specific strategies
                return self.handle_api_error(error, &request, iterations).await;
            }
        };
        
        // ... rest of existing loop ...
    }
}

// NEW: Resilient API call wrapper
async fn resilient_api_call(
    &mut self,
    request: &ApiRequest,
) -> Result<Vec<AssistantEvent>, ApiError> {
    // Apply resilience configuration to the API client call
    // This delegates to the API client's resilience-aware methods
    self.api_client.stream_with_resilience(request, &self.resilience_config).await
}

// NEW: Comprehensive error handler
async fn handle_api_error(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Record error for telemetry
    self.record_api_error(&error, iteration).await?;
    
    // Match on error type for specific handling
    match error {
        ApiError::Api { 
            ref message, 
            ref error_type, 
            status, 
            ref body, 
            retryable, 
            .. 
        } if retryable => {
            // Handle specific error messages
            match (message.as_deref(), error_type.as_deref(), status.as_u16()) {
                // Model reloaded error
                (Some(msg), Some(err_type), 400) if msg.contains("Model reloaded") && err_type == "invalid_request_error" => {
                    return self.handle_model_reloaded(error, request, iteration).await;
                }
                
                // Context size exceeded
                (Some(msg), Some(err_type), 400) if msg.contains("Context size has been exceeded") && err_type == "invalid_request_error" => {
                    return self.handle_context_exceeded(error, request, iteration).await;
                }
                
                // Model unloaded
                (Some(msg), Some(err_type), 400) if msg.contains("Model unloaded") && err_type == "invalid_request_error" => {
                    return self.handle_model_unloaded(error, request, iteration).await;
                }
                
                // Invalid tool_use/tool_result sequence (NEW)
                (Some(msg), Some(err_type), 400) if msg.contains("tool_use blocks must be immediately followed by tool_result blocks") && err_type == "invalid_request_error" => {
                    return self.handle_tool_sequence_error(error, request, iteration).await;
                }
                
                // Default retry handling for other retryable errors
                _ => {
                    return self.handle_generic_retry(error, request, iteration).await;
                }
            }
        }
        
        // Stream produced no content (NEW - unknown error kind)
        ApiError::Unknown { msg } if msg.contains("assistant stream produced no content") => {
            return self.handle_empty_stream(error, request, iteration).await;
        }
        
        // Decoding errors
        ApiError::Json { .. } => {
            return self.handle_decoding_error(error, request, iteration).await;
        }
        
        // Tool sequence errors (direct handling)
        ApiError::ToolSequenceError { .. } => {
            return self.handle_tool_sequence_error(error, request, iteration).await;
        }
        
        // Stream debug info (for enhanced diagnostics)
        ApiError::StreamDebugInfo { .. } => {
            return self.handle_stream_debug(error, request, iteration).await;
        }
        
        // Non-retryable errors
        _ => {
            self.record_turn_failed(iteration, &error);
            return Err(error);
        }
    }
}

// NEW: Specific error handlers

// Handle model reloaded error
async fn handle_model_reloaded(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Check if we have retries left
    if self.get_retry_count("model_reloaded") < self.resilience_config.model_reloaded_max_retries {
        // Apply backoff
        self.apply_backoff("model_reloaded").await?;
        
        // Increment retry counter
        self.increment_retry_count("model_reloaded");
        
        // Retry the request
        return self.retry_request(request, iteration).await;
    }
    
    // If we've exhausted retries, try context compaction as last resort
    if self.attempt_context_compaction("model_reloaded").await? {
        // Reset retry counter after successful compaction
        self.reset_retry_count("model_reloaded");
        return self.retry_request(request, iteration).await;
    }
    
    // If all else fails, return the error
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle context size exceeded error
async fn handle_context_exceeded(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Try aggressive compaction first
    if self.attempt_aggressive_compaction().await? {
        // Reset context tracking
        self.context_usage_percent = None;
        return self.retry_request(request, iteration).await;
    }
    
    // If compaction fails, try message truncation
    if self.attempt_message_truncation().await? {
        return self.retry_request(request, iteration).await;
    }
    
    // If all else fails, return error
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle model unloaded error
async fn handle_model_unloaded(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // For local models, wait for model to be ready
    if self.is_local_model_request(request).await? {
        if self.wait_for_model_ready().await? {
            // Model is ready, retry request
            return self.retry_request(request, iteration).await;
        }
    }
    
    // For remote models or if waiting failed, apply standard retry logic
    if self.get_retry_count("model_unloaded") < self.resilience_config.model_unloaded_max_retries {
        self.apply_backoff("model_unloaded").await?;
        self.increment_retry_count("model_unloaded");
        return self.retry_request(request, iteration).await;
    }
    
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle tool sequence error (NEW)
async fn handle_tool_sequence_error(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // This indicates malformed conversation history
    // Attempt to heal the history by fixing tool_use/tool_result pairs
    
    if self.attempt_history_healing().await? {
        // History healed, retry request
        if self.get_retry_count("tool_sequence") < self.resilience_config.tool_sequence_error_max_retries {
            self.apply_backoff("tool_sequence").await?;
            self.increment_retry_count("tool_sequence");
            return self.retry_request(request, iteration).await;
        }
    }
    
    // If healing fails or retries exhausted, return error
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle empty stream error (NEW - extensive debugging)
async fn handle_empty_stream(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Increment consecutive stream failures
    self.consecutive_stream_failures += 1;
    
    // If we have stream debug info, record it
    if let ApiError::StreamDebugInfo { message, tokens_produced, stream_events } = error {
        self.last_stream_tokens = tokens_produced;
        self.stream_debug_events.extend(stream_events);
        
        // Record extensive debugging info
        self.record_stream_debug_info(&message, tokens_produced, &stream_events).await?;
    }
    
    // If we haven't exceeded max retries, try recovery strategies
    if self.consecutive_stream_failures < self.resilience_config.stream_empty_max_retries {
        // Apply backoff
        self.apply_backoff("stream_empty").await?;
        
        // Try different context reduction strategies based on attempt number
        match self.consecutive_stream_failures {
            1 => {
                // First retry: try with reduced context (remove oldest 30%)
                if self.reduce_context_by_percentage(0.3).await? {
                    return self.retry_request(request, iteration).await;
                }
            }
            2 => {
                // Second retry: try with summary-only context (keep system + last 2 exchanges)
                if self.reduce_to_summary_context().await? {
                    return self.retry_request(request, iteration).await;
                }
            }
            3 => {
                // Third retry: try with minimal context (system only)
                if self.reduce_to_system_context().await? {
                    return self.retry_request(request, iteration).await;
                }
            }
            _ => {
                // Beyond standard retries, try aggressive measures
                if self.attempt_emergency_context_reset().await? {
                    return self.retry_request(request, iteration).await;
                }
            }
        }
    }
    
    // If all recovery strategies fail, return error with debug info
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle decoding errors
async fn handle_decoding_error(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Check if we have retries left
    if self.get_retry_count("decoding") < self.resilience_config.decoding_error_max_retries {
        // Apply backoff
        self.apply_backoff("decoding").await?;
        
        // Before retry, try to simplify the request
        if self.simplify_request_for_decoding(request).await? {
            self.increment_retry_count("decoding");
            return self.retry_request(request, iteration).await;
        }
    }
    
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle stream debug info (for enhanced diagnostics)
async fn handle_stream_debug(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Extract stream debug info
    if let ApiError::StreamDebugInfo { message, tokens_produced, stream_events } = error {
        // Record detailed debugging information
        self.record_stream_debug_info(&message, tokens_produced, &stream_events).await?;
        
        // For stream debug info, we typically don't retry immediately as it's informational
        // But if it's associated with an empty stream, we might want to apply similar logic
        if message.contains("assistant stream produced no content") {
            // Treat similar to empty stream for recovery purposes
            return self.handle_empty_stream(error, request, iteration).await;
        }
    }
    
    // If not associated with a recoverable error, just record and continue
    // (In practice, we might still want to retry depending on context)
    self.record_turn_faced(iteration, &error);
    return Err(error);
}

// Generic retry handler for other errors
async fn handle_generic_retry(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Use a generic retry key for errors without specific handlers
    let retry_key = format!("generic_{:?}", error);
    
    if self.get_retry_count(&retry_key) < 3 { // Default max retries for generic errors
        self.apply_backoff("generic").await?;
        self.increment_retry_count(&retry_key);
        return self.retry_request(request, iteration).await;
    }
    
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Helper methods for the above handlers

// Get retry count for a specific error type
fn get_retry_count(&self, error_type: &str) -> usize {
    *self.retry_counts.get(error_type).unwrap_or(&0)
}

// Increment retry count for a specific error type
fn increment_retry_count(&mut self, error_type: &str) {
    *self.retry_counts.entry(error_type.to_string()).or_insert(0) += 1;
}

// Reset retry count for a specific error type
fn reset_retry_count(&mut self, error_type: &str) {
    self.retry_counts.insert(error_type.to_string(), 0);
}

// Apply backoff based on error type and retry count
async fn apply_backoff(&mut self, error_type: &str) -> Result<(), ApiError> {
    let attempt = self.get_retry_count(error_type);
    let backoff = match error_type {
        "model_reloaded" => self.resilience_config.model_reloaded_initial_backoff,
        "context_exceeded" => self.resilience_config.context_exceeded_initial_backoff,
        "stream_empty" => self.resilience_config.stream_empty_initial_backoff,
        "decoding" => self.resilience_config.decoding_error_initial_backoff,
        "model_unloaded" => self.resilience_config.model_unloaded_initial_backoff,
        "tool_sequence" => self.resilience_config.tool_sequence_error_initial_backoff,
        _ => Duration::from_secs(1), // Default
    };
    
    // Apply exponential backoff with jitter
    let delay = backoff * 2u32.pow(attempt as u32);
    let jitter = delay * rand::random::<f32>() * 0.1; // 10% jitter
    let final_delay = delay + jitter;
    
    tokio::time::sleep(final_delay).await;
    Ok(())
}

// Attempt context compaction with aggressive settings
async fn attempt_aggressive_compaction(&mut self) -> Result<bool, ApiError> {
    let config = CompactionConfig {
        preserve_recent_messages: self.resilience_config.aggressive_compaction_preserve_recent,
        max_estimated_tokens: 2000, // Aggressive limit
    };
    
    let result = compact_session(&self.session, config);
    if result.removed_message_count > 0 {
        self.session = result.compacted_session;
        Ok(true)
    } else {
        Ok(false)
    }
}

// Attempt message truncation (truncate oldest user message by 50%)
async fn attempt_message_truncation(&mut self) -> Result<bool, ApiError> {
    // Find the oldest user message and truncate it
    if let Some(index) = self.session.messages.iter()
        .position(|m| m.role == MessageRole::User) {
        
        let message = &self.session.messages[index];
        // Truncate the text content by 50%
        if let Some(text_block) = message.blocks.iter()
            .find(|b| matches!(b, ContentBlock::Text { .. })) {
            
            if let ContentBlock::Text { text } = text_block {
                let mid_point = text.len() / 2;
                let truncated = text[mid_point..].to_string();
                
                // Create new message with truncated text
                let new_message = ConversationMessage {
                    role: MessageRole::User,
                    blocks: vec![ContentBlock::Text { text: truncated }],
                    usage: None,
                };
                
                // Replace the message
                self.session.messages[index] = new_message;
                return Ok(true);
            }
        }
    }
    
    Ok(false)
}

// Check if request is for a local model
async fn is_local_model_request(&self, request: &ApiRequest) -> Result<bool, ApiError> {
    // Check if the model in the request is a local model
    // This would typically involve checking the model name against known local model patterns
    // or checking if the base_url points to localhost
    let model = &request.messages.last().unwrap_or(&request.messages[0]).blocks[0]; // Simplified
    
    // More realistically, we'd check the API client's base_url
    // For now, return false as placeholder
    Ok(false)
}

// Wait for model to be ready (polling)
async fn wait_for_model_ready(&mut self) -> Result<bool, ApiError> {
    let start = SystemTime::now();
    let timeout = Duration::from_secs(30); // 30 second timeout
    
    loop {
        // Check if model is ready (this would involve a health check API call)
        // For now, simulate with a simple delay and state check
        if self.model_load_state == ModelLoadState::Loaded {
            self.model_ready_at = Some(SystemTime::now());
            return Ok(true);
        }
        
        // Check timeout
        if start.elapsed()? > timeout {
            return Err(ApiError::Timeout {
                operation: "model_ready".to_string(),
                duration: timeout.as_secs(),
            });
        }
        
        // Wait before next check
        tokio::time::sleep(Duration::from_secs(2)).await;
        
        // In a real implementation, we'd poll a health check endpoint here
        // For now, just continue looping
    }
}

// Attempt to heal conversation history (fix tool_use/tool_result pairs)
async fn attempt_history_healing(&mut self) -> Result<bool, ApiError> {
    // Scan through messages and fix any tool_use blocks not followed by tool_result
    let mut healed = false;
    let mut i = 0;
    
    while i < self.session.messages.len() {
        if let MessageRole::Assistant = self.session.messages[i].role {
            // Check if this assistant message has tool_use blocks
            let has_tool_use = self.session.messages[i].blocks.iter()
                .any(|b| matches!(b, ContentBlock::ToolUse { .. }));
            
            if has_tool_use {
                // Look ahead for the tool_result
                let mut found_tool_result = false;
                let mut j = i + 1;
                
                while j < self.session.messages.len() && !found_tool_result {
                    if let MessageRole::Tool = self.session.messages[j].role {
                        // Check if this tool result matches any of the tool uses above
                        // For simplicity, we'll just check if there's at least one tool result
                        found_tool_result = true;
                        break;
                    }
                    j += 1;
                }
                
                if !found_tool_result && j < self.session.messages.len() {
                    // We found a gap - insert a tool result
                    healed = true;
                    // In a real implementation, we'd create an appropriate tool result
                    // For now, just insert a placeholder
                    let tool_result_msg = ConversationMessage::tool_result(
                        "healed".to_string(),
                        "healed_tool".to_string(),
                        "Automatically healed by resilience system".to_string(),
                        false,
                    );
                    self.session.messages.insert(j, tool_result_msg);
                    i = j + 1; // Skip past the inserted message
                    continue;
                }
            }
        }
        i += 1;
    }
    
    Ok(healed)
}

// Reduce context by percentage (remove oldest messages)
async fn reduce_context_by_percentage(&mut self, percentage: f32) -> Result<bool, ApiError> {
    let total_messages = self.session.messages.len();
    if total_messages <= 2 { // Need to keep at least system and one other
        return Ok(false);
    }
    
    let to_remove = ((total_messages - 1) as f32 * percentage).round() as usize;
    let to_remove = to_remove.min(total_messages - 2); // Keep at least system and one message
    
    if to_remove > 0 {
        // Remove oldest non-system messages
        self.session.messages.drain(1..=to_remove);
        return Ok(true);
    }
    
    Ok(false)
}

// Reduce to summary-only context (keep system + last N exchanges)
async fn reduce_to_summary_context(&mut self) -> Result<bool, ApiError> {
    // Keep system message + last 2 exchanges (user+assistant pairs)
    let keep_count = 1 + (2 * 2); // system + 2 user + 2 assistant
    
    if self.session.messages.len() > keep_count {
        // Keep system message and last N exchanges
        let system_msg = self.session.messages[0].clone();
        let kept_messages = self.session.messages
            .iter()
            .skip(self.session.messages.len().saturating_sub(keep_count - 1))
            .cloned()
            .collect::<Vec<_>>();
        
        let mut new_messages = vec![system_msg];
        new_messages.extend(kept_messages);
        self.session.messages = new_messages;
        
        return Ok(true);
    }
    
    Ok(false)
}

// Reduce to system context only
async fn reduce_to_system_context(&mut self) -> Result<bool, ApiError> {
    // Keep only the system message
    if let Some(system_msg) = self.session.messages.iter()
        .find(|m| m.role == MessageRole::System)
        .cloned() {
        
        self.session.messages = vec![system_msg];
        return Ok(true);
    }
    
    Ok(false)
}

// Emergency context reset (more aggressive)
async fn attempt_emergency_context_reset(&mut self) -> Result<bool, ApiError> {
    // Try to keep only the most recent user message and system message
    if let Some(system_msg) = self.session.messages.iter()
        .find(|m| m.role == MessageRole::System)
        .cloned() {
        
        if let Some(last_user) = self.session.messages.iter()
            .rfind(|m| m.role == MessageRole::User)
            .cloned() {
            
            self.session.messages = vec![system_msg, last_user];
            return Ok(true);
        }
    }
    
    Ok(false)
}

// Simplify request for decoding errors (remove non-essential fields)
async fn simplify_request_for_decoding(&mut self, _request: &ApiRequest) -> Result<bool, ApiError> {
    #[allow(unused_variables)]
    let request = _request;
    // In a real implementation, we would:
    // 1. Remove non-essential fields like metadata, tools, etc.
    // 2. Keep only essential fields: model, messages, max_tokens, stream
    // 3. Simplify messages if needed
    
    // For now, just return false to indicate we didn't simplify
    Ok(false)
}

// Record stream debug info for diagnostics
async fn record_stream_debug_info(
    &mut self,
    message: &str,
    tokens_produced: Option<u32>,
    stream_events: &[String],
) -> Result<(), ApiError> {
    // Record to telemetry/tracing
    if let Some(tracer) = &self.session_tracer {
        let mut events_map = Map::new();
        events_map.insert("message".to_string(), Value::String(message.to_string()));
        events_map.insert("tokens_produced".to_string(), 
                         Value::from(tokens_produced.unwrap_or(0)));
        events_map.insert("event_count".to_string(), 
                         Value::from(stream_events.len()));
        
        // Add first few events as samples
        let sample_events: Vec<Value> = stream_events
            .iter()
            .take(5)
            .map(|e| Value::String(e.to_string()))
            .collect();
        events_map.insert("sample_events".to_string(), Value::Array(sample_events));
        
        tracer.record("stream_debug", events_map);
    }
    
    Ok(())
}

// Update context usage percentage (would call external token counting service)
fn update_context_usage(&mut self) -> Result<(), ApiError> {
    // In a real implementation, this would:
    // 1. Call the token counting endpoint
    // 2. Calculate usage percentage based on model's context window
    // 3. Store the result
    
    // For now, just set a placeholder value
    self.context_usage_percent = Some(0.5); // 50% placeholder
    Ok(())
}

// Retry the current request
async fn retry_request(
    &mut self,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Reset the stream failure count on retry attempt
    self.consecutive_stream_failures = 0;
    self.stream_debug_events.clear();
    
    // Re-run the turn with the same user input (but potentially modified session)
    // This is simplified - in reality we'd need to extract the original user input
    // from the session and rebuild the request
    self.run_turn_internal(request, iteration).await
}

// Internal helper to run turn with specific request
async fn run_turn_internal(
    &mut self,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // This would contain the core loop logic from run_turn
    // but using the provided request instead of rebuilding from session
    // For brevity, we're showing the concept
    
    let events = self.api_client.stream(request.clone()).await?;
    // ... process events as in original run_turn ...
    
    // Return a summary (simplified)
    Ok(TurnSummary {
        assistant_messages: Vec::new(),
        tool_results: Vec::new(),
        prompt_cache_events: Vec::new(),
        iterations: iteration,
        usage: TokenUsage::default(),
        auto_compaction: None,
    })
}

// Record API error for telemetry
async fn record_api_error(&self, error: &ApiError, iteration: usize) -> Result<(), ApiError> {
    if let Some(tracer) = &self.session_tracer {
        let mut attributes = Map::new();
        attributes.insert("iteration".to_string(), Value::from(iteration as u64));
        attributes.insert("error_type".to_string(), Value::from(format!("{:?}", error)));
        attributes.insert("error_message".to_string(), Value::from(error.to_string()));
        
        // Add context info if available
        if let Some(usage) = self.context_usage_percent {
            attributes.insert("context_usage_percent".to_string(), Value::from(usage));
        }
        
        tracer.record("api_error", attributes);
    }
    
    Ok(())
}

// Record turn failed for telemetry
fn record_turn_failed(&self, iteration: usize, error: &RuntimeError) {
    // Existing method - just calling it for completeness
    // self.record_turn_failed(iteration, error); // Already exists in original code
}
```

### Phase 3: API Client Enhancements (`anthropic.rs`)

#### 3.1 Resilience-Aware Streaming Method
**Lines to modify:** Around the `stream_message` method (~800-900)

**Specific Changes:**
```rust
impl AnthropicClient {
    // ... existing methods ...
    
    // NEW: Resilience-aware stream method
    pub async fn stream_with_resilience(
        &mut self,
        request: &MessageRequest,
        resilience_config: &ResilienceConfig,
    ) -> Result<Vec<AssistantEvent>, ApiError> {
        // Apply resilience configuration to this client instance
        let original_config = self.resilience_config.clone();
        self.resilience_config = resilience_config.clone();
        
        let result = self.stream_message(request).await;
        
        // Restore original config
        self.resilience_config = original_config;
        
        result
    }
    
    // ... existing stream_message method ...    
    // NEW: Enhanced stream_message with resilience features
    pub async fn stream_message(
        &mut self,
        request: &MessageRequest,
    ) -> Result<MessageStream, ApiError> {
        // ... existing preflight ...
        
        // NEW: Add resilience context to request for debugging
        let mut resilient_request = request.clone();
        // In a real implementation, we'd add resilience metadata to the request
        
        // Call existing stream_message but with enhanced error handling
        let response = self
            .send_with_retry_enhanced(&resilient_request)
            .await?;
            
        Ok(MessageStream {
            request_id: request_id_from_headers(response.headers()),
            response,
            parser: SseParser::new().with_context("Anthropic", request.model.clone()),
            pending: VecDeque::new(),
            done: false,
            request: resilient_request,
            prompt_cache: self.prompt_cache.clone(),
            latest_usage: None,
            usage_recorded: false,
            last_prompt_cache_record: Arc::clone(&self.last_prompt_cache_record),
        })
    }
    
    // NEW: Enhanced retry logic with resilience configuration
    async fn send_with_retry_enhanced(
        &mut self,
        request: &MessageRequest,
    ) -> Result<reqwest::Response, ApiError> {
        let mut attempts = 0;
        let mut last_error: Option<ApiError>;
        
        loop {
            attempts += 1;
            
            // NEW: Check resilience config for force disable
            if self.resilience_config.force_disable {
                return Err(ApiError::ResilienceDisabled);
            }
            
            // NEW: Check if we should attempt streaming based on resilience config
            if !self.should_attempt_streaming() {
                return Err(ApiError::StreamingDisabledByResilience);
            }
            
            match self.send_raw_request(request).await {
                Ok(response) => match self.expect_success_enhanced(response).await {
                    Ok(response) => {
                        // Record success
                        self.record_success(attempts)?;
                        return Ok(response);
                    }
                    Err(error) if error.is_retryable() && self.should_retry(error, attempts, &self.resilience_config) => {
                        self.record_failure(attempts, &error)?;
                        last_error = Some(error);
                    }
                    Err(error) => {
                        // Non-retryable error or max retries exceeded
                        let error = self.enhance_error_with_context(error, &self.auth, attempts)?;
                        self.record_failure(attempts, &error)?;
                        return Err(error);
                    }
                }
                Err(error) if error.is_retryable() && self.should_retry(error, attempts, &self.resilience_config) => {
                    self.record_failure(attempts, &error)?;
                    last_error = Some(error);
                }
                Err(error) => {
                    let error = self.enhance_error_with_context(error, &self.auth, attempts)?;
                    self.record_failure(attempts, &error)?;
                    return Err(error);
                }
            }
            
            // Check if we've exceeded max attempts
            if !self.should_continue_retrying(attempts, &last_error, &self.resilience_config) {
                break;
            }
            
            // Apply backoff based on error type and resilience config
            self.apply_resilient_backoff(attempts, &last_error, &self.resilience_config).await?;
        }
        
        Err(ApiError::RetriesExhausted {
            attempts,
            last_error: Box::new(last_error.expect("retry loop must capture an error")),
        })
    }
    
    // NEW: Determine if we should attempt streaming based on resilience config
    fn should_attempt_streaming(&self) -> bool {
        match self.resilience_config.force_enable() {
            true => true, // force-enable always attempts
            false => {
                // Only attempt if provider is considered local or explicitly enabled
                self.resilience_config.should_enable_for_provider(self.provider_name())
                    || self.resilience_config.should_enable_for_url(&self.base_url)
            }
        }
    }
    
    // NEW: Determine if we should retry based on error type and config
    fn should_retry(
        &self,
        error: &ApiError,
        attempt: u32,
        config: &ResilienceConfig,
    ) -> bool {
        // Check if we've exceeded max attempts for this error type
        match error {
            ApiError::Api { status, .. } => {
                match status.as_u16() {
                    400 => {
                        // Check specific 400 errors
                        let body_str = String::from_utf8_lossy(&error.body_bytes());
                        if body_str.contains("Model reloaded") {
                            attempt <= config.model_reloaded_max_retries
                        } else if body_str.contains("Context size has been exceeded") {
                            attempt <= config.context_exceeded_max_retries
                        } else if body_str.contains("Model unloaded") {
                            attempt <= config.model_unloaded_max_retries
                        } else if body_str.contains("tool_use blocks must be immediately followed by tool_result blocks") {
                            attempt <= config.tool_sequence_error_max_retries
                        } else {
                            // Default retry logic for other 400s
                            attempt <= 3
                        }
                    }
                    429 | 500 | 502 | 503 | 504 => {
                        // Standard retryable status codes
                        attempt <= 3 // Default, could be made configurable
                    }
                    _ => false, // Not retryable
                }
            }
            ApiError::Json { .. } => {
                // Decoding errors
                attempt <= config.decoding_error_max_retries
            }
            ApiError::Unknown { ref msg } => {
                // Unknown errors (like empty stream)
                if msg.contains("assistant stream produced no content") {
                    attempt <= 3 // Default for stream errors
                } else {
                    false
                }
            }
            _ => false, // Not retryable by default
        }
    }
    
    // NEW: Determine if we should continue retrying
    fn should_continue_retrying(
        &self,
        attempt: u32,
        last_error: &Option<ApiError>,
        config: &ResilienceConfig,
    ) -> bool {
        // Check force settings first
        if config.force_disable {
            return false;
        }
        
        // Check if we've exceeded general retry limits
        if attempt > 10 { // Hard limit to prevent infinite loops
            return false;
        }
        
        // Check specific error type limits via should_retry
        if let Some(error) = last_error {
            return self.should_retry(error, attempt, config);
        }
        
        true // Continue if no error yet
    }
    
    // NEW: Apply backoff based on error type and resilience config
    async fn apply_resilient_backoff(
        &mut self,
        attempt: u32,
        last_error: &Option<ApiError>,
        config: &ResilienceConfig,
    ) -> Result<(), ApiError> {
        // Determine base backoff based on error type
        let base_backoff = match last_error {
            Some(ApiError::Api { status, .. }) => {
                match status.as_u16() {
                    400 => {
                        let body_str = String::from_utf8_lossy(&status.to_string()); // Simplified
                        if body_str.contains("Model reloaded") {
                            config.model_reloaded_initial_backoff
                        } else if body_str.contains("Context size has been exceeded") {
                            config.context_exceeded_initial_backoff
                        } else if body_str.contains("Model unloaded") {
                            config.model_unloaded_initial_backoff
                        } else if body_str.contains("tool_use blocks must be immediately followed by tool_result blocks") {
                            config.tool_sequence_error_initial_backoff
                        } else {
                            Duration::from_secs(1) // Default
                        }
                    }
                    429 | 500 | 502 | 503 | 504 => Duration::from_secs(1), // Standard
                    _ => Duration::from_secs(1),
                }
            }
            Some(ApiError::Json { .. }) => config.decoding_error_initial_backoff,
            Some(ApiError::Unknown { ref msg }) => {
                if msg.contains("assistant stream produced no content") {
                    Duration::from_secs(1) // Stream error backoff
                } else {
                    Duration::from_secs(1)
                }
            }
            None => Duration::from_secs(1), // No error yet
        };
        
        // Apply exponential backoff with jitter
        let backoff = base_backoff * 2u32.pow(attempt.saturating_sub(1));
        let jitter = backoff * rand::random::<f32>() * 0.1; // 10% jitter
        let final_delay = backoff + jitter;
        
        tokio::time::sleep(final_delay).await;
        Ok(())
    }
    
    // NEW: Enhance error with context information
    fn enhance_error_with_context(
        &self,
        error: ApiError,
        auth: &AuthSource,
        attempt: u32,
    ) -> Result<ApiError, ApiError> {
        // Add attempt number and resilience context to errors
        match error {
            ApiError::Api { 
                status, 
                error_type, 
                message, 
                request_id, 
                body, 
                retryable, 
                suggested_action 
            } => {
                let resilience_context = ResilienceContext {
                    attempt,
                    max_attempts: 3, // Would come from config
                    error_type: error_type.clone().unwrap_or_else(|| "unknown".to_string()),
                    resilience_enabled: !self.resilience_config.force_disable,
                    context_usage_percent: None, // Would be updated from conversation runtime
                };
                
                Ok(ApiError::Api {
                    status,
                    error_type,
                    message,
                    request_id,
                    body,
                    retryable,
                    suggested_action,
                    resilience_context: Some(resilience_context),
                })
            }
            other => Ok(other), // Don't modify non-Api errors
        }
    }
    
    // NEW: Enhanced success expectation with better error details
    async fn expect_success_enhanced(
        &mut self,
        response: reqwest::Response,
    ) -> Result<reqwest::Response, ApiError> {
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        
        // Enhanced error handling with more context
        let request_id = request_id_from_headers(response.headers());
        let body = response.text().await.unwrap_or_else(|_| String::new());
        
        // Try to parse as Anthropic error
        let parsed_error = serde_json::from_str::<AnthropicErrorEnvelope>(&body).ok();
        let retryable = self.is_retryable_status(status);
        
        // Build enhanced error
        let mut api_error = ApiError::Api {
            status,
            error_type: parsed_error.as_ref().map(|e| e.error.error_type.clone()),
            message: parsed_error.as_ref().map(|e| e.error.message.clone()),
            request_id,
            body,
            retryable,
            suggested_action: None,
        };
        
        // Apply bearer token error enrichment if needed
        let enhanced_error = self.enrich_bearer_auth_error(api_error, &self.auth);
        
        // Add resilience context
        let final_error = self.enhance_error_with_context(enhanced_error, &self.auth, 0)?;
        
        Ok(final_error)
    }
    
    // ... existing helper methods (is_retryable_status, enrich_bearer_auth_error, etc.) ... 
}
```

#### 3.2 Payload Size Guarding
**Lines to modify:** Around the `send_raw_request` method (~1000-1100)

**Specific Changes:**
```rust
// NEW: Maximum response size constant
const MAX_RESPONSE_BODY_SIZE: usize = 5 * 1024 * 1024; // 5MB

async fn send_raw_request(
    &mut self,
    request: &MessageRequest,
) -> Result<reqwest::Response, ApiError> {
    let request_url = format!("{}/v1/messages", self.base_url.trim_end_matches('/'));
    let mut request_body = self.request_profile.render_json_body(request)?;
    strip_unsupported_beta_body_fields(&mut request_body);
    let request_builder = self.build_request(&request_url).json(&request_body);
    
    // NEW: Use timed request with size limits
    let response = request_builder
        .timeout(self.resilience_config.request_timeout) // Would need to add to config
        .send()
        .await
        .map_err(ApiError::from)?;
    
    // NEW: Check content length before reading body
    if let Some(content_length) = response.content_length() {
        if content_length as usize > MAX_RESPONSE_BODY_SIZE {
            return Err(ApiError::PayloadTooLarge {
                limit: MAX_RESPONSE_BODY_SIZE,
                actual: content_length as usize,
            });
        }
    }
    
    Ok(response)
}

// NEW: Helper to read response body with size limits
async fn read_response_body_with_limit(
    mut response: reqwest::Response,
    max_size: usize,
) -> Result<Bytes, ApiError> {
    let mut buffer = BytesMut::with_capacity(max_size);
    let mut read = 0usize;
    
    while let Some(chunk) = response.chunk().await? {
        let remaining = max_size - read;
        if chunk.len() > remaining {
            // Would exceed limit
            return Err(ApiError::PayloadTooLarge {
                limit: max_size,
                actual: read + chunk.len(),
            });
        }
        
        buffer.extend_from_slice(&chunk);
        read += chunk.len();
    }
    
    Ok(buffer.freeze())
}
```

### Phase 4: Provider Dispatch Layer (`client.rs`)

#### 4.1 Enhanced Error Propagation
**Lines to modify:** Around the `send_message` and `stream_message` methods (~150-200)

**Specific Changes:**
```rust
impl ProviderClient {
    // ... existing methods ...
    
    // NEW: Enhanced send_message with resilience context
    pub async fn send_message(
        &self,
        request: &MessageRequest,
    ) -> Result<MessageResponse, ApiError> {
        // Add attempt tracking to request for resilience logging
        let mut tracked_request = request.clone();
        // In a real implementation, we'd add resilience metadata
        
        match self {
            Self::Anthropic(client) => client.send_message(&tracked_request).await,
            Self::Xai(client) | Self::OpenAi(client) => client.send_message(&tracked_request).await,
        }
        // Note: In a full implementation, we'd need to extract resilience context
        // from the response and propagate it back to the conversation runtime
    }
    
    // NEW: Enhanced stream_message with resilience context
    pub async fn stream_message(
        &self,
        request: &MessageRequest,
    ) -> Result<MessageStream, ApiError> {
        let mut tracked_request = request.clone();
        // Add tracking metadata
        
        match self {
            Self::Anthropic(client) => client.stream_message(&tracked_request).await,
            Self::Xai(client) | Self::OpenAi(client) => client.stream_message(&tracked_request).await,
        }
    }
}
```

### Phase 5: Compaction Enhancements (`compact.rs`)

#### 5.1 Context-Aware Compaction Strategies
**Lines to modify:** Around the `compact_session` function (~50-150)

**Specific Changes:**
```rust
// NEW: Compaction strategy enum for different error scenarios
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompactionStrategy {
    Standard,
    Aggressive,      // For context overflow
    Conservative,    // For stream errors
    Preservative,    // For model reloads
    Emergency,       // For critical failures
}

// Update CompactionConfig to support strategies
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CompactionConfig {
    pub preserve_recent_messages: usize,
    pub max_estimated_tokens: usize,
    pub strategy: CompactionStrategy,
    
    // NEW: Context-specific parameters
    pub context_warning_threshold: f32,
    pub context_critical_threshold: f32,
}

impl Default for CompactionConfig {
    fn default() -> Self {
        Self {
            preserve_recent_messages: 4,
            max_estimated_tokens: 10_000,
            strategy: CompactionStrategy::Standard,
            context_warning_threshold: 0.8,
            context_critical_threshold: 0.95,
        }
    }
}

// NEW: Context-aware compaction factory
impl CompactionConfig {
    pub fn for_context_usage(&self, usage_percent: f32) -> Self {
        let mut config = *self;
        
        if usage_percent >= self.context_critical_threshold {
            config.strategy = CompactionStrategy::Aggressive;
            config.preserve_recent_messages = 1; // Keep minimal context
            config.max_estimated_tokens = 2000; // Aggressive limit
        } else if usage_percent >= self.context_warning_threshold {
            config.strategy = CompactionStrategy::Conservative;
            config.preserve_recent_messages = 3; // Keep reasonable context
            config.max_estimated_tokens = 5000; // Moderate limit
        } else {
            config.strategy = CompactionStrategy::Standard;
            // Keep defaults
        }
        
        config
    }
}

// Update compact_session to accept strategy
#[must_use]
pub fn compact_session(session: &Session, config: CompactionConfig) -> CompactionResult {
    // Use strategy to determine behavior
    match config.strategy {
        CompactionStrategy::Aggressive => compact_session_aggressive(session, config),
        CompactionStrategy::Conservative => compact_session_conservative(session, config),
        CompactionStrategy::Preservative => compact_session_preservative(session, config),
        CompactionStrategy::Emergency => compact_session_emergency(session, config),
        CompactionStrategy::Standard => compact_session_standard(session, config),
    }
}

// NEW: Aggressive compaction for context overflow
fn compact_session_aggressive(session: &Session, config: CompactionConfig) -> CompactionResult {
    // More aggressive than standard - preserve very little, summarize heavily
    let mut config = config;
    config.preserve_recent_messages = config.preserve_recent_messages.min(1);
    config.max_estimated_tokens = config.max_estimated_tokens.min(2000);
    
    compact_session_standard(session, config)
}

// NEW: Conservative compaction for stream errors
fn compact_session_conservative(session: &Session, config: CompactionConfig) -> CompactionResult {
    // Less aggressive - preserve more context to avoid losing useful information
    let mut config = config;
    config.preserve_recent_messages = config.preserve_recent_messages + 2;
    config.max_estimated_tokens = config.max_estimated_tokens + 2000;
    
    compact_session_standard(session, config)
}

// NEW: Preservative compaction for model reloads
fn compact_session_preservative(session: &Session, config: CompactionConfig) -> CompactionResult {
    // Preserve as much as possible since model state changed, not context issues
    let mut config = config;
    config.preserve_recent_messages = config.preserve_recent_messages + 3;
    config.max_estimated_tokens = config.max_estimated_tokens + 3000;
    
    compact_session_standard(session, config)
}

// NEW: Emergency compaction for critical failures
fn compact_session_emergency(session: &Session, config: CompactionConfig) -> CompactionResult {
    // Most aggressive - keep absolute minimum
    let mut config = config;
    config.preserve_recent_messages = config.preserve_recent_messages.min(0);
    config.max_estimated_tokens = config.max_estimated_tokens.min(1000);
    
    compact_session_standard(session, config)
}

// Standard compaction (existing logic moved here)
fn compact_session_standard(session: &Session, config: CompactionConfig) -> CompactionResult {
    // ... existing compact_session logic ...
    // (This would be the original compact_session function renamed)
}
```

### Phase 6: Session Management Enhancements (`session.rs`)

#### 6.1 Context Usage Tracking
**Lines to modify:** Around the Session struct and related methods

**Specific Changes:**
```rust
// NEW: Add context tracking to Session
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    // ... existing fields ...
    
    // NEW: Context tracking
    pub context_tracking: Option<ContextTracking>,
    
    // NEW: Model state tracking
    pub model_state: ModelState,
}

// NEW: Context tracking struct
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextTracking {
    pub estimated_tokens: usize,
    pub context_window_size: usize,
    pub last_updated: SystemTime,
    pub history: VecDeque<ContextSample>,
}

// NEW: Context sample for tracking usage over time
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextSample {
    pub timestamp: SystemTime,
    pub estimated_tokens: usize,
    pub context_window_size: usize,
}

// NEW: Model state tracking
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelState {
    Unknown,
    Loading,
    Loaded,
    Unloading,
    Failed,
    Reloading,
}

// NEW: Methods to update context tracking
impl Session {
    // ... existing methods ...
    
    // NEW: Update context usage estimate
    pub fn update_context_usage(&mut self, estimated_tokens: usize, context_window_size: usize) -> Result<(), SessionError> {
        if self.context_tracking.is_none() {
            self.context_tracking = Some(ContextTracking {
                estimated_tokens: 0,
                context_window_size: 0,
                last_updated: SystemTime::now(),
                history: VecDeque::with_capacity(100),
            });
        }
        
        if let Some(tracking) = &mut self.context_tracking {
            tracking.estimated_tokens = estimated_tokens;
            tracking.context_window_size = context_window_size;
            tracking.last_updated = SystemTime::now();
            
            // Add to history
            tracking.history.push_back(ContextSample {
                timestamp: SystemTime::now(),
                estimated_tokens,
                context_window_size,
            });
            
            // Keep history limited
            if tracking.history.len() > 100 {
                tracking.history.pop_front();
            }
        }
        
        Ok(())
    }
    
    // NEW: Get context usage percentage
    pub fn context_usage_percent(&self) -> Option<f32> {
        self.context_tracking.as_ref().map(|tracking| {
            if tracking.context_window_size == 0 {
                0.0
            } else {
                tracking.estimated_tokens as f32 / tracking.context_window_size as f32 * 100.0
            }
        })
    }
    
    // NEW: Get context trend (increasing/decreasing/stable)
    pub fn context_trend(&self) -> Option<ContextTrend> {
        self.context_tracking.as_ref().and_then(|tracking| {
            if tracking.history.len() < 2 {
                return None;
            }
            
            let recent = tracking.history.range(tracking.history.len().saturating_sub(5)..);
            let tokens: Vec<usize> = recent.map(|s| s.estimated_tokens).collect();
            
            if tokens.len() < 2 {
                return None;
            }
            
            let first = tokens[0] as f32;
            let last = *tokens.last().unwrap() as f32;
            
            if last > first * 1.1 {
                Some(ContextTrend::Increasing)
            } else if last < first * 0.9 {
                Some(ContextTrend::Decreasing)
            } else {
                Some(ContextTrend::Stable)
            }
        })
    }
    
    // NEW: Predict when context will be exceeded
    pub fn predict_context_exhaustion(&self) -> Option<Duration> {
        self.context_tracking.as_ref().and_then(|tracking| {
            if tracking.history.len() < 3 {
                return None;
            }
            
            // Simple linear prediction based on last 3 samples
            let samples: Vec<ContextSample> = tracking.history.range(tracking.history.len().saturating_sub(3)..).cloned().collect();
            if samples.len() < 3 {
                return None;
            }
            
            let time_diff = samples[2].timestamp.duration_since(samples[0].timestamp).ok()?;
            let token_diff = samples[2].estimated_tokens as i64 - samples[0].estimated_tokens as i64;
            
            if token_diff <= 0 || tracking.context_window_size == 0 {
                return None;
            }
            
            let tokens_per_second = token_diff as f32 / time_diff.as_secs_f32();
            let tokens_remaining = (tracking.context_window_size as i64 - tracking.estimated_tokens as i64) as f32;
            
            if tokens_per_second <= 0.0 {
                return None;
            }
            
            let seconds_remaining = tokens_remaining / tokens_per_second;
            Some(Duration::from_secs_f32(seconds_remaining))
        })
    }
}

// NEW: Context trend enum
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContextTrend {
    Increasing,
    Decreasing,
    Stable,
}
```

### Phase 7: Hook System Enhancements (`hooks.rs`)

#### 7.1 Debugging Hooks for Stream Issues
**Lines to modify:** Around the HookRunner and related traits

**Specific Changes:**
```rust
// NEW: Stream debugging hook types
pub trait HookStreamDebugger {
    fn on_stream_start(
        &mut self,
        request: &MessageRequest,
        context: &StreamDebugContext,
    ) -> HookRunResult;
    
    fn on_stream_chunk(
        &mut self,
        chunk: &[u8],
        context: &StreamDebugContext,
    ) -> HookRunResult;
    
    fn on_stream_end(
        &mut self,
        result: &StreamResult,
        context: &StreamDebugContext,
    ) -> HookRunResult;
    
    fn on_stream_error(
        &mut self,
        error: &ApiError,
        context: &StreamDebugContext,
    ) -> HookRunResult;
}

// NEW: Stream debugging context
#[derive(Debug, Clone)]
pub struct StreamDebugContext {
    pub request_id: Option<String>,
    pub model: String,
    pub attempt: u32,
    pub resilience_enabled: bool,
    pub context_usage_percent: Option<f32>,
    pub consecutive_failures: usize,
    pub tokens_produced_so_far: Option<u32>,
}

// NEW: Stream result for debugging
#[derive(Debug, Clone)]
pub struct StreamResult {
    pub events_produced: usize,
    pub tokens_produced: Option<u32>,
    pub duration: Duration,
    pub success: bool,
}

// Update HookRunner to support stream debugging hooks
pub struct HookRunner {
    // ... existing fields ...
    
    // NEW: Stream debugging hooks
    pub stream_debug_hooks: Vec<Box<dyn HookStreamDebugger>>,
    
    // ... existing methods ...
    
    // NEW: Methods to run stream debugging hooks
    pub fn run_stream_debug_start_hook(
        &mut self,
        request: &MessageRequest,
        context: &StreamDebugContext,
    ) -> HookRunResult {
        // ... implementation similar to other hook runners ...
    }
    
    // ... other stream debug hook methods ...
}

// Update StaticToolExecutor or add new StreamDebugExecutor for testing
#[derive(Default)]
pub struct StreamDebugExecutor {
    // ... fields for capturing stream debug info ...
}

// Implement HookStreamDebugger for StreamDebugExecutor
impl HookStreamDebugger for StreamDebugExecutor {
    // ... implementation ...
}
```

## Implementation Sequence

### Phase 1: Foundation (Days 1-2)
1. [ ] Update `resilience_config.rs` with error-specific configurations
2. [ ] Enhance `error.rs` with new error types and context tracking
3. [ ] Implement basic resilience configuration validation

### Phase 2: Conversation Runtime (Days 3-5)
1. [ ] Update `conversation.rs` constructor and fields
2. [ ] Implement enhanced `run_turn` with resilience-aware API calls
3. [ ] Add all specific error handlers (model reloaded, context exceeded, etc.)
4. [ ] Implement helper methods for backoff, retry counting, context management
5. [ ] Add telemetry recording for resilience events

### Phase 3: API Client (Days 6-8)
1. [ ] Add resilience-aware streaming method to `anthropic.rs`
2. [ ] Implement enhanced retry logic with error-type-specific backoffs
3. [ ] Add payload size guarding and response size limits
4. [ ] Enhance error reporting with context information
5. [ ] Update OpenAI-compatible provider similarly

### Phase 4: Provider Dispatch (Day 9)
1. [ ] Enhance `client.rs` to propagate resilience context
2. [ ] Ensure error information flows properly between layers

### Phase 5: Compaction Enhancement (Days 10-11)
1. [ ] Update `compact.rs` with strategy-based compaction
2. [ ] Implement context-aware compaction strategies
3. [ ] Add emergency and preservative compaction modes

### Phase 6: Session Management (Days 12-13)
1. [ ] Update `session.rs` with context tracking capabilities
2. [ ] Add model state tracking
3. [ ] Implement context usage prediction and trending

### Phase 7: Hook System (Days 14-15)
1. [ ] Update `hooks.rs` with stream debugging capabilities
2. [ ] Add hooks for capturing detailed stream information
3. [ ] Implement debug hook executors for testing

### Phase 8: Testing and Validation (Days 16-20)
1. [ ] Create unit tests for each error handler
2. [ ] Build integration tests simulating error conditions
3. [ ] Develop chaos engineering tests for concurrent failures
4. [ ] Performance benchmarking to ensure no degradation
5. [ ] Documentation and knowledge transfer

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

## Performance Considerations

### Overhead Minimization
1. [ ] Resilience checks add <1% overhead in non-error paths
2. [ ] Context tracking uses efficient circular buffers
3. [ ] Error type discrimination uses enum matching, not string comparisons
4. [ ] Backoff calculations are lightweight and cached where possible

### Memory Efficiency
1. [ ] Stream debug events use bounded VecDeque (100 entries max)
2. [ ] Context history uses bounded VecDeque (100 entries max)
3. [ ] Retry counts use HashMap with bounded growth
4. [ ] Telemetry data is sampled when volume is high

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
6. **Testability**: Comprehensive test coverage for all scenarios

Each modification includes specific line references and implementation procedures, making it straightforward for developers to follow and implement. The plan builds upon the existing resilience foundation and incorporates lessons from the robustness layer documents while adding extensive new capabilities for handling the specific error conditions identified.

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

### Phase 1: Foundation Enhancements

#### 1.1 Resilience Configuration Updates (`resilience_config.rs`)
**Lines to modify:** Around 20-50 (constructor and methods)

**Specific Changes:**
```rust
// Add error-type-specific retry budgets
#[derive(Debug, Clone)]
pub struct ResilienceConfig {
    // ... existing fields ...
    
    // Error-specific retry configurations
    pub model_reloaded_max_retries: u32,
    pub context_exceeded_max_retries: u32,
    pub stream_empty_max_retries: u32,
    pub decoding_error_max_retries: u32,
    pub model_unloaded_max_retries: u32,
    pub tool_sequence_error_max_retries: u32,
    
    // Backoff configurations
    pub model_reloaded_initial_backoff: Duration,
    pub context_exceeded_initial_backoff: Duration,
    pub stream_empty_initial_backoff: Duration,
    pub decoding_error_initial_backoff: Duration,
    pub model_unloaded_initial_backoff: Duration,
    pub tool_sequence_error_initial_backoff: Duration,
    
    // Context management thresholds
    pub context_warning_threshold: f32,  // 0.8 for 80%
    pub context_critical_threshold: f32, // 0.95 for 95%
    pub aggressive_compaction_preserve_recent: usize,
    pub conservative_compaction_preserve_recent: usize,
}

// Update default() method
impl ResilienceConfig {
    pub fn default() -> Self {
        Self {
            // ... existing defaults ...
            model_reloaded_max_retries: 3,
            context_exceeded_max_retries: 2,
            stream_empty_max_retries: 3,
            decoding_error_max_retries: 2,
            model_unloaded_max_retries: 5,
            tool_sequence_error_max_retries: 2,
            
            model_reloaded_initial_backoff: Duration::from_secs(1),
            context_exceeded_initial_backoff: Duration::from_secs(2),
            stream_empty_initial_backoff: Duration::from_secs(1),
            decoding_error_initial_backoff: Duration::from_secs(1),
            model_unloaded_initial_backoff: Duration::from_secs(3),
            tool_sequence_error_initial_backoff: Duration::from_secs(1),
            
            context_warning_threshold: 0.8,
            context_critical_threshold: 0.95,
            aggressive_compaction_preserve_recent: 1,
            conservative_compaction_preserve_recent: 3,
        }
    }
}

// Add validation method
impl ResilienceConfig {
    pub fn validate(&self) -> Result<(), String> {
        if self.model_reloaded_max_retries > 10 {
            return Err("model_reloaded_max_retries too high".to_string());
        }
        // ... validate other fields ...
        Ok(())
    }
}
```

#### 1.2 Error Type Enhancements (`error.rs`)
**Lines to modify:** Add new error variants around existing ApiError enum

**Specific Changes:**
```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApiError {
    // ... existing variants ...
    
    // New error types for better handling
    ToolSequenceError {
        request_id: Option<String>,
        body: String,
    },
    
    StreamDebugInfo {
        message: String,
        tokens_produced: Option<u32>,
        stream_events: Vec<String>,
    },
    
    // Enhanced existing error with more context
    Api {
        // ... existing fields ...
        resilience_context: Option<ResilienceContext>,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResilienceContext {
    pub attempt: u32,
    pub max_attempts: u32,
    pub error_type: String,
    pub resilience_enabled: bool,
    pub context_usage_percent: Option<f32>,
}

// Implement From conversions for new error types
impl From<ToolSequenceError> for ApiError {
    fn from(err: ToolSequenceError) -> Self {
        ApiError::ToolSequenceError {
            request_id: err.request_id,
            body: err.body,
        }
    }
}

// Add helper to create stream debug info
impl ApiError {
    pub fn stream_debug(
        message: impl Into<String>,
        tokens_produced: Option<u32>,
        stream_events: Vec<String>
    ) -> Self {
        ApiError::StreamDebugInfo {
            message: message.into(),
            tokens_produced,
            stream_events,
        }
    }
}
```

### Phase 2: Conversation Runtime Enhancements (`conversation.rs`)

#### 2.1 Constructor and Field Updates
**Lines to modify:** Around 50-100 (constructor and new_with_features)

**Specific Changes:**
```rust
pub struct ConversationRuntime<C, T> {
    // ... existing fields ...
    
    // NEW: Resilience configuration
    resilience_config: ResilienceConfig,
    
    // NEW: Error tracking and debugging
    consecutive_stream_failures: usize,
    last_stream_tokens: Option<u32>,
    stream_debug_events: VecDeque<String>,
    
    // NEW: Model state tracking
    model_load_state: ModelLoadState,
    model_ready_at: Option<SystemTime>,
    
    // NEW: Context monitoring
    context_usage_percent: Option<f32>,
}

// Add new enum for model state tracking
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelLoadState {
    Unknown,
    Loading,
    Loaded,
    Unloading,
    Failed,
}

// Update constructor to accept resilience config
impl<C, T> ConversationRuntime<C, T>
where
    C: ApiClient,
    T: ToolExecutor,
{
    #[must_use]
    pub fn new(
        session: Session,
        api_client: C,
        tool_executor: T,
        permission_policy: PermissionPolicy,
        system_prompt: Vec<String>,
        resilience_config: ResilienceConfig, // NEW PARAMETER
    ) -> Self {
        // ... existing init ...
        Self {
            // ... existing fields ...
            resilience_config,
            consecutive_stream_failures: 0,
            last_stream_tokens: None,
            stream_debug_events: VecDeque::with_capacity(100),
            model_load_state: ModelLoadState::Unknown,
            model_ready_at: None,
            context_usage_percent: None,
        }
    }
}

// Update new_with_features similarly
```

#### 2.2 Enhanced `run_turn` Method
**Lines to modify:** Around 200-300 (main loop)

**Specific Changes:**
```rust
pub fn run_turn(
    &mut self,
    user_input: impl Into<String>,
    mut prompter: Option<&mut dyn PermissionPrompter>,
) -> Result<TurnSummary, RuntimeError> {
    // ... existing setup ...
    
    // NEW: Pre-turn context check
    self.update_context_usage()?;
    
    // NEW: Handle context warnings/critical levels
    if let Some(usage) = self.context_usage_percent {
        if usage >= self.resilience_config.context_critical_threshold {
            // Critical context level - force compaction before proceeding
            if let Err(e) = self.handle_critical_context()? {
                return Err(RuntimeError::new(format!(
                    "Failed to handle critical context: {}", e
                )));
            }
        } else if usage >= self.resilience_config.context_warning_threshold {
            // Warning level - log for monitoring
            if let Some(tracer) = &self.session_tracer {
                tracer.record("context_warning", map!{
                    "usage_percent" => usage,
                    "threshold" => self.resilience_config.context_warning_threshold
                });
            }
        }
    }
    
    // ... existing message pushing ...
    
    // MAIN LOOP WITH ENHANCED ERROR HANDLING
    loop {
        // ... iteration limit check ...
        
        let request = ApiRequest {
            system_prompt: self.system_prompt.clone(),
            messages: self.session.messages.clone(),
        };
        
        // NEW: Resilience-aware API call with specific error handling
        let events = match self.resilient_api_call(&request).await {
            Ok(events) => events,
            Err(error) => {
                // NEW: Enhanced error handling with specific strategies
                return self.handle_api_error(error, &request, iterations).await;
            }
        };
        
        // ... rest of existing loop ...
    }
}

// NEW: Resilient API call wrapper
async fn resilient_api_call(
    &mut self,
    request: &ApiRequest,
) -> Result<Vec<AssistantEvent>, ApiError> {
    // Apply resilience configuration to the API client call
    // This delegates to the API client's resilience-aware methods
    self.api_client.stream_with_resilience(request, &self.resilience_config).await
}

// NEW: Comprehensive error handler
async fn handle_api_error(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Record error for telemetry
    self.record_api_error(&error, iteration).await?;
    
    // Match on error type for specific handling
    match error {
        ApiError::Api { 
            ref message, 
            ref error_type, 
            status, 
            ref body, 
            retryable, 
            .. 
        } if retryable => {
            // Handle specific error messages
            match (message.as_deref(), error_type.as_deref(), status.as_u16()) {
                // Model reloaded error
                (Some(msg), Some(err_type), 400) if msg.contains("Model reloaded") && err_type == "invalid_request_error" => {
                    return self.handle_model_reloaded(error, request, iteration).await;
                }
                
                // Context size exceeded
                (Some(msg), Some(err_type), 400) if msg.contains("Context size has been exceeded") && err_type == "invalid_request_error" => {
                    return self.handle_context_exceeded(error, request, iteration).await;
                }
                
                // Model unloaded
                (Some(msg), Some(err_type), 400) if msg.contains("Model unloaded") && err_type == "invalid_request_error" => {
                    return self.handle_model_unloaded(error, request, iteration).await;
                }
                
                // Invalid tool_use/tool_result sequence (NEW)
                (Some(msg), Some(err_type), 400) if msg.contains("tool_use blocks must be immediately followed by tool_result blocks") && err_type == "invalid_request_error" => {
                    return self.handle_tool_sequence_error(error, request, iteration).await;
                }
                
                // Default retry handling for other retryable errors
                _ => {
                    return self.handle_generic_retry(error, request, iteration).await;
                }
            }
        }
        
        // Stream produced no content (NEW - unknown error kind)
        ApiError::Unknown { msg } if msg.contains("assistant stream produced no content") => {
            return self.handle_empty_stream(error, request, iteration).await;
        }
        
        // Decoding errors
        ApiError::Json { .. } => {
            return self.handle_decoding_error(error, request, iteration).await;
        }
        
        // Tool sequence errors (direct handling)
        ApiError::ToolSequenceError { .. } => {
            return self.handle_tool_sequence_error(error, request, iteration).await;
        }
        
        // Stream debug info (for enhanced diagnostics)
        ApiError::StreamDebugInfo { .. } => {
            return self.handle_stream_debug(error, request, iteration).await;
        }
        
        // Non-retryable errors
        _ => {
            self.record_turn_failed(iteration, &error);
            return Err(error);
        }
    }
}

// NEW: Specific error handlers

// Handle model reloaded error
async fn handle_model_reloaded(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Check if we have retries left
    if self.get_retry_count("model_reloaded") < self.resilience_config.model_reloaded_max_retries {
        // Apply backoff
        self.apply_backoff("model_reloaded").await?;
        
        // Increment retry counter
        self.increment_retry_count("model_reloaded");
        
        // Retry the request
        return self.retry_request(request, iteration).await;
    }
    
    // If we've exhausted retries, try context compaction as last resort
    if self.attempt_context_compaction("model_reloaded").await? {
        // Reset retry counter after successful compaction
        self.reset_retry_count("model_reloaded");
        return self.retry_request(request, iteration).await;
    }
    
    // If all else fails, return the error
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle context size exceeded error
async fn handle_context_exceeded(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Try aggressive compaction first
    if self.attempt_aggressive_compaction().await? {
        // Reset context tracking
        self.context_usage_percent = None;
        return self.retry_request(request, iteration).await;
    }
    
    // If compaction fails, try message truncation
    if self.attempt_message_truncation().await? {
        return self.retry_request(request, iteration).await;
    }
    
    // If all else fails, return error
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle model unloaded error
async fn handle_model_unloaded(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // For local models, wait for model to be ready
    if self.is_local_model_request(request).await? {
        if self.wait_for_model_ready().await? {
            // Model is ready, retry request
            return self.retry_request(request, iteration).await;
        }
    }
    
    // For remote models or if waiting failed, apply standard retry logic
    if self.get_retry_count("model_unloaded") < self.resilience_config.model_unloaded_max_retries {
        self.apply_backoff("model_unloaded").await?;
        self.increment_retry_count("model_unloaded");
        return self.retry_request(request, iteration).await;
    }
    
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle tool sequence error (NEW)
async fn handle_tool_sequence_error(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // This indicates malformed conversation history
    // Attempt to heal the history by fixing tool_use/tool_result pairs
    
    if self.attempt_history_healing().await? {
        // History healed, retry request
        if self.get_retry_count("tool_sequence") < self.resilience_config.tool_sequence_error_max_retries {
            self.apply_backoff("tool_sequence").await?;
            self.increment_retry_count("tool_sequence");
            return self.retry_request(request, iteration).await;
        }
    }
    
    // If healing fails or retries exhausted, return error
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle empty stream error (NEW - extensive debugging)
async fn handle_empty_stream(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Increment consecutive stream failures
    self.consecutive_stream_failures += 1;
    
    // If we have stream debug info, record it
    if let ApiError::StreamDebugInfo { message, tokens_produced, stream_events } = error {
        self.last_stream_tokens = tokens_produced;
        self.stream_debug_events.extend(stream_events);
        
        // Record extensive debugging info
        self.record_stream_debug_info(&message, tokens_produced, &stream_events).await?;
    }
    
    // If we haven't exceeded max retries, try recovery strategies
    if self.consecutive_stream_failures < self.resilience_config.stream_empty_max_retries {
        // Apply backoff
        self.apply_backoff("stream_empty").await?;
        
        // Try different context reduction strategies based on attempt number
        match self.consecutive_stream_failures {
            1 => {
                // First retry: try with reduced context (remove oldest 30%)
                if self.reduce_context_by_percentage(0.3).await? {
                    return self.retry_request(request, iteration).await;
                }
            }
            2 => {
                // Second retry: try with summary-only context (keep system + last 2 exchanges)
                if self.reduce_to_summary_context().await? {
                    return self.retry_request(request, iteration).await;
                }
            }
            3 => {
                // Third retry: try with minimal context (system only)
                if self.reduce_to_system_context().await? {
                    return self.retry_request(request, iteration).await;
                }
            }
            _ => {
                // Beyond standard retries, try aggressive measures
                if self.attempt_emergency_context_reset().await? {
                    return self.retry_request(request, iteration).await;
                }
            }
        }
    }
    
    // If all recovery strategies fail, return error with debug info
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle decoding errors
async fn handle_decoding_error(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Check if we have retries left
    if self.get_retry_count("decoding") < self.resilience_config.decoding_error_max_retries {
        // Apply backoff
        self.apply_backoff("decoding").await?;
        
        // Before retry, try to simplify the request
        if self.simplify_request_for_decoding(request).await? {
            self.increment_retry_count("decoding");
            return self.retry_request(request, iteration).await;
        }
    }
    
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Handle stream debug info (for enhanced diagnostics)
async fn handle_stream_debug(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Extract stream debug info
    if let ApiError::StreamDebugInfo { message, tokens_produced, stream_events } = error {
        // Record detailed debugging information
        self.record_stream_debug_info(&message, tokens_produced, &stream_events).await?;
        
        // For stream debug info, we typically don't retry immediately as it's informational
        // But if it's associated with an empty stream, we might want to apply similar logic
        if message.contains("assistant stream produced no content") {
            // Treat similar to empty stream for recovery purposes
            return self.handle_empty_stream(error, request, iteration).await;
        }
    }
    
    // If not associated with a recoverable error, just record and continue
    // (In practice, we might still want to retry depending on context)
    self.record_turn_faced(iteration, &error);
    return Err(error);
}

// Generic retry handler for other errors
async fn handle_generic_retry(
    &mut self,
    error: ApiError,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Use a generic retry key for errors without specific handlers
    let retry_key = format!("generic_{:?}", error);
    
    if self.get_retry_count(&retry_key) < 3 { // Default max retries for generic errors
        self.apply_backoff("generic").await?;
        self.increment_retry_count(&retry_key);
        return self.retry_request(request, iteration).await;
    }
    
    self.record_turn_failed(iteration, &error);
    return Err(error);
}

// Helper methods for the above handlers

// Get retry count for a specific error type
fn get_retry_count(&self, error_type: &str) -> usize {
    *self.retry_counts.get(error_type).unwrap_or(&0)
}

// Increment retry count for a specific error type
fn increment_retry_count(&mut self, error_type: &str) {
    *self.retry_counts.entry(error_type.to_string()).or_insert(0) += 1;
}

// Reset retry count for a specific error type
fn reset_retry_count(&mut self, error_type: &str) {
    self.retry_counts.insert(error_type.to_string(), 0);
}

// Apply backoff based on error type and retry count
async fn apply_backoff(&mut self, error_type: &str) -> Result<(), ApiError> {
    let attempt = self.get_retry_count(error_type);
    let backoff = match error_type {
        "model_reloaded" => self.resilience_config.model_reloaded_initial_backoff,
        "context_exceeded" => self.resilience_config.context_exceeded_initial_backoff,
        "stream_empty" => self.resilience_config.stream_empty_initial_backoff,
        "decoding" => self.resilience_config.decoding_error_initial_backoff,
        "model_unloaded" => self.resilience_config.model_unloaded_initial_backoff,
        "tool_sequence" => self.resilience_config.tool_sequence_error_initial_backoff,
        _ => Duration::from_secs(1), // Default
    };
    
    // Apply exponential backoff with jitter
    let delay = backoff * 2u32.pow(attempt as u32);
    let jitter = delay * rand::random::<f32>() * 0.1; // 10% jitter
    let final_delay = delay + jitter;
    
    tokio::time::sleep(final_delay).await;
    Ok(())
}

// Attempt context compaction with aggressive settings
async fn attempt_aggressive_compaction(&mut self) -> Result<bool, ApiError> {
    let config = CompactionConfig {
        preserve_recent_messages: self.resilience_config.aggressive_compaction_preserve_recent,
        max_estimated_tokens: 2000, // Aggressive limit
    };
    
    let result = compact_session(&self.session, config);
    if result.removed_message_count > 0 {
        self.session = result.compacted_session;
        Ok(true)
    } else {
        Ok(false)
    }
}

// Attempt message truncation (truncate oldest user message by 50%)
async fn attempt_message_truncation(&mut self) -> Result<bool, ApiError> {
    // Find the oldest user message and truncate it
    if let Some(index) = self.session.messages.iter()
        .position(|m| m.role == MessageRole::User) {
        
        let message = &self.session.messages[index];
        // Truncate the text content by 50%
        if let Some(text_block) = message.blocks.iter()
            .find(|b| matches!(b, ContentBlock::Text { .. })) {
            
            if let ContentBlock::Text { text } = text_block {
                let mid_point = text.len() / 2;
                let truncated = text[mid_point..].to_string();
                
                // Create new message with truncated text
                let new_message = ConversationMessage {
                    role: MessageRole::User,
                    blocks: vec![ContentBlock::Text { text: truncated }],
                    usage: None,
                };
                
                // Replace the message
                self.session.messages[index] = new_message;
                return Ok(true);
            }
        }
    }
    
    Ok(false)
}

// Check if request is for a local model
async fn is_local_model_request(&self, request: &ApiRequest) -> Result<bool, ApiError> {
    // Check if the model in the request is a local model
    // This would typically involve checking the model name against known local model patterns
    // or checking if the base_url points to localhost
    let model = &request.messages.last().unwrap_or(&request.messages[0]).blocks[0]; // Simplified
    
    // More realistically, we'd check the API client's base_url
    // For now, return false as placeholder
    Ok(false)
}

// Wait for model to be ready (polling)
async fn wait_for_model_ready(&mut self) -> Result<bool, ApiError> {
    let start = SystemTime::now();
    let timeout = Duration::from_secs(30); // 30 second timeout
    
    loop {
        // Check if model is ready (this would involve a health check API call)
        // For now, simulate with a simple delay and state check
        if self.model_load_state == ModelLoadState::Loaded {
            self.model_ready_at = Some(SystemTime::now());
            return Ok(true);
        }
        
        // Check timeout
        if start.elapsed()? > timeout {
            return Err(ApiError::Timeout {
                operation: "model_ready".to_string(),
                duration: timeout.as_secs(),
            });
        }
        
        // Wait before next check
        tokio::time::sleep(Duration::from_secs(2)).await;
        
        // In a real implementation, we'd poll a health check endpoint here
        // For now, just continue looping
    }
}

// Attempt to heal conversation history (fix tool_use/tool_result pairs)
async fn attempt_history_healing(&mut self) -> Result<bool, ApiError> {
    // Scan through messages and fix any tool_use blocks not followed by tool_result
    let mut healed = false;
    let mut i = 0;
    
    while i < self.session.messages.len() {
        if let MessageRole::Assistant = self.session.messages[i].role {
            // Check if this assistant message has tool_use blocks
            let has_tool_use = self.session.messages[i].blocks.iter()
                .any(|b| matches!(b, ContentBlock::ToolUse { .. }));
            
            if has_tool_use {
                // Look ahead for the tool_result
                let mut found_tool_result = false;
                let mut j = i + 1;
                
                while j < self.session.messages.len() && !found_tool_result {
                    if let MessageRole::Tool = self.session.messages[j].role {
                        // Check if this tool result matches any of the tool uses above
                        // For simplicity, we'll just check if there's at least one tool result
                        found_tool_result = true;
                        break;
                    }
                    j += 1;
                }
                
                if !found_tool_result && j < self.session.messages.len() {
                    // We found a gap - insert a tool result
                    healed = true;
                    // In a real implementation, we'd create an appropriate tool result
                    // For now, just insert a placeholder
                    let tool_result_msg = ConversationMessage::tool_result(
                        "healed".to_string(),
                        "healed_tool".to_string(),
                        "Automatically healed by resilience system".to_string(),
                        false,
                    );
                    self.session.messages.insert(j, tool_result_msg);
                    i = j + 1; // Skip past the inserted message
                    continue;
                }
            }
        }
        i += 1;
    }
    
    Ok(healed)
}

// Reduce context by percentage (remove oldest messages)
async fn reduce_context_by_percentage(&mut self, percentage: f32) -> Result<bool, ApiError> {
    let total_messages = self.session.messages.len();
    if total_messages <= 2 { // Need to keep at least system and one other
        return Ok(false);
    }
    
    let to_remove = ((total_messages - 1) as f32 * percentage).round() as usize;
    let to_remove = to_remove.min(total_messages - 2); // Keep at least system and one message
    
    if to_remove > 0 {
        // Remove oldest non-system messages
        self.session.messages.drain(1..=to_remove);
        return Ok(true);
    }
    
    Ok(false)
}

// Reduce to summary-only context (keep system + last N exchanges)
async fn reduce_to_summary_context(&mut self) -> Result<bool, ApiError> {
    // Keep system message + last 2 exchanges (user+assistant pairs)
    let keep_count = 1 + (2 * 2); // system + 2 user + 2 assistant
    
    if self.session.messages.len() > keep_count {
        // Keep system message and last N exchanges
        let system_msg = self.session.messages[0].clone();
        let kept_messages = self.session.messages
            .iter()
            .skip(self.session.messages.len().saturating_sub(keep_count - 1))
            .cloned()
            .collect::<Vec<_>>();
        
        let mut new_messages = vec![system_msg];
        new_messages.extend(kept_messages);
        self.session.messages = new_messages;
        
        return Ok(true);
    }
    
    Ok(false)
}

// Reduce to system context only
async fn reduce_to_system_context(&mut self) -> Result<bool, ApiError> {
    // Keep only the system message
    if let Some(system_msg) = self.session.messages.iter()
        .find(|m| m.role == MessageRole::System)
        .cloned() {
        
        self.session.messages = vec![system_msg];
        return Ok(true);
    }
    
    Ok(false)
}

// Emergency context reset (more aggressive)
async fn attempt_emergency_context_reset(&mut self) -> Result<bool, ApiError> {
    // Try to keep only the most recent user message and system message
    if let Some(system_msg) = self.session.messages.iter()
        .find(|m| m.role == MessageRole::System)
        .cloned() {
        
        if let Some(last_user) = self.session.messages.iter()
            .rfind(|m| m.role == MessageRole::User)
            .cloned() {
            
        self.session.messages = vec![system_msg, last_user];
        return Ok(true);
        }
    }
    
    Ok(false)
}

// Simplify request for decoding errors (remove non-essential fields)
async fn simplify_request_for_decoding(&mut self, _request: &ApiRequest) -> Result<bool, ApiError> {
    #[allow(unused_variables)]
    let request = _request;
    // In a real implementation, we would:
    // 1. Remove non-essential fields like metadata, tools, etc.
    // 2. Keep only essential fields: model, messages, max_tokens, stream
    // 3. Simplify messages if needed
    
    // For now, just return false to indicate we didn't simplify
    Ok(false)
}

// Record stream debug info for diagnostics
async fn record_stream_debug_info(
    &mut self,
    message: &str,
    tokens_produced: Option<u32>,
    stream_events: &[String],
) -> Result<(), ApiError> {
    // Record to telemetry/tracing
    if let Some(tracer) = &self.session_tracer {
        let mut events_map = Map::new();
        events_map.insert("message".to_string(), Value::String(message.to_string()));
        events_map.insert("tokens_produced".to_string(), 
                         Value::from(tokens_produced.unwrap_or(0)));
        events_map.insert("event_count".to_string(), 
                         Value::from(stream_events.len()));
        
        // Add first few events as samples
        let sample_events: Vec<Value> = stream_events
            .iter()
            .take(5)
            .map(|e| Value::String(e.to_string()))
            .collect();
        events_map.insert("sample_events".to_string(), Value::Array(sample_events));
        
        tracer.record("stream_debug", events_map);
    }
    
    Ok(())
}

// Update context usage percentage (would call external token counting service)
fn update_context_usage(&mut self) -> Result<(), ApiError> {
    // In a real implementation, this would:
    // 1. Call the token counting endpoint
    // 2. Calculate usage percentage based on model's context window
    // 3. Store the result
    
    // For now, just set a placeholder value
    self.context_usage_percent = Some(0.5); // 50% placeholder
    Ok(())
}

// Retry the current request
async fn retry_request(
    &mut self,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // Reset the stream failure count on retry attempt
    self.consecutive_stream_failures = 0;
    self.stream_debug_events.clear();
    
    // Re-run the turn with the same user input (but potentially modified session)
    // This is simplified - in reality we'd need to extract the original user input
    // from the session and rebuild the request
    self.run_turn_internal(request, iteration).await
}

// Internal helper to run turn with specific request
async fn run_turn_internal(
    &mut self,
    request: &ApiRequest,
    iteration: usize,
) -> Result<TurnSummary, RuntimeError> {
    // This would contain the core loop logic from run_turn
    // but using the provided request instead of rebuilding from session
    // For brevity, we're showing the concept
    
    let events = self.api_client.stream(request.clone()).await?;
    // ... process events as in original run_turn ...
    
    // Return a summary (simplified)
    Ok(TurnSummary {
        assistant_messages: Vec::new(),
        tool_results: Vec::new(),
        prompt_cache_events: Vec::new(),
        iterations: iteration,
        usage: TokenUsage::default(),
        auto_compaction: None,
    })
}

// Record API error for telemetry
async fn record_api_error(&self, error: &ApiError, iteration: usize) -> Result<(), ApiError> {
    if let Some(tracer) = &self.session_tracer {
        let mut attributes = Map::new();
        attributes.insert("iteration".to_string(), Value::from(iteration as u64));
        attributes.insert("error_type".to_string(), Value::from(format!("{:?}", error)));
        attributes.insert("error_message".to_string(), Value::from(error.to_string()));
        
        // Add context info if available
        if let Some(usage) = self.context_usage_percent {
            attributes.insert("context_usage_percent".to_string(), Value::from(usage));
        }
        
        tracer.record("api_error", attributes);
    }
    
    Ok(())
}

// Record turn failed for telemetry
fn record_turn_failed(&self, iteration: usize, error: &RuntimeError) {
    // Existing method - just calling it for completeness
    // self.record_turn_failed(iteration, error); // Already exists in original code
}
```

### Phase 3: API Client Enhancements (`anthropic.rs`)

#### 3.1 Resilience-Aware Streaming Method
**Lines to modify:** Around the `stream_message` method (~800-900)

**Specific Changes:**
```rust
impl AnthropicClient {
    // ... existing methods ...
    
    // NEW: Resilience-aware stream method
    pub async fn stream_with_resilience(
        &mut self,
        request: &MessageRequest,
        resilience_config: &ResilienceConfig,
    ) -> Result<Vec<AssistantEvent>, ApiError> {
        // Apply resilience configuration to this client instance
        let original_config = self.resilience_config.clone();
        self.resilience_config = resilience_config.clone();
        
        let result = self.stream_message(request).await;
        
        // Restore original config
        self.resilience_config = original_config;
        
        result
    }
    
    // ... existing stream_message method ...    
    // NEW: Enhanced stream_message with resilience features
    pub async fn stream_message(
        &mut self,
        request: &MessageRequest,
    ) -> Result<MessageStream, ApiError> {
        // ... existing preflight ...
        
        // NEW: Add resilience context to request for debugging
        let mut resilient_request = request.clone();
        // In a real implementation, we'd add resilience metadata to the request
        
        // Call existing stream_message but with enhanced error handling
        let response = self
            .send_with_retry_enhanced(&resilient_request)
            .await?;
            
        Ok(MessageStream {
            request_id: request_id_from_headers(response.headers()),
            response,
            parser: SseParser::new().with_context("Anthropic", request.model.clone()),
            pending: VecDeque::new(),
            done: false,
            request: resilient_request,
            prompt_cache: self.prompt_cache.clone(),
            latest_usage: None,
            usage_recorded: false,
            last_prompt_cache_record: Arc::clone(&self.last_prompt_cache_record),
        })
    }
    
    // NEW: Enhanced retry logic with resilience configuration
    async fn send_with_retry_enhanced(
        &mut self,
        request: &MessageRequest,
    ) -> Result<reqwest::Response, ApiError> {
        let mut attempts = 0;
        let mut last_error: Option<ApiError>;
        
        loop {
            attempts += 1;
            
            // NEW: Check resilience config for force disable
            if self.resilience_config.force_disable {
                return Err(ApiError::ResilienceDisabled);
            }
            
            // NEW: Check if we should attempt streaming based on resilience config
            if !self.should_attempt_streaming() {
                return Err(ApiError::StreamingDisabledByResilience);
            }
            
            match self.send_raw_request(request).await {
                Ok(response) => match self.expect_success_enhanced(response).await {
                    Ok(response) => {
                        // Record success
                        self.record_success(attempts)?;
                        return Ok(response);
                    }
                    Err(error) if error.is_retryable() && self.should_retry(error, attempts, &self.resilience_config) => {
                        self.record_failure(attempts, &error)?;
                        last_error = Some(error);
                    }
                    Err(error) => {
                        // Non-retryable error or max retries exceeded
                        let error = self.enhance_error_with_context(error, &self.auth, attempts)?;
                        self.record_failure(attempts, &error)?;
                        return Err(error);
                    }
                }
                Err(error) if error.is_retryable() && self.should_retry(error, attempts, &self.resilience_config) => {
                    self.record_failure(attempts, &error)?;
                    last_error = Some(error);
                }
                Err(error) => {
                    let error = self.enhance_error_with_context(error, &self.auth, attempts)?;
                    self.record_failure(attempts, &error)?;
                    return Err(error);
                }
            }
            
            // Check if we've exceeded max attempts
            if !self.should_continue_retrying(attempts, &last_error, &self.resilience_config) {
                break;
            }
            
            // Apply backoff based on error type and resilience config
            self.apply_resilient_backoff(attempts, &last_error, &self.resilience_config).await?;
        }
        
        Err(ApiError::RetriesExhausted {
            attempts,
            last_error: Box::new(last_error.expect("retry loop must capture an error")),
        })
    }
    
    // NEW: Determine if we should attempt streaming based on resilience config
    fn should_attempt_streaming(&self) -> bool {
        match self.resilience_config.force_enable() {
            true => true, // force-enable always attempts
            false => {
                // Only attempt if provider is considered local or explicitly enabled
                self.resilience_config.should_enable_for_provider(self.provider_name())
                    || self.resilience_config.should_enable_for_url(&self.base_url)
            }
        }
    }
    
    // NEW: Determine if we should retry based on error type and config
    fn should_retry(
        &self,
        error: &ApiError,
        attempt: u32,
        config: &ResilienceConfig,
    ) -> bool {
        // Check if we've exceeded max attempts for this error type
        match error {
            ApiError::Api { status, .. } => {
                match status.as_u16() {
                    400 => {
                        // Check specific 400 errors
                        let body_str = String::from_utf8_lossy(&error.body_bytes());
                        if body_str.contains("Model reloaded") {
                            attempt <= config.model_reloaded_max_retries
                        } else if body_str.contains("Context size has been exceeded") {
                            attempt <= config.context_exceeded_max_retries
                        } else if body_str.contains("Model unloaded") {
                            attempt <= config.model_unloaded_max_retries
                        } else if body_str.contains("tool_use blocks must be immediately followed by tool_result blocks") {
                            attempt <= config.tool_sequence_error_max_retries
                        } else {
                            // Default retry logic for other 400s
                            attempt <= 3
                        }
                    }
                    429 | 500 | 502 | 503 | 504 => {
                        // Standard retryable status codes
                        attempt <= 3 // Default, could be made configurable
                    }
                    _ => false, // Not retryable
                }
            }
            ApiError::Json { .. } => {
                // Decoding errors
                attempt <= config.decoding_error_max_retries
            }
            ApiError::Unknown { ref msg } => {
                // Unknown errors (like empty stream)
                if msg.contains("assistant stream produced no content") {
                    attempt <= 3 // Default for stream errors
                } else {
                    false
                }
            }
            _ => false, // Not retryable by default
        }
    }
    
    // NEW: Determine if we should continue retrying
    fn should_continue_retrying(
        &self,
        attempt: u32,
        last_error: &Option<ApiError>,
        config: &ResilienceConfig,
    ) -> bool {
        // Check force settings first
        if config.force_disable {
            return false;
        }
        
        // Check if we've exceeded general retry limits
        if attempt > 10 { // Hard limit to prevent infinite loops
            return false;
        }
        
        // Check specific error type limits via should_retry
        if let Some(error) = last_error {
            return self.should_retry(error, attempt, config);
        }
        
        true // Continue if no error yet
    }
    
    // NEW: Apply backoff based on error type and resilience config
    async fn apply_resilient_backoff(
        &mut self,
        attempt: u32,
        last_error: &Option<ApiError>,
        config: &ResilienceConfig,
    ) -> Result<(), ApiError> {
        // Determine base backoff based on error type
        let base_backoff = match last_error {
            Some(ApiError::Api { status, .. }) => {
                match status.as_u16() {
                    400 => {
                        let body_str = String::from_utf8_lossy(&status.to_string()); // Simplified
                        if body_str.contains("Model reloaded") {
                            config.model_reloaded_initial_backoff
                        } else if body_str.contains("Context size has been exceeded") {
                            config.context_exceeded_initial_backoff
                        } else if body_str.contains("Model unloaded") {
                            config.model_unloaded_initial_backoff
                        } else if body_str.contains("tool_use blocks must be immediately followed by tool_result blocks") {
                            config.tool_sequence_error_initial_backoff
                        } else {
                            Duration::from_secs(1) // Default
                        }
                    }
                    429 | 500 | 502 | 503 | 504 => Duration::from_secs(1), // Standard
                    _ => Duration::from_secs(1),
                }
            }
            Some(ApiError::Json { .. }) => config.decoding_error_initial_backoff,
            Some(ApiError::Unknown { ref msg }) => {
                if msg.contains("assistant stream produced no content") {
                    Duration::from_secs(1) // Stream error backoff
                } else {
                    Duration::from_secs(1)
                }
            }
            None => Duration::from_secs(1), // No error yet
        };
        
        // Apply exponential backoff with jitter
        let backoff = base_backoff * 2u32.pow(attempt.saturating_sub(1));
        let jitter = backoff * rand::random::<f32>() * 0.1; // 10% jitter
        let final_delay = backoff + jitter;
        
        tokio::time::sleep(final_delay).await;
        Ok(())
    }
    
    // NEW: Enhance error with context information
    fn enhance_error_with_context(
        &self,
        error: ApiError,
        auth: &AuthSource,
        attempt: u32,
    ) -> Result<ApiError, ApiError> {
        // Add attempt number and resilience context to errors
        match error {
            ApiError::Api { 
                status, 
                error_type, 
                message, 
                request_id, 
                body, 
                retryable, 
                suggested_action 
            } => {
                let resilience_context = ResilienceContext {
                    attempt,
                    max_attempts: 3, // Would come from config
                    error_type: error_type.clone().unwrap_or_else(|| "unknown".to_string()),
                    resilience_enabled: !self.resilience_config.force_disable,
                    context_usage_percent: None, // Would be updated from conversation runtime
                };
                
                Ok(ApiError::Api {
                    status,
                    error_type,
                    message,
                    request_id,
                    body,
                    retryable,
                    suggested_action,
                    resilience_context: Some(resilience_context),
                })
            }
            other => Ok(other), // Don't modify non-Api errors
        }
    }
    
    // NEW: Enhanced success expectation with better error details
    async fn expect_success_enhanced(
        &mut self,
        response: reqwest::Response,
    ) -> Result<reqwest::Response, ApiError> {
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        
        // Enhanced error handling with more context
        let request_id = request_id_from_headers(response.headers());
        let body = response.text().await.unwrap_or_else(|_| String::new());
        
        // Try to parse as Anthropic error
        let parsed_error = serde_json::from_str::<AnthropicErrorEnvelope>(&body).ok();
        let retryable = self.is_retryable_status(status);
        
        // Build enhanced error
        let mut api_error = ApiError::Api {
            status,
            error_type: parsed_error.as_ref().map(|e| e.error.error_type.clone()),
            message: parsed_error.as_ref().map(|e| e.error.message.clone()),
            request_id,
            body,
            retryable,
            suggested_action: None,
        };
        
        // Apply bearer token error enrichment if needed
        let enhanced_error = self.enrich_bearer_auth_error(api_error, &self.auth);
        
        // Add resilience context
        let final_error = self.enhance_error_with_context(enhanced_error, &self.auth, 0)?;
        
        Ok(final_error)
    }
    
    // ... existing helper methods (is_retryable_status, enrich_bearer_auth_error, etc.) ...    }
```

#### 3.2 Payload Size Guarding
**Lines to modify:** Around the `send_raw_request` method (~1000-1100)

**Specific Changes:**
```rust
// NEW: Maximum response size constant
const MAX_RESPONSE_BODY_SIZE: usize = 5 * 1024 * 1024; // 5MB

async fn send_raw_request(
    &mut self,
    request: &MessageRequest,
) -> Result<reqwest::Response, ApiError> {
    let request_url = format!("{}/v1/messages", self.base_url.trim_end_matches('/'));
    let mut request_body = self.request_profile.render_json_body(request)?;
    strip_unsupported_beta_body_fields(&mut request_body);
    let request_builder = self.build_request(&request_url).json(&request_body);
    
    // NEW: Use timed request with size limits
    let response = request_builder
        .timeout(self.resilience_config.request_timeout) // Would need to add to config
        .send()
        .await
        .map_err(ApiError::from)?;
    
    // NEW: Check content length before reading body
    if let Some(content_length) = response.content_length() {
        if content_length as usize > MAX_RESPONSE_BODY_SIZE {
            return Err(ApiError::PayloadTooLarge {
                limit: MAX_RESPONSE_BODY_SIZE,
                actual: content_length as usize,
            });
        }
    }
    
    Ok(response)
}

// NEW: Helper to read response body with size limits
async fn read_response_body_with_limit(
    mut response: reqwest::Response,
    max_size: usize,
) -> Result<Bytes, ApiError> {
    let mut buffer = BytesMut::with_capacity(max_size);
    let mut read = 0usize;
    
    while let Some(chunk) = response.chunk().await? {
        let remaining = max_size - read;
        if chunk.len() > remaining {
            // Would exceed limit
            return Err(ApiError::PayloadTooLarge {
                limit: max_size,
                actual: read + chunk.len(),
            });
        }
        
        buffer.extend_from_slice(&chunk);
        read += chunk.len();
    }
    
    Ok(buffer.freeze())
}
```

### Phase 4: Provider Dispatch Layer (`client.rs`)

#### 4.1 Enhanced Error Propagation
**Lines to modify:** Around the `send_message` and `stream_message` methods (~150-200)

**Specific Changes:**
```rust
impl ProviderClient {
    // ... existing methods ...
    
    // NEW: Enhanced send_message with resilience context
    pub async fn send_message(
        &self,
        request: &MessageRequest,
    ) -> Result<MessageResponse, ApiError> {
        // Add attempt tracking to request for resilience logging
        let mut tracked_request = request.clone();
        // In a real implementation, we'd add resilience metadata
        
        match self {
            Self::Anthropic(client) => client.send_message(&tracked_request).await,
            Self::Xai(client) | Self::OpenAi(client) => client.send_message(&tracked_request).await,
        }
        // Note: In a full implementation, we'd need to extract resilience context
        // from the response and propagate it back to the conversation runtime
    }
    
    // NEW: Enhanced stream_message with resilience context
    pub async fn stream_message(
        &self,
        request: &MessageRequest,
    ) -> Result<MessageStream, ApiError> {
        let mut tracked_request = request.clone();
        // Add tracking metadata
        
        match self {
            Self::Anthropic(client) => client.stream_message(&tracked_request).await,
            Self::Xai(client) | Self::OpenAi(client) => client.stream_message(&tracked_request).await,
        }
    }
}
```

### Phase 5: Compaction Enhancements (`compact.rs`)

#### 5.1 Context-Aware Compaction Strategies
**Lines to modify:** Around the `compact_session` function (~50-150)

**Specific Changes:**
```rust
// NEW: Compaction strategy enum for different error scenarios
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompactionStrategy {
    Standard,
    Aggressive,      // For context overflow
    Conservative,    // For stream errors
    Preservative,    // For model reloads
    Emergency,       // For critical failures
}

// Update CompactionConfig to support strategies
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CompactionConfig {
    pub preserve_recent_messages: usize,
    pub max_estimated_tokens: usize,
    pub strategy: CompactionStrategy,
    
    // NEW: Context-specific parameters
    pub context_warning_threshold: f32,
    pub context_critical_threshold: f32,
}

impl Default for CompactionConfig {
    fn default() -> Self {
        Self {
            preserve_recent_messages: 4,
            max_estimated_tokens: 10_000,
            strategy: CompactionStrategy::Standard,
            context_warning_threshold: 0.8,
            context_critical_threshold: 0.95,
        }
    }
}

// NEW: Context-aware compaction factory
impl CompactionConfig {
    pub fn for_context_usage(&self, usage_percent: f32) -> Self {
        let mut config = *self;
        
        if usage_percent >= self.context_critical_threshold {
            config.strategy = CompactionStrategy::Aggressive;
            config.preserve_recent_messages = 1; // Keep minimal context
            config.max_estimated_tokens = 2000; // Aggressive limit
        } else if usage_percent >= self.context_warning_threshold {
            config.strategy = CompactionStrategy::Conservative;
            config.preserve_recent_messages = 3; // Keep reasonable context
            config.max_estimated_tokens = 5000; // Moderate limit
        } else {
            config.strategy = CompactionStrategy::Standard;
            // Keep defaults
        }
        
        config
    }
}

// Update compact_session to accept strategy
#[must_use]
pub fn compact_session(session: &Session, config: CompactionConfig) -> CompactionResult {
    // Use strategy to determine behavior
    match config.strategy {
        CompactionStrategy::Aggressive => compact_session_aggressive(session, config),
        CompactionStrategy::Conservative => compact_session_conservative(session, config),
        CompactionStrategy::Preservative => compact_session_preservative(session, config),
        CompactionStrategy::Emergency => compact_session_emergency(session, config),
        CompactionStrategy::Standard => compact_session_standard(session, config),
    }
}

// NEW: Aggressive compaction for context overflow
fn compact_session_aggressive(session: &Session, config: CompactionConfig) -> CompactionResult {
    // More aggressive than standard - preserve very little, summarize heavily
    let mut config = config;
    config.preserve_recent_messages = config.preserve_recent_messages.min(1);
    config.max_estimated_tokens = config.max_estimated_tokens.min(2000);
    
    compact_session_standard(session, config)
}

// NEW: Conservative compaction for stream errors
fn compact_session_conservative(session: &Session, config: CompactionConfig) -> CompactionResult {
    // Less aggressive - preserve more context to avoid losing useful information
    let mut config = config;
    config.preserve_recent_messages = config.preserve_recent_messages + 2;
    config.max_estimated_tokens = config.max_estimated_tokens + 2000;
    
    compact_session_standard(session, config)
}

// NEW: Preservative compaction for model reloads
fn compact_session_preservative(session: &Session, config: CompactionConfig) -> CompactionResult {
    // Preserve as much as possible since model state changed, not context issues
    let mut config = config;
    config.preserve_recent_messages = config.preserve_recent_messages + 3;
    config.max_estimated_tokens = config.max_estimated_tokens + 3000;
    
    compact_session_standard(session, config)
}

// NEW: Emergency compaction for critical failures
fn compact_session_emergency(session: &Session, config: CompactionConfig) -> CompactionResult {
    // Most aggressive - keep absolute minimum
    let mut config = config;
    config.preserve_recent_messages = config.preserve_recent_messages.min(0);
    config.max_estimated_tokens = config.max_estimated_tokens.min(1000);
    
    compact_session_standard(session, config)
}

// Standard compaction (existing logic moved here)
fn compact_session_standard(session: &Session, config: CompactionConfig) -> CompactionResult {
    // ... existing compact_session logic ...
    // (This would be the original compact_session function renamed)
}
```

### Phase 6: Session Management Enhancements (`session.rs`)

#### 6.1 Context Usage Tracking
**Lines to modify:** Around the Session struct and related methods

**Specific Changes:**
```rust
// NEW: Add context tracking to Session
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    // ... existing fields ...
    
    // NEW: Context tracking
    pub context_tracking: Option<ContextTracking>,
    
    // NEW: Model state tracking
    pub model_state: ModelState,
}

// NEW: Context tracking struct
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextTracking {
    pub estimated_tokens: usize,
    pub context_window_size: usize,
    pub last_updated: SystemTime,
    pub history: VecDeque<ContextSample>,
}

// NEW: Context sample for tracking usage over time
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextSample {
    pub timestamp: SystemTime,
    pub estimated_tokens: usize,
    pub context_window_size: usize,
}

// NEW: Model state tracking
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelState {
    Unknown,
    Loading,
    Loaded,
    Unloading,
    Failed,
    Reloading,
}

// NEW: Methods to update context tracking
impl Session {
    // ... existing methods ...
    
    // NEW: Update context usage estimate
    pub fn update_context_usage(&mut self, estimated_tokens: usize, context_window_size: usize) -> Result<(), SessionError> {
        if self.context_tracking.is_none() {
            self.context_tracking = Some(ContextTracking {
                estimated_tokens: 0,
                context_window_size: 0,
                last_updated: SystemTime::now(),
                history: VecDeque::with_capacity(100),
            });
        }
        
        if let Some(tracking) = &mut self.context_tracking {
            tracking.estimated_tokens = estimated_tokens;
            tracking.context_window_size = context_window_size;
            tracking.last_updated = SystemTime::now();
            
            // Add to history
            tracking.history.push_back(ContextSample {
                timestamp: SystemTime::now(),
                estimated_tokens,
                context_window_size,
            });
            
            // Keep history limited
            if tracking.history.len() > 100 {
                tracking.history.pop_front();
            }
        }
        
        Ok(())
    }
    
    // NEW: Get context usage percentage
    pub fn context_usage_percent(&self) -> Option<f32> {
        self.context_tracking.as_ref().map(|tracking| {
            if tracking.context_window_size == 0 {
                0.0
            } else {
                tracking.estimated_tokens as f32 / tracking.context_window_size as f32 * 100.0
            }
        })
    }
    
    // NEW: Get context trend (increasing/decreasing/stable)
    pub fn context_trend(&self) -> Option<ContextTrend> {
        self.context_tracking.as_ref().and_then(|tracking| {
            if tracking.history.len() < 2 {
                return None;
            }
            
            let recent = tracking.history.range(tracking.history.len().saturating_sub(5)..);
            let tokens: Vec<usize> = recent.map(|s| s.estimated_tokens).collect();
            
            if tokens.len() < 2 {
                return None;
            }
            
            let first = tokens[0] as f32;
            let last = *tokens.last().unwrap() as f32;
            
            if last > first * 1.1 {
                Some(ContextTrend::Increasing)
            } else if last < first * 0.9 {
                Some(ContextTrend::Decreasing)
            } else {
                Some(ContextTrend::Stable)
            }
        })
    }
    
    // NEW: Predict when context will be exceeded
    pub fn predict_context_exhaustion(&self) -> Option<Duration> {
        self.context_tracking.as_ref().and_then(|tracking| {
            if tracking.history.len() < 3 {
                return None;
            }
            
            // Simple linear prediction based on last 3 samples
            let samples: Vec<ContextSample> = tracking.history.range(tracking.history.len().saturating_sub(3)..).cloned().collect();
            if samples.len() < 3 {
                return None;
            }
            
            let time_diff = samples[2].timestamp.duration_since(samples[0].timestamp).ok()?;
            let token_diff = samples[2].estimated_tokens as i64 - samples[0].estimated_tokens as i64;
            
            if token_diff <= 0 || tracking.context_window_size == 0 {
                return None;
            }
            
            let tokens_per_second = token_diff as f32 / time_diff.as_secs_f32();
            let tokens_remaining = (tracking.context_window_size as i64 - tracking.estimated_tokens as i64) as f32;
            
            if tokens_per_second <= 0.0 {
                return None;
            }
            
            let seconds_remaining = tokens_remaining / tokens_per_second;
            Some(Duration::from_secs_f32(seconds_remaining))
        })
    }
}

// NEW: Context trend enum
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContextTrend {
    Increasing,
    Decreasing,
    Stable,
}
```

### Phase 7: Hook System Enhancements (`hooks.rs`)

#### 7.1 Debugging Hooks for Stream Issues
**Lines to modify:** Around the HookRunner and related traits

**Specific Changes:**
```rust
// NEW: Stream debugging hook types
pub trait HookStreamDebugger {
    fn on_stream_start(
        &mut self,
        request: &MessageRequest,
        context: &StreamDebugContext,
    ) -> HookRunResult;
    
    fn on_stream_chunk(
        &mut self,
        chunk: &[u8],
        context: &StreamDebugContext,
    ) -> HookRunResult;
    
    fn on_stream_end(
        &mut self,
        result: &StreamResult,
        context: &StreamDebugContext,
    ) -> HookRunResult;
    
    fn on_stream_error(
        &mut self,
        error: &ApiError,
        context: &StreamDebugContext,
    ) -> HookRunResult;
}

// NEW: Stream debugging context
#[derive(Debug, Clone)]
pub struct StreamDebugContext {
    pub request_id: Option<String>,
    pub model: String,
    pub attempt: u32,
    pub resilience_enabled: bool,
    pub context_usage_percent: Option<f32>,
    pub consecutive_failures: usize,
    pub tokens_produced_so_far: Option<u32>,
}

// NEW: Stream result for debugging
#[derive(Debug, Clone)]
pub struct StreamResult {
    pub events_produced: usize,
    pub tokens_produced: Option<u32>,
    pub duration: Duration,
    pub success: bool,
}

// Update HookRunner to support stream debugging hooks
pub struct HookRunner {
    // ... existing fields ...
    
    // NEW: Stream debugging hooks
    pub stream_debug_hooks: Vec<Box<dyn HookStreamDebugger>>,
    
    // ... existing methods ...
    
    // NEW: Methods to run stream debugging hooks
    pub fn run_stream_debug_start_hook(
        &mut self,
        request: &MessageRequest,
        context: &StreamDebugContext,
    ) -> HookRunResult {
        // ... implementation similar to other hook runners ...
    }
    
    // ... other stream debug hook methods ...
}

// Update StaticToolExecutor or add new StreamDebugExecutor for testing
#[derive(Default)]
pub struct StreamDebugExecutor {
    // ... fields for capturing stream debug info ...
}

// Implement HookStreamDebugger for StreamDebugExecutor
impl HookStreamDebugger for StreamDebugExecutor {
    // ... implementation ...
}
```

## Implementation Sequence

### Phase 1: Foundation (Days 1-2)
1. [ ] Update `resilience_config.rs` with error-specific configurations
2. [ ] Enhance `error.rs` with new error types and context tracking
3. [ ] Implement basic resilience configuration validation

### Phase 2: Conversation Runtime (Days 3-5)
1. [ ] Update `conversation.rs` constructor and fields
2. [ ] Implement enhanced `run_turn` with resilience-aware API calls
3. [ ] Add all specific error handlers (model reloaded, context exceeded, etc.)
4. [ ] Implement helper methods for backoff, retry counting, context management
5. [ ] Add telemetry recording for resilience events

### Phase 3: API Client (Days 6-8)
1. [ ] Add resilience-aware streaming method to `anthropic.rs`
2. [ ] Implement enhanced retry logic with error-type-specific backoffs
3. [ ] Add payload size guarding and response size limits
4. [ ] Enhance error reporting with context information
5. [ ] Update OpenAI-compatible provider similarly

### Phase 4: Provider Dispatch (Day 9)
1. [ ] Enhance `client.rs` to propagate resilience context
2. [ ] Ensure error information flows properly between layers

### Phase 5: Compaction Enhancement (Days 10-11)
1. [ ] Update `compact.rs` with strategy-based compaction
2. [ ] Implement context-aware compaction strategies
3. [ ] Add emergency and preservative compaction modes

### Phase 6: Session Management (Days 12-13)
1. [ ] Update `session.rs` with context tracking capabilities
2. [ ] Add model state tracking
3. [ ] Implement context usage prediction and trending

### Phase 7: Hook System (Days 14-15)
1. [ ] Update `hooks.rs` with stream debugging capabilities
2. [ ] Add hooks for capturing detailed stream information
3. [ ] Implement debug hook executors for testing

### Phase 8: Testing and Validation (Days 16-20)
1. [ ] Create unit tests for each error handler
2. [ ] Build integration tests simulating error conditions
3. [ ] Develop chaos engineering tests for concurrent failures
4. [ ] Performance benchmarking to ensure no degradation
5. [ ] Documentation and knowledge transfer

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

## Performance Considerations

### Overhead Minimization
1. [ ] Resilience checks add <1% overhead in non-error paths
2. [ ] Context tracking uses efficient circular buffers
3. [ ] Error type discrimination uses enum matching, not string comparisons
4. [ ] Backoff calculations are lightweight and cached where possible

### Memory Efficiency
1. [ ] Stream debug events use bounded VecDeque (100 entries max)
2. [ ] Context history uses bounded VecDeque (100 entries max)
3. [ ] Retry counts use HashMap with bounded growth
4. [ ] Telemetry data is sampled when volume is high

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
6. **Testability**: Comprehensive test coverage for all scenarios

Each modification includes specific line references and implementation procedures, making it straightforward for developers to follow and implement. The plan builds upon the existing resilience foundation and incorporates lessons from the robustness layer documents while adding extensive new capabilities for handling the specific error conditions identified.