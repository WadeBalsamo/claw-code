#!/usr/bin/env bash
# setup_opencode_shortcut_v3.sh
#
# Installs the `opencode` launcher for claw-code with OpenRouter.
#
# Browser improvements over v2:
#   - Multi-token filter input on one line:  p deepseek k coding $ .15 x 1000000
#   - All matching models shown, paginated (n = next, b = back)
#   - fzf fuzzy picker used automatically when fzf is installed
#   - clear-screen TUI redraw on every change
#   - Much richer auto-derived categories (provider aliases, capability keywords)
#   - No hardcoded model list; only one hardcoded default

set -euo pipefail

echo "Installing opencode launcher..."
mkdir -p "$HOME/bin"
mkdir -p "$HOME/.config/opencode"

cat > "$HOME/bin/opencode" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
set -euo pipefail

# ── paths & constants ─────────────────────────────────────────────────────────
CONFIG_DIR="$HOME/.config/opencode"
ENV_FILE="$CONFIG_DIR/.env"
MODEL_FILE="$CONFIG_DIR/selected_model"
RECENTS_FILE="$CONFIG_DIR/recent_models"
CACHE_FILE="$CONFIG_DIR/openrouter_models_cache.tsv"
CACHE_TTL=$(( 60 * 60 * 6 ))   # 6 hours
MAX_RECENTS=5
DEFAULT_MODEL="deepseek/deepseek-v4-pro"
REPO_ROOT="${CLAW_CODE_ROOT:-$HOME/claw-code}"
CLI_BIN="$REPO_ROOT/rust/target/debug/claw"
OPENROUTER_API="https://openrouter.ai/api/v1/models?supported_parameters=tools"
PAGE_SIZE=18    # results per page in TUI
MODEL=""

mkdir -p "$CONFIG_DIR"

# ── binary check ──────────────────────────────────────────────────────────────
if [ ! -x "$CLI_BIN" ]; then
  echo; echo "ERROR: claw binary not found: $CLI_BIN"
  echo "Build with: cd $REPO_ROOT/rust && cargo build --workspace"
  exit 1
fi

# ── API key ───────────────────────────────────────────────────────────────────
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo; echo "OpenRouter API key not configured."
  read -rsp "Paste OPENROUTER_API_KEY: " OPENROUTER_API_KEY; echo
  OPENROUTER_API_KEY="$(echo "$OPENROUTER_API_KEY" | tr -d '[:space:]')"
  [ -n "$OPENROUTER_API_KEY" ] || { echo "No key entered."; exit 1; }
  printf 'OPENROUTER_API_KEY=%s\n' "$OPENROUTER_API_KEY" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"; echo "Saved: $ENV_FILE"
fi

# ── tool availability ─────────────────────────────────────────────────────────
HAS_TOOLS=1
command -v curl    >/dev/null 2>&1 || HAS_TOOLS=0
command -v python3 >/dev/null 2>&1 || HAS_TOOLS=0
HAS_FZF=0
command -v fzf     >/dev/null 2>&1 && HAS_FZF=1

# ── display helpers ───────────────────────────────────────────────────────────
tui_clear() {
  command -v tput >/dev/null 2>&1 && tput clear 2>/dev/null \
    || printf '\033[2J\033[H'
}

fmt_ctx() {
  local n="${1:-0}"
  if   [ "$n" -ge 1000000 ]; then awk -v n="$n" 'BEGIN{printf "%.0fM",n/1000000}'
  elif [ "$n" -ge 1000 ];    then printf '%dK' $(( n / 1000 ))
  else                            printf '%d'  "$n"
  fi
}

fmt_cost() { printf '$%.4f/M' "${1:-0}"; }

# bold / dim via tput, fall back to plain
bold() { command -v tput >/dev/null 2>&1 && printf '%s%s%s' "$(tput bold 2>/dev/null)" "$*" "$(tput sgr0 2>/dev/null)" || printf '%s' "$*"; }

# ── recents ───────────────────────────────────────────────────────────────────
save_recent() {
  local m="$1"; [ -n "$m" ] || return 0
  { printf '%s\n' "$m"
    [ -f "$RECENTS_FILE" ] && cat "$RECENTS_FILE" || true
  } | awk 'NF && !seen[$0]++' | head -n "$MAX_RECENTS" > "$RECENTS_FILE.tmp"
  mv "$RECENTS_FILE.tmp" "$RECENTS_FILE"
}

# ── catalog cache ─────────────────────────────────────────────────────────────
# TSV columns (1-based for awk):
#   1:id  2:name  3:provider  4:ctx  5:in_cost  6:out_cost  7:categories  8:modality  9:description
cache_fresh() {
  [ -f "$CACHE_FILE" ] || return 1
  local age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
  [ "$age" -lt "$CACHE_TTL" ]
}

refresh_cache() {
  if [ "$HAS_TOOLS" -eq 0 ]; then
    echo "curl and python3 are required to fetch the live catalog."; return 1
  fi
  echo "Fetching OpenRouter tool-capable model catalog..."
  local tj tt
  tj="$(mktemp)" tt="$(mktemp)"
  if ! curl -fsSL --max-time 20 "$OPENROUTER_API" -o "$tj" 2>/dev/null; then
    rm -f "$tj" "$tt"; echo "Network error."; return 1
  fi
  python3 - "$tj" "$tt" <<'PY'
import json, sys

def flt(v):
    try:    return float(v)
    except: return 0.0

# Rich category derivation from id, name, description, pricing, context
def derive_cats(mid, name, desc, ctx, in_c):
    t = ' '.join([mid, name, desc]).lower()
    c = set()

    # --- provider family ---
    prov = mid.split('/')[0].lower() if '/' in mid else 'other'
    c.add(prov)

    # Common aliases so "qwen" matches qwen/* models etc.
    FAMILY_ALIASES = {
        'anthropic':  ['claude'],
        'openai':     ['gpt-', 'o1-', 'o3-', 'o4-'],
        'google':     ['gemini', 'palm'],
        'meta-llama': ['llama'],
        'mistralai':  ['mistral', 'mixtral', 'codestral'],
        'deepseek':   ['deepseek'],
        'qwen':       ['qwen'],
        'x-ai':       ['grok'],
        'cohere':     ['command'],
        'moonshotai': ['kimi'],
        'xiaomi':     ['mimo'],
        'nvidia':     ['nvidia', 'nemotron'],
        'microsoft':  ['phi-', 'wizardlm'],
        'amazon':     ['nova', 'titan'],
        'ibm-granite':['granite'],
        'perplexity': ['r1-', 'sonar'],
        'together':   ['together'],
        'nousresearch':['hermes', 'nous'],
    }
    for fam, keywords in FAMILY_ALIASES.items():
        if prov == fam or any(k in t for k in keywords):
            c.add(fam)

    # --- context tier ---
    if   ctx >= 1_000_000: c.add('long-context')
    elif ctx >= 128_000:   c.add('large-context')

    # --- price tier ---
    if   in_c == 0:      c.add('free')
    elif in_c <= 0.30:   c.add('budget')
    elif in_c <= 2.00:   c.add('value')
    elif in_c <= 8.00:   c.add('balanced')
    else:                c.add('premium')

    # --- capability keywords ---
    CAPS = [
        # coding
        ('cod',          'coding'),
        ('program',      'coding'),
        ('software',     'coding'),
        ('engineer',     'coding'),
        ('debug',        'coding'),
        ('swe-',         'coding'),
        ('develo',       'coding'),
        ('script',       'coding'),
        # reasoning
        ('reason',       'reasoning'),
        ('math',         'reasoning'),
        ('logic',        'reasoning'),
        ('think',        'reasoning'),
        ('analyt',       'reasoning'),
        ('chain-of',     'reasoning'),
        ('stem',         'reasoning'),
        # agents / tools
        ('agent',        'agents'),
        ('agentic',      'agents'),
        ('tool',         'agents'),
        ('function call','agents'),
        ('autonomous',   'agents'),
        ('workflow',     'agents'),
        ('orchestrat',   'agents'),
        # multimodal
        ('vision',       'multimodal'),
        ('image',        'multimodal'),
        ('multimodal',   'multimodal'),
        ('visual',       'multimodal'),
        ('video',        'multimodal'),
        ('audio',        'multimodal'),
        ('omni',         'multimodal'),
        ('vlm',          'multimodal'),
        # writing / creative
        ('writ',         'writing'),
        ('creat',        'writing'),
        ('story',        'writing'),
        ('content',      'writing'),
        ('copywrite',    'writing'),
        # instruct / chat
        ('instruct',     'instruct'),
        ('chat',         'chat'),
        ('conversati',   'chat'),
        ('assistant',    'chat'),
        # search / RAG
        ('search',       'search'),
        ('retriev',      'search'),
        ('rag',          'search'),
        # fast / flash
        ('flash',        'fast'),
        ('turbo',        'fast'),
        ('mini',         'fast'),
        ('lite',         'fast'),
        ('haiku',        'fast'),
        # large / flagship
        ('opus',         'flagship'),
        ('ultra',        'flagship'),
        ('pro',          'flagship'),
    ]
    for kw, cat in CAPS:
        if kw in t:
            c.add(cat)

    return ','.join(sorted(c))


src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding='utf-8') as f:
    models = json.load(f).get('data', [])

rows = []
for m in models:
    if 'tools' not in set(m.get('supported_parameters') or []):
        continue
    mid   = m.get('id', '')
    name  = m.get('name', mid)
    ctx   = int(m.get('context_length') or 0)
    p     = m.get('pricing') or {}
    arch  = m.get('architecture') or {}
    in_c  = flt(p.get('prompt'))     * 1_000_000
    out_c = flt(p.get('completion')) * 1_000_000
    desc  = (m.get('description') or '').replace('\n', ' ').strip()[:200]
    prov  = mid.split('/')[0] if '/' in mid else 'other'
    cats  = derive_cats(mid, name, desc, ctx, in_c)
    rows.append((mid, name, prov, ctx, in_c, out_c, cats,
                 arch.get('modality', 'text->text'), desc))

# sort: free & cheap first, then largest context within tier
rows.sort(key=lambda r: (r[4], -r[3]))

with open(dst, 'w', encoding='utf-8') as out:
    for r in rows:
        out.write('\t'.join([
            r[0], r[1], r[2], str(r[3]),
            f'{r[4]:.4f}', f'{r[5]:.4f}',
            r[6], r[7], r[8]
        ]) + '\n')
PY
  mv "$tt" "$CACHE_FILE"; rm -f "$tj"
  printf 'Catalog cached: %d tool-capable models → %s\n' "$(wc -l < "$CACHE_FILE")" "$CACHE_FILE"
}

maybe_refresh() { cache_fresh || refresh_cache || true; }

# ── filtering ──────────────────────────────────────────────────────────────────
# Outputs all matching TSV rows (no arbitrary cap – caller paginates).
filter_catalog() {
  local prov="$1" cat="$2" max_in="$3" min_ctx="$4" term="$5"
  [ -f "$CACHE_FILE" ] || return 0
  awk -F'\t' \
    -v p="$prov" -v c="$cat" -v mi="$max_in" -v mc="$min_ctx" -v s="$term" '
    BEGIN { IGNORECASE=1 }
    {
      ok = 1
      if (p  != "" && $3 !~ p)                   ok = 0
      if (c  != "" && $7 !~ c)                   ok = 0
      if (s  != "" && ($1 " " $2 " " $9) !~ s)  ok = 0
      if (mi != "" && ($5 + 0) > (mi + 0))       ok = 0
      if (mc != "" && ($4 + 0) < (mc + 0))       ok = 0
      if (ok) print
    }
  ' "$CACHE_FILE"
}

# ── multi-token input parser ───────────────────────────────────────────────────
# Parses a single input line containing any combination of filter tokens and
# one optional action.  Updates f_* filter variables in the caller's scope.
#
# Sets ACTION to one of: filter  quit  clear  refresh  next  back  select  redraw
# Sets ACTION_ARG to the argument for "select".
#
# Supported tokens:
#   p <provider>   k <category>   $ <max_in>   x <min_ctx>
#   s <term…>      (s consumes the rest of the line)
#   m <n>          select result number n
#   a              clear all filters (can be combined: a p deepseek)
#   r              refresh catalog
#   n / b          next / back page  (standalone only)
#   q              quit
parse_input() {
  local line="$1"
  ACTION="filter"; ACTION_ARG=""

  # Strip leading/trailing whitespace and collapse runs
  local trimmed
  trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  # --- standalone single-word commands ---
  case "$trimmed" in
    q|Q)         ACTION="quit";    return ;;
    r|R)         ACTION="refresh"; return ;;
    n|N)         ACTION="next";    return ;;
    b|B)         ACTION="back";    return ;;
    "")          ACTION="redraw";  return ;;
  esac

  # --- multi-token scan ---
  local -a toks
  read -ra toks <<< "$trimmed"
  local i=0 ntoks="${#toks[@]}"

  while [ "$i" -lt "$ntoks" ]; do
    local t="${toks[$i]}"
    i=$(( i + 1 ))

    # peek at next token
    local nxt=""
    [ "$i" -lt "$ntoks" ] && nxt="${toks[$i]}"

    case "$t" in
      p)
        if [ -n "$nxt" ]; then f_prov="$nxt"; i=$(( i + 1 ))
        else                   f_prov=""
        fi ;;
      k)
        if [ -n "$nxt" ]; then f_cat="$nxt"; i=$(( i + 1 ))
        else                   f_cat=""
        fi ;;
      '$'|'$'*)
        # allow both "$ .15" and "$.15"
        local val="${t#'$'}"
        if [ -z "$val" ]; then
          if [ -n "$nxt" ]; then val="$nxt"; i=$(( i + 1 )); fi
        fi
        f_in="$val" ;;
      x)
        if [ -n "$nxt" ]; then f_ctx="$nxt"; i=$(( i + 1 ))
        else                   f_ctx=""
        fi ;;
      s)
        # s takes the rest of the line
        local rest_arr=("${toks[@]:$i}")
        f_term="${rest_arr[*]:-}"
        i="$ntoks"   # consume remainder
        ;;
      m)
        ACTION="select"
        ACTION_ARG="$nxt"
        return ;;
      a)
        f_prov=""; f_cat=""; f_in=""; f_ctx=""; f_term="" ;;
      q) ACTION="quit";    return ;;
      r) ACTION="refresh"; return ;;
      n) ACTION="next";    return ;;
      b) ACTION="back";    return ;;
      *) : ;;   # unknown token – skip silently
    esac
  done
  # If we reach here we changed at least one filter
  ACTION="filter"
}

# ── fzf browser (used when fzf is available) ──────────────────────────────────
browse_with_fzf() {
  maybe_refresh
  [ -f "$CACHE_FILE" ] || { echo "No catalog available."; return 1; }

  local selected
  # Build display lines:  id   ctx   in_cost   out_cost   categories
  # fzf preview shows the description from col 9
  selected=$(
    awk -F'\t' '{
      printf "%-44s  %5s  in:%-12s  out:%-12s  %s\n",
             $1, $4, "$"$5"/M", "$"$6"/M", $7
    }' "$CACHE_FILE" | \
    fzf \
      --height=90% \
      --layout=reverse \
      --info=inline \
      --prompt="model> " \
      --header="Enter=select   Ctrl-C=cancel   Type to fuzzy-search" \
      --preview="awk -F'\t' -v id={1} '\$1==id{print \$2\"\n\nCtx:  \"\$4\"\nIn:   \$\"\$5\"/M\nOut:  \$\"\$6\"/M\nMod:  \"\$8\"\nCats: \"\$7\"\n\n\"\$9}' \"$CACHE_FILE\"" \
      --preview-window=right:45%:wrap \
      2>/dev/null
  ) || return 1

  # Extract model id (first whitespace-delimited field)
  MODEL="$(awk '{print $1}' <<< "$selected")"
  [ -n "$MODEL" ]
}

# ── TUI browser (fallback when fzf is not available) ─────────────────────────
# Sets global MODEL on success and returns 0.
# Returns 1 if user quits without selecting.
browse_tui() {
  maybe_refresh
  if [ ! -f "$CACHE_FILE" ]; then
    echo; echo "Live catalog unavailable.  Use 'c' to enter a model id manually."
    return 1
  fi

  # Filter state
  local f_prov="" f_cat="" f_in="" f_ctx="" f_term=""
  # Pagination state
  local page=0
  # Current result set (reloaded when filters change)
  local -a rows=()
  local total=0 total_pages=0
  # Action set by parse_input
  local ACTION="" ACTION_ARG=""
  # Track whether filters changed so we know when to reload rows
  local filters_dirty=1   # 1 = need reload

  while true; do
    # ── reload if filters changed ─────────────────────────────────────────
    if [ "$filters_dirty" -eq 1 ]; then
      mapfile -t rows < <(filter_catalog "$f_prov" "$f_cat" "$f_in" "$f_ctx" "$f_term")
      total="${#rows[@]}"
      total_pages=$(( (total + PAGE_SIZE - 1) / PAGE_SIZE ))
      [ "$total_pages" -lt 1 ] && total_pages=1
      page=0
      filters_dirty=0
    fi

    # ── clamp page ────────────────────────────────────────────────────────
    [ "$page" -lt 0 ] && page=0
    [ "$page" -ge "$total_pages" ] && page=$(( total_pages - 1 ))

    # ── render ────────────────────────────────────────────────────────────
    tui_clear

    # Header
    printf '══════════════════════════════════════════════════════════════════\n'
    printf ' Model Browser   %d models in catalog   %d match current filters\n' \
      "$(wc -l < "$CACHE_FILE")" "$total"
    printf '══════════════════════════════════════════════════════════════════\n'

    # Active filters row
    printf ' provider:%-14s  category:%-16s\n' "${f_prov:-any}" "${f_cat:-any}"
    printf ' max-in:$%-14s  min-ctx:%-16s' "${f_in:-any}" "${f_ctx:-any}"
    [ -n "$f_term" ] && printf '  search: %s' "$f_term"
    echo

    # Pagination indicator
    printf ' Page %d / %d\n' "$(( page + 1 ))" "$total_pages"
    printf '──────────────────────────────────────────────────────────────────\n'

    # Results for this page
    local start=$(( page * PAGE_SIZE ))
    local end=$(( start + PAGE_SIZE ))
    [ "$end" -gt "$total" ] && end="$total"

    if [ "$total" -eq 0 ]; then
      echo ' (no models match – type "a" to clear all filters)'
    else
      local i="$start"
      while [ "$i" -lt "$end" ]; do
        local row="${rows[$i]}"
        local id name prov ctx in_c out_c cats mod desc
        IFS=$'\t' read -r id name prov ctx in_c out_c cats mod desc <<< "$row"
        local n=$(( i + 1 ))
        printf ' %3d)  %-40s  %5s ctx\n' "$n" "$id" "$(fmt_ctx "$ctx")"
        printf '       in: %-13s  out: %-13s  %s\n' \
          "$(fmt_cost "$in_c")" "$(fmt_cost "$out_c")" "$mod"
        printf '       %s\n' "$cats"
        [ -n "$desc" ] && printf '       %s\n' "${desc:0:88}"
        echo
        i=$(( i + 1 ))
      done
    fi

    # Help bar
    printf '──────────────────────────────────────────────────────────────────\n'
    printf ' FILTERS (combine on one line: p deepseek k coding $ .15 x 1000000)\n'
    printf '  p <prov>   provider    e.g. anthropic  openai  deepseek  qwen  google\n'
    printf '  k <tag>    category    e.g. coding  reasoning  long-context  budget  free\n'
    printf '  $ <num>    max \$/1M in e.g. $ 1.00   $ 0.30\n'
    printf '  x <num>    min ctx     e.g. x 200000   x 1000000\n'
    printf '  s <text>   free search (takes rest of line)\n'
    printf '  a          clear all filters\n'
    printf ' NAVIGATION\n'
    printf '  m <n>      select model by global number\n'
    printf '  n / b      next / back page\n'
    printf '  r          re-fetch catalog   q  quit\n'
    printf '══════════════════════════════════════════════════════════════════\n'

    # ── read input ────────────────────────────────────────────────────────
    read -rp ' filter/nav> ' user_input || return 1

    parse_input "$user_input"

    case "$ACTION" in
      quit)
        return 1
        ;;
      redraw)
        : # just re-render
        ;;
      refresh)
        refresh_cache || true
        filters_dirty=1
        ;;
      clear)
        f_prov=""; f_cat=""; f_in=""; f_ctx=""; f_term=""
        filters_dirty=1
        ;;
      next)
        page=$(( page + 1 ))
        [ "$page" -ge "$total_pages" ] && page=$(( total_pages - 1 ))
        ;;
      back)
        page=$(( page - 1 ))
        [ "$page" -lt 0 ] && page=0
        ;;
      filter)
        filters_dirty=1
        ;;
      select)
        local sel_n="$ACTION_ARG"
        if [[ ! "$sel_n" =~ ^[0-9]+$ ]]; then
          read -rp " Enter model number: " sel_n
        fi
        if [[ ! "$sel_n" =~ ^[0-9]+$ ]]; then
          printf ' Not a number.\n'; sleep 1; continue
        fi
        local sel_idx=$(( sel_n - 1 ))
        if [ "$sel_idx" -lt 0 ] || [ "$sel_idx" -ge "$total" ]; then
          printf ' Number out of range (1–%d).\n' "$total"; sleep 1; continue
        fi
        IFS=$'\t' read -r MODEL _ <<< "${rows[$sel_idx]}"
        echo; printf ' Selected: %s\n' "$MODEL"
        return 0
        ;;
    esac
  done
}

# ── dispatch browser ──────────────────────────────────────────────────────────
browse_models() {
  if [ "$HAS_FZF" -eq 1 ]; then
    browse_with_fzf && return 0
    # fzf cancelled (Ctrl-C) – drop back to TUI so user can navigate
    echo " (fzf cancelled – falling back to TUI browser)"
    sleep 1
  fi
  browse_tui
}

# ── startup screen ────────────────────────────────────────────────────────────
show_start() {
  tui_clear
  echo
  echo '══════════════════════════════════════════════════════════════════'
  echo ' opencode  ·  claw-code launcher via OpenRouter'
  echo '══════════════════════════════════════════════════════════════════'
  echo

  local saved=""
  [ -f "$MODEL_FILE" ] && saved="$(cat "$MODEL_FILE")"
  local effective="${saved:-$DEFAULT_MODEL}"
  printf ' default  →  %s\n\n' "$effective"

  local recents=()
  [ -f "$RECENTS_FILE" ] && mapfile -t recents < <(head -n "$MAX_RECENTS" "$RECENTS_FILE")

  if [ "${#recents[@]}" -gt 0 ]; then
    echo ' Recent models'
    echo ' ─────────────'
    local i=1
    for m in "${recents[@]}"; do
      printf '  %d)  %s\n' "$i" "$m"
      i=$(( i + 1 ))
    done
    echo
  fi

  echo ' Actions'
  echo ' ───────'
  printf '  Enter / d)  use default  (%s)\n' "$effective"
  [ "$HAS_FZF" -eq 1 ] && echo '  b)          browse catalog  (fzf)' \
                        || echo '  b)          browse catalog  (TUI)'
  echo '  c)          enter a custom model id'
  echo '  q)          quit'
  echo
}

# ── main ──────────────────────────────────────────────────────────────────────
MODEL="${1:-}"
SKIP_SAVE_PROMPT=0

if [ -n "$MODEL" ]; then
  SKIP_SAVE_PROMPT=1
else
  show_start

  RECENTS=()
  [ -f "$RECENTS_FILE" ] && mapfile -t RECENTS < <(head -n "$MAX_RECENTS" "$RECENTS_FILE")

  SAVED=""
  [ -f "$MODEL_FILE" ] && SAVED="$(cat "$MODEL_FILE")"
  EFFECTIVE_DEFAULT="${SAVED:-$DEFAULT_MODEL}"

  read -rp " Choose [d]: " pick
  pick="${pick:-d}"

  # numbered recent shortcut?
  if [[ "$pick" =~ ^[1-9][0-9]*$ ]]; then
    idx=$(( pick - 1 ))
    if [ "$idx" -ge "${#RECENTS[@]}" ]; then
      echo "Invalid recent selection (only ${#RECENTS[@]} recent model(s))."
      exit 1
    fi
    MODEL="${RECENTS[$idx]}"
  else
    case "$pick" in
      d|D|"")
        MODEL="$EFFECTIVE_DEFAULT"
        [ "$MODEL" = "$SAVED" ] && SKIP_SAVE_PROMPT=1
        ;;
      b|B)
        browse_models || { echo; echo "No model selected."; exit 0; }
        ;;
      c|C)
        echo
        read -rp " Enter OpenRouter model id: " MODEL
        MODEL="$(echo "$MODEL" | tr -d '[:space:]')"
        ;;
      q|Q)
        exit 0
        ;;
      *)
        echo "Invalid selection."; exit 1
        ;;
    esac
  fi
fi

[ -n "$MODEL" ] || { echo "No model selected."; exit 1; }

# ── optionally save as default ────────────────────────────────────────────────
if [ "$SKIP_SAVE_PROMPT" -eq 0 ]; then
  SAVED=""
  [ -f "$MODEL_FILE" ] && SAVED="$(cat "$MODEL_FILE")"
  if [ "$MODEL" != "${SAVED:-}" ]; then
    echo
    read -rp " Save '$MODEL' as default? [Y/n]: " sv
    sv="${sv:-Y}"
    if [[ "$sv" =~ ^[Yy]$ ]]; then
      echo "$MODEL" > "$MODEL_FILE"
      echo " Default saved."
    fi
  fi
fi

save_recent "$MODEL"

# ── launch ────────────────────────────────────────────────────────────────────
export OPENAI_BASE_URL="https://openrouter.ai/api/v1"
export OPENAI_API_KEY="$OPENROUTER_API_KEY"
export HTTP_REFERER="https://localhost"
export X_TITLE="claw-code"

echo
echo '══════════════════════════════════════════════════════════════════'
printf ' Launching claw-code\n'
printf '   model : %s\n' "$MODEL"
printf '   dir   : %s\n' "$(pwd)"
printf '   base  : %s\n' "$OPENAI_BASE_URL"
echo '══════════════════════════════════════════════════════════════════'
echo

# Disable resilience for cloud providers (OpenRouter uses cloud APIs)
export CLAW_RESILIENCE=none
exec "$CLI_BIN" --model "$MODEL" --permission-mode workspace-write
LAUNCHER_EOF

chmod +x "$HOME/bin/opencode"

# ── PATH setup ────────────────────────────────────────────────────────────────
PROFILE="$HOME/.bashrc"
if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
  echo; echo "~/bin is not in your current PATH."
  if [ -f "$PROFILE" ]; then
    if ! grep -q 'export PATH="$HOME/bin:$PATH"' "$PROFILE"; then
      { echo; echo '# Added by opencode installer'; echo 'export PATH="$HOME/bin:$PATH"'; } >> "$PROFILE"
      echo "Added ~/bin to PATH in $PROFILE"
    fi
  else
    echo "No ~/.bashrc – add manually:  export PATH=\"\$HOME/bin:\$PATH\""
  fi
  echo; echo "Activate now:  source ~/.bashrc"
fi

echo
echo '══════════════════════════════════════════════════════════════════'
echo ' Setup complete'
echo '══════════════════════════════════════════════════════════════════'
echo ' Reload shell:  source ~/.bashrc'
echo ' Run:           opencode'
echo ' With a model:  opencode deepseek/deepseek-v4-pro'
echo