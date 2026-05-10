# error_decoding_robustness_layer.md

## Purpose
This document defines a **decoding‑robustness layer** that guarantees the API client never fails with an “http error: error decoding response body” (or similar JSON‑deserialization panics) when **resilience mode** is active. It achieves this by:

1. **Anticipating malformed or unexpected payloads** before they trigger a panic.
2. **Gracefully handling deserialization failures** and returning structured, actionable errors.
3. **Isolating the decoding step** so that a single bad response never crashes the entire request flow.
4. **Providing clear user feedback** (including the `SK_ANT_BEARER_HINT` when relevant) while preserving the original error information.

---

## 1. Current Failure Modes (When Resilience Mode Is Enabled)

| Failure Mode | Typical Error Message | Root Cause |
|--------------|----------------------|------------|
| **JSON deserialization panic** | `error: http error: error decoding response body` (often wrapped in `ApiError::Json`) | `serde_json::from_str::<T>(body)` is called without guarding against non‑JSON or partially‑filled bodies; a malformed payload causes the process to abort or return an opaque error. |
| **Partial JSON leading to missing fields** | `ApiError::Json(DeserializeError { ... })` | The provider returns a reduced payload (e.g., missing `id` or `model` fields) that cannot be mapped to the expected struct, causing `deserialize` to fail. |
| **Non‑JSON fallback (HTML error page, plain text)** | Same decoding error as above | The client assumes every successful HTTP status returns valid JSON; when the server returns HTML or plain text (e.g., maintenance page), deserialization fails. |
| **Large payload causing memory pressure** | `ApiError::Json(DeserializeError { .. })` with “invalid length” | Attempting to read the entire response body into memory before deserialization can OOM, which then surfaces as a generic “error decoding response body”. |
| **Resilience‑forced retry on a bad payload** | Repeated decoding failures across retries | The retry loop does not detect that the failure is *decoding* rather than *transient network* and keeps retrying, eventually exhausting the retry budget. |

---

## 2. Design Goals for the Decoding‑Robustness Layer

| Goal | Description |
|------|-------------|
| **Zero‑panic decoding** | All `serde_json` deserialization is wrapped in a `catch_unwind`‑style guard that never panics, returning a dedicated `DecodingError` enum. |
| **Early payload sanity check** | Before attempting full deserialization, perform a cheap structural check (e.g., verify that the top‑level JSON is an object and contains a `"type"` field for error envelopes). |
| **Fallback to raw response** | When decoding fails, return the raw response body (truncated to a safe length) as part of the error, preserving context for debugging. |
| **Resilience‑aware error suppression** | If resilience is forced **and** the failure is a known non‑retryable decoding error, abort the retry loop early with a clear message instead of exhausting retries. |
| **Consistent user‑facing hints** | Preserve or enrich the `SK_ANT_BEARER_HINT` for 401‑type errors and also add a decoding‑specific hint (e.g., “the provider returned an unexpected payload; verify that the endpoint URL is correct”). |
| **Memory‑safe handling** | Impose a maximum response‑body size (e.g., 5 MiB) before attempting to read it into a `String`; larger bodies are rejected early with a clear error. |
| **Comprehensive test coverage** | Add unit tests that simulate malformed JSON, empty bodies, HTML pages, and oversized payloads under resilience‑enabled configurations. |

---

## 3. Proposed Decoding‑Robustness Implementation

### 3.1. Centralized Decoding Helper

Create a utility that safely decodes any `&[u8]` or `String` into a target type:

```rust
/// Safely decode JSON, never panicking.
pub fn safe_deserialize<'de, T: DeserializeOwned>(input: &[u8]) -> Result<T, DecodingError> {
    // 1️⃣ Optional size guard (e.g., reject > 5MiB)
    const MAX_BYTES: usize = 5 * 1024 * 1024;
    if input.len() > MAX_BYTES {
        return Err(DecodingError::PayloadTooLarge);
    }

    // 2️⃣ Quick structural sanity check
    if !input.starts_with(b"{") {
        return Err(DecodingError::NotJson);
    }

    // 3️⃣ Attempt deserialization inside a catch‑unwind
    let result: Result<T, serde_json::Error> = std::panic::catch_unwind(||
        serde_json::from_slice(input)
    );

    match result {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(e)) => Err(DecodingError::Serde(serde_json::Error::from(e))),
        Err(_panic) => Err(DecodingError::PanicDuringDeserialize),
    }
}
```

- **`DecodingError`** is an enum that wraps all possible failure reasons (`NotJson`, `Panic`, `Serde(..)`, `PayloadTooLarge`).

### 3.2. Replace All Direct `serde_json::from_str` Calls

Locate every place in the codebase where the client deserializes a response body, e.g.:

- `MessageResponse::from_json_body`
- `CountTokensResponse::from_json_body`
- `OAuthTokenSet::from_json_body`
- Any custom `ApiError::json_deserialize` calls

Replace them with:

```rust
let parsed = safe_deserialize(&body_bytes)?;
```

and handle the returned `DecodingError` appropriately (see 3.4).

### 3.3. Structured Error Conversion

Add a conversion from `DecodingError` to the existing `ApiError`:

```rust
impl From<DecodingError> for ApiError {
    fn from(err: DecodingError) -> Self {
        match err {
            DecodingError::NotJson => ApiError::Json("response body is not valid JSON".into()),
            DecodingError::PanicDuringDeserialize => ApiError::Json("panic occurred while decoding response".into()),
            DecodingError::Serde(e) => {
                // Preserve original message but tag it as a decoding issue
                ApiError::Json(format!("failed to deserialize JSON: {e}"))
            }
            DecodingError::PayloadTooLarge => ApiError::Json("response payload exceeds size limit".into()),
        }
    }
}
```

- This ensures the **decoding layer** integrates cleanly with the existing error taxonomy.

### 3.4. Graceful Degradation in `send_with_retry`

When a decoding error occurs, we want to:

1. **Log the raw payload** (truncated) for debugging.
2. **Return a structured error** that includes the hint about decoding problems.
3. **Optionally abort retry** if resilience is forced and the error is non‑retryable.

Update the `send_with_retry` loop:

```rust
match self.send_raw_request(request).await {
    Ok(response) => {
        // Read body *once* into a byte buffer (limit size)
        let body_bytes = read_response_body(&response, /*max_bytes=*/5_000_000)?;
        // Try to deserialize
        match safe_deserialize(&body_bytes) {
            Ok(parsed) => {
                // Continue with normal processing...
            }
            Err(dec_err) => {
                // Convert to ApiError
                let api_err = ApiError::from(dec_err);
                // Enrich with hint if resilience is forced and status is 401/500 etc.
                let enriched = if self.resilience_config.force_enable() && api_err.is_client_error() {
                    // Attach decoding‑specific hint
                    match api_err {
                        ApiError::Json(_) => {
                            // Add a generic decoding hint
                            let mut msg = api_err.to_string();
                            msg.push_str(" — decoding hint: response payload may be malformed or exceed size limit; verify provider health.");
                            api_err.with_custom_message(msg)
                        }
                        _ => api_err,
                    }
                } else {
                    api_err
                };
                return Err(enriched);
            }
        }
    }
    Err(e) => return Err(e),
}
```

- `read_response_body` is a small helper that reads at most `MAX_BYTES` from the response stream, returning a `Vec<u8>` or error if the limit is exceeded.

### 3.5. Early Payload Size Guard in `send_raw_request`

Before reading the full response body, enforce the size guard:

```rust
fn read_response_body(response: &reqwest::Response, max_bytes: usize) -> Result<Vec<u8>, ApiError> {
    // Stream the body but stop after `max_bytes`
    let mut buf = Vec::with_capacity(max_bytes);
    let mut taken = 0usize;
    while let Some(chunk) = response.chunk().await? {
        let remaining = max_bytes - taken;
        if chunk.len() > remaining {
            // Truncate and record that we hit the limit
            buf.extend_from_slice(&chunk[..remaining]);
            return Err(ApiError::Json("response payload exceeds size limit".into()));
        }
        buf.extend_from_slice(chunk.as_ref());
        taken += chunk.len();
    }
    Ok(buf)
}
```

- This prevents OOM and ensures the decoding helper never receives a gigantic payload.

### 3.6. Unit Tests

Add tests under `tests/` that cover:

| Test | Scenario |
|------|----------|
| `decode_malformed_json_returns_error` | Simulate a response with `{ "invalid": json }` → expect `ApiError::Json` with decoding hint. |
| `decode_panic_is_caught` | Feed a deliberately malformed payload that would cause a panic in `serde_json` → assert that the panic is caught and converted to `DecodingError::PanicDuringDeserialize`. |
| `large_payload_is_rejected` | Mock a response that streams >5 MiB → ensure `ApiError::Json("response payload exceeds size limit")` is returned. |
| `decoding_error_under_force_resilience` | Force resilience on and return a malformed JSON → assert that the retry loop aborts early and includes the decoding hint. |
| `size_limit_hint_is_preserved` | Verify that the error message contains the size‑limit hint when resilience is forced. |

### 3.7. Migration Path

1. **Add `DecodingError` enum** to `crate::error`.  
2. **Implement `safe_deserialize`** in a new module `decoding::robust`.  
3. **Replace every `serde_json::from_str/from_slice`** call with `safe_deserialize`.  
4. **Update `From<DecodingError>`** for `ApiError`.  
5. **Modify `read_response_body`** and `send_raw_request` to enforce the size limit.  
6. **Adjust `send_with_retry`** to handle decoding errors as described.  
7. **Add the unit tests** under `tests/decoding_robustness`.  
8. **Document the new behavior** in `RESILIENCE_CONFIGURATION.md` (new subsection “Decoding Robustness”).  
9. **Run the full test suite** with `RESILIENCE=force` to confirm no panics.  

### 3.8. Checklist for Deployment

- [ ] Code review of all changes (especially the panic‑catching logic).  
- [ ] Run `cargo test --workspace --all-targets` with `RESILIENCE=force`.  
- [ ] Verify that `error_decoding_robustness_layer.md` is present at the repo root and referenced in `README.md`.  
- [ ] Ensure that any new dependencies (`catch_unwind`, size‑limit constants) are added to `Cargo.toml` if not already present.  
- [ ] Deploy to a canary environment and monitor logs for any `DecodingError` occurrences.  

---

## TL;DR

By **centralizing safe JSON deserialization**, **guarding against oversized or malformed payloads**, and **integrating with the existing resilience configuration**, we eliminate the “http error: error decoding response body” failure mode entirely. The layer returns **structured, informative errors**, preserves debugging context, and guarantees that a single bad response can never crash the client while resilience is active.
