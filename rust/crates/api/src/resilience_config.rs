/// Resilience configuration for enabling recovery on any provider/URL combination.
/// This allows fine-grained control over when the resilience layer activates.
///
/// Can be configured via the `CLAW_RESILIENCE` environment variable:
/// - `force` - Force enable resilience on all providers/URLs
/// - `none` - Force disable resilience on all providers/URLs
/// - `auto` or unset - Default behavior (auto-detect localhost)

use std::time::Duration;

#[derive(Debug, Clone)]
pub struct ResilienceConfig {
    /// Force enable resilience recovery regardless of provider/URL
    pub force_enable: bool,

    /// Force disable resilience recovery regardless of provider/URL
    pub force_disable: bool,

    /// Auto-enable for localhost endpoints (default: true)
    pub auto_enable_for_local: bool,

    /// Enable for Anthropic API endpoints (default: false for now, can be enabled)
    pub enable_for_anthropic: bool,

    /// Enable for OpenAI-compatible endpoints (default: auto-detect localhost)
    pub enable_for_openai_compat: bool,

    // Error-specific retry configurations
    /// Maximum retries for model reloaded errors
    pub model_reloaded_max_retries: u32,
    /// Maximum retries for context size exceeded errors
    pub context_exceeded_max_retries: u32,
    /// Maximum retries for empty stream errors
    pub stream_empty_max_retries: u32,
    /// Maximum retries for decoding errors
    pub decoding_error_max_retries: u32,
    /// Maximum retries for model unloaded errors
    pub model_unloaded_max_retries: u32,
    /// Maximum retries for tool sequence errors
    pub tool_sequence_error_max_retries: u32,

    // Backoff configurations (initial backoff duration)
    /// Initial backoff for model reloaded errors
    pub model_reloaded_initial_backoff: Duration,
    /// Initial backoff for context exceeded errors
    pub context_exceeded_initial_backoff: Duration,
    /// Initial backoff for stream empty errors
    pub stream_empty_initial_backoff: Duration,
    /// Initial backoff for decoding errors
    pub decoding_error_initial_backoff: Duration,
    /// Initial backoff for model unloaded errors
    pub model_unloaded_initial_backoff: Duration,
    /// Initial backoff for tool sequence errors
    pub tool_sequence_error_initial_backoff: Duration,

    // Context management thresholds (0.0 to 1.0)
    /// Warning threshold for context usage percentage (default: 0.8 = 80%)
    pub context_warning_threshold: f32,
    /// Critical threshold for context usage percentage (default: 0.95 = 95%)
    pub context_critical_threshold: f32,

    // Compaction strategies
    /// Preserve recent messages count for aggressive compaction
    pub aggressive_compaction_preserve_recent: usize,
    /// Preserve recent messages count for conservative compaction
    pub conservative_compaction_preserve_recent: usize,
}

impl ResilienceConfig {
    /// Create default resilience configuration
    pub fn default() -> Self {
        Self {
            force_enable: false,
            force_disable: false,
            auto_enable_for_local: true,
            enable_for_anthropic: false,
            enable_for_openai_compat: true,
            // Error-specific retry configurations
            model_reloaded_max_retries: 3,
            context_exceeded_max_retries: 2,
            stream_empty_max_retries: 3,
            decoding_error_max_retries: 2,
            model_unloaded_max_retries: 5,
            tool_sequence_error_max_retries: 2,
            // Backoff configurations
            model_reloaded_initial_backoff: Duration::from_secs(1),
            context_exceeded_initial_backoff: Duration::from_secs(2),
            stream_empty_initial_backoff: Duration::from_secs(1),
            decoding_error_initial_backoff: Duration::from_secs(1),
            model_unloaded_initial_backoff: Duration::from_secs(3),
            tool_sequence_error_initial_backoff: Duration::from_secs(1),
            // Context management thresholds
            context_warning_threshold: 0.8,
            context_critical_threshold: 0.95,
            // Compaction strategies
            aggressive_compaction_preserve_recent: 1,
            conservative_compaction_preserve_recent: 3,
        }
    }

    /// Force enable resilience on all providers
    pub fn force_enable() -> Self {
        Self {
            force_enable: true,
            force_disable: false,
            auto_enable_for_local: true,
            enable_for_anthropic: true,
            enable_for_openai_compat: true,
            // Error-specific retry configurations (higher for forced enable)
            model_reloaded_max_retries: 5,
            context_exceeded_max_retries: 3,
            stream_empty_max_retries: 5,
            decoding_error_max_retries: 3,
            model_unloaded_max_retries: 10,
            tool_sequence_error_max_retries: 3,
            // Backoff configurations
            model_reloaded_initial_backoff: Duration::from_secs(1),
            context_exceeded_initial_backoff: Duration::from_secs(2),
            stream_empty_initial_backoff: Duration::from_secs(1),
            decoding_error_initial_backoff: Duration::from_secs(1),
            model_unloaded_initial_backoff: Duration::from_secs(3),
            tool_sequence_error_initial_backoff: Duration::from_secs(1),
            // Context management thresholds
            context_warning_threshold: 0.8,
            context_critical_threshold: 0.95,
            // Compaction strategies (more aggressive for forced enable)
            aggressive_compaction_preserve_recent: 1,
            conservative_compaction_preserve_recent: 3,
        }
    }

    /// Force disable resilience on all providers
    pub fn force_disable() -> Self {
        Self {
            force_enable: false,
            force_disable: true,
            auto_enable_for_local: false,
            enable_for_anthropic: false,
            enable_for_openai_compat: false,
            // Error-specific retry configurations (none for forced disable)
            model_reloaded_max_retries: 0,
            context_exceeded_max_retries: 0,
            stream_empty_max_retries: 0,
            decoding_error_max_retries: 0,
            model_unloaded_max_retries: 0,
            tool_sequence_error_max_retries: 0,
            // Backoff configurations
            model_reloaded_initial_backoff: Duration::from_secs(0),
            context_exceeded_initial_backoff: Duration::from_secs(0),
            stream_empty_initial_backoff: Duration::from_secs(0),
            decoding_error_initial_backoff: Duration::from_secs(0),
            model_unloaded_initial_backoff: Duration::from_secs(0),
            tool_sequence_error_initial_backoff: Duration::from_secs(0),
            // Context management thresholds
            context_warning_threshold: 0.8,
            context_critical_threshold: 0.95,
            // Compaction strategies
            aggressive_compaction_preserve_recent: 1,
            conservative_compaction_preserve_recent: 3,
        }
    }

    /// Create resilience configuration from environment variable CLAW_RESILIENCE
    /// - "force" - Force enable resilience everywhere
    /// - "none" - Force disable resilience everywhere
    /// - "auto" or unset - Default (auto-detect localhost)
    pub fn from_env() -> Self {
        match std::env::var("CLAW_RESILIENCE")
            .ok()
            .map(|s| s.to_lowercase())
        {
            Some(s) if s == "force" => Self::force_enable(),
            Some(s) if s == "none" => Self::force_disable(),
            _ => Self::default(),
        }
    }

    /// Enable resilience for Anthropic API
    pub fn with_anthropic_enabled(mut self, enabled: bool) -> Self {
        self.enable_for_anthropic = enabled;
        self
    }

    /// Enable resilience for OpenAI-compatible endpoints
    pub fn with_openai_compat_enabled(mut self, enabled: bool) -> Self {
        self.enable_for_openai_compat = enabled;
        self
    }

    /// Force enable resilience (overrides all other settings)
    pub fn with_force_enable(mut self, enabled: bool) -> Self {
        self.force_enable = enabled;
        self
    }

    /// Force disable resilience (overrides all other settings)
    pub fn with_force_disable(mut self, enabled: bool) -> Self {
        self.force_disable = enabled;
        self
    }

    /// Check if resilience should be enabled for a provider
    pub fn should_enable_for_provider(&self, provider_name: &str) -> bool {
        // Force settings override everything
        if self.force_enable {
            return true;
        }
        if self.force_disable {
            return false;
        }

        match provider_name.to_lowercase().as_str() {
            "anthropic" => self.enable_for_anthropic,
            "openai" | "xai" | "dashscope" | "lm_studio" | "local" => self.enable_for_openai_compat,
            _ => false,
        }
    }

    /// Check if resilience should be enabled for a specific URL
    pub fn should_enable_for_url(&self, base_url: &str) -> bool {
        // Force settings override everything
        if self.force_enable {
            return true;
        }
        if self.force_disable {
            return false;
        }

        // Auto-enable for localhost
        if self.auto_enable_for_local {
            let lower = base_url.to_lowercase();
            if lower.contains("localhost") || lower.contains("127.0.0.1") || lower.contains("local")
            {
                return true;
            }
        }

        false
    }
}

impl Default for ResilienceConfig {
    fn default() -> Self {
        Self::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn force_enable_overrides_all_settings() {
        let config = ResilienceConfig::force_enable();
        assert!(config.should_enable_for_provider("anthropic"));
        assert!(config.should_enable_for_provider("openai"));
        assert!(config.should_enable_for_url("https://api.openai.com"));
    }

    #[test]
    fn force_disable_overrides_all_settings() {
        let config = ResilienceConfig::force_disable();
        assert!(!config.should_enable_for_provider("anthropic"));
        assert!(!config.should_enable_for_url("http://localhost:8000"));
    }

    #[test]
    fn auto_enable_for_localhost() {
        let config = ResilienceConfig::default();
        assert!(config.should_enable_for_url("http://localhost:8000"));
        assert!(config.should_enable_for_url("http://127.0.0.1:8000"));
        assert!(config.should_enable_for_url("http://local-llama:8000"));
        assert!(!config.should_enable_for_url("https://api.openai.com"));
    }

    #[test]
    fn anthropic_disabled_by_default() {
        let config = ResilienceConfig::default();
        assert!(!config.should_enable_for_provider("anthropic"));
    }

    #[test]
    fn anthropic_can_be_enabled() {
        let config = ResilienceConfig::default().with_anthropic_enabled(true);
        assert!(config.should_enable_for_provider("anthropic"));
    }

    #[test]
    fn openai_compat_enabled_by_default() {
        let config = ResilienceConfig::default();
        assert!(config.should_enable_for_provider("openai"));
        assert!(config.should_enable_for_provider("xai"));
    }

    #[test]
    fn from_env_respects_force_enable() {
        std::env::set_var("CLAW_RESILIENCE", "force");
        let config = ResilienceConfig::from_env();
        assert!(config.force_enable);
        std::env::remove_var("CLAW_RESILIENCE");
    }

    #[test]
    fn from_env_respects_force_disable() {
        std::env::set_var("CLAW_RESILIENCE", "none");
        let config = ResilienceConfig::from_env();
        assert!(config.force_disable);
        std::env::remove_var("CLAW_RESILIENCE");
    }

    #[test]
    fn from_env_defaults_to_auto() {
        std::env::remove_var("CLAW_RESILIENCE");
        let config = ResilienceConfig::from_env();
        assert!(!config.force_enable);
        assert!(!config.force_disable);
        assert!(config.auto_enable_for_local);
    }
}
