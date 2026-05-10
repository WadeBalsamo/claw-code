#!/usr/bin/env bash
# setup_lmcode.sh
# Sets up the lmcode shortcut command for easy LM Studio integration
# with robust automatic fallback to recent / local addresses.

set -euo pipefail

echo "Setting up lmcode shortcut..."

# Create ~/bin directory if it doesn't exist
mkdir -p "$HOME/bin"

# Create the lmcode script
cat > "$HOME/bin/lmcode" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${CLAW_CODE_ROOT:-$HOME/claw-code}"
CLI_BIN="$REPO_ROOT/rust/target/debug/claw"
LM_STUDIO_HOST="${LM_STUDIO_HOST:-10.0.0.58}"
LM_STUDIO_PORT="${LM_STUDIO_PORT:-1234}"
RECENT_FILE="${LM_STUDIO_RECENT_FILE:-$HOME/.lmstudio_recent_ips}"

export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-local-model}"

# ----------------------------------------------------------------------
# helper functions
# ----------------------------------------------------------------------

# fetch_models <base_url>
# On success, prints model IDs one per line to stdout and returns 0.
# On failure, returns non-zero.
fetch_models() {
  python3 - "$1" <<'PY' 2>/dev/null
import sys, json, urllib.request

# Disable proxy handling to avoid "No route to host" errors
# caused by system-wide proxy settings.
proxy_handler = urllib.request.ProxyHandler({})
opener = urllib.request.build_opener(proxy_handler)

url = sys.argv[1].rstrip('/') + '/v1/models'
req = urllib.request.Request(url, headers={'Content-Type': 'application/json'})
try:
    with opener.open(req, timeout=10) as resp:
        data = json.load(resp)
except Exception as e:
    print(f"Connection error: {e}", file=sys.stderr)
    sys.exit(1)

models = [item.get('id') for item in data.get('data', []) if isinstance(item, dict) and 'id' in item]
print('\n'.join(models))
PY
}

# test_host_port "host:port"
# Returns 0 if /v1/models can be fetched, non-zero otherwise.
test_host_port() {
  local input="$1"
  local host port
  IFS=':' read -r host port <<< "$input"
  port="${port:-1234}"
  fetch_models "http://${host}:${port}" >/dev/null 2>&1
}

# normalize_address <input>  -> prints "host:port"
# Accepts "host:port" or "http://host:port/path"
normalize_address() {
  local input="$1"
  local host port
  # Strip http:// or https:// prefix if present
  input="${input#http://}"
  input="${input#https://}"
  # Remove any trailing path
  input="${input%%/*}"
  # Split on ':'
  IFS=':' read -r host port <<< "$input"
  port="${port:-1234}"
  echo "${host}:${port}"
}

# add_to_recent "host:port"
add_to_recent() {
  local addr="$1"
  # Avoid duplicate consecutive entries
  if [ ! -f "$RECENT_FILE" ] || ! grep -qxF "$addr" "$RECENT_FILE" 2>/dev/null; then
    echo "$addr" >> "$RECENT_FILE"
  fi
}

# ----------------------------------------------------------------------
# automatic silent probing of candidate addresses
# ----------------------------------------------------------------------
auto_probe_addresses() {
  # 1. Recent addresses (most recent first)
  if [ -f "$RECENT_FILE" ] && [ -s "$RECENT_FILE" ]; then
    while IFS= read -r addr; do
      [ -z "$addr" ] && continue
      if test_host_port "$addr"; then
        echo "$addr"
        return 0
      fi
    done < <(tac "$RECENT_FILE" | awk '!seen[$0]++')
  fi

  # 2. localhost / 127.0.0.1 with the configured port
  for candidate in "127.0.0.1:${LM_STUDIO_PORT}" "localhost:${LM_STUDIO_PORT}"; do
    if test_host_port "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

# ----------------------------------------------------------------------
# interactive fallback (only used if auto-probe fails)
# ----------------------------------------------------------------------
interactive_select() {
  local options=()
  if [ -f "$RECENT_FILE" ] && [ -s "$RECENT_FILE" ]; then
    mapfile -t options < <(tac "$RECENT_FILE" | awk '!seen[$0]++')
  fi

  while true; do
    echo "Select an option:"
    if [ ${#options[@]} -gt 0 ]; then
      echo "Recent addresses:"
      for idx in "${!options[@]}"; do
        printf "  %3d) %s\n" "$((idx+1))" "${options[$idx]}"
      done
      echo "  n) Enter a new address"
      echo "  q) Quit"
    else
      echo "No recent addresses on file."
      echo "Enter a new address (host:port, default port 1234) or 'q' to quit:"
      read -rp "> " user_input
      if [ "$user_input" = "q" ]; then
        return 1
      fi
      addr=$(normalize_address "$user_input")
      if test_host_port "$addr"; then
        add_to_recent "$addr"
        echo "$addr"
        return 0
      else
        echo "Failed to connect to $addr. Try again." >&2
        continue
      fi
    fi

    read -rp "Choice: " choice
    case "$choice" in
      q|Q) return 1 ;;
      n|N)
        read -rp "Enter host:port (default port 1234): " user_input
        addr=$(normalize_address "$user_input")
        if test_host_port "$addr"; then
          add_to_recent "$addr"
          echo "$addr"
          return 0
        else
          echo "Connection failed. Try again." >&2
          continue
        fi
        ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#options[@]} ]; then
          selected="${options[$((choice-1))]}"
          if test_host_port "$selected"; then
            echo "$selected"
            return 0
          else
            echo "Connection failed for $selected. Removing from recent." >&2
            tmpfile=$(mktemp)
            grep -vxF "$selected" "$RECENT_FILE" > "$tmpfile" || true
            mv "$tmpfile" "$RECENT_FILE"
            unset options
            if [ -f "$RECENT_FILE" ] && [ -s "$RECENT_FILE" ]; then
              mapfile -t options < <(tac "$RECENT_FILE" | awk '!seen[$0]++')
            else
              options=()
            fi
            continue
          fi
        else
          echo "Invalid choice." >&2
          continue
        fi
        ;;
    esac
  done
}

# ----------------------------------------------------------------------
# argument parsing
# ----------------------------------------------------------------------
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
Usage: lmcode [--host HOST] [--port PORT] [--model MODEL]

Runs claw-code from the current directory using LM Studio.
If --model is not given, this command will list available LM Studio models
and prompt you to choose one.
The shell session will use full write permissions.

If the initial LM Studio server cannot be reached, the script will silently
probe previously used addresses, then common localhost addresses (127.0.0.1
and localhost) before asking you to choose or enter a new address.

Examples:
  lmcode
  lmcode --model qwen/qwen3-coder-next
  lmcode --host 10.0.0.58 --port 1234
HELP_EOF
      exit 0
      ;;
    *)
      echo "Error: unknown option $1" >&2
      exit 1
      ;;
  esac
done

# ----------------------------------------------------------------------
# prerequisites
# ----------------------------------------------------------------------
if [ ! -x "$CLI_BIN" ]; then
  echo "Error: claw binary not found at $CLI_BIN" >&2
  echo "Build it first with: cd $REPO_ROOT/rust && cargo build --workspace" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required to parse LM Studio model list." >&2
  exit 1
fi

# ----------------------------------------------------------------------
# main logic: obtain a working address (with automatic fallback)
# ----------------------------------------------------------------------
CURRENT_ADDR="${LM_STUDIO_HOST}:${LM_STUDIO_PORT}"

# 1) Try the configured default
if ! test_host_port "$CURRENT_ADDR"; then
  echo "Default address $CURRENT_ADDR is unreachable." >&2
  echo "Trying previously used and common local addresses..." >&2

  # 2) Auto-probe (recent + localhost)
  if found_addr=$(auto_probe_addresses); then
    echo "Connected to $found_addr" >&2
    IFS=':' read -r LM_STUDIO_HOST LM_STUDIO_PORT <<< "$found_addr"
    LM_STUDIO_PORT="${LM_STUDIO_PORT:-1234}"
    add_to_recent "$found_addr"
  else
    echo "No automatic fallback succeeded." >&2
    echo "Launching interactive address selection..." >&2
    if new_addr=$(interactive_select); then
      IFS=':' read -r LM_STUDIO_HOST LM_STUDIO_PORT <<< "$new_addr"
      LM_STUDIO_PORT="${LM_STUDIO_PORT:-1234}"
    else
      echo "No valid LM Studio address provided. Exiting." >&2
      exit 1
    fi
  fi
else
  # Default worked; ensure it's in recent file
  add_to_recent "$CURRENT_ADDR"
fi

export ANTHROPIC_BASE_URL="http://${LM_STUDIO_HOST}:${LM_STUDIO_PORT}"
# Also set OPENAI_BASE_URL so the client routes to OpenAI-compatible provider
# which has resilience features (auto-recovery from model unloads, empty streams, etc.)
export OPENAI_BASE_URL="http://${LM_STUDIO_HOST}:${LM_STUDIO_PORT}/v1"
# Use a placeholder API key for local models (LM Studio doesn't require real auth)
export OPENAI_API_KEY="${OPENAI_API_KEY:-local-model}"

# ----------------------------------------------------------------------
# obtain models list
# ----------------------------------------------------------------------
MODEL_LIST_JSON=""
if MODEL_LIST_JSON=$(fetch_models "$ANTHROPIC_BASE_URL"); then
  IFS=$'\n' read -r -d '' -a MODELS < <(printf '%s\0' "$MODEL_LIST_JSON")
  if [ ${#MODELS[@]} -eq 0 ]; then
    echo "Error: no models returned by LM Studio at ${ANTHROPIC_BASE_URL}/v1/models" >&2
    exit 1
  fi

  if [ -z "$MODEL_ARG" ]; then
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
else
  echo "Error: could not fetch model list from $ANTHROPIC_BASE_URL" >&2
  exit 1
fi

if [ -z "$MODEL_ARG" ]; then
  echo "Error: model selection failed." >&2
  exit 1
fi

echo "Launching claw in $(pwd) with model $MODEL_ARG and full write permissions..."
# Force enable resilience for local LM Studio
export CLAW_RESILIENCE=force
exec "$CLI_BIN" --model "$MODEL_ARG" --permission-mode danger-full-access
EOF

# Make it executable
chmod +x "$HOME/bin/lmcode"

# Check if ~/bin is in PATH
if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
  echo ""
  echo "Note: Add ~/bin to your PATH by adding this to your ~/.bashrc or ~/.zshrc:"
  echo "  export PATH=\"\$HOME/bin:\$PATH\""
  echo ""
  echo "Or run this command in your current session:"
  echo "  export PATH=\"\$HOME/bin:\$PATH\""
fi

echo "Setup complete! You can now run 'lmcode' from any directory."
echo ""
echo "Usage:"
echo "  lmcode                    # Interactive model selection"
echo "  lmcode --model MODEL      # Use specific model"
echo "  lmcode --host HOST --port PORT  # Custom LM Studio server"
echo ""
echo "If the LM Studio server cannot be reached, the script will silently"
echo "probe recent addresses and common local addresses before asking you."