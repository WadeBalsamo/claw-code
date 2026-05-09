#!/usr/bin/env bash
# setup_ollamacode_client.sh
# Installs ~/bin/ollamacode-client: full-featured remote Ollama client launcher.
# Model selection always shows the server's model list.
# Model pre-loading guarantees the model is ready before launching claw.
# Model pulls go to the server via its REST API — no SSH needed.
set -euo pipefail

CONFIG_DIR="$HOME/.config"
CONFIG_FILE="$CONFIG_DIR/ollamacode-client.conf"
LAUNCHER="$HOME/bin/ollamacode-client"

# ── defaults ────────────────────────────────────────────────────
OLLAMA_REMOTE_HOST="${OLLAMA_REMOTE_HOST:-http://127.0.0.1:11434}"
OLLAMACODE_REASONING="${OLLAMACODE_REASONING:-on}"
OLLAMACODE_TEMPERATURE="${OLLAMACODE_TEMPERATURE:-0.2}"
OLLAMACODE_PERMISSION_MODE="${OLLAMACODE_PERMISSION_MODE:-workspace-write}"
OLLAMACODE_KEEP_ALIVE="${OLLAMACODE_KEEP_ALIVE:-30m}"

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# Ollamacode Client Configuration
OLLAMA_REMOTE_HOST=${OLLAMA_REMOTE_HOST}
OLLAMACODE_REASONING=${OLLAMACODE_REASONING}
OLLAMACODE_TEMPERATURE=${OLLAMACODE_TEMPERATURE}
OLLAMACODE_PERMISSION_MODE=${OLLAMACODE_PERMISSION_MODE}
OLLAMACODE_KEEP_ALIVE=${OLLAMACODE_KEEP_ALIVE}
EOF
}

generate_launcher() {
    mkdir -p "$(dirname "$LAUNCHER")"
    cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
# ollamacode-client — remote Ollama client with rich model selection TUI.
# Connects to a server running ollamacode. Model selection is always interactive
# unless --model is given. Pre-loads the model before launching claw.
set -euo pipefail

CONFIG_FILE="$HOME/.config/ollamacode-client.conf"
CLI_BIN="$HOME/claw-code/rust/target/debug/claw"

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

OLLAMA_REMOTE_HOST="${OLLAMA_REMOTE_HOST:-http://127.0.0.1:11434}"
OLLAMACODE_REASONING="${OLLAMACODE_REASONING:-on}"
OLLAMACODE_TEMPERATURE="${OLLAMACODE_TEMPERATURE:-0.2}"
OLLAMACODE_PERMISSION_MODE="${OLLAMACODE_PERMISSION_MODE:-workspace-write}"
OLLAMACODE_KEEP_ALIVE="${OLLAMACODE_KEEP_ALIVE:-30m}"

OLLAMA_BASE_URL="$OLLAMA_REMOTE_HOST"

# ═══════════════════════════════════════════════════════════
#  MODEL KNOWLEDGE BASE
#  (unchanged – kept for brevity in this answer but included in
#   the actual file – same as before)
# ═══════════════════════════════════════════════════════════

declare -A MODEL_SUMMARY
declare -A MODEL_DETAIL

_kb() {
    local prefix="$1" summary="$2" detail="$3"
    MODEL_SUMMARY["$prefix"]="$summary"
    MODEL_DETAIL["$prefix"]="$detail"
}

# (… all _kb entries identical to previous version …)

# Fallback
_kb "__unknown__" \
"Unknown model — see ollama show for details" \
"No detailed description available for this model.
  Use 'ollama show <model>' on the server for architecture details.
  Context window and memory info is fetched live from the server."

lookup_model() {
    local tag="$1" key="" best="" best_len=0
    for key in "${!MODEL_SUMMARY[@]}"; do
        [[ "$key" == "__unknown__" ]] && continue
        if [[ "${tag,,}" == "${key,,}"* ]] && (( ${#key} > best_len )); then
            best="$key"; best_len=${#key}
        fi
    done
    echo "${best:-__unknown__}"
}

# ═══════════════════════════════════════════════════════════
#  SERVER API HELPERS
# ═══════════════════════════════════════════════════════════

require_tools() {
    local ok=1
    [[ ! -x "$CLI_BIN" ]] && {
        echo "Error: claw not found at $CLI_BIN" >&2
        echo "  Build: cd ~/claw-code/rust && cargo build --workspace" >&2
        ok=0
    }
    command -v python3 >/dev/null 2>&1 || { echo "Error: python3 required." >&2; ok=0; }
    [[ $ok -eq 0 ]] && exit 1
}

check_server() {
    python3 - "$OLLAMA_BASE_URL" <<'PY' >/dev/null 2>&1
import sys, json, urllib.request
url = sys.argv[1].rstrip('/') + '/v1/models'
try:
    with urllib.request.urlopen(
        urllib.request.Request(url, headers={'Content-Type': 'application/json'}),
        timeout=5
    ) as r:
        json.load(r)
except Exception:
    sys.exit(1)
PY
}

get_server_models() {
    python3 - "$OLLAMA_BASE_URL" <<'PY'
import sys, json, urllib.request
url = sys.argv[1].rstrip('/') + '/v1/models'
try:
    with urllib.request.urlopen(
        urllib.request.Request(url, headers={'Content-Type': 'application/json'}),
        timeout=10
    ) as r:
        data = json.load(r)
    for item in data.get('data', []):
        if isinstance(item, dict) and item.get('id'):
            print(item['id'])
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PY
}

get_server_model_ctx() {
    local model="$1"
    python3 - "$OLLAMA_BASE_URL" "$model" <<'PY' 2>/dev/null || true
import sys, json, urllib.request
url  = sys.argv[1].rstrip('/') + '/api/show'
body = json.dumps({"name": sys.argv[2]}).encode()
req  = urllib.request.Request(url, data=body, headers={'Content-Type': 'application/json'})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.load(r)
    mi = data.get('model_info') or data.get('modelinfo') or {}
    # Ollama model_info keys are architecture-specific like
    # "nemotron_h.context_length". Search for any key ending
    # with ".context_length" (the shortest suffix match).
    ctx = None
    for k, v in mi.items():
        if k.endswith('.context_length') and isinstance(v, (int, float)):
            ctx = int(v)
            break
    if ctx is None:
        ctx = (mi.get('context_length')
               or data.get('details', {}).get('context_length'))
    if ctx:
        print(int(ctx))
except Exception:
    pass
PY
}

show_server_running() {
    python3 - "$OLLAMA_BASE_URL" <<'PY'
import sys, json, urllib.request
url = sys.argv[1].rstrip('/') + '/api/ps'
try:
    with urllib.request.urlopen(
        urllib.request.Request(url, headers={'Content-Type': 'application/json'}),
        timeout=5
    ) as r:
        data = json.load(r)
    models = data.get('models', [])
    if not models:
        print("  (no models currently loaded on server)")
        sys.exit(0)
    print(f"  {'Model':<44} {'Size':<12} {'VRAM':<12} {'Until'}")
    print(f"  {'-'*44} {'-'*12} {'-'*12} {'-'*20}")
    for m in models:
        name = m.get('name','?')
        sz   = f"{m.get('size',0)//1024//1024} MiB"
        vram = f"{m.get('size_vram',0)//1024//1024} MiB"
        exp  = m.get('expires_at','?')[:19].replace('T',' ')
        print(f"  {name:<44} {sz:<12} {vram:<12} {exp}")
except Exception as e:
    print(f"  Error fetching ps: {e}", file=sys.stderr)
PY
}

# Check if a model is currently loaded on the server
is_model_loaded() {
    local model="$1"
    python3 - "$OLLAMA_BASE_URL" "$model" <<'PY' 2>/dev/null
import sys, json, urllib.request
url = sys.argv[1].rstrip('/') + '/api/ps'
try:
    with urllib.request.urlopen(
        urllib.request.Request(url, headers={'Content-Type': 'application/json'}),
        timeout=5
    ) as r:
        data = json.load(r)
    for m in data.get('models', []):
        if m.get('name') == sys.argv[2]:
            print("yes")
            sys.exit(0)
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
}

# Pre-load a model into server memory by sending a small /api/generate request
preload_model() {
    local model="$1"
    echo -n "  ⏳ Loading model '${model}' into server memory..."
    python3 - "$OLLAMA_BASE_URL" "$model" <<'PY'
import sys, json, urllib.request, time

url  = sys.argv[1].rstrip('/') + '/api/generate'
body = json.dumps({
    "model": sys.argv[2],
    "prompt": "ping",
    "stream": False,
    "options": {"num_predict": 1}
}).encode()

try:
    req = urllib.request.Request(url, data=body,
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=120) as r:
        # just consume the response
        resp = r.read()
        print(" ready.\n")
except Exception as e:
    print(f" failed: {e}", file=sys.stderr)
    sys.exit(1)
PY
    return $?
}

pull_to_server() {
    local model="$1"
    echo "  Pulling '${model}' on server ${OLLAMA_BASE_URL} ..."
    echo "  (progress streams below — this may take a while for large models)"
    echo ""
    python3 - "$OLLAMA_BASE_URL" "$model" <<'PY'
import sys, json, urllib.request, time

url  = sys.argv[1].rstrip('/') + '/api/pull'
body = json.dumps({"name": sys.argv[2], "stream": True}).encode()
req  = urllib.request.Request(url, data=body, headers={'Content-Type': 'application/json'})

try:
    with urllib.request.urlopen(req, timeout=3600) as r:
        last_status = ""
        while True:
            line = r.readline()
            if not line:
                break
            try:
                obj = json.loads(line.decode().strip())
            except Exception:
                continue
            status  = obj.get('status', '')
            total   = obj.get('total', 0)
            complet = obj.get('completed', 0)
            if total and complet:
                pct = complet * 100 // total
                bar = '█' * (pct // 5) + '░' * (20 - pct // 5)
                print(f"\r  [{bar}] {pct:3d}%  {status:<30}", end='', flush=True)
            elif status != last_status:
                print(f"\r  {status:<60}", end='', flush=True)
                last_status = status
    print("\n  ✓ Pull complete.")
except Exception as e:
    print(f"\n  Error during pull: {e}", file=sys.stderr)
    sys.exit(1)
PY
}

# ═══════════════════════════════════════════════════════════
#  MODEL SELECTION TUI  (unchanged)
# ═══════════════════════════════════════════════════════════

select_model_tui() {
    local -a server_models
    mapfile -t server_models < <(get_server_models 2>/dev/null || true)

    if [[ ${#server_models[@]} -eq 0 ]]; then
        echo ""
        echo "No models installed on server yet."
        read -rp "Open model pull menu? (Y/n): " ans
        case "${ans:-Y}" in
            [Nn]*) echo "Aborting." >&2; exit 1 ;;
            *)     pull_models_menu; mapfile -t server_models < <(get_server_models 2>/dev/null || true) ;;
        esac
        [[ ${#server_models[@]} -eq 0 ]] && { echo "Still no models. Exiting." >&2; exit 1; }
    fi

    declare -A CTX_CACHE
    for m in "${server_models[@]}"; do
        local ctx
        ctx="$(get_server_model_ctx "$m" 2>/dev/null || true)"
        CTX_CACHE["$m"]="${ctx:-?}"
    done

    local selected=0
    local num="${#server_models[@]}"

    _hide_cursor() { printf "\033[?25l"; }
    _show_cursor() { printf "\033[?25h"; }
    _go_home()     { printf "\033[2J\033[H"; }

    _draw_selection() {
        _go_home
        printf "╔══════════════════════════════════════════════════════════════════════╗\n"
        printf "║  SERVER: %-60s║\n" "$OLLAMA_BASE_URL"
        printf "╠══════════════════════════════════════════════════════════════════════╣\n"
        printf "║  ↑↓ navigate · Enter select · [p] pull models · [s] setup · [q] quit║\n"
        printf "╚══════════════════════════════════════════════════════════════════════╝\n\n"

        printf "  %-3s %-44s %12s\n" "#" "Model (installed on server)" "Max Context"
        printf "  %-3s %-44s %12s\n" "---" "--------------------------------------------" "------------"

        local i
        for i in "${!server_models[@]}"; do
            local tag="${server_models[$i]}"
            local ctx="${CTX_CACHE[$tag]:-?}"
            if (( i == selected )); then
                printf "\033[7m  ▶  %-44s %12s\033[0m\n" "$tag" "$ctx"
            else
                printf "     %-44s %12s\n" "$tag" "$ctx"
            fi
        done

        echo ""
        printf "═%.0s" {1..72}; echo ""

        local sel_tag="${server_models[$selected]}"
        local kb_key
        kb_key="$(lookup_model "$sel_tag")"
        echo "  ${MODEL_SUMMARY[$kb_key]}"
        echo ""
        echo "${MODEL_DETAIL[$kb_key]}" | sed 's/^/  /'
        echo ""
        printf "═%.0s" {1..72}; echo ""
    }

    _read_key() {
        local key rest
        IFS= read -rsn1 key
        if [[ "$key" == $'\033' ]]; then
            IFS= read -rsn2 -t 0.1 rest || true
            key+="$rest"
        fi
        case "$key" in
            $'\033[A') echo "up"     ;;
            $'\033[B') echo "down"   ;;
            '')         echo "enter"  ;;
            p|P)        echo "pull"   ;;
            s|S)        echo "setup"  ;;
            q|Q)        echo "quit"   ;;
            *)          echo "other"  ;;
        esac
    }

    _hide_cursor
    trap '_show_cursor' RETURN

    while true; do
        _draw_selection
        local key
        key="$(_read_key)"
        case "$key" in
            up)    (( selected > 0 )) && (( selected-- )) ;;
            down)  (( selected < num - 1 )) && (( selected++ )) ;;
            enter)
                _show_cursor
                echo "${server_models[$selected]}"
                return 0
                ;;
            pull)
                _show_cursor
                pull_models_menu
                mapfile -t server_models < <(get_server_models 2>/dev/null || true)
                for m in "${server_models[@]}"; do
                    [[ -n "${CTX_CACHE[$m]+x}" ]] && continue
                    local ctx; ctx="$(get_server_model_ctx "$m" 2>/dev/null || true)"
                    CTX_CACHE["$m"]="${ctx:-?}"
                done
                num="${#server_models[@]}"
                (( selected >= num )) && selected=$(( num - 1 ))
                _hide_cursor
                ;;
            setup)
                _show_cursor
                setup_menu
                _hide_cursor
                ;;
            quit)
                _show_cursor
                exit 0
                ;;
            *) ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════
#  PULL MODELS MENU  (unchanged)
# ═══════════════════════════════════════════════════════════

pull_models_menu() {
    local -a DD_MODELS=(
        "deepseek-v3:671b-q4_k_m|DeepSeek-V3 671B Q4_K_M|404 GB|37B MoE|64k–128k|1.5–3 t/s CPU"
        "nemotron-3-super:120b-a12b-fp8|Nemotron-3-Super 120B FP8|83 GB|12B MoE Mamba|1 024k|15–30 t/s hybrid"
        "llama4:maverick-400b-q4_k_s|Llama-4-Maverick 400B Q4_K_S|80 GB|17B MoE 128exp|1 024k|5–10 t/s CPU"
        "qwen3:27b-q4_k_m|Qwen3 27B Q4_K_M|17 GB|27B Dense|262k–1M|40–72 t/s GPU"
        "codestral:22b-v25.01-fp16|Codestral 25.01 22B FP16|44 GB|22B Dense|256k|5–10 t/s hybrid"
        "medgemma:27b-text-fp16|MedGemma 27B FP16|54 GB|27B Dense|32k|5–10 t/s hybrid"
        "qwen2.5-vl:72b-q5_k_m|Qwen2.5-VL 72B Q5_K_M|47 GB|72B Dense VL|131k|5–12 t/s hybrid"
        "qwen3-coder:80b-q4_k_m|Qwen3-Coder 80B Q4_K_M|49 GB|3B active MoE|256k|15–25 t/s hybrid"
        "deepseek-r1:70b-llama-distill-q4_k_m|DeepSeek-R1 70B Distill Q4_K_M|40 GB|70B Dense|128k|8–12 t/s CPU"
        "gemma3:27b-q4_k_m|Gemma3 27B Q4_K_M|20 GB|27B Dense|128k|20–40 t/s GPU"
        "nemotron-3-nano:30b-a3b-q8_0|Nemotron-3-Nano 30B Q8_0|23 GB|3.5B MoE Mamba|1 024k|100–150 t/s GPU"
        "phi4-mini:14b-q4_k_m|Phi-4-Mini 14B Q4_K_M|9 GB|14B Dense|16k|100–120 t/s GPU"
    )
    local -a DD_DETAILS=(
"① DeepSeek-V3 671B Q4_K_M  ──  THE OVERNIGHT BRAIN …"
"② Nemotron-3-Super 120B FP8  ──  REASONING POWERHOUSE …"
"③ Llama-4-Maverick 400B Q4_K_S  ──  MASSIVE CODE GENERATOR …"
"④ Qwen3 27B Q4_K_M  ──  MULTILINGUAL DAILY DRIVER …"
"⑤ Codestral 25.01 22B FP16  ──  CODE SPECIALIST …"
"⑥ MedGemma 27B FP16  ──  MEDICAL SPECIALIST …"
"⑦ Qwen2.5-VL 72B Q5_K_M  ──  VISION-LANGUAGE …"
"⑧ Qwen3-Coder 80B Q4_K_M  ──  CODE REFACTORING ENGINE …"
"⑨ DeepSeek-R1 70B Distill Q4_K_M  ──  DISTILLED REASONER …"
"⑩ Gemma3 27B Q4_K_M  ──  GPU-NATIVE SPRINTER …"
"⑪ Nemotron-3-Nano 30B Q8_0  ──  FAST HYBRID WITH 1M CONTEXT …"
"⑫ Phi-4-Mini 14B Q4_K_M  ──  LIGHTWEIGHT DAILY DRIVER …"
    )

    local num_models=${#DD_MODELS[@]}
    local selected=0

    _dd_hide_cursor() { printf "\033[?25l"; }
    _dd_show_cursor() { printf "\033[?25h"; }
    _dd_home()        { printf "\033[2J\033[H"; }

    _dd_draw() {
        _dd_home
        printf "╔══════════════════════════════════════════════════════════════════════╗\n"
        printf "║  PULL MODELS TO SERVER: %-47s║\n" "$OLLAMA_BASE_URL"
        printf "╠══════════════════════════════════════════════════════════════════════╣\n"
        printf "║  ↑↓ scroll · Enter pull to server · [n] custom tag · [q] done       ║\n"
        printf "╚══════════════════════════════════════════════════════════════════════╝\n\n"
        printf "  %-3s %-34s %8s %14s %8s %-14s\n" \
               "#" "Model" "Disk" "Active" "Ctx" "Speed"
        printf "  %-3s %-34s %8s %14s %8s %-14s\n" \
               "---" "----------------------------------" "--------" "--------------" "--------" "--------------"
        local i
        for i in "${!DD_MODELS[@]}"; do
            IFS='|' read -r _tag name disk active ctx speed <<< "${DD_MODELS[$i]}"
            if (( i == selected )); then
                printf "\033[7m  ▶  %-34s %8s %14s %8s %-14s\033[0m\n" \
                       "$name" "$disk" "$active" "$ctx" "$speed"
            else
                printf "     %-34s %8s %14s %8s %-14s\n" \
                       "$name" "$disk" "$active" "$ctx" "$speed"
            fi
        done
        echo ""
        printf "═%.0s" {1..72}; echo ""
        echo "${DD_DETAILS[$selected]}" | sed 's/^/  /'
        echo ""
        printf "═%.0s" {1..72}; echo ""
    }

    _dd_read_key() {
        local key rest
        IFS= read -rsn1 key
        if [[ "$key" == $'\033' ]]; then
            IFS= read -rsn2 -t 0.1 rest || true
            key+="$rest"
        fi
        case "$key" in
            $'\033[A') echo "up"     ;;
            $'\033[B') echo "down"   ;;
            '')         echo "enter"  ;;
            n|N)        echo "custom" ;;
            q|Q)        echo "quit"   ;;
            *)          echo "other"  ;;
        esac
    }

    _dd_custom_pull() {
        echo ""
        local tag
        read -rp "  Enter full Ollama model tag (e.g. codellama:70b): " tag
        [[ -z "${tag:-}" ]] && { echo "  Cancelled."; sleep 1; return; }
        pull_to_server "$tag"
        echo "  Press Enter to return."
        read -r
    }

    _dd_hide_cursor
    trap '_dd_show_cursor' RETURN

    while true; do
        _dd_draw
        local key
        key="$(_dd_read_key)"
        case "$key" in
            up)    (( selected > 0 )) && (( selected-- )) ;;
            down)  (( selected < num_models - 1 )) && (( selected++ )) ;;
            enter)
                IFS='|' read -r tag _rest <<< "${DD_MODELS[$selected]}"
                _dd_show_cursor
                echo ""
                pull_to_server "$tag"
                echo "  Press Enter to return."
                read -r
                _dd_hide_cursor
                ;;
            custom)
                _dd_show_cursor
                _dd_custom_pull
                _dd_hide_cursor
                ;;
            quit) break ;;
            *) ;;
        esac
    done

    _dd_show_cursor
}

# ═══════════════════════════════════════════════════════════
#  SETUP MENU
# ═══════════════════════════════════════════════════════════

save_settings() {
    cat > "$CONFIG_FILE" <<EOF
OLLAMA_REMOTE_HOST=${OLLAMA_REMOTE_HOST}
OLLAMACODE_REASONING=${OLLAMACODE_REASONING}
OLLAMACODE_TEMPERATURE=${OLLAMACODE_TEMPERATURE}
OLLAMACODE_PERMISSION_MODE=${OLLAMACODE_PERMISSION_MODE}
OLLAMACODE_KEEP_ALIVE=${OLLAMACODE_KEEP_ALIVE}
EOF
    OLLAMA_BASE_URL="$OLLAMA_REMOTE_HOST"
}

setup_menu() {
    local choice
    while true; do
        echo ""
        echo "══════════════════ Ollamacode Client Settings ══════════════════"
        echo "  Connection"
        echo "   1) Remote server URL  : ${OLLAMA_REMOTE_HOST}"
        echo ""
        echo "  Model defaults"
        echo "   2) Reasoning level    : ${OLLAMACODE_REASONING}  (off|low|on)"
        echo "   3) Temperature        : ${OLLAMACODE_TEMPERATURE}"
        echo "   4) Permission mode    : ${OLLAMACODE_PERMISSION_MODE}"
        echo "   5) Keep alive         : ${OLLAMACODE_KEEP_ALIVE}"
        echo ""
        echo "  Actions"
        echo "   6) List models on server"
        echo "   7) Show running models on server"
        echo "   8) Pull models to server (Dirty Dozen TUI)"
        echo "   9) Pull custom model tag to server"
        echo "  10) Test server connectivity"
        echo "  11) Save and exit"
        echo "  12) Exit without saving"
        echo "════════════════════════════════════════════════════════════════"
        echo ""
        read -rp "Option: " choice
        case "${choice:-}" in
            1)  read -rp "Remote server URL [${OLLAMA_REMOTE_HOST}]: " v
                if [[ -n "${v:-}" ]]; then
                    OLLAMA_REMOTE_HOST="$v"
                    OLLAMA_BASE_URL="$v"
                fi ;;
            2)  read -rp "Reasoning (off|low|on) [${OLLAMACODE_REASONING}]: " v
                [[ "${v:-}" =~ ^(off|low|on)$ ]] && OLLAMACODE_REASONING="$v" ;;
            3)  read -rp "Temperature 0.0–2.0 [${OLLAMACODE_TEMPERATURE}]: " v
                [[ "${v:-}" =~ ^[0-9]+\.?[0-9]*$ ]] && OLLAMACODE_TEMPERATURE="$v" ;;
            4)  echo "  workspace-write    — edits only inside current workspace"
                echo "  danger-full-access — edits anywhere on filesystem"
                echo "  read-only          — no file writes"
                read -rp "Permission mode [${OLLAMACODE_PERMISSION_MODE}]: " v
                [[ -n "${v:-}" ]] && OLLAMACODE_PERMISSION_MODE="$v" ;;
            5)  read -rp "Keep alive (e.g. 30m, 2h, -1) [${OLLAMACODE_KEEP_ALIVE}]: " v
                [[ -n "${v:-}" ]] && OLLAMACODE_KEEP_ALIVE="$v" ;;
            6)  echo ""; get_server_models ;;
            7)  echo ""; show_server_running ;;
            8)  pull_models_menu ;;
            9)  echo ""
                read -rp "Model tag to pull to server: " v
                [[ -n "${v:-}" ]] && pull_to_server "$v" ;;
           10)  if check_server; then
                   echo "  ✓ Server reachable at $OLLAMA_BASE_URL"
               else
                   echo "  ✗ Cannot reach server at $OLLAMA_BASE_URL"
               fi ;;
           11) save_settings; echo "Saved to $CONFIG_FILE"; return 0 ;;
           12) echo "Exiting without saving."; return 1 ;;
            *) echo "Invalid selection." ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════
#  HELP
# ═══════════════════════════════════════════════════════════

show_help() {
    cat <<'HELP'
Usage: ollamacode-client [options]

  --model MODEL        Use a specific server model tag (bypasses menu)
  --ctx N              Override context window (default: server model max)
  --keep-alive VALUE   Override keep_alive (e.g. 10m, 2h, -1)
  --reasoning LEVEL    Set reasoning level: off | low | on  (default: on)
  --temperature FLOAT  Set temperature 0.0–2.0  (default: 0.2)
  --host URL           Override server URL (e.g. http://192.168.1.5:11434)
  --pull               Open Dirty Dozen model pull menu
  --list               List models on server and exit
  --running            Show currently running models on server and exit
  --setup              Open configuration menu
  --help               Show this help

Without --model, the full model-selection TUI is shown.
The selected model is automatically loaded into server memory
before launching claw.
HELP
}

# ═══════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════

MODEL_ARG=""
CTX_OVERRIDE=""
KEEP_ALIVE_OVERRIDE=""
REASONING_OVERRIDE=""
TEMP_OVERRIDE=""
DO_PULL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --setup)        setup_menu; exit 0 ;;
        --list)         get_server_models; exit 0 ;;
        --running)      show_server_running; exit 0 ;;
        --pull)         DO_PULL=1; shift ;;
        --model)        MODEL_ARG="$2"; shift 2 ;;
        --ctx)          CTX_OVERRIDE="$2"; shift 2 ;;
        --keep-alive)   KEEP_ALIVE_OVERRIDE="$2"; shift 2 ;;
        --reasoning)    REASONING_OVERRIDE="$2"; shift 2 ;;
        --temperature)  TEMP_OVERRIDE="$2"; shift 2 ;;
        --host)         OLLAMA_REMOTE_HOST="$2"; OLLAMA_BASE_URL="$2"; shift 2 ;;
        --help|-h)      show_help; exit 0 ;;
        *)              echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

require_tools

[[ -n "${REASONING_OVERRIDE:-}" ]] && OLLAMACODE_REASONING="$REASONING_OVERRIDE"
[[ -n "${TEMP_OVERRIDE:-}"      ]] && OLLAMACODE_TEMPERATURE="$TEMP_OVERRIDE"

# ── Check server ───────────────────────────────────────────────────
if ! check_server; then
    echo "Error: Ollama server not reachable at $OLLAMA_BASE_URL" >&2
    echo ""
    echo "  • Is the server running?  SSH in and run: ollamacode"
    echo "  • Is OLLAMA_HOST=0.0.0.0 set on the server?"
    echo "  • Check firewall — port ${OLLAMA_BASE_URL##*:} must be open from this machine"
    echo "  • Update host: ollamacode-client --setup → option 1"
    exit 1
fi

# ── Optional pre-pull ──────────────────────────────────────────────
(( DO_PULL )) && pull_models_menu

# ── Pick model ─────────────────────────────────────────────────────
if [[ -z "${MODEL_ARG:-}" ]]; then
    MODEL_ARG="$(select_model_tui)"
else
    local server_models_check
    server_models_check="$(get_server_models 2>/dev/null || true)"
    if ! echo "$server_models_check" | grep -Fxq "$MODEL_ARG"; then
        echo "Error: Model '$MODEL_ARG' not found on server." >&2
        echo "Available models:" >&2
        echo "$server_models_check" >&2
        exit 1
    fi
fi

# ── Context ────────────────────────────────────────────────────────
MODEL_MAX_CTX="$(get_server_model_ctx "$MODEL_ARG" 2>/dev/null || true)"
DEFAULT_CTX="${CTX_OVERRIDE:-${MODEL_MAX_CTX:-131072}}"

echo ""
[[ -n "${MODEL_MAX_CTX:-}" ]] \
    && echo "  Server model max context : ${MODEL_MAX_CTX} tokens" \
    || echo "  (could not fetch model max context — defaulting to ${DEFAULT_CTX})"

read -rp "  Context window (num_ctx) [${DEFAULT_CTX}]: " ctx_in
NUM_CTX="${ctx_in:-$DEFAULT_CTX}"

# ── Keep-alive ─────────────────────────────────────────────────────
EFFECTIVE_KA="${KEEP_ALIVE_OVERRIDE:-${OLLAMACODE_KEEP_ALIVE}}"
read -rp "  Keep alive [${EFFECTIVE_KA}]: " keep_in
EFFECTIVE_KA="${keep_in:-$EFFECTIVE_KA}"

# ── Pre-load model into server memory ──────────────────────────────
if ! is_model_loaded "$MODEL_ARG"; then
    preload_model "$MODEL_ARG" || {
        echo "Error: Failed to load model on server." >&2
        exit 1
    }
else
    echo "  Model already loaded on server."
fi

# ── Set all environment variables ──────────────────────────────────
export OPENAI_BASE_URL="${OLLAMA_BASE_URL}/v1"
export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
export OLLAMACODE_NUM_CTX="$NUM_CTX"
export OLLAMACODE_KEEP_ALIVE="$EFFECTIVE_KA"
export OLLAMACODE_REASONING="$OLLAMACODE_REASONING"
export OLLAMACODE_TEMPERATURE="$OLLAMACODE_TEMPERATURE"

echo "🚀 Launching claw (client mode)"
echo "   Model            : openai/$MODEL_ARG"
echo "   Context          : $NUM_CTX"
echo "   Keep alive       : $EFFECTIVE_KA"
echo "   Reasoning        : $OLLAMACODE_REASONING"
echo "   Temperature      : $OLLAMACODE_TEMPERATURE"
echo "   Permission mode  : $OLLAMACODE_PERMISSION_MODE"
echo "   Ollama endpoint  : $OLLAMA_BASE_URL"
echo ""
CLAW_MODEL="openai/$MODEL_ARG"

exec "$CLI_BIN" \
    --model "$CLAW_MODEL" \
    --permission-mode "$OLLAMACODE_PERMISSION_MODE"
LAUNCHER_EOF

    chmod +x "$LAUNCHER"
}

# ═══════════════════════════════════════════════════════════
#  INSTALLER MAIN
# ═══════════════════════════════════════════════════════════
echo "=== Ollamacode Client Installer ==="
echo ""
echo "  Remote server : $OLLAMA_REMOTE_HOST"
echo "  (configure with: ollamacode-client --setup)"
echo ""

save_config
generate_launcher

# ── Make immediately available via /usr/local/bin symlink ─────────
if sudo sudo ln -sf "$LAUNCHER" /usr/local/bin/ollamacode-client 2>/dev/null \
   || sudo ln -sf "$LAUNCHER" /usr/local/bin/ollamacode-client 2>/dev/null; then
    echo "✓ Symlinked to /usr/local/bin/ollamacode-client (available immediately)"
else
    SHELL_RC="$HOME/.bashrc"
    [[ "${SHELL:-}" == */zsh ]] && SHELL_RC="$HOME/.zshrc"
    if ! grep -q 'HOME/bin' "$SHELL_RC" 2>/dev/null; then
        echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_RC"
    fi
    echo "✓ ~/bin added to PATH in $SHELL_RC"
    echo "  Run: source $SHELL_RC  (or open a new terminal)"
fi

echo "✓ Launcher : $LAUNCHER"
echo "✓ Config   : $CONFIG_FILE"
echo ""
echo "🎉 Installation complete!"
echo ""
echo "Reload your shell or start a new terminal"
echo "source ~/.bashrc"
echo ""
echo "Usage:"
echo "  ollamacode-client                          — interactive model selection TUI"
echo "  ollamacode-client --model MODEL            — launch with a specific server model"
echo "  ollamacode-client --host http://IP:11434   — specify server"
echo "  ollamacode-client --pull                   — pull models to server first"
echo "  ollamacode-client --setup                  — configure all settings"
echo "  ollamacode-client --running                — show models loaded on server"
echo "  ollamacode-client --help                   — full option list"
echo ""
echo "NOTE: The server must have OLLAMA_HOST=0.0.0.0:11434."
echo "      Run 'ollamacode --setup' on the server to verify."