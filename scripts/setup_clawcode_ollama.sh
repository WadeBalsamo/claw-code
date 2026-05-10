#!/usr/bin/env bash
# Setup_clawcode_ollama.sh
# Installs claw-code dependencies, installs/configures Ollama, pulls nemotron-3-super,
# and updates the clawcode shortcut to support both LM Studio and Ollama.

set -euo pipefail

echo "==> Starting clawcode + Ollama setup"

REPO_ROOT="${CLAW_CODE_ROOT:-$(pwd)}"
if [ ! -d "$REPO_ROOT" ]; then
  echo "Error: repo root not found: $REPO_ROOT" >&2
  exit 1
fi

cd "$REPO_ROOT"

echo "==> Repo root: $REPO_ROOT"

# --- Helpers ---
have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_python() {
  if have_cmd python3; then
    echo "python3"
  elif have_cmd python; then
    echo "python"
  else
    echo ""
  fi
}

PYTHON_BIN="$(detect_python)"
if [ -z "$PYTHON_BIN" ]; then
  echo "Error: Python is required but was not found." >&2
  exit 1
fi

echo "==> Using Python: $PYTHON_BIN"

# --- Python deps ---
if [ -f "requirements.txt" ]; then
  echo "==> Installing Python requirements.txt"
  "$PYTHON_BIN" -m pip install --upgrade pip setuptools wheel
  "$PYTHON_BIN" -m pip install -r requirements.txt
else
  echo "==> No requirements.txt found at repo root, skipping Python dependency install"
fi

if [ -f "pyproject.toml" ]; then
  echo "==> Detected pyproject.toml"
  "$PYTHON_BIN" -m pip install --upgrade pip setuptools wheel
  if grep -qE '^\[build-system\]|^\[project\]' pyproject.toml; then
    echo "==> Installing repo in editable mode"
    "$PYTHON_BIN" -m pip install -e .
  fi
fi

# --- JS deps if present ---
if [ -f "package.json" ]; then
  if have_cmd npm; then
    echo "==> Installing npm dependencies"
    npm install
  else
    echo "==> package.json found but npm is missing, skipping JS dependency install"
  fi
fi

# --- Rust build if present ---
if [ -d "rust" ]; then
  if have_cmd cargo; then
    echo "==> Building claw Rust workspace"
    (
      cd rust
      cargo build --workspace
    )
  else
    echo "Warning: cargo not found; cannot build rust/ workspace" >&2
  fi
fi

# --- Install Ollama ---
if have_cmd ollama; then
  echo "==> Ollama already installed: $(ollama -v || true)"
else
  echo "==> Installing Ollama"
  curl -fsSL https://ollama.com/install.sh | sh
fi

if ! have_cmd systemctl; then
  echo "Warning: systemctl not found. Will try to run Ollama manually." >&2
else
  echo "==> Configuring Ollama systemd override for local API binding"
  sudo mkdir -p /etc/systemd/system/ollama.service.d

  sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<'EOF'
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable ollama || true
  sudo systemctl restart ollama || sudo systemctl start ollama
fi

# Fallback if systemd service is unavailable
if ! curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "==> Ollama API not responding yet; attempting user-space launch"
  nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
  sleep 5
fi

echo "==> Verifying Ollama API"
if ! curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "Error: Ollama API is not reachable at http://127.0.0.1:11434" >&2
  echo "Check with: journalctl -u ollama -e --no-pager" >&2
  exit 1
fi

# --- Pull model ---
echo "==> Pulling nemotron-3-nano from Ollama"
ollama pull nemotron-3-nano

echo "==> Installed Ollama models:"
ollama list || true

# --- Install/update launcher shortcut ---
SHORTCUT_SCRIPT="$REPO_ROOT/setup_clawcode_shortcut.sh"
if [ -f "$SHORTCUT_SCRIPT" ]; then
  echo "==> Running shortcut setup script"
  bash "$SHORTCUT_SCRIPT"
else
  echo "Warning: $SHORTCUT_SCRIPT not found; create/update it first." >&2
fi

echo ""
echo "==> Setup complete"
echo "Examples:"
echo "  clawcode --provider ollama"
echo "  clawcode --provider ollama --model nemotron-3-nano"
echo "  clawcode --provider lmstudio"
echo "  clawcode --provider lmstudio --model your-loaded-model"