#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="$HOME/.config/ollamacode"
mkdir -p "$CONFIG_DIR"

CLI_BIN="${CLAW_CODE_ROOT:-$HOME/claw-code}/rust/target/debug/claw"
if [ ! -x "$CLI_BIN" ]; then
  echo "ERROR: claw binary not found at $CLI_BIN" >&2
  exit 1
fi

# Load configuration
source "$CONFIG_DIR/config"

normalize_host() {
  local h="$1"
  [[ "$h" != http://* && "$h" != https://* ]] && h="http://${h}"
  printf '%s' "${h%/}"
}

probe_host() {
  python3 - "$1" <<'PY'
import sys, json, urllib.request
url = sys.argv[1].rstrip('/') + '/api/tags'
try:
    with urllib.request.urlopen(
        urllib.request.Request(url, headers={'Content-Type':'application/json'}),
        timeout=4
    ) as r:
        data = json.load(r)
    for m in data.get('models', []):
        if isinstance(m, dict) and (name := m.get('name') or m.get('model')):
            print(name)
except Exception:
    sys.exit(1)
PY
}

get_model_ctx() {
  python3 - "$1" "$2" <<'PY'
import sys, json, urllib.request
url = sys.argv[1].rstrip('/') + '/api/show'
body = json.dumps({"name": sys.argv[2]}).encode()
req = urllib.request.Request(url, data=body, headers={'Content-Type':'application/json'})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        data = json.load(r)
    mi = data.get('model_info') or {}
    for k, v in mi.items():
        if k.endswith('.context_length') and isinstance(v, (int, float)):
            print(int(v)); exit(0)
    ctx = mi.get('context_length')
    if ctx: print(int(ctx))
except Exception:
    pass
PY
}

preload_model() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, json, urllib.request
url = sys.argv[1].rstrip('/') + '/api/generate'
body = json.dumps({
    "model": sys.argv[2],
    "prompt": "",
    "stream": False,
    "keep_alive": sys.argv[3]
}).encode()
req = urllib.request.Request(url, data=body, headers={'Content-Type':'application/json'})
with urllib.request.urlopen(req, timeout=60) as r:
    pass
PY
}

get_all_models() {
  local -a hosts_arr=()
  IFS=',' read -ra hosts_arr <<< "$OLLAMACODE_HOSTS"
  declare -A seen=()

  for raw_host in "${hosts_arr[@]}"; do
    host="$(normalize_host "$raw_host")" || continue
    [ -z "$host" ] && continue

    local models
    if ! models="$(probe_host "$host" 2>/dev/null)"; then
      continue
    fi

    while IFS= read -r model; do
      [ -z "$model" ] && continue
      if [[ -z "${seen[$model]:-}" ]]; then
        seen[$model]=1
        echo "$host|$model"
      fi
    done <<< "$models"
  done
}

select_model() {
  local -a models=()
  mapfile -t models < <(get_all_models)

  if [[ ${#models[@]} -eq 0 ]]; then
    echo "ERROR: No Ollama hosts reachable." >&2
    exit 1
  fi

  {
    echo ""
    echo "Available models (server preferred):"
    local i=1
    for entry in "${models[@]}"; do
      IFS='|' read -r host model <<< "$entry"
      printf '  %3d) %-50s [%s]\n' "$i" "$model" "$host"
      i=$((i+1))
    done
    echo ""
  } >&2

  while true; do
    read -rp "Choose number: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && \
       [ "$choice" -ge 1 ] && [ "$choice" -le "${#models[@]}" ]; then
      local idx=$((choice-1))
      IFS='|' read -r SELECTED_HOST SELECTED_MODEL <<< "${models[$idx]}"
      return 0
    fi
    echo "Invalid selection." >&2
  done
}

MODEL_ARG=""
CTX_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL_ARG="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "$OLLAMACODE_ROLE" == "server" ]]; then
  if ! probe_host "http://127.0.0.1:${OLLAMACODE_HOSTS##*:}" >/dev/null 2>&1; then
    echo "Starting local Ollama server..."
    if command -v systemctl >/dev/null 2>&1 && sudo systemctl is-active --quiet ollama 2>/dev/null; then
      sudo systemctl start ollama || true
    elif command -v ollama >/dev/null 2>&1; then
      OLLAMA_HOST="${OLLAMACODE_HOSTS%%,*}" nohup ollama serve >/tmp/ollama.log 2>&1 &
    fi
    sleep 3
  fi
fi

if [[ -z "${MODEL_ARG:-}" ]]; then
  select_model || exit 1
else
  found=0
  while IFS='|' read -r host model; do
    if [[ "$model" == "$MODEL_ARG" ]]; then
      SELECTED_HOST="$host"
      SELECTED_MODEL="$MODEL_ARG"
      found=1
      break
    fi
  done < <(get_all_models)
  
  if [[ $found -eq 0 ]]; then
    echo "Model '$MODEL_ARG' not found on any configured host." >&2
    exit 1
  fi
fi

MODEL_CTX="$(get_model_ctx "$SELECTED_HOST" "$SELECTED_MODEL")"
DEFAULT_CTX="${CTX_OVERRIDE:-${MODEL_CTX:-131072}}"

read -rp "Context window [${DEFAULT_CTX}]: " ctx_in
NUM_CTX="${ctx_in:-$DEFAULT_CTX}"

echo "Preloading model into memory..."
preload_model "$SELECTED_HOST" "$SELECTED_MODEL" "$OLLAMACODE_KEEP_ALIVE"

export OPENAI_BASE_URL="${SELECTED_HOST%/}/v1"
export OPENAI_API_KEY="ollama"

echo ""
echo "Launching claw..."
printf '  model      : %s\n' "$SELECTED_MODEL"
printf '  base_url   : %s/v1\n' "$SELECTED_HOST"
printf '  num_ctx    : %d\n' "$NUM_CTX"
printf '  permission : %s\n' "$OLLAMACODE_PERMISSION_MODE"

exec "$CLI_BIN" \
  --model "$SELECTED_MODEL" \
  --permission-mode "$OLLAMACODE_PERMISSION_MODE"
