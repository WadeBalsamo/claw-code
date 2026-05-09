/// Resilience configuration for enabling recovery on any provider/URL combination.
/// This allows fine-grained control over when the resilience layer activates.
///
/// Can be configured via the `CLAW_RESILIENCE` environment variable:
/// - `force` - Force enable resilience on all providers/URLs
/// - `none` - Force disable resilience on all providers/URLs
/// - `auto` or unset - Default behavior (auto-detect localhost)

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
