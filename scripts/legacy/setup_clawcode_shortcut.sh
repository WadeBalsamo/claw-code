#!/usr/bin/env bash
# setup_clawcode_shortcut.sh
set -euo pipefail

INSTALL_DIR="$HOME/bin"
TARGET="$INSTALL_DIR/clawcode"

mkdir -p "$INSTALL_DIR"

echo "Installing clawcode → $TARGET"

cat > "$TARGET" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${CLAW_CODE_ROOT:-$HOME/claw-code}"
CLI_BIN="$REPO_ROOT/rust/target/debug/claw"

DEFAULT_PROVIDER="${CLAWCODE_PROVIDER:-lmstudio}"

LM_STUDIO_HOST="${LM_STUDIO_HOST:-10.0.0.58}"
LM_STUDIO_PORT="${LM_STUDIO_PORT:-1234}"

OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"

PROVIDER="$DEFAULT_PROVIDER"
MODEL_ARG=""
CUSTOM_HOST=""
CUSTOM_PORT=""

show_help() {
cat <<EOF2
Usage:
  clawcode [--provider PROVIDER] [--model MODEL] [--host HOST] [--port PORT]

Providers:
  lmstudio
  ollama
EOF2
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

check_connection() {
    local host="$1"
    local port="$2"
    curl -fsS "http://${host}:${port}/v1/models" >/dev/null 2>&1
}

get_ram_gb() {
    if command -v free >/dev/null; then
        free -k | awk '/^Mem:/ {print int($7/1024/1024)}'
    else
        echo 0
    fi
}

get_vram_gb() {
    if command -v nvidia-smi >/dev/null; then
        local info
        info=$(nvidia-smi \
            --query-gpu=memory.total,memory.used \
            --format=csv,noheader,nounits \
            2>/dev/null | head -1)

        if [ -n "$info" ]; then
            local total used free
            total=$(echo "$info" | cut -d, -f1 | xargs)
            used=$(echo "$info" | cut -d, -f2 | xargs)
            free=$((total-used))
            echo $((free/1024))
        else
            echo 0
        fi
    else
        echo 0
    fi
}

fetch_models() {
python3 - "$1" "$2" <<'PY'
import json
import sys
import urllib.request

base=sys.argv[1].rstrip("/")
provider=sys.argv[2]

req=urllib.request.Request(
    base + "/v1/models",
    headers={"Content-Type":"application/json"}
)

with urllib.request.urlopen(req, timeout=10) as r:
    data=json.load(r)

models=[]

for m in data.get("data",[]):
    if isinstance(m,dict):
        models.append({
            "id":m.get("id","unknown"),
            "size":m.get("size",0),
            "provider":provider,
        })

print(json.dumps(models))
PY
}

while [ $# -gt 0 ]; do
    case "$1" in
        --provider)
            PROVIDER="$2"
            shift 2
            ;;
        --model)
            MODEL_ARG="$2"
            shift 2
            ;;
        --host)
            CUSTOM_HOST="$2"
            shift 2
            ;;
        --port)
            CUSTOM_PORT="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

case "$PROVIDER" in
    lmstudio)
        API_HOST="${CUSTOM_HOST:-$LM_STUDIO_HOST}"
        API_PORT="${CUSTOM_PORT:-$LM_STUDIO_PORT}"
        API_KEY="${ANTHROPIC_API_KEY:-local-model}"
        ;;
    ollama)
        API_HOST="${CUSTOM_HOST:-$OLLAMA_HOST}"
        API_PORT="${CUSTOM_PORT:-$OLLAMA_PORT}"
        API_KEY="${ANTHROPIC_API_KEY:-ollama}"
        ;;
    *)
        fail "unsupported provider: $PROVIDER"
        ;;
esac

[ -x "$CLI_BIN" ] || fail "claw binary not found at $CLI_BIN"

BASE="http://${API_HOST}:${API_PORT}"
check_connection "$API_HOST" "$API_PORT" || fail "cannot connect to $BASE"

export ANTHROPIC_BASE_URL="$BASE"
export ANTHROPIC_API_KEY="$API_KEY"
export ANTHROPIC_AUTH_TOKEN="$API_KEY"

RAM=$(get_ram_gb)
VRAM=$(get_vram_gb)

echo
echo "Provider: $PROVIDER"
echo "Endpoint: $BASE"
echo "RAM: ${RAM}GB"
echo "Free VRAM: ${VRAM}GB"
echo

MODELS_JSON=$(fetch_models "$BASE" "$PROVIDER")

if [ -z "$MODEL_ARG" ]; then
    mapfile -t IDS < <(
        python3 - <<'PY' <<<"$MODELS_JSON"
import json,sys
models=json.load(sys.stdin)
for m in models:
    print(m["id"])
PY
    )

    [ "${#IDS[@]}" -gt 0 ] || fail "no models returned"

    echo "Available models:"
    for i in "${!IDS[@]}"; do
        printf " %3d) %s\n" "$((i+1))" "${IDS[$i]}"
    done

    echo

    while true; do
        read -rp "Choose model: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           [ "$choice" -ge 1 ] &&
           [ "$choice" -le ${#IDS[@]} ]; then
            MODEL_ARG="${IDS[$((choice-1))]}"
            break
        fi
    done
fi

echo
echo "Launching claw with model=$MODEL_ARG"
echo

exec "$CLI_BIN" \
    --model "$MODEL_ARG" \
    --permission-mode danger-full-access
EOF

chmod +x "$TARGET"

PATH_EXPORT='export PATH="$HOME/bin:$PATH"'

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc" ]; then
        if ! grep -Fq "$PATH_EXPORT" "$rc"; then
            echo "" >> "$rc"
            echo "# clawcode shortcut" >> "$rc"
            echo "$PATH_EXPORT" >> "$rc"
            echo "Updated $rc"
        fi
    fi
done

export PATH="$HOME/bin:$PATH"

echo
echo "Install complete."
echo
echo "Verify:"
echo "  which clawcode"
echo "  clawcode --help"
echo
echo "If shell does not pick it up immediately:"
echo "  source ~/.bashrc"
echo "or"
echo "  source ~/.zshrc"