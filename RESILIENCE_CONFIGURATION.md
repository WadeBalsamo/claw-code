# Resilience Configuration Guide

## Overview

The resilience layer now supports flexible configuration to enable recovery on **any provider/URL combination**, not just local endpoints. This allows you to:

- ✅ Force enable resilience on cloud providers (Anthropic, OpenAI, xAI)
- ✅ Force disable resilience on local providers
- ✅ Fine-tune which endpoints get resilience
- ✅ Enable resilience for Anthropic API
- ✅ Auto-detect localhost endpoints (default behavior)

---

## Quick Start: Force Resilience On

### Environment Variable (Simplest)
```bash
export CLAW_RESILIENCE=force
claw-code
```

### Programmatic Usage
```rust
use api::{OpenAiCompatClient, OpenAiCompatConfig, ResilienceConfig};

let config = OpenAiCompatConfig::openai();
let client = OpenAiCompatClient::from_env(config)?
    .with_resilience_config(ResilienceConfig::force_enable());
```

---

## ResilienceConfig API

### Create Configuration

#### Default (Auto-detect localhost)
```rust
let config = ResilienceConfig::default();
// Resilience enabled for: localhost, 127.0.0.1, local URLs
// Resilience disabled for: Cloud providers
```

#### Force Enable Everywhere
```rust
let config = ResilienceConfig::force_enable();
// Resilience enabled on ALL providers/URLs
```

#### Force Disable Everywhere
```rust
let config = ResilienceConfig::force_disable();
// Resilience disabled on ALL providers/URLs
```

### Builder Pattern

```rust
let config = ResilienceConfig::default()
    .with_anthropic_enabled(true)      // Enable for Anthropic
    .with_openai_compat_enabled(true)  // Enable for OpenAI-compatible
    .with_force_enable(false);         // Don't force, just enable these

// Or start with force and selectively disable
let config = ResilienceConfig::force_enable()
    .with_force_disable(false)
    .with_anthropic_enabled(false);   // Disable for Anthropic only
```

---

## Configuration Table

| Setting | Default | Effect |
|---------|---------|--------|
| `force_enable` | `false` | Override all other settings, enable resilience everywhere |
| `force_disable` | `false` | Override all other settings, disable resilience everywhere |
| `auto_enable_for_local` | `true` | Auto-enable for localhost/127.0.0.1/local URLs |
| `enable_for_anthropic` | `false` | Enable resilience for Anthropic API |
| `enable_for_openai_compat` | `true` | Enable resilience for OpenAI-compatible endpoints |

---

## Use Cases

### Use Case 1: Force Resilience on Production

**Problem**: Cloud provider has intermittent timeouts, want resilience everywhere

**Solution**:
```rust
let config = ResilienceConfig::force_enable();
let client = OpenAiCompatClient::from_env(openai_config)?
    .with_resilience_config(config);
```

**Environment Variable**:
```bash
export CLAW_RESILIENCE=force
```

### Use Case 2: Enable Resilience for Anthropic API

**Problem**: Anthropic API occasionally has transient 5xx errors, want recovery

**Solution**:
```rust
let config = ResilienceConfig::default()
    .with_anthropic_enabled(true);

let anthropic_client = AnthropicClient::from_env()?
    .with_resilience_config(config);
```

### Use Case 3: Disable Resilience Everywhere

**Problem**: Testing, want predictable failures without retries

**Solution**:
```rust
let config = ResilienceConfig::force_disable();

let client = OpenAiCompatClient::from_env(config)?
    .with_resilience_config(config);
```

### Use Case 4: Custom Organization's Endpoint

**Problem**: Internal company endpoint (non-localhost) needs resilience

**Solution**:
```rust
let config = ResilienceConfig::default()
    .with_force_enable(true);  // Or selectively enable for OpenAI-compat

let client = OpenAiCompatClient::from_env(config)?
    .with_base_url("https://internal-llm.company.com:8000")
    .with_resilience_config(config);
```

---

## Integration Points

### OpenAiCompatClient
```rust
let client = OpenAiCompatClient::from_env(config)?
    .with_resilience_config(ResilienceConfig::force_enable());
```

### AnthropicClient
```rust
let client = AnthropicClient::from_env()?
    .with_resilience_config(
        ResilienceConfig::default()
            .with_anthropic_enabled(true)
    );
```

Or force enable resilience on Anthropic via environment variable:
```bash
export CLAW_RESILIENCE=force
```

### ProviderClient (High-Level)
```rust
let client = ProviderClient::from_model("gpt-4o")?;
// Resilience auto-configured based on provider + URL
// Also reads CLAW_RESILIENCE environment variable automatically
```

When using `ProviderClient::from_model()`, the resilience configuration is automatically loaded from the environment:
- `CLAW_RESILIENCE=force` → enables resilience for all providers
- `CLAW_RESILIENCE=none` → disables resilience completely
- Unset → auto-detect localhost endpoints (default)

---

## How It Works

### Decision Flow
```
1. Check force_enable flag
   ↓ YES → Enable resilience
   ↓ NO ↓
2. Check force_disable flag
   ↓ YES → Disable resilience
   ↓ NO ↓
3. Check provider-specific settings
   ↓ Anthropic → enable_for_anthropic
   ↓ OpenAI-compat → enable_for_openai_compat
   ↓ NO ↓
4. Check URL (for local detection)
   ↓ Localhost detected + auto_enable_for_local → Enable
   ↓ Otherwise → Disable
```

### Example Decisions

| Config | Provider | URL | Result |
|--------|----------|-----|--------|
| `force_enable()` | Any | Any | **Enabled** |
| `force_disable()` | Any | Any | **Disabled** |
| `default()` | Anthropic | Any | **Disabled** |
| `default()` | OpenAI | localhost | **Enabled** |
| `default()` | OpenAI | api.openai.com | **Disabled** |
| `default().with_anthropic_enabled(true)` | Anthropic | Any | **Enabled** |

---

## Environment Variables

### `CLAW_RESILIENCE`

Control resilience via environment variable. This is the easiest way to enable resilience on any provider/URL without code changes:

```bash
# Force enable on all providers/URLs (Anthropic, OpenAI, local, etc.)
export CLAW_RESILIENCE=force
claw-code

# Force disable on all providers/URLs  
export CLAW_RESILIENCE=none
claw-code

# Default (auto-detect localhost)
unset CLAW_RESILIENCE  # or export CLAW_RESILIENCE=auto
claw-code
```

The environment variable is read once when creating the client, so the setting applies to the entire session.

---

## Testing

### Verify Resilience is Enabled
```rust
#[test]
fn test_resilience_forced_for_openai() {
    let config = ResilienceConfig::force_enable();
    assert!(config.should_enable_for_provider("openai"));
}

#[test]
fn test_resilience_enabled_for_localhost() {
    let config = ResilienceConfig::default();
    assert!(config.should_enable_for_url("http://localhost:8000"));
}

#[test]
fn test_force_disable_blocks_everything() {
    let config = ResilienceConfig::force_disable();
    assert!(!config.should_enable_for_url("http://localhost:8000"));
    assert!(!config.should_enable_for_provider("openai"));
}
```

---

## Migration Guide

### Before (Auto-detect only)
```rust
let client = OpenAiCompatClient::from_env(config)?;
// Resilience only enabled for localhost
```

### After (With configuration)
```rust
// Option 1: Default behavior (unchanged)
let client = OpenAiCompatClient::from_env(config)?;

// Option 2: Force enable everywhere
let client = OpenAiCompatClient::from_env(config)?
    .with_resilience_config(ResilienceConfig::force_enable());

// Option 3: Custom config
let client = OpenAiCompatClient::from_env(config)?
    .with_resilience_config(
        ResilienceConfig::default()
            .with_anthropic_enabled(true)
    );
```

---

## Performance Impact

### Zero Overhead Cases
- Cloud providers with `force_disable()`
- Endpoints not matching any resilience rule

### Minimal Overhead Cases (~1ms per request)
- Error classification (fast HashMap lookup)
- Health profile check (fast in-memory cache)
- No actual retries (unless failure occurs)

### Expected Overhead with Retries
- Retry 1: ~500ms backoff
- Retry 2: ~1500ms backoff  
- Retry 3: ~4000ms backoff
- **Only happens on actual failures** (transparent to user)

---

## Troubleshooting

### Resilience Not Working
**Check**:
1. Is `ResilienceConfig` being applied to the client?
2. Is the URL detected correctly?
3. Run `should_enable_for_url()` or `should_enable_for_provider()` to verify

### Too Many Retries
**Solution**:
- Use `force_disable()` to disable resilience
- Or set `force_disable: true` via environment

### Want Different Behavior Per Endpoint
**Solution**:
```rust
let openai_client = OpenAiCompatClient::from_env(config)?
    .with_resilience_config(ResilienceConfig::force_enable());

let anthropic_client = AnthropicClient::from_env()?
    .with_resilience_config(
        ResilienceConfig::default()
            .with_anthropic_enabled(true)
    );
```

---

## Next Steps

### For Users
1. Set `CLAW_RESILIENCE=force` if you want resilience on all endpoints
2. Use `ResilienceConfig::force_enable()` programmatically if needed
3. File an issue if a specific provider needs resilience

### For Developers
1. Review `resilience_config.rs` for configuration logic
2. Extend with Anthropic support when needed
3. Add telemetry to track which resilience rules are active

---

## Summary

The resilience configuration provides **flexible, zero-breaking-change** control over where resilience is applied:

- ✅ Works with any provider (Anthropic, OpenAI, xAI, local models)
- ✅ Respects existing behavior (auto-detect localhost by default)
- ✅ Easy to override with `force_enable()` or environment variables
- ✅ Minimal performance impact when not retrying
- ✅ Transparent recovery when failures occur
