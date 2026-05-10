#!/usr/bin/env bash
# setup_ollamacode_server.sh
# Installs ~/bin/ollamacode: workstation launcher for GPU+CPU-offloaded Ollama + claw.
set -euo pipefail

CONFIG_DIR="$HOME/.config"
CONFIG_FILE="$CONFIG_DIR/ollamacode-server.conf"
LAUNCHER="$HOME/bin/ollamacode"

# ─────────────────────────── installer-side defaults ─────────────
OLLAMA_HOST="${OLLAMA_HOST:-0.0.0.0}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"
OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"
OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
OLLAMA_ORIGINS="${OLLAMA_ORIGINS:-*}"
OLLAMA_MAX_QUEUE="${OLLAMA_MAX_QUEUE:-10}"
OLLAMACODE_SERVER_MODE="${OLLAMACODE_SERVER_MODE:-session}"
OLLAMACODE_DEFAULT_MODEL="${OLLAMACODE_DEFAULT_MODEL:-}"
OLLAMACODE_REASONING="${OLLAMACODE_REASONING:-on}"
OLLAMACODE_TEMPERATURE="${OLLAMACODE_TEMPERATURE:-0.2}"
OLLAMACODE_PERMISSION_MODE="${OLLAMACODE_PERMISSION_MODE:-workspace-write}"

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ── installer hardware helpers ────────────────────────────────────
get_vram_mb() {
    command -v nvidia-smi >/dev/null 2>&1 \
        && nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 \
        || echo "0"
}
get_ram_mb() { awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; }
is_wsl()     { grep -qi microsoft /proc/version 2>/dev/null; }
get_ram_gb() { awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo; }
is_wsl()     { grep -qi microsoft /proc/version 2>/dev/null; }

# ── installer config save ─────────────────────────────────────────
save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# Ollamacode Server Configuration
OLLAMA_HOST=${OLLAMA_HOST}
OLLAMA_PORT=${OLLAMA_PORT}
OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}
OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}
OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}
OLLAMA_FLASH_ATTENTION=${OLLAMA_FLASH_ATTENTION}
OLLAMA_KV_CACHE_TYPE=${OLLAMA_KV_CACHE_TYPE}
CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}
OLLAMA_ORIGINS=${OLLAMA_ORIGINS}
OLLAMA_MAX_QUEUE=${OLLAMA_MAX_QUEUE}
OLLAMACODE_SERVER_MODE=${OLLAMACODE_SERVER_MODE}
OLLAMACODE_DEFAULT_MODEL=${OLLAMACODE_DEFAULT_MODEL}
OLLAMACODE_REASONING=${OLLAMACODE_REASONING}
OLLAMACODE_TEMPERATURE=${OLLAMACODE_TEMPERATURE}
OLLAMACODE_PERMISSION_MODE=${OLLAMACODE_PERMISSION_MODE}
EOF
}

# ── installer-side systemd override ──────────────────────────────
install_systemd_override() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "systemctl not found — skipping systemd override." >&2; return 1
    fi
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    echo "Installing systemd override for persistent Ollama tuning..."
    mkdir -p "$(dirname "/etc/systemd/system/ollama.service.d")"
    tee "/etc/systemd/system/ollama.service.d/override.conf" > /dev/null <<EOF
[Service]
Environment="OLLAMA_HOST=${OLLAMA_HOST}:${OLLAMA_PORT}"
Environment="OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}"
Environment="OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}"
Environment="OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}"
Environment="OLLAMA_FLASH_ATTENTION=${OLLAMA_FLASH_ATTENTION}"
Environment="OLLAMA_KV_CACHE_TYPE=${OLLAMA_KV_CACHE_TYPE}"
Environment="CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}"
Environment="OLLAMA_ORIGINS=${OLLAMA_ORIGINS}"
Environment="OLLAMA_MAX_QUEUE=${OLLAMA_MAX_QUEUE}"
EOF
    systemctl daemon-reload
    systemctl restart ollama || true
    echo "✓ Systemd override installed"
}

# ─────────────────────────── generate launcher ───────────────────
generate_launcher() {
    mkdir -p "$(dirname "$LAUNCHER")"
    cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
# ollamacode — workstation launcher
set -euo pipefail

CONFIG_FILE="$HOME/.config/ollamacode-server.conf"
CLI_BIN="$HOME/claw-code/rust/target/debug/claw"

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

OLLAMA_HOST="${OLLAMA_HOST:-0.0.0.0}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"
OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"
OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"
CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
OLLAMA_ORIGINS="${OLLAMA_ORIGINS:-*}"
OLLAMA_MAX_QUEUE="${OLLAMA_MAX_QUEUE:-10}"
OLLAMACODE_SERVER_MODE="${OLLAMACODE_SERVER_MODE:-session}"
OLLAMACODE_DEFAULT_MODEL="${OLLAMACODE_DEFAULT_MODEL:-}"
OLLAMACODE_REASONING="${OLLAMACODE_REASONING:-on}"
OLLAMACODE_TEMPERATURE="${OLLAMACODE_TEMPERATURE:-0.2}"
OLLAMACODE_PERMISSION_MODE="${OLLAMACODE_PERMISSION_MODE:-workspace-write}"

OLLAMA_BASE_URL="http://127.0.0.1:${OLLAMA_PORT}"
SERVER_PID=""

# ═══════════════════════════════════════════════════════════
#  HARDWARE HELPERS
get_vram_mb() {
    command -v nvidia-smi >/dev/null 2>&1 \
        && nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 \
        || echo "0"
}
get_ram_gb() { awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo; }

# ═══════════════════════════════════════════════════════════
#  MODEL INFO HELPERS
get_model_max_ctx() {
    local model="$1"
    ollama show "$model" 2>/dev/null \
        | awk 'tolower($0) ~ /context.?length/ {
            for (i=1; i<=NF; i++) {
                gsub(/,/, "", $i)
                if ($i ~ /^[0-9]+$/ && $i+0 > 512) { print $i+0; exit }
            }
        }'
}

get_model_memory_mb() {
    local model="$1"
    ollama show "$model" 2>/dev/null | awk '
        /^[[:space:]]+memory[[:space:]]/ {
            if (match($0, /([0-9]+\.?[0-9]*)[[:space:]]*(MiB|GiB)/i, arr)) {
                val = arr[1]+0
                if (toupper(arr[2]) == "GIB") val *= 1024
                printf "%.0f", val; exit
            }
        }'
}

# ═══════════════════════════════════════════════════════════
#  SERVER LIFECYCLE
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

get_models() {
    python3 - "$OLLAMA_BASE_URL" <<'PY'
import os, sys, json, urllib.request
url = sys.argv[1].rstrip('/') + '/v1/models'
with urllib.request.urlopen(
    urllib.request.Request(url, headers={'Content-Type': 'application/json'}),
    timeout=10
) as r:
    data = json.load(r)
for item in data.get('data', []):
    if isinstance(item, dict) and item.get('id'):
        print(item['id'])
PY
}

start_server() {
    local ctx="$1"
    if check_server; then
        echo "Ollama already running at $OLLAMA_BASE_URL"
        return 0
    fi
    echo "Starting Ollama ctx=${ctx} KV=${OLLAMA_KV_CACHE_TYPE} flash=${OLLAMA_FLASH_ATTENTION}"
    OLLAMA_HOST="${OLLAMA_HOST}:${OLLAMA_PORT}" \
    OLLAMA_CONTEXT_LENGTH="$ctx" \
    OLLAMA_MAX_LOADED_MODELS="$OLLAMA_MAX_LOADED_MODELS" \
    OLLAMA_NUM_PARALLEL="$OLLAMA_NUM_PARALLEL" \
    OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE" \
    OLLAMA_FLASH_ATTENTION="$OLLAMA_FLASH_ATTENTION" \
    OLLAMA_KV_CACHE_TYPE="$OLLAMA_KV_CACHE_TYPE" \
    CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
    OLLAMA_ORIGINS="$OLLAMA_ORIGINS" \
    OLLAMA_MAX_QUEUE="$OLLAMA_MAX_QUEUE" \
    nohup ollama serve >>/tmp/ollama-server.log 2>&1 &
    SERVER_PID=$!
    for i in {1..30}; do
        check_server && { echo " ✓ Server ready"; return 0; }
        printf "."; sleep 1
    done
    echo ""
    echo "Error: server did not become ready — check /tmp/ollama-server.log" >&2
    kill "$SERVER_PID" 2>/dev/null || true
    return 1
}

stop_server() {
    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Stopping Ollama server (pid ${SERVER_PID})..."
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi
}

cleanup() {
    [[ "${OLLAMACODE_SERVER_MODE:-session}" == "session" ]] && stop_server
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════
#  GPU RESIDENCY CHECK
verify_gpu_residency() {
    local model="$1"
    echo "Preloading model to check layer distribution..."
    ollama run "$model" "" >/dev/null 2>&1 || true
    sleep 2
    local proc_info=""
    proc_info="$(ollama ps 2>/dev/null | grep -F "$model" | awk '{print $NF}' || true)"
    if [[ -n "${proc_info:-}" ]]; then
        echo "  Layer distribution: $proc_info"
        case "$proc_info" in
            "100% GPU") echo "  ✓ Fully GPU resident" ;;
            *GPU*)      echo "  ✓ Split GPU+CPU — GPU layers in VRAM, remainder offloaded to RAM" ;;
            *)          echo "  ⚠  CPU only — check VRAM vs model size" ;;
        esac
    else
        echo "  (could not determine residency)"
    fi
}

# ═══════════════════════════════════════════════════════════
#  THE DIRTY DOZEN — interactive model puller TUI
pull_models_menu() {
    command -v ollama >/dev/null 2>&1 || { echo "Error: ollama CLI not found." >&2; return 1; }

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
"① DeepSeek-V3 671B Q4_K_M  ──  THE OVERNIGHT BRAIN
 Active: 37B Mixture-of-Experts (top-tier logic & code)
 Disk: 404 GB  |  Context: 64k native (128k with positional patch)
 Speed: 1.5–3 t/s CPU — saturates 8-channel memory bandwidth
 Best for: overnight bug hunts, multi-file refactors, graduate-level maths,
           architecture reviews.  Leave it running and go sleep.
 Tradeoff: Slow per token; plan prompts carefully.  Requires full 512 GB RAM."

"② Nemotron-3-Super 120B FP8  ──  REASONING POWERHOUSE
 Active: 12B MoE (Mamba SSM hybrid — extremely efficient KV)
 Disk: 83 GB  |  Context: 1 024k tokens (1 M)
 Speed: 15–30 t/s hybrid GPU+CPU
 Best for: complex multi-step reasoning, long document analysis,
           hard maths, 1M-context summarisation.
 Tradeoff: FP8 saves ~40 GB vs FP16; quality loss <1%.  Mamba layers
           mean KV memory barely grows with context length."

"③ Llama-4-Maverick 400B Q4_K_S  ──  MASSIVE CODE GENERATOR
 Active: 17B MoE (128 experts per token)
 Disk: 80 GB  |  Context: 1 024k
 Speed: 5–10 t/s CPU
 Best for: huge codebase ingestion, multi-repo refactors, long reasoning chains.
 Tradeoff: Needs the full 512 GB RAM pool — fix .wslconfig first.
           Q4_K_S saves 30 GB vs Q5 with <1% quality loss."

"④ Qwen3 27B Q4_K_M  ──  MULTILINGUAL DAILY DRIVER
 Active: 27B Dense
 Disk: 17 GB  |  Context: 262k (1M w/ YaRN positional extension)
 Speed: 40–72 t/s GPU — fits entirely in 24 GB VRAM
 Best for: multilingual work, fast code gen, everyday use,
           anything where you want instant responses.
 Tradeoff: Smaller than the heavyweights but covers 90% of daily tasks."

"⑤ Codestral 25.01 22B FP16  ──  CODE SPECIALIST
 Active: 22B Dense
 Disk: 44 GB  |  Context: 256k
 Speed: 5–10 t/s hybrid
 Best for: code review, fill-in-the-middle, documentation generation,
           precise language-server-style completions.
 Tradeoff: FP16 = best quality for code; ~20 GB overflows from VRAM to RAM.
           Not open-weight for commercial use."

"⑥ MedGemma 27B FP16  ──  MEDICAL SPECIALIST
 Active: 27B Dense
 Disk: 54 GB  |  Context: 32k
 Speed: 5–10 t/s hybrid
 Best for: clinical notes, medical research summarisation,
           diagnostic reasoning, biomedical NLP.
 Tradeoff: Domain-specific — weaker on general tasks.
           Short 32k context; keep queries focused."

"⑦ Qwen2.5-VL 72B Q5_K_M  ──  VISION-LANGUAGE
 Active: 72B Dense (multimodal)
 Disk: 47 GB  |  Context: 131k
 Speed: 5–12 t/s hybrid
 Best for: image analysis, chart/diagram reading, OCR, multimodal pipelines,
           code-from-screenshot tasks.
 Tradeoff: Only model here with native vision input.
           Needs significant VRAM+RAM split for 72B."

"⑧ Qwen3-Coder 80B Q4_K_M  ──  CODE REFACTORING ENGINE
 Active: 3B active MoE (very efficient)
 Disk: 49 GB  |  Context: 256k
 Speed: 15–25 t/s hybrid
 Best for: large-scale refactors, code optimisation, multi-file edits,
           repo-wide search-and-transform tasks.
 Tradeoff: MoE efficiency = fast for its disk size.
           Great GPU+CPU split candidate for 24 GB VRAM machines."

"⑨ DeepSeek-R1 70B Distill Q4_K_M  ──  DISTILLED REASONER
 Active: 70B Dense (distilled from R1-671B)
 Disk: 40 GB  |  Context: 128k
 Speed: 8–12 t/s CPU
 Best for: reasoning, maths, general-purpose smart assistant tasks,
           chain-of-thought work where you want visible thinking.
 Tradeoff: Distillation retains most R1 reasoning but uses far less RAM.
           Slower than 27B models; faster than 400B."

"⑩ Gemma3 27B Q4_K_M  ──  GPU-NATIVE SPRINTER
 Active: 27B Dense
 Disk: 20 GB  |  Context: 128k
 Speed: 20–40 t/s GPU — fits in 24 GB VRAM
 Best for: interactive coding sessions, quick Q&A, code snippets,
           any task where latency matters more than depth.
 Tradeoff: Shorter context than Qwen3 27B; otherwise comparable quality.
           Fully GPU = lowest latency option at this quality tier."

"⑪ Nemotron-3-Nano 30B Q8_0  ──  FAST HYBRID WITH MILLION-TOKEN CONTEXT
 Active: 3.5B MoE (Mamba SSM — KV barely grows with context)
 Disk: 23 GB  |  Context: 1 024k
 Speed: 100–150 t/s GPU
 Best for: agentic loops, rapid iteration, streaming code generation,
           tasks needing 1M context at interactive speed.
 Tradeoff: Mamba SSM = unique architecture; may behave differently
           from transformer models on some tasks.  Q8_0 = high quality."

"⑫ Phi-4-Mini 14B Q4_K_M  ──  LIGHTWEIGHT DAILY DRIVER
 Active: 14B Dense
 Disk: 9 GB  |  Context: 16k
 Speed: 100–120 t/s GPU
 Best for: lightweight tasks, quick queries, constrained environments,
           cases where you want maximum t/s and minimum VRAM.
 Tradeoff: Short 16k context.  Best for quick in-and-out questions."
    )

    local num_models=${#DD_MODELS[@]}
    local selected=0

    _hide_cursor() { printf "\033[?25l"; }
    _show_cursor() { printf "\033[?25h"; }
    _go_home()     { printf "\033[2J\033[H"; }

    _draw_tui() {
        _go_home
        printf "╔══════════════════════════════════════════════════════════════════════╗\n"
        printf "║  THE DIRTY DOZEN  ──  512 GB WORKSTATION MODEL SELECTOR             ║\n"
        printf "╠══════════════════════════════════════════════════════════════════════╣\n"
        printf "║  ↑↓ scroll · Enter pull · [n] custom model tag · [q] quit           ║\n"
        printf "╚══════════════════════════════════════════════════════════════════════╝\n\n" > /dev/tty
        printf "  %-3s %-34s %8s %14s %8s %-16s\n" \
               "#" "Model" "Disk" "Active" "Ctx" "Speed"
        printf "  %-3s %-34s %8s %14s %8s %-16s\n" > /dev/tty \
               "---" "----------------------------------" "--------" "--------------" "--------" "----------------"
        local i
        for i in "${!DD_MODELS[@]}"; do
            IFS='|' read -r _tag name disk active ctx speed <<< "${DD_MODELS[$i]}"
            if (( i == selected )); then
                printf "\033[7m  ▶  %-34s %8s %14s %8s %-16s\033[0m\n" \
                       "$name" "$disk" "$active" "$ctx" "$speed"
            else > /dev/tty
                printf "     %-34s %8s %14s %8s %-16s\n" \
                       "$name" "$disk" "$active" "$ctx" "$speed"
            fi
        done
        echo "" > /dev/tty
        printf "═%.0s" {1..72}; echo ""
        echo "${DD_DETAILS[$selected]}" | sed 's/^/  /'
        echo "" > /dev/tty
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
            q|Q)        echo "quit"   ;;
            n|N)        echo "custom" ;;
            *)          echo "other"  ;;
        esac
    }

    _custom_pull() {
        echo ""
        local tag
        read -rp "Enter full Ollama model tag (e.g. codellama:70b): " tag
        [[ -z "${tag:-}" ]] && { echo "Cancelled."; sleep 1; return; }
        echo "Pulling ${tag} ..."
        ollama pull "$tag"
        echo "Done. Press Enter."
        read -r
    }

    _hide_cursor
    trap '_show_cursor' RETURN

    while true; do
        _draw_tui > /dev/tty
        local key
        key="$(_read_key)"
        case "$key" in
            up)     (( selected > 0 )) && (( selected-- )) ;;
            down)   (( selected < num_models - 1 )) && (( selected++ )) ;;
            enter)
                IFS='|' read -r tag _rest <<< "${DD_MODELS[$selected]}"
                echo ""
                echo "Pulling ${tag} ..."
                ollama pull "$tag"
                echo "Done. Press Enter to return."
                read -r
                ;;
            custom) _custom_pull ;;
            quit)   break ;;
            *)      ;;
        esac
    done

    _show_cursor
}

# ═══════════════════════════════════════════════════════════
#  MODEL SELECTION TUI (FIXED: only model name to stdout)
select_model() {
    while true; do
        local models
        mapfile -t models < <(get_models 2>/dev/null || true)

        # Pre-compute array length to avoid parsing issues with ${#models[@]}
        local num_models=${#models[@]}

        if [[ $num_models -eq 0 ]]; then
            echo ""
            echo "No installed models found."
            read -rp "Open Dirty Dozen pull menu? (Y/n): " ans
            case "${ans:-Y}" in
                [Nn]*) echo "Aborting." >&2; exit 1 ;;
                *)     pull_models_menu ;;
            esac
            continue
        fi

        local selected=0
        _hide_cursor() { printf "\033[?25l"; }
        _show_cursor() { printf "\033[?25h"; }
        _go_home()     { printf "\033[2J\033[H"; }

        _draw_selection() {
            _go_home
            echo "Installed models:" > /dev/tty
            local i
            for i in "${!models[@]}"; do
                local ctx
                ctx="$(get_model_max_ctx "${models[$i]}" 2>/dev/null || true)"
                if (( i == selected )); then
                    printf "\033[7m" > /dev/tty
                fi
                if [ -n "${ctx:-}" ]; then
                    printf "  %3d) %-46s [max ctx: %s]\n" "$((i+1))" "${models[$i]}" "$ctx"
                else
                    printf "  %3d) %s\n" "$((i+1))" "${models[$i]}"
                fi
                if (( i == selected )); then
                    printf "\033[0m" > /dev/tty
                fi
            done
            echo "" > /dev/tty
            printf "  %-3d) Pull more models (Dirty Dozen)\n" "$(( num_models + 1 ))"
            printf "  %-3d) Setup\n"                             "$(( num_models + 2 ))"
            printf "  %-3d) Exit\n"                              "$(( num_models + 3 ))"
        }

        _read_key() {
            local key rest
            IFS= read -rsn1 key
            if [[ "$key" == $'\033' ]]; then
                IFS= read -rsn2 -t 0.1 rest || true
                key+="$rest"
            fi
            case "$key" in
                $'\033[A') echo "up" ;;
                $'\033[B') echo "down" ;;
                '')         echo "enter" ;;
                q|Q)        echo "quit" ;;
                *)          echo "other" ;;
            esac
        }

        _hide_cursor
        trap '_show_cursor' RETURN

        while true; do
            _draw_selection > /dev/tty
            local key
            key="$(_read_key)"
            case "$key" in
                up)    (( selected > 0 )) && (( selected-- )) ;;
                down)  (( selected < num_models - 1 )) && (( selected++ )) ;;
                enter)
                    _show_cursor
                    echo "${models[$selected]}"
                    return 0
                    ;;
                quit)
                    _show_cursor
                    exit 0
                    ;;
                *)
                    local choice=$((selected + 1))
                    if [[ "$choice" == $((num_models + 1)) ]]; then
                        pull_models_menu
                        break
                    elif [[ "$choice" == $((num_models + 2)) ]]; then
                        setup_menu || true
                        break
                    elif [[ "$choice" == $((num_models + 3)) ]]; then
                        _show_cursor
                        exit 0
                    fi
                    ;;
            esac
        done
    done
}

# ═══════════════════════════════════════════════════════════
#  SETUP MENU (FIXED: safe return)
setup_menu() {
    local choice
    while true; do
        echo ""
        echo "══════════════════ Ollamacode Server Settings ══════════════════"
        echo "  Server"
        echo "   1) Server mode        : ${OLLAMACODE_SERVER_MODE}  (session|systemd|off)"
        echo "   2) Bind address       : ${OLLAMA_HOST}"
        echo "   3) Port               : ${OLLAMA_PORT}"
        echo ""
        echo "  Model defaults"
        echo "   4) Default model      : ${OLLAMACODE_DEFAULT_MODEL:-<none — always prompt>}"
        echo "   5) Reasoning level    : ${OLLAMACODE_REASONING}  (off|low|on)"
        echo "   6) Temperature        : ${OLLAMACODE_TEMPERATURE}"
        echo "   7) Permission mode    : ${OLLAMACODE_PERMISSION_MODE}"
        echo ""
        echo "  Ollama tuning"
        echo "   8) Max loaded models  : ${OLLAMA_MAX_LOADED_MODELS}"
        echo "   9) Parallel requests  : ${OLLAMA_NUM_PARALLEL}"
        echo "  10) Keep alive         : ${OLLAMA_KEEP_ALIVE}"
        echo "  11) Flash Attention    : ${OLLAMA_FLASH_ATTENTION}  (0|1)"
        echo "  12) KV cache type      : ${OLLAMA_KV_CACHE_TYPE}  (f16|q8_0|q4_0)"
        echo "  13) CUDA devices       : ${CUDA_VISIBLE_DEVICES}"
        echo "  14) Allowed origins    : ${OLLAMA_ORIGINS}"
        echo "  15) Max queue          : ${OLLAMA_MAX_QUEUE}"
        echo ""
        echo "  Actions"
        echo "  16) Show installed models + max context"
        echo "  17) View current ollama ps"
        echo "  18) Pull more models (Dirty Dozen TUI)"
        echo "  19) Install/update systemd override"
        echo "  20) Save and exit"
        echo "  21) Exit without saving"
        echo "════════════════════════════════════════════════════════════════"
        read -rp "Option: " choice
        case "${choice:-}" in
            1)  read -rp "Server mode [${OLLAMACODE_SERVER_MODE}]: " v
                [[ "${v:-}" =~ ^(session|systemd|off)$ ]] && OLLAMACODE_SERVER_MODE="$v" ;;
            2)  read -rp "Bind address [${OLLAMA_HOST}]: " v; [[ -n "${v:-}" ]] && OLLAMA_HOST="$v" ;;
            3)  read -rp "Port [${OLLAMA_PORT}]: " v; [[ "${v:-}" =~ ^[0-9]+$ ]] && OLLAMA_PORT="$v" ;;
            4)  read -rp "Default model tag (blank = always prompt): " v
                OLLAMACODE_DEFAULT_MODEL="${v:-}" ;;
            5)  read -rp "Reasoning [${OLLAMACODE_REASONING}]: " v
                [[ "${v:-}" =~ ^(off|low|on)$ ]] && OLLAMACODE_REASONING="$v" ;;
            6)  read -rp "Temperature [${OLLAMACODE_TEMPERATURE}]: " v
                [[ "${v:-}" =~ ^[0-9]+\.?[0-9]*$ ]] && OLLAMACODE_TEMPERATURE="$v" ;;
            7)  read -rp "Permission mode [${OLLAMACODE_PERMISSION_MODE}]: " v
                [[ -n "${v:-}" ]] && OLLAMACODE_PERMISSION_MODE="$v" ;;
            8)  read -rp "Max loaded models [${OLLAMA_MAX_LOADED_MODELS}]: " v
                [[ "${v:-}" =~ ^[0-9]+$ ]] && OLLAMA_MAX_LOADED_MODELS="$v" ;;
            9)  read -rp "Parallel requests [${OLLAMA_NUM_PARALLEL}]: " v
                [[ "${v:-}" =~ ^[0-9]+$ ]] && OLLAMA_NUM_PARALLEL="$v" ;;
           10)  read -rp "Keep alive [${OLLAMA_KEEP_ALIVE}]: " v; [[ -n "${v:-}" ]] && OLLAMA_KEEP_ALIVE="$v" ;;
           11)  read -rp "Flash Attention [${OLLAMA_FLASH_ATTENTION}]: " v
                [[ "${v:-}" =~ ^[01]$ ]] && OLLAMA_FLASH_ATTENTION="$v" ;;
           12)  read -rp "KV cache [${OLLAMA_KV_CACHE_TYPE}]: " v
                [[ "${v:-}" =~ ^(f16|q8_0|q4_0)$ ]] && OLLAMA_KV_CACHE_TYPE="$v" ;;
           13)  read -rp "CUDA devices [${CUDA_VISIBLE_DEVICES}]: " v; [[ -n "${v:-}" ]] && CUDA_VISIBLE_DEVICES="$v" ;;
           14)  read -rp "Allowed origins [${OLLAMA_ORIGINS}]: " v; [[ -n "${v:-}" ]] && OLLAMA_ORIGINS="$v" ;;
           15)  read -rp "Max queue [${OLLAMA_MAX_QUEUE}]: " v
                [[ "${v:-}" =~ ^[0-9]+$ ]] && OLLAMA_MAX_QUEUE="$v" ;;
           16)  echo ""; get_models | while read m; do
                    ctx="$(get_model_max_ctx "$m" 2>/dev/null || true)"
                    printf "  %-46s [max ctx: %s]\n" "$m" "${ctx:-?}"
                done ;;
           17)  ollama ps 2>/dev/null || echo "Ollama not running." ;;
           18)  pull_models_menu ;;
           19)  install_systemd_override || true ;;
           20)  save_settings; echo "Saved to $CONFIG_FILE"; return 0 ;;
           21)  echo "Exiting without saving."; return 1 ;; # Safe: caller handles
            *)  echo "Invalid selection." ;;
        esac
    done
}

save_settings() {
    cat > "$CONFIG_FILE" <<EOF
OLLAMA_HOST=${OLLAMA_HOST}
OLLAMA_PORT=${OLLAMA_PORT}
OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}
OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}
OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}
OLLAMA_FLASH_ATTENTION=${OLLAMA_FLASH_ATTENTION}
OLLAMA_KV_CACHE_TYPE=${OLLAMA_KV_CACHE_TYPE}
CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}
OLLAMA_ORIGINS=${OLLAMA_ORIGINS}
OLLAMA_MAX_QUEUE=${OLLAMA_MAX_QUEUE}
OLLAMACODE_SERVER_MODE=${OLLAMACODE_SERVER_MODE}
OLLAMACODE_DEFAULT_MODEL=${OLLAMACODE_DEFAULT_MODEL}
OLLAMACODE_REASONING=${OLLAMACODE_REASONING}
OLLAMACODE_TEMPERATURE=${OLLAMACODE_TEMPERATURE}
OLLAMACODE_PERMISSION_MODE=${OLLAMACODE_PERMISSION_MODE}
EOF
}

# ═══════════════════════════════════════════════════════════
#  REQUIRE TOOLS
require_tools() {
    local ok=1
    [[ ! -x "$CLI_BIN" ]] && {
        echo "Error: claw not found at $CLI_BIN" >&2
        echo "  Build: cd ~/claw-code/rust && cargo build --workspace" >&2
        ok=0
    }
    command -v python3 >/dev/null 2>&1 || { echo "Error: python3 required." >&2; ok=0; }
    command -v ollama  >/dev/null 2>&1 || { echo "Error: ollama CLI not found." >&2; ok=0; }
    [[ $ok -eq 0 ]] && exit 1
}

show_help() {
    cat <<'HELP'
Usage: ollamacode [options]

  --model MODEL        Use a specific installed model tag
  --ctx N              Override context window (default: model's reported max)
  --keep-alive VALUE   Override keep_alive (e.g. 10m, 2h, -1, 0)
  --reasoning LEVEL    Set reasoning level: off | low | on  (default: on)
  --temperature FLOAT  Set temperature 0.0–2.0  (default: 0.2)
  --pull               Open Dirty Dozen model puller before selection
  --list               List installed models and exit
  --server-mode MODE   Force server mode: session | systemd | off
  --setup              Open configuration menu
  --help               Show this help

Examples:
  ollamacode
  ollamacode --pull
  ollamacode --model qwen3:27b-q4_k_m
  ollamacode --setup
HELP
}

# ═══════════════════════════════════════════════════════════
#  MAIN
MODEL_ARG=""
CTX_OVERRIDE=""
KEEP_ALIVE_OVERRIDE=""
REASONING_OVERRIDE=""
TEMP_OVERRIDE=""
DO_PULL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --setup)       setup_menu || true; exit 0 ;;
        --list)        get_models; exit 0 ;;
        --pull)        DO_PULL=1; shift ;;
        --model)       MODEL_ARG="$2"; shift 2 ;;
        --ctx)         CTX_OVERRIDE="$2"; shift 2 ;;
        --keep-alive)  KEEP_ALIVE_OVERRIDE="$2"; shift 2 ;;
        --reasoning)   REASONING_OVERRIDE="$2"; shift 2 ;;
        --temperature) TEMP_OVERRIDE="$2"; shift 2 ;;
        --server-mode) OLLAMACODE_SERVER_MODE="$2"; shift 2 ;;
        --help|-h)     show_help; exit 0 ;;
        *)             echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

require_tools

# Apply CLI overrides
[[ -n "${REASONING_OVERRIDE:-}" ]] && OLLAMACODE_REASONING="$REASONING_OVERRIDE"
[[ -n "${TEMP_OVERRIDE:-}"      ]] && OLLAMACODE_TEMPERATURE="$TEMP_OVERRIDE"

# Optional pre-pull step
(( DO_PULL )) && pull_models_menu

# ── Start Ollama in session mode with a safe initial context ────────
if [[ "${OLLAMACODE_SERVER_MODE}" == "session" ]]; then
    start_server "131072" || { echo "Server start failed — exiting." >&2; exit 1; }
fi

if ! check_server; then
    echo "Error: Ollama not reachable at $OLLAMA_BASE_URL" >&2
    exit 1
fi

# ── Pick model (FIXED: only model name to stdout) ───────────────────
if [[ -z "${MODEL_ARG:-}" ]]; then
    if [[ -n "${OLLAMACODE_DEFAULT_MODEL:-}" ]]; then
        read -rp "Use default model [${OLLAMACODE_DEFAULT_MODEL}]? (Y/n/setup): " ans
        case "${ans:-Y}" in
            [Nn]*)       MODEL_ARG="$(select_model)" ;;
            setup|SETUP) setup_menu || true; MODEL_ARG="$(select_model)" ;;
            *)           MODEL_ARG="$OLLAMACODE_DEFAULT_MODEL" ;;
        esac
    else
        MODEL_ARG="$(select_model)"
    fi
fi

# ── Context — default to model's own max ────────────────────────────
MODEL_MAX_CTX="$(get_model_max_ctx "$MODEL_ARG" 2>/dev/null || true)"
DEFAULT_CTX="${CTX_OVERRIDE:-${MODEL_MAX_CTX:-131072}}"

echo ""
[[ -n "${MODEL_MAX_CTX:-}" ]] \
    && echo "  Model max context : ${MODEL_MAX_CTX} tokens" \
    || echo "  (could not detect model max context — defaulting to ${DEFAULT_CTX})"

read -rp "  Context window (num_ctx) [${DEFAULT_CTX}]: " ctx_in
NUM_CTX="${ctx_in:-$DEFAULT_CTX}"

# ── Restart server with the exact session context ──────────────────
if [[ "${OLLAMACODE_SERVER_MODE}" == "session" ]]; then
    stop_server
    start_server "$NUM_CTX" || { echo "Could not restart server with ctx=${NUM_CTX}" >&2; exit 1; }
fi

# ── Keep-alive ─────────────────────────────────────────────────────
EFFECTIVE_KA="${KEEP_ALIVE_OVERRIDE:-${OLLAMA_KEEP_ALIVE}}"
read -rp "  Keep alive [${EFFECTIVE_KA}]: " keep_in
EFFECTIVE_KA="${keep_in:-$EFFECTIVE_KA}"

# ── GPU residency check ────────────────────────────────────────────
verify_gpu_residency "$MODEL_ARG"

# ── FIX: Use raw model name (no ollama/ prefix) ────────────────────
export OPENAI_BASE_URL="${OLLAMA_BASE_URL}/v1"
export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"

echo ""
echo "🚀 Launching claw"
echo "   Model            : $MODEL_ARG"
echo "   Context          : $NUM_CTX"
echo "   Keep alive       : $EFFECTIVE_KA"
echo "   Reasoning        : $OLLAMACODE_REASONING"
echo "   Temperature      : $OLLAMACODE_TEMPERATURE"
echo "   Permission mode  : $OLLAMACODE_PERMISSION_MODE"
echo "   Ollama server    : $OLLAMA_BASE_URL"
echo ""

# ── FIX: Export all env vars before exec ───────────────────────────
exec "$CLI_BIN" \
    --model "$MODEL_ARG" \
    --permission-mode "$OLLAMACODE_PERMISSION_MODE"

LAUNCHER_EOF

    chmod +x "$LAUNCHER"
}

# ═══════════════════════════════════════════════════════════
#  INSTALLER MAIN
echo "=== Ollamacode Server Installer ==="

VRAM_MB="$(get_vram_mb)"
RAM_MB="$(get_ram_mb)"
VRAM_GB=$(( VRAM_MB / 1024 ))
RAM_GB=$(( RAM_MB / 1024 ))

echo "  NVIDIA VRAM : ${VRAM_GB} GiB  (${VRAM_MB} MiB)"
echo "  System RAM  : ${RAM_GB} GiB  (${RAM_MB} MiB)"

if is_wsl; then
    echo ""
    echo "  ⚠️  WSL2 detected — RAM shown is capped (default: 50% of host RAM)."
    echo "     To expose the full physical RAM, add to C:\\Users\\<you>\\.wslconfig:"
    echo "       [wsl2]"
    echo "       memory=480GB"
    echo "     Then: wsl --shutdown"
fi

echo ""
echo "  Ollama GPU+CPU offloading:"
echo "    • GPU layers fill VRAM first; remaining layers offload to CPU RAM automatically."
echo "    • q8_0 KV cache halves KV memory vs f16 with negligible quality loss."
echo "    • 128k context needs ~16–40 GiB KV RAM depending on model architecture."
echo ""

save_config
generate_launcher

# ── Ensure ~/bin is in PATH ─────────────────────────────────────────
SHELL_RC=""
case "${SHELL:-bash}" in
    */zsh)  SHELL_RC="$HOME/.zshrc" ;;
    */fish) SHELL_RC="$HOME/.config/fish/config.fish" ;;
    *)      SHELL_RC="$HOME/.bashrc" ;;
esac

if ! grep -q 'HOME/bin' "${SHELL_RC}" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# Added by setup_ollamacode_server.sh" >> "$SHELL_RC"
    if [[ "${SHELL:-}" == */fish ]]; then
        echo "fish_add_path \$HOME/bin" >> "$SHELL_RC"
    else
        echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_RC"
    fi
    echo "  ✓ Added ~/bin to PATH in ${SHELL_RC}"
else
    echo "  ✓ ~/bin already in PATH (${SHELL_RC})"
fi

# Symlink into /usr/local/bin so it's usable immediately
if ln -sf "$LAUNCHER" /usr/local/bin/ollamacode 2>/dev/null \
   || ln -sf "$LAUNCHER" /usr/local/bin/ollamacode 2>/dev/null; then
    echo "  ✓ Symlinked to /usr/local/bin/ollamacode (usable immediately)"
else
    echo "  ℹ  Cannot write to /usr/local/bin — run this to use ollamacode now:"
    echo "     export PATH=\"\$HOME/bin:\$PATH\""
fi

if [[ "${OLLAMACODE_SERVER_MODE:-session}" == "systemd" ]]; then
    install_systemd_override
else
    echo ""
    echo "  ℹ  Server mode: session (Ollama starts/stops with ollamacode)."
    echo "     For persistent LAN hosting: ollamacode --setup → option 1 → systemd"
fi

LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<unknown>')"

echo ""
echo "✓ Launcher : $LAUNCHER"
echo "✓ Config   : $CONFIG_FILE"
echo ""
echo "🎉 Installation complete!"
echo ""
echo "Usage:"
echo "  ollamacode               — start, pick model, launch claw (workstation mode)"
echo "  ollamacode --pull        — open Dirty Dozen model puller first"
echo "  ollamacode --setup       — configure all settings"
echo "  ollamacode --model qwen3:27b-q4_k_m"
echo "  ollamacode --help        — full option list"
echo ""
echo "  LAN address : http://${LOCAL_IP}:${OLLAMA_PORT}"
