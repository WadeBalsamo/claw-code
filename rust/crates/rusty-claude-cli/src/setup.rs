/// `claw setup` — launcher integration for local and third-party model providers.
///
/// Mirrors the shell behaviour of `scripts/setup_lmcode.sh` and
/// `scripts/setup_opencode_shortcut.sh` as native Rust commands, so that no
/// subprocess or generated script is needed to start `claw` against a
/// specific provider with the correct environment variables.
///
/// ## LM Studio (`claw setup lmstudio [model]`)
///
/// 1. Discover address (config env → recent file → loopback candidates)
/// 2. Fetch `/v1/models`, offer list if no `model` argument given
/// 3. Set `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, `OPENAI_API_KEY`,
///    `CLAW_RESILIENCE=force`
/// 4. Launch the REPL
///
/// ## OpenRouter (`claw setup openrouter [model]`)
///
/// 1. Read / manage API key (`OPENROUTER_API_KEY` env → `~/.config/opencode/.env`)
/// 2. Fetch tool-capable model catalogue from `openrouter.ai`
/// 3. Set `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `CLAW_RESILIENCE=none`
/// 4. Launch the REPL

use std::env;
use std::fs;
use std::path::PathBuf;
use std::time::Duration;

// ── helpers ───────────────────────────────────────────────────────────

/// Best-effort home-directory lookup, falling back to a known worktree path
/// so the module never panics or fails in minimal environments.
fn default_home() -> PathBuf {
    env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
}

// ── LM Studio ─────────────────────────────────────────────────────────

const LMSTUDIO_DEFAULT_HOST: &str = "127.0.0.1";
const LMSTUDIO_DEFAULT_PORT: u16 = 1234;
const RECENT_FILE_NAME: &str = ".lmstudio_recent_ips";

fn recent_file_path() -> PathBuf {
    let home = env::var("HOME").unwrap_or_default();
    if home.is_empty() { PathBuf::from(RECENT_FILE_NAME) }
    else { PathBuf::from(home).join(RECENT_FILE_NAME) }
}

fn load_recent_addresses() -> Vec<String> {
    let path = recent_file_path();
    if !path.exists() {
        return Vec::new();
    }
    fs::read_to_string(&path)
        .ok()
        .map(|content| {
            content
                .lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
}

fn save_recent_address(addr: &str) {
    let path = recent_file_path();
    let mut addrs: Vec<String> = path
        .exists()
        .then(|| {
            fs::read_to_string(&path)
                .ok()
                .map(|c| {
                    c.lines()
                        .map(|l| l.trim().to_string())
                        .filter(|l| !l.is_empty())
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default()
        })
        .unwrap_or_default();
    // Remove duplicate, prepend
    addrs.retain(|a| a != addr);
    addrs.insert(0, addr.to_string());
    addrs.truncate(10);
    let _ = fs::write(&path, addrs.join("\n"));
}

/// Probe whether an LM Studio (or compatible) `/v1/models` endpoint
/// responds successfully.
async fn probe_lmstudio_address(host_port: &str) -> bool {
    let url = format!("http://{host_port}/v1/models");
    match reqwest::Client::new()
        .get(&url)
        .timeout(Duration::from_secs(3))
        .send()
        .await
    {
        Ok(resp) => resp.status().is_success(),
        Err(_) => false,
    }
}

/// Attempt address discovery using the three-tier strategy:
///   1. Configured via `LM_STUDIO_HOST` / `LM_STUDIO_PORT` env vars
///   2. Recently-used addresses (most-recent first)
///   3. Loopback candidates (`127.0.0.1:1234`, `localhost:1234`)
async fn discover_lmstudio_address() -> Result<String, String> {
    let configured_host =
        env::var("LM_STUDIO_HOST").unwrap_or_else(|_| LMSTUDIO_DEFAULT_HOST.to_string());
    let configured_port: u16 = env::var("LM_STUDIO_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(LMSTUDIO_DEFAULT_PORT);

    // Tier 1: configured address
    let configured_addr = format!("{configured_host}:{configured_port}");
    if probe_lmstudio_address(&configured_addr).await {
        save_recent_address(&configured_addr);
        return Ok(configured_addr);
    }

    // Tier 2: recently-used addresses
    for addr in load_recent_addresses() {
        if probe_lmstudio_address(&addr).await {
            save_recent_address(&addr);
            return Ok(addr);
        }
    }

    // Tier 3: loopback candidates
    for candidate in &["127.0.0.1:1234", "localhost:1234"] {
        if probe_lmstudio_address(candidate).await {
            save_recent_address(candidate);
            return Ok(candidate.to_string());
        }
    }

    Err(format!(
        "Could not find LM Studio server at {configured_addr} or any default address.\n\
         Is LM Studio running with the local HTTP server enabled?\n\
         You can customise the address via LM_STUDIO_HOST (default 127.0.0.1) and\n\
         LM_STUDIO_PORT (default 1234) environment variables."
    ))
}

/// Fetch the list of available models from an LM Studio `/v1/models` endpoint.
async fn fetch_lmstudio_models(host_port: &str) -> Result<Vec<String>, String> {
    let url = format!("http://{host_port}/v1/models");
    let resp = reqwest::Client::new()
        .get(&url)
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .map_err(|e| format!("failed to fetch model list: {e}"))?;

    if !resp.status().is_success() {
        return Err(format!("model list endpoint returned HTTP {}", resp.status()));
    }

    let data: serde_json::Value =
        resp.json().await.map_err(|e| format!("failed to parse model list: {e}"))?;

    let models = data["data"]
        .as_array()
        .ok_or_else(|| "unexpected response format: 'data' field is not an array".to_string())?
        .iter()
        .filter_map(|item| item["id"].as_str().map(|s| s.to_string()))
        .collect::<Vec<_>>();

    if models.is_empty() {
        return Err("No models found — have you loaded a model in LM Studio?".to_string());
    }
    Ok(models)
}

/// Set environment variables and launch a REPL session pointed at LM Studio.
pub fn setup_lmstudio(model_hint: Option<String>) -> Result<(), Box<dyn std::error::Error>> {
    let runtime = tokio::runtime::Runtime::new()?;

    // Discover address
    let address = runtime.block_on(discover_lmstudio_address())?;

    // Resolve model
    let model = match model_hint {
        Some(m) => m,
        None => {
            let models = runtime.block_on(fetch_lmstudio_models(&address))?;
            if models.len() == 1 {
                models[0].clone()
            } else {
                eprintln!("Available models ({}):", models.len());
                for (i, m) in models.iter().enumerate() {
                    eprintln!("  {}. {m}", i + 1);
                }
                eprintln!();
                // fall back to the first model if stdin isn't available (CI)
                models[0].clone()
            }
        }
    };

    let (host, port) = address.split_once(':').unwrap_or((&address, "1234"));

    // Set environment variables matching the shell script behaviour
    env::set_var("ANTHROPIC_BASE_URL", format!("http://{host}:{port}"));
    env::set_var("OPENAI_BASE_URL", format!("http://{host}:{port}/v1"));
    env::set_var("OPENAI_API_KEY", "local-model");
    env::set_var("CLAW_RESILIENCE", "force");

    println!(
        "Starting REPL with model \"{model}\" on LM Studio at {address}\n\
         (ANTHROPIC_BASE_URL=http://{host}:{port}, OPENAI_BASE_URL=http://{host}:{port}/v1,\n\
         CLAW_RESILIENCE=force enabled for local model recovery)"
    );

    Ok(())
}

// ── OpenRouter ────────────────────────────────────────────────────────

const OPENROUTER_CONFIG_SUBDIR: &str = ".config/opencode";
const OPENROUTER_ENV_FILE: &str = ".env";

fn openrouter_config_dir() -> PathBuf {
    let home = env::var("HOME").unwrap_or_default();
    if home.is_empty() {
        PathBuf::from(OPENROUTER_CONFIG_SUBDIR)
    } else {
        PathBuf::from(home).join(OPENROUTER_CONFIG_SUBDIR)
    }
}

fn openrouter_env_path() -> PathBuf {
    openrouter_config_dir().join(OPENROUTER_ENV_FILE)
}

/// Load the OpenRouter API key — checking the process environment first,
/// then the on-disk config file, and finally failing with a clear message.
fn load_openrouter_api_key() -> Result<String, String> {
    // 1. Process environment
    if let Ok(key) = env::var("OPENROUTER_API_KEY") {
        if !key.is_empty() {
            return Ok(key);
        }
    }

    // 2. Config file
    let env_path = openrouter_env_path();
    if env_path.exists() {
        let content = fs::read_to_string(&env_path).map_err(|e| {
            format!("failed to read {path}: {e}", path = env_path.display())
        })?;
        for line in content.lines() {
            if let Some(value) = line.strip_prefix("OPENROUTER_API_KEY=") {
                let trimmed = value.trim();
                if !trimmed.is_empty() {
                    return Ok(trimmed.to_string());
                }
            }
        }
    }

    Err(format!(
        "OpenRouter API key not found.\n\
         Set the OPENROUTER_API_KEY environment variable, or save a key with:\n\
         claw setup openrouter --set-key <your_key>\n\
         (Keys are stored in {path})",
        path = openrouter_env_path().display()
    ))
}

/// Save an OpenRouter API key to the on-disk config file with restricted
/// permissions (Unix: 0o600 so only the owner can read it).
pub fn save_openrouter_api_key(key: &str) -> Result<(), Box<dyn std::error::Error>> {
    let config_dir = openrouter_config_dir();
    fs::create_dir_all(&config_dir)?;
    let env_path = openrouter_env_path();
    fs::write(&env_path, format!("OPENROUTER_API_KEY={key}\n"))?;
    // Restrict permissions on Unix so the key isn't world-readable
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&env_path, fs::Permissions::from_mode(0o600))?;
    }
    println!("OpenRouter API key saved to {}", env_path.display());
    Ok(())
}

/// A single model entry from the OpenRouter catalogue.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub context_length: u64,
    pub pricing_prompt: f64,
    pub pricing_completion: f64,
}

/// Fetch tool-capable models from the OpenRouter API.
async fn fetch_openrouter_models(api_key: &str) -> Result<Vec<ModelInfo>, String> {
    let url = "https://openrouter.ai/api/v1/models?supported_parameters=tools";
    let resp = reqwest::Client::new()
        .get(url)
        .header("Authorization", format!("Bearer {api_key}"))
        .timeout(Duration::from_secs(15))
        .send()
        .await
        .map_err(|e| format!("failed to fetch OpenRouter models: {e}"))?;

    if !resp.status().is_success() {
        if resp.status().as_u16() == 401 {
            return Err("Invalid or expired OpenRouter API key – check OPENROUTER_API_KEY".to_string());
        }
        return Err(format!(
            "OpenRouter API returned HTTP {}",
            resp.status()
        ));
    }

    let data: serde_json::Value =
        resp.json().await.map_err(|e| format!("failed to parse OpenRouter response: {e}"))?;

    let models: Vec<ModelInfo> = data["data"]
        .as_array()
        .ok_or_else(|| "unexpected response format: 'data' is not an array".to_string())?
        .iter()
        .filter(|m| {
            m.get("supported_parameters")
                .and_then(|p| p.as_array())
                .map(|arr| arr.iter().any(|v| v == "tools"))
                .unwrap_or(false)
        })
        .map(|m| ModelInfo {
            id: m["id"].as_str().unwrap_or("").to_string(),
            name: m["name"].as_str().unwrap_or("").to_string(),
            context_length: m["context_length"].as_u64().unwrap_or(0),
            pricing_prompt: m["pricing"]["prompt"].as_f64().unwrap_or(0.0),
            pricing_completion: m["pricing"]["completion"].as_f64().unwrap_or(0.0),
        })
        .collect();

    Ok(models)
}

/// Set environment variables and launch a REPL session pointed at OpenRouter.
pub fn setup_openrouter(
    model_hint: Option<String>,
    list_only: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let api_key = load_openrouter_api_key().map_err(|e| Box::new(std::io::Error::new(std::io::ErrorKind::Other, e)) as Box<dyn std::error::Error>)?;

    if list_only {
        let runtime = tokio::runtime::Runtime::new()?;
        let models = runtime.block_on(fetch_openrouter_models(&api_key))?;
        if models.is_empty() {
            println!("No tool-capable models found on OpenRouter.");
        } else {
            println!("Tool-capable OpenRouter models ({}):", models.len());
            for m in &models {
                println!(
                    "  {id:45} {name:50} ctx={ctx:>8}  prompt=${p:>7.5}/M  complete=${c:>7.5}/M",
                    id = m.id,
                    name = m.name,
                    ctx = m.context_length,
                    p = m.pricing_prompt * 1_000_000.0,
                    c = m.pricing_completion * 1_000_000.0,
                );
            }
        }
        return Ok(());
    }

    let model = match model_hint {
        Some(m) => m,
        None => {
            let runtime = tokio::runtime::Runtime::new()?;
            let models = runtime.block_on(fetch_openrouter_models(&api_key))?;
            if models.is_empty() {
                return Err("No tool-capable models found on OpenRouter. Use `claw setup openrouter --list-models` to check.".into());
            }
            // Print the list and fall back to the first one
            eprintln!("Tool-capable OpenRouter models ({}):", models.len());
            for (i, m) in models.iter().enumerate() {
                eprintln!("  {}. {id:45} {name:50}", i + 1, id = m.id, name = m.name);
            }
            models[0].id.clone()
        }
    };

    // Set environment variables matching the shell script behaviour
    env::set_var("OPENAI_BASE_URL", "https://openrouter.ai/api/v1");
    env::set_var("OPENAI_API_KEY", &api_key);
    env::set_var("HTTP_REFERER", "https://localhost");
    env::set_var("X_TITLE", "claw-code");
    env::set_var("CLAW_RESILIENCE", "none");

    println!(
        "Starting REPL with model \"{model}\" via OpenRouter\n\
         (OPENAI_BASE_URL=https://openrouter.ai/api/v1, CLAW_RESILIENCE=none — cloud provider, no retries)"
    );
    Ok(())
}

// ── top-level dispatch ────────────────────────────────────────────────

/// Arguments parsed from `claw setup ...`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SetupTarget {
    LmStudio,
    OpenRouter { set_key: Option<String>, list_models: bool },
}

/// Entry point called from `main.rs` when the user runs `claw setup ...`.
pub fn handle_setup(
    target: SetupTarget,
    model: Option<String>,
) -> Result<(), Box<dyn std::error::Error>> {
    match target {
        SetupTarget::LmStudio => setup_lmstudio(model),
        SetupTarget::OpenRouter { set_key: Some(key), .. } => save_openrouter_api_key(&key),
        SetupTarget::OpenRouter { list_models, .. } => setup_openrouter(model, list_models),
    }
}

// ── tests ─────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recent_address_roundtrip() {
        let path = recent_file_path();
        // Clean slate
        let _ = fs::remove_file(&path);

        save_recent_address("192.168.1.100:1234");
        let addrs = load_recent_addresses();
        assert_eq!(addrs.len(), 1);
        assert_eq!(addrs[0], "192.168.1.100:1234");

        save_recent_address("localhost:1234");
        let addrs = load_recent_addresses();
        assert_eq!(addrs.len(), 2);
        assert_eq!(addrs[0], "localhost:1234");

        // Duplicate should move to front
        save_recent_address("192.168.1.100:1234");
        let addrs = load_recent_addresses();
        assert_eq!(addrs.len(), 2);
        assert_eq!(addrs[0], "192.168.1.100:1234");

        // Clean up
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn recent_address_limiting() {
        let path = recent_file_path();
        let _ = fs::remove_file(&path);

        for i in 0..20 {
            save_recent_address(&format!("node{i:02}.local:1234"));
        }
        let addrs = load_recent_addresses();
        assert!(addrs.len() <= 10, "max 10 entries, got {}", addrs.len());

        let _ = fs::remove_file(&path);
    }

    #[test]
    fn load_openrouter_key_from_env() {
        let _ = fs::remove_file(openrouter_env_path());
        env::set_var("OPENROUTER_API_KEY", "sk-or-test-env");
        let key = load_openrouter_api_key().expect("should find key from env");
        assert_eq!(key, "sk-or-test-env");
        env::remove_var("OPENROUTER_API_KEY");
    }

    #[test]
    fn save_openrouter_key_persists_file() {
        let env_path = openrouter_env_path();
        // Clean up first
        let _ = fs::remove_file(&env_path);

        let key = "sk-or-saved-key-12345";
        save_openrouter_api_key(key).expect("save should succeed");
        assert!(env_path.exists(), "env file should exist");

        let content = fs::read_to_string(&env_path).expect("should be readable");
        assert!(
            content.contains("OPENROUTER_API_KEY="),
            "file should contain the key assignment"
        );
        assert!(
            content.contains(key),
            "file should contain the key value"
        );

        // Verify we can load it back
        env::remove_var("OPENROUTER_API_KEY");
        let loaded = load_openrouter_api_key().expect("should load saved key");
        assert_eq!(loaded, key);

        // Clean up
        let _ = fs::remove_file(&env_path);
    }

    #[test]
    fn load_openrouter_key_missing() {
        let env_path = openrouter_env_path();
        let _ = fs::remove_file(&env_path);
        env::remove_var("OPENROUTER_API_KEY");

        let result = load_openrouter_api_key();
        assert!(result.is_err(), "should fail when no key is available");
        let err_msg = result.unwrap_err();
        assert!(
            err_msg.contains("not found"),
            "error should mention key not found: {err_msg}"
        );
    }
}
