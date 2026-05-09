#!/usr/bin/env bash
# setup_opencode_shortcut.sh
#
# Installs the `opencode` launcher for claw-code with OpenRouter.
# Sets DeepSeek V4 Pro as the recommended default, or lets you choose
# from a curated catalogue or live OpenRouter tool‑capable models.

set -euo pipefail

echo "Installing opencode launcher..."

mkdir -p "$HOME/bin"
mkdir -p "$HOME/.config/opencode"

cat > "$HOME/bin/opencode" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="$HOME/.config/opencode"
ENV_FILE="$CONFIG_DIR/.env"
MODEL_FILE="$CONFIG_DIR/selected_model"
CACHE_FILE="$CONFIG_DIR/openrouter_models_cache.tsv"
CACHE_TTL_SECONDS=$((60 * 60 * 6))

REPO_ROOT="${CLAW_CODE_ROOT:-$HOME/claw-code}"
CLI_BIN="$REPO_ROOT/rust/target/debug/claw"
OPENROUTER_MODELS_API="https://openrouter.ai/api/v1/models?supported_parameters=tools"

mkdir -p "$CONFIG_DIR"

if [ ! -x "$CLI_BIN" ]; then
  echo
  echo "ERROR: claw binary not found or not executable:"
  echo "  $CLI_BIN"
  echo
  echo "Build claw-code first:"
  echo
  echo "  cd $REPO_ROOT/rust"
  echo "  cargo build --workspace"
  echo
  exit 1
fi

# load existing .env
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# ask for OpenRouter API key if missing
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo
  echo "OpenRouter API key not configured."
  echo
  read -rsp "Paste OPENROUTER_API_KEY: " OPENROUTER_API_KEY
  echo
  # trim whitespace
  OPENROUTER_API_KEY="$(echo "$OPENROUTER_API_KEY" | tr -d '[:space:]')"

  if [ -z "$OPENROUTER_API_KEY" ]; then
    echo "No key entered."
    exit 1
  fi

  cat > "$ENV_FILE" <<ENVEOF
OPENROUTER_API_KEY=$OPENROUTER_API_KEY
ENVEOF
  chmod 600 "$ENV_FILE"
  echo
  echo "Saved: $ENV_FILE"
fi

############################################
# curated model catalogue
############################################
MODELS=(
"anthropic/claude-opus-4.7|Claude Opus 4.7|flagship|reasoning, coding, writing, autonomous agents|1M ctx|\$5.00/M in | \$25.00/M out|multimodal dense|n/a public|medium|Best premium agentic model"
"~anthropic/claude-opus-latest|Claude Opus Latest|flagship alias|reasoning, coding, writing|1M ctx|\$5.00/M in | \$25.00/M out|multimodal routed|n/a public|medium|Stable family alias"
"~anthropic/claude-sonnet-latest|Claude Sonnet Latest|top-tier|coding, editing, writing, agent loops|1M ctx|\$3.00/M in | \$15.00/M out|multimodal routed|n/a public|fast|Excellent default for claw-code"
"~anthropic/claude-haiku-latest|Claude Haiku Latest|value|fast editing, tool calls, routing|200K ctx|\$1.00/M in | \$5.00/M out|multimodal routed|n/a public|very fast|Great lightweight sub-agent"
"openai/gpt-5.5|OpenAI GPT-5.5|top-tier|reasoning, coding, synthesis|1.05M ctx|\$5.00/M in | \$30.00/M out|multimodal dense|n/a public|medium|Frontier all-rounder"
"openai/gpt-5.5-pro|OpenAI GPT-5.5 Pro|flagship|hard reasoning, critical coding|1.05M ctx|\$30.00/M in | \$180.00/M out|multimodal dense|n/a public|slow|Use when accuracy matters more"
"~google/gemini-pro-latest|Gemini Pro Latest|top-tier|1M analysis, repo digestion|1.05M ctx|\$2.00/M in | \$12.00/M out|multimodal routed|n/a public|fast|Strong long-context value"
"~google/gemini-flash-latest|Gemini Flash Latest|value|cheap long-context, planning|1.05M ctx|\$0.50/M in | \$3.00/M out|multimodal routed|n/a public|very fast|Cheap 1M option"
"deepseek/deepseek-v4-pro|DeepSeek V4 Pro|top-tier value|coding, reasoning, long-context agents|1.05M ctx|\$0.435/M in | \$0.87/M out|MoE|1.6T/49B active|fast|Outstanding price-performance"
"deepseek/deepseek-v4-flash|DeepSeek V4 Flash|budget|cheap coding, search loops|1.05M ctx|\$0.14/M in | \$0.28/M out|MoE|284B/13B active|very fast|Exceptional value"
"moonshotai/kimi-k2.6|Kimi K2.6|top-tier value|long-horizon coding|262K ctx|\$0.74/M in | \$3.49/M out|multimodal|n/a public|fast|Strong coding model"
"qwen/qwen3.6-max-preview|Qwen3.6 Max Preview|top-tier value|agentic coding, reasoning|262K ctx|\$1.04/M in | \$6.24/M out|MoE|~1T total|fast|Premium Qwen agent"
"qwen/qwen3.5-plus-20260420|Qwen3.5 Plus|value|1M coding, reasoning|1M ctx|\$0.40/M in | \$2.40/M out|multimodal|n/a public|fast|Attractive 1M value"
"qwen/qwen3.6-flash|Qwen3.6 Flash|budget|cheap 1M scans, planning|1M ctx|\$0.25/M in | \$1.50/M out|multimodal|n/a public|very fast|Budget long-context"
"qwen/qwen3.6-35b-a3b|Qwen3.6 35B A3B|budget+|coding, reasoning, economical|262K ctx|\$0.1612/M in | \$0.9653/M out|MoE|35B/3B active|fast|Great open-weight value"
"x-ai/grok-4.3|Grok 4.3|top-tier|reasoning, agent workflows, 1M|1M ctx|\$1.25/M in | \$2.50/M out|multimodal|n/a public|fast|Premium/value crossover"
"xiaomi/mimo-v2.5-pro|MiMo V2.5 Pro|top-tier value|agentic coding, SWE-style|1.05M ctx|\$1.00/M in | \$3.00/M out|text|n/a public|fast|Strong benchmark coder"
"xiaomi/mimo-v2.5|MiMo V2.5|value|cheap multimodal agents|1.05M ctx|\$0.40/M in | \$2.00/M out|omnimodal|n/a public|fast|Half the price of Pro"
"inclusionai/ling-2.6-flash|Ling 2.6 Flash|ultra-budget|cheap agent workers, triage|262K ctx|\$0.08/M in | \$0.24/M out|MoE|104B/7.4B active|very fast|Excellent parallel sub-agent"
"ibm-granite/granite-4.1-8b|IBM Granite 4.1 8B|ultra-budget|basic coding, enterprise-safe|131K ctx|\$0.05/M in | \$0.10/M out|dense|8B|fast|Very cheap structured tasks"
"poolside/laguna-m.1:free|Poolside Laguna M.1 (free)|free|coding experiments|131K ctx|\$0.00/M in | \$0.00/M out|coding agent model|n/a|fast|Free coding-agent"
"openrouter/owl-alpha|OpenRouter Owl Alpha|free|agentic workloads, long context|1.05M ctx|\$0.00/M in | \$0.00/M out|foundation model|n/a|fast|Free long-context agentic"
)
# live model caching (needs curl + python3)
REQUIRE_LIVE_TOOLS=1
command -v curl >/dev/null 2>&1 || REQUIRE_LIVE_TOOLS=0
command -v python3 >/dev/null 2>&1 || REQUIRE_LIVE_TOOLS=0

refresh_openrouter_cache() {
  [ "$REQUIRE_LIVE_TOOLS" -eq 1 ] || return 1
  local tmp_json tmp_tsv
  tmp_json="$(mktemp)"
  tmp_tsv="$(mktemp)"
  if ! curl -fsSL "$OPENROUTER_MODELS_API" -o "$tmp_json"; then
    rm -f "$tmp_json" "$tmp_tsv"
    return 1
  fi
  python3 - <<'PY' "$tmp_json" "$tmp_tsv"
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, 'r', encoding='utf-8') as f:
    data = json.load(f).get('data', [])
def per_m(v):
    try: return f"${float(v)*1_000_000:.4f}/M"
    except: return "n/a"
def speed_hint(ctx):
    return "fast" if ctx < 200000 else "varies"
rows = []
for m in data:
    if "tools" not in set(m.get("supported_parameters") or []):
        continue
    mid = m.get("id","")
    name = m.get("name",mid)
    ctx = int(m.get("context_length") or 0)
    pricing = m.get("pricing") or {}
    arch = m.get("architecture") or {}
    rows.append((
        mid, name, ctx,
        per_m(pricing.get("prompt")),
        per_m(pricing.get("completion")),
        arch.get("modality","text->text"),
        arch.get("tokenizer","unknown"),
        (m.get("description") or "").replace("\n"," ")[:160],
        speed_hint(ctx)
    ))
rows.sort(key=lambda r: (r[2], r[0]), reverse=True)
with open(dst, "w", encoding="utf-8") as out:
    for r in rows:
        out.write("\t".join(map(str, r)) + "\n")
PY
  mv "$tmp_tsv" "$CACHE_FILE"
  rm -f "$tmp_json"
}

cache_is_fresh() {
  [ -f "$CACHE_FILE" ] || return 1
  local now modified age
  now="$(date +%s)"
  modified="$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)"
  age=$((now - modified))
  [ "$age" -lt "$CACHE_TTL_SECONDS" ]
}

maybe_refresh_cache() {
  cache_is_fresh || refresh_openrouter_cache || true
}

show_curated_models() {
  echo
  echo "=============================================================="
  echo " Curated OpenRouter Models for claw-code"
  echo "=============================================================="
  echo
  echo "Recommended defaults by use:"
  echo "  - Best balanced default:    ~anthropic/claude-sonnet-latest"
  echo "  - Best premium default:     anthropic/claude-opus-4.7"
  echo "  - Best cheap 1M context:    deepseek/deepseek-v4-flash"
  echo "  - Best value 1M context:    deepseek/deepseek-v4-pro"
  echo "  - Best cheap multimodal:    ~google/gemini-flash-latest"
  echo "  - Best budget sub-agent:    inclusionai/ling-2.6-flash"
  echo

  local i=1
  for row in "${MODELS[@]}"; do
    IFS='|' read -r id name tier best_for context pricing arch params speed notes <<< "$row"
    printf "%2d) %-32s %s\n" "$i" "$name" "$context"
    echo "    model:      $id"
    echo "    tier:       $tier"
    echo "    best for:   $best_for"
    echo "    pricing:    $pricing"
    echo "    arch:       $arch"
    echo "    params:     $params"
    echo "    speed:      $speed"
    echo "    notes:      $notes"
    echo
    ((i++))
  done
}

show_live_models() {
  maybe_refresh_cache
  if [ ! -f "$CACHE_FILE" ]; then
    echo
    echo "Live OpenRouter catalog unavailable (no curl/python3 or network issue)."
    echo "You can still choose from curated models or enter a custom model id."
    echo
    return 1
  fi
  echo
  echo "=============================================================="
  echo " Live OpenRouter Tool-Capable Models (top 40 by context)"
  echo "=============================================================="
  echo
  local i=1
  while IFS=$'\t' read -r id name ctx in_p out_p modality tok desc speed; do
    printf "%2d) %-32s %s ctx\n" "$i" "$name" "$ctx"
    echo "    model:      $id"
    echo "    pricing:    $in_p in | $out_p out"
    echo "    arch:       $modality"
    echo "    tokenizer:  $tok"
    echo "    speed:      $speed"
    echo "    notes:      $desc"
    echo
    i=$((i + 1))
    [ "$i" -le 40 ] || break
  done < "$CACHE_FILE"
}

pick_from_live_models() {
  maybe_refresh_cache
  [ -f "$CACHE_FILE" ] || return 1
  mapfile -t LIVE_MODELS < <(cut -f1 "$CACHE_FILE" | head -n 200)
  show_live_models || return 1
  read -rp "Choose live model number (or blank to cancel): " pick
  [ -n "$pick" ] || return 1
  if [[ ! "$pick" =~ ^[0-9]+$ ]]; then
    echo "Invalid selection."; return 1
  fi
  local idx=$((pick - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#LIVE_MODELS[@]}" ]; then
    echo "Invalid selection."; return 1
  fi
  MODEL="${LIVE_MODELS[$idx]}"
  return 0
}

choose_model() {
  show_curated_models
  echo " l) browse live OpenRouter models"
  echo " r) refresh live OpenRouter cache"
  echo " c) custom model"
  echo " q) quit"
  echo
}

# --- argument parsing ---
MODEL="${1:-}"

# --- load saved default if no model given ---
if [ -z "$MODEL" ] && [ -f "$MODEL_FILE" ]; then
  SAVED="$(cat "$MODEL_FILE")"
  echo
  echo "Saved default model: $SAVED"
  read -rp "Use saved model? [Y/n]: " yn
  yn="${yn:-Y}"
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    MODEL="$SAVED"
  fi
fi

# --- if still no model, offer DeepSeek V4 Pro as quick default ---
if [ -z "$MODEL" ]; then
  echo
  echo "No model selected. DeepSeek V4 Pro is recommended for best value."
  read -rp "Set deepseek/deepseek-v4-pro as default? [Y/n]: " quick
  quick="${quick:-Y}"
  if [[ "$quick" =~ ^[Yy]$ ]]; then
    MODEL="deepseek/deepseek-v4-pro"
    echo "$MODEL" > "$MODEL_FILE"
    echo "Default saved: $MODEL"
  fi
fi

# --- interactive selection if still empty ---
if [ -z "$MODEL" ]; then
  choose_model
  read -rp "Choose model: " pick
  case "$pick" in
    q) exit 0 ;;
    c) read -rp "Enter OpenRouter model id: " MODEL ;;
    r)
      echo; echo "Refreshing live OpenRouter catalog..."
      refresh_openrouter_cache || true
      choose_model
      read -rp "Choose model: " pick2
      case "$pick2" in
        l) pick_from_live_models || exit 1 ;;
        c) read -rp "Enter OpenRouter model id: " MODEL ;;
        [0-9]*)
          idx=$((pick2 - 1))
          if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#MODELS[@]}" ]; then
            echo "Invalid selection."; exit 1
          fi
          IFS='|' read -r MODEL _ <<< "${MODELS[$idx]}" ;;
        *) echo "Invalid selection."; exit 1 ;;
      esac
      ;;
    l) pick_from_live_models || exit 1 ;;
    [0-9]*)
      idx=$((pick - 1))
      if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#MODELS[@]}" ]; then
        echo "Invalid selection."; exit 1
      fi
      IFS='|' read -r MODEL _ <<< "${MODELS[$idx]}" ;;
    *) echo "Invalid selection."; exit 1 ;;
  esac

  echo
  read -rp "Save as default? [Y/n]: " save
  save="${save:-Y}"
  if [[ "$save" =~ ^[Yy]$ ]]; then
    echo "$MODEL" > "$MODEL_FILE"
    echo "Default saved: $MODEL"
  fi
fi

# --- launch claw-code ---
export OPENAI_BASE_URL="https://openrouter.ai/api/v1"
export OPENAI_API_KEY="$OPENROUTER_API_KEY"
export HTTP_REFERER="https://localhost"
export X_TITLE="claw-code"

echo
echo "=============================================================="
echo "Launching claw-code"
echo "=============================================================="
echo "dir:   $(pwd)"
echo "model: $MODEL"
echo "base:  $OPENAI_BASE_URL"
echo

exec "$CLI_BIN" \
  --model "$MODEL" \
  --permission-mode workspace-write
LAUNCHER_EOF

chmod +x "$HOME/bin/opencode"

# --- add ~/bin to PATH permanently if not already there ---
add_to_path() {
  local profile="$HOME/.bashrc"
  if [ -f "$profile" ]; then
    if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$profile"; then
      echo '' >> "$profile"
      echo '# Added by opencode installer' >> "$profile"
      echo 'export PATH="$HOME/bin:$PATH"' >> "$profile"
      echo "Added ~/bin to PATH in $profile"
    else
      echo "~/bin already in PATH in $profile"
    fi
  else
    echo "No ~/.bashrc found. Please add this line to your shell profile manually:"
    echo '  export PATH="$HOME/bin:$PATH"'
  fi
}

if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
  echo
  echo "~/bin is not in your current PATH."
  add_to_path
  echo
  echo "To use opencode immediately, run:"
  echo "  source ~/.bashrc"
  echo "or start a new terminal session."
  echo
fi

echo
echo "=============================================================="
echo " Setup complete"
echo "=============================================================="
echo "Reload your shell or start a new terminal"
echo "source ~/.bashrc"
echo "Run:"
echo "  opencode"
echo
echo "or directly with a model:"
echo "  opencode deepseek/deepseek-v4-pro"
echo