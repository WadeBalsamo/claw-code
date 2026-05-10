# no_stream_tokens_robustness_layer.md

## Purpose
This document describes a comprehensive robustness layer for streaming token handling when the **resilience mode** is enabled. It aims to prevent the errors that previously caused stream failures (e.g., missing token streams, panic on malformed responses, retry exhaustion) by implementing defensive programming, proper error handling, and configuration-aware behavior.

---

## 1. Current Failure Modes (When Resilience Mode is `true`)

| Failure Mode | Symptom | Root Cause |
|--------------|---------|------------|
| **Missing or malformed token stream** | Downstream services receive `Error: assistant stream produced no content` | `stream_message` assumes a valid chunk of SSE data; when the provider returns an empty or unexpected payload, `next_event` returns `None` and the caller aborts. |
| **Panic on unwrap** | Process crashes with stack trace | Code uses `unwrap()` on `Result` from `serde_json::from_str` without guarding against provider‑side errors. |
| **Exhausted retry loop** | Request fails after N retries, returning `RetriesExhausted` | Backoff logic does not respect the `ResilienceConfig` throttling when forced‑enable is active, leading to unnecessary retries. |
| **Unauthorized 401 with hidden hint** | Users see generic “Invalid bearer token” without guidance | `enrich_bearer_auth_error` swallows the hint when `ApiKeyAndBearer` is present, making debugging harder under resilience. |
| **Token limit violation** | `ContextWindowExceeded` errors appear even though the request was already streamed | Token counting happens *after* streaming begins; if resilience forces a request that exceeds limits, the error is raised too late. |

---

## 2. Design Goals for the Robustness Layer

1. **Graceful Degradation** – When a stream cannot be produced, return a well‑structured error instead of panicking or returning empty content.
2. **Resilience‑Aware Retries** – Respect the `ResilienceConfig` settings (force‑enable, force‑disable, auto‑enable) when deciding whether to retry.
3. **Early Validation** – Validate token limits and response shape *before* beginning a stream.
4. **Clear User Feedback** – Preserve or enrich error messages with actionable hints (e.g., the `sk‑ant` hint) while avoiding false positives.
5. **Test Coverage** – Provide unit and integration tests that simulate resilience‑enabled failures.

---

## 3. Proposed Robustness Layer Implementation

### 3.1. Guard Clause for Resilience‑Enabled Streaming

Add a helper that checks the current `ResilienceConfig` before attempting a stream:

```rust
fn should_attempt_streaming(&self) -> bool {
    match self.resilience_config.force_enable() {
        true => true, // force‑enable always attempts streaming
        false => {
            // Only attempt streaming if the provider is considered local or explicitly enabled
            self.resilience_config.should_enable_for_provider(self.provider_name())
                || self.resilience_config.should_enable_for_url(&self.base_url)
        }
    }
}
```

- Call this at the start of `stream_message`. If it returns `false`, return a custom `StreamError::StreamingDisabled` instead of proceeding.

### 3.2. Pre‑Stream Validation

Before opening the HTTP connection, validate:

1. **Token Limit** – Use `count_tokens` *synchronously* (no await) to ensure the request fits within the model's context window. If not, return `ApiError::ContextWindowExceeded` early.
2. **Response Shape** – Verify that the provider’s `/v1/messages` endpoint supports streaming (`supports_streaming: true` flag in provider metadata). If not, abort with `ApiError::StreamingNotSupported`.

### 3.3. Safer Stream Parsing

Replace the current `loop { match self.response.chunk().await { ... }}` with a more defensive pattern:

```rust
while let Some(chunk) = self.response.chunk().await? {
    // Guard against empty chunks
    if chunk.is_empty() {
        // Emit a "heartbeat" event or return a controlled error
        return Ok(Some(StreamEvent::MessageStop("empty chunk received".into())));
    }
    self.pending.extend(self.parser.push(&chunk)?);
}
```

- Return a `StreamEvent::MessageStop` with a descriptive message rather than silently ending the stream.

### 3.4. Structured Error Propagation

Define a dedicated error type for streaming failures:

```rust
#[derive(Debug, thiserror::Error)]
pub enum StreamError {
    #[error("streaming disabled by resilience config")]
    StreamingDisabled,
    #[error("provider returned empty payload")]
    EmptyPayload,
    #[error("failed to parse server‑sent events: {0}")]
    SseParseError(#[from] std::io::Error),
    #[error("unexpected HTTP status {0}")]
    UnexpectedStatus(reqwest::StatusCode),
}
```

- Propagate `StreamError` up the call stack instead of generic `ApiError` when the failure originates from streaming.

### 3.5. Resilience‑Aware Retry Logic

Modify `send_with_retry` to incorporate the `ResilienceConfig`:

```rust
async fn send_with_retry(&self, request: &MessageRequest) -> Result<reqwest::Response, ApiError> {
    // Respect forced disable
    if !self.resilience_config.force_disable() && !self.should_attempt_streaming() {
        return Err(ApiError::StreamingDisabled);
    }

    // Use jittered backoff but cap retries according to resilience config
    let max_attempts = if self.resilience_config.force_enable() {
        self.max_retries + 1 // allow full retry budget
    } else {
        // Normal policy – may limit retries for non‑local providers
        self.max_retries + 1
    };

    // ... existing loop logic, but break early if resilience disallows retry
}
```

- When `force_disable` is true, short‑circuit with a clear error.

### 3.6. Enriched Error Messages

Preserve the `SK_ANT_BEARER_HINT` logic but ensure it is *always* attached to a 401 error **when resilience is enabled**, regardless of `AuthSource`:

```rust
fn enrich_bearer_auth_error(error: ApiError, auth: &AuthSource) -> ApiError {
    // ... existing logic ...
    // When resilience is forced, always attach hint for 401 errors
    if self.resilience_config.force_enable() && status == StatusCode::UNAUTHORIZED {
        // Attach hint unconditionally
        // (same logic as before)
    }
    // ... fallback to original behavior ...
}
```

- This guarantees users see the hint even when both `api_key` and `bearer_token` are present.

### 3.7. Unit Tests

Add tests covering:

- **Force‑enable streaming** with a mock provider that returns an empty payload → expects `StreamError::EmptyPayload`.
- **Force‑disable streaming** → request should be rejected early.
- **Token limit violation** before streaming → returns `ContextWindowExceeded`.
- **401 with hint** when both auth fields are set and resilience is forced.

---

## 4. Migration Path

1. **Add the `StreamError` enum** to `crate::error`.
2. **Update `AnthropicClient::stream_message`** to call `should_attempt_streaming()` and perform pre‑stream validation.
3. **Replace the unsafe `unwrap`/`expect` blocks** in `stream_message` and `send_raw_request` with proper error handling that returns `StreamError` or `ApiError::StreamingDisabled`.
4. **Modify `send_with_retry`** to respect `ResilienceConfig` when deciding the maximum number of attempts.
5. **Adjust `enrich_bearer_auth_error`** to always attach the `SK_ANT_BEARER_HINT` when `force_enable` is active.
6. **Write comprehensive tests** under `tests/` to verify each path.
7. **Document the new behavior** in `RESILIENCE_CONFIGURATION.md` and add a section in the developer wiki.

---

## 5. Checklist for Deployment

- [ ] Code review of all changes (ensure no `unwrap` on network responses).
- [ ] Run `cargo test --workspace --all-targets -Z unstable-options` (or the project's test suite) with `RESILIENCE=true` env var.
- [ ] Verify that `no_stream_tokens_robustness_layer.md` is added to the repository root and referenced in `README.md`.
- [ ] Bump version in `Cargo.toml` if needed.
- [ ] Deploy to staging and monitor for `stream_message` errors under forced resilience (`CLAW_RESILIENCE=force`).

---

### TL;DR
By adding **early validation**, **structured error types**, **resilience‑aware retry logic**, and **consistent user‑facing hints**, we can guarantee that streaming tokens will never again produce a “no content” failure when resilience mode is enabled. This layer isolates streaming from the rest of the system, making failures predictable and debuggable.
