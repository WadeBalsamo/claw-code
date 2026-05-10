#!/usr/bin/env bash
# setup_clawcode_shortcut.sh
# Sets up the clawcode shortcut command for easy LM Studio integration

set -euo pipefail

echo "Setting up clawcode shortcut..."

# Create ~/bin directory if it doesn't exist
mkdir -p "$HOME/bin"

# Create the clawcode script
cat > "$HOME/bin/clawcode" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${CLAW_CODE_ROOT:-$HOME/claw-code}"
CLI_BIN="$REPO_ROOT/rust/target/debug/claw"
LM_STUDIO_HOST="${LM_STUDIO_HOST:-10.0.0.58}"
LM_STUDIO_PORT="${LM_STUDIO_PORT:-1234}"

export ANTHROPIC_BASE_URL="http://${LM_STUDIO_HOST}:${LM_STUDIO_PORT}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-local-model}"

if [ ! -x "$CLI_BIN" ]; then
  echo "Error: claw binary not found at $CLI_BIN" >&2
  echo "Build it first with: cd $REPO_ROOT/rust && cargo build --workspace" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required to parse LM Studio model list." >&2
  exit 1
fi

MODEL_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      if [ $# -lt 2 ]; then
        echo "Error: --model requires a value" >&2
        exit 1
      fi
      MODEL_ARG="$2"
      shift 2
      ;;
    --host)
      if [ $# -lt 2 ]; then
        echo "Error: --host requires a value" >&2
        exit 1
      fi
      LM_STUDIO_HOST="$2"
      shift 2
      ;;
    --port)
      if [ $# -lt 2 ]; then
        echo "Error: --port requires a value" >&2
        exit 1
      fi
      LM_STUDIO_PORT="$2"
      shift 2
      ;;
    --help|-h)
      cat <<'HELP_EOF'
Usage: clawcode [--host HOST] [--port PORT] [--model MODEL]

Runs claw-code from the current directory using LM Studio.
If --model is not given, this command will list available LM Studio models and prompt you to choose one.
The shell session will use full write permissions.

Examples:
  clawcode
  clawcode --model qwen/qwen3-coder-next
  clawcode --host 10.0.0.58 --port 1234
HELP_EOF
      exit 0
      ;;
    *)
      echo "Error: unknown option $1" >&2
      exit 1
      ;;
  esac
done

export ANTHROPIC_BASE_URL="http://${LM_STUDIO_HOST}:${LM_STUDIO_PORT}"

if [ -z "$MODEL_ARG" ]; then
  if ! MODEL_LIST_JSON=$(python3 - "$ANTHROPIC_BASE_URL" <<'PY'
import sys, json, urllib.request
url = sys.argv[1].rstrip('/') + '/v1/models'
req = urllib.request.Request(url, headers={'Content-Type': 'application/json'})
with urllib.request.urlopen(req, timeout=10) as resp:
    data = json.load(resp)
models = [item.get('id') for item in data.get('data', []) if isinstance(item, dict) and 'id' in item]
print('\n'.join(models))
PY
  ); then
    echo "Error: failed to fetch models from ${ANTHROPIC_BASE_URL}/v1/models" >&2
    exit 1
  fi

  IFS=$'\n' read -r -d '' -a MODELS < <(printf '%s\0' "$MODEL_LIST_JSON")
  if [ ${#MODELS[@]} -eq 0 ]; then
    echo "Error: no models returned by LM Studio at ${ANTHROPIC_BASE_URL}/v1/models" >&2
    exit 1
  fi

  if [ ${#MODELS[@]} -eq 1 ]; then
    MODEL_ARG="${MODELS[0]}"
    echo "Using model: $MODEL_ARG"
  else
    echo "Available LM Studio models:"
    for idx in "${!MODELS[@]}"; do
      printf '  %3d) %s\n' "$((idx+1))" "${MODELS[$idx]}"
    done
    while true; do
      read -rp "Choose a model number (1-${#MODELS[@]}): " choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#MODELS[@]} ]; then
        MODEL_ARG="${MODELS[$((choice-1))]}"
        break
      fi
      echo "Invalid selection."
    done
  fi
fi

if [ -z "$MODEL_ARG" ]; then
  echo "Error: model selection failed." >&2
  exit 1
fi

echo "Launching claw in $(pwd) with model $MODEL_ARG and full write permissions..."
exec "$CLI_BIN" --model "$MODEL_ARG" --permission-mode danger-full-access
EOF

# Make it executable
chmod +x "$HOME/bin/clawcode"

# Check if ~/bin is in PATH
if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
  echo ""
  echo "Note: Add ~/bin to your PATH by adding this to your ~/.bashrc or ~/.zshrc:"
  echo "  export PATH=\"\$HOME/bin:\$PATH\""
  echo ""
  echo "Or run this command in your current session:"
  echo "  export PATH=\"\$HOME/bin:\$PATH\""
fi

echo "Setup complete! You can now run 'clawcode' from any directory."
echo ""
echo "Usage:"
echo "  clawcode                    # Interactive model selection"
echo "  clawcode --model MODEL      # Use specific model"
echo "  clawcode --host HOST --port PORT  # Custom LM Studio server"