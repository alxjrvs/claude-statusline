#!/usr/bin/env bash
# claude-statusline — a self-contained Claude Code statusline.
#
# Drop-in: needs only `git` and `jq` on PATH. No extra binaries.
# Point Claude Code at it in ~/.claude/settings.json:
#
#   "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }
#
# Reads the Claude Code statusline JSON on stdin and emits 3-5 colored lines:
#   Line 1: repo/dir [@branch(/worktree)][#N:state][counters][+N/-M]
#   Line 2: [model ctxflag effort style] $cost ($/h)
#   Line 3: CTX <bar w/ amber autocompact cell> N% Nk/Nk cache N% N%->AC [200k+]
#   Line 4: 5h  <bar> N% Xh Ym left [delta]   (+ inline "7d N%" when 7d hidden)
#   Line 5: 7d  <bar> N% Xd Yh left [delta]   (shown only when 7d is binding)
#
# Pure ASCII; no Nerd Font required. Colors honor NO_COLOR and degrade on
# non-truecolor terminals. Everything degrades gracefully: missing fields just
# drop their segment.
#
# Bash 3.2 compatible (macOS system bash).

# ── Primitives ────────────────────────────────────────────────────────────
# Bars + sigils are pure ASCII: width-deterministic on every terminal (incl.
# cmux's re-emulated grid) and no Nerd Font dependency.
ESC=$(printf '\033')
BEL=$(printf '\007')
# Each bar cell type is a distinct SHAPE (not just a distinct color), so the
# marker / projection / fill stay legible in mono terminals and colorblind view.
PIP_FILL='#'     # bar fill            (gradient)
PIP_EMPTY='-'    # bar track           (muted)
PIP_MARKER='|'   # clock / threshold   (marker color)
PIP_PROJ='*'     # burn projection     (yellow)
PIP_OVERFLOW='!' # projection overflow (bold red)
SIG_BRANCH='@'   # branch    (evokes git @/HEAD)
SIG_PR='#'       # pull request

# ── Color capability ────────────────────────────────────────────────────────
# Honor NO_COLOR (https://no-color.org) and dumb terminals; detect truecolor so
# the 24-bit gradient can degrade to a 256-color ramp elsewhere. The ASCII pip
# shapes already carry meaning without color, so mono output stays legible.
USE_COLOR=1
[ -n "${NO_COLOR:-}" ] && USE_COLOR=0
[ "${TERM:-}" = "dumb" ] && USE_COLOR=0
TRUECOLOR=0
case "${COLORTERM:-}" in *truecolor* | *24bit*) TRUECOLOR=1 ;; esac

# ── Style primitives ──────────────────────────────────────────────────────
if [ "$USE_COLOR" -eq 0 ]; then
  UNDIM="" BOLD="" RST="" MUTED="" RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN=""
  NEAR_WHITE="" MARKER="" PROJ="" AUTOCOMPACT=""
else
  UNDIM="${ESC}[22m"
  BOLD="${ESC}[1m"
  RST="${ESC}[0m"
  MUTED="${ESC}[90m"
  RED="${ESC}[31m"
  GREEN="${ESC}[32m"
  YELLOW="${ESC}[33m"
  BLUE="${ESC}[34m"
  MAGENTA="${ESC}[35m"
  CYAN="${ESC}[36m"
  if [ "$TRUECOLOR" -eq 1 ]; then
    NEAR_WHITE="${ESC}[38;2;235;235;235m"
    MARKER="${ESC}[38;2;96;200;255m"     # rate-window clock pip (blue)
    PROJ="${ESC}[38;2;255;210;80m"       # burn projection pip (yellow)
    AUTOCOMPACT="${ESC}[38;2;255;128;0m" # autocompact threshold cell (amber)
  else
    # 256-color approximations for terminals without truecolor.
    NEAR_WHITE="${ESC}[38;5;255m"
    MARKER="${ESC}[38;5;39m"
    PROJ="${ESC}[38;5;221m"
    AUTOCOMPACT="${ESC}[38;5;208m"
  fi
fi

DEFAULT_PIP_COUNT=30 # fallback when the terminal width is unknown

# Bars stretch to fill the row: pip_count = cols - BAR_RESERVE, so on a wide
# terminal the bar uses all the space the fixed text leaves free. BAR_RESERVE is
# the widest fixed overhead across all bar lines (the 5h/7d window line):
#   label(3) + space + space + pct(3) + '%' + space + time(<=9) + space +
#   '[' + delta(<=5) + ']'  ~= 25 visible cols, +3 safety margin.
# All bars share one pip_count (driven by the same cols) so they stay vertically
# aligned; the CTX line's smaller overhead just leaves a little trailing slack.
BAR_RESERVE=28
MIN_PIP_COUNT=12 # keep the bar readable on a narrow pane (and >1 for the gradient divisor)

# Claude Code reports the *full* terminal width via COLUMNS, but it renders the
# statusline inside its own chrome — a left indent plus a right-edge reservation
# for its UI hints. Filling a bar line to exactly COLUMNS therefore overruns that
# usable region: the row auto-wraps and shoves Claude's chrome off-screen. Hold
# back a fixed margin so the bars still stretch to fill the row but stop short of
# the chrome ("as wide as possible without losing Claude's UI"). Fixed, not
# proportional: the chrome is a constant column cost regardless of terminal width.
# Override with CLAUDE_STATUSLINE_CHROME_MARGIN when a build's chrome differs.
CHROME_MARGIN=8

# ── Helpers ────────────────────────────────────────────────────────────────

# Integer prefix of a string ("42.7" → 42, "" / garbage → 0).
int_prefix() {
  local s=${1%%.*}
  case "$s" in
    '' | *[!0-9-]*) echo 0 ;;
    *) echo "$s" ;;
  esac
}

# Abbreviate a token count: 42 / 12k / 1M (integer math, no decimals).
abbrev_num() {
  local n=$1
  if [ "$n" -lt 1000 ]; then
    echo "$n"
  elif [ "$n" -lt 1000000 ]; then
    echo "$((n / 1000))k"
  else
    echo "$((n / 1000000))M"
  fi
}

# Middle-ellipsize a string to <=max visible chars ("longbranchname" → "long..name").
# Pure ASCII ".." ellipsis. Leaves short strings and tiny budgets untouched.
trunc_mid() {
  local s=$1 max=$2 len=${#1}
  if [ "$max" -lt 5 ] || [ "$len" -le "$max" ]; then
    printf '%s' "$s"
    return
  fi
  local keep=$((max - 2)) head tail
  head=$(((keep + 1) / 2))
  tail=$((keep / 2))
  printf '%s..%s' "${s:0:head}" "${s:len-tail}"
}

# Build an OSC8 hyperlink: osc8 <url> <text>
osc8() { printf '%s]8;;%s%s%s%s]8;;%s' "$ESC" "$1" "$BEL" "$2" "$ESC" "$BEL"; }

# ── cmux compatibility shim ─────────────────────────────────────────────────
# The bars and sigils above are already pure ASCII, so the only thing that still
# garbles under cmux (the libghostty agent multiplexer, which re-emulates the
# grid and freezes frames into per-tab scrollback) is OSC 8 hyperlinks: a
# variable-length zero-width payload cmux miscounts, wrapping an unbudgeted row
# and desyncing the scroll region. Detect cmux via its launch env (CMUX_SURFACE_ID
# = the render surface, always set; CMUX_BUNDLE_ID as backstop) and emit link
# text without the escape. Real Ghostty.app sets neither, so links stay clickable.
if [ -n "${CMUX_SURFACE_ID:-}${CMUX_BUNDLE_ID:-}" ]; then
  osc8() { printf '%s' "$2"; }
fi

# Bar width from terminal columns: fill the row edge-to-edge, reserving
# BAR_RESERVE cols for the fixed text, with a MIN_PIP_COUNT floor (no ceiling).
pip_count_for_width() {
  local c=$1
  if [ -z "$c" ]; then
    echo "$DEFAULT_PIP_COUNT"
    return
  fi
  local n=$((c - BAR_RESERVE))
  [ "$n" -lt "$MIN_PIP_COUNT" ] && n=$MIN_PIP_COUNT
  echo "$n"
}

# Blackbody-style gradient at t (0..10000); sets globals _GR/_GG/_GB.
gradient_at() {
  local t=$1 u
  if [ "$t" -le 3500 ]; then
    u=$((t * 10000 / 3500))
    _GR=$((74 + (176 - 74) * u / 10000))
    _GG=$((79 + (74 - 79) * u / 10000))
    _GB=$((92 + (58 - 92) * u / 10000))
  elif [ "$t" -le 7000 ]; then
    u=$(((t - 3500) * 10000 / 3500))
    _GR=$((176 + (240 - 176) * u / 10000))
    _GG=$((74 + (160 - 74) * u / 10000))
    _GB=$((58 + (64 - 58) * u / 10000))
  elif [ "$t" -le 9000 ]; then
    u=$(((t - 7000) * 10000 / 2000))
    _GR=$((240 + (255 - 240) * u / 10000))
    _GG=$((160 + (232 - 160) * u / 10000))
    _GB=$((64 + (144 - 64) * u / 10000))
  else
    u=$(((t - 9000) * 10000 / 1000))
    _GR=255
    _GG=$((232 + (255 - 232) * u / 10000))
    _GB=$((144 + (255 - 144) * u / 10000))
  fi
}

# Precompute the fill gradient once as a small palette of SGR-open strings, so
# render_bar is a table lookup per cell rather than a fresh gradient computation
# per cell (a wide, now-uncapped bar can be 150+ cells across three bars every
# refresh). Index a cell by gi = i*(GRAD_N-1)/(pip_count-1). Non-truecolor uses a
# cool→warm 256-color ramp; NO_COLOR leaves the entries empty (bare '#' fill).
GRAD_N=24
_grad_palette=()
_grad256_ramp=(60 66 96 132 168 203 202 208 214 220 228)
build_palette() {
  local i t
  for ((i = 0; i < GRAD_N; i++)); do
    t=$((i * 10000 / (GRAD_N - 1)))
    if [ "$USE_COLOR" -eq 0 ]; then
      _grad_palette[i]=""
    elif [ "$TRUECOLOR" -eq 1 ]; then
      gradient_at "$t"
      _grad_palette[i]="${ESC}[38;2;${_GR};${_GG};${_GB}m"
    else
      _grad_palette[i]="${ESC}[38;5;${_grad256_ramp[$((t * (${#_grad256_ramp[@]} - 1) / 10000))]}m"
    fi
  done
}
build_palette

# render_bar <pct> <marker_pct|""> <proj_pct|""> <cols|""> <marker_color>
render_bar() {
  local pct=$1 marker_pct=$2 proj_pct=$3 cols=$4 marker_color=$5
  local pip_count
  pip_count=$(pip_count_for_width "$cols")
  [ "$pct" -lt 0 ] && pct=0
  local filled=$((pct * pip_count / 100))
  [ "$filled" -gt "$pip_count" ] && filled=$pip_count
  if [ "$pct" -gt 0 ] && [ "$filled" -eq 0 ]; then filled=1; fi

  local marker_idx=-1 marker_expired=0
  if [ -n "$marker_pct" ]; then
    if [ "$marker_pct" -ge 100 ]; then
      marker_idx=$((pip_count - 1))
      marker_expired=1
    else
      local m=$marker_pct
      [ "$m" -lt 0 ] && m=0
      marker_idx=$((m * pip_count / 100))
      [ "$marker_idx" -gt $((pip_count - 1)) ] && marker_idx=$((pip_count - 1))
    fi
  fi
  local proj_idx=-1 proj_overflow=0
  if [ -n "$proj_pct" ] && [ "$proj_pct" -ge 0 ]; then
    if [ "$proj_pct" -gt 100 ]; then
      # Projection runs off the right edge: pin to the last cell, flag overflow.
      proj_idx=$((pip_count - 1))
      proj_overflow=1
    else
      proj_idx=$((proj_pct * pip_count / 100))
      [ "$proj_idx" -gt $((pip_count - 1)) ] && proj_idx=$((pip_count - 1))
    fi
  fi

  local out="" i pip gi
  for ((i = 0; i < pip_count; i++)); do
    if [ "$i" -lt "$filled" ]; then pip=$PIP_FILL; else pip=$PIP_EMPTY; fi
    if [ "$i" -eq "$marker_idx" ]; then
      if [ "$marker_expired" -eq 1 ]; then
        out="${out}${UNDIM}${RED}${PIP_MARKER}"
      else
        out="${out}${UNDIM}${marker_color}${PIP_MARKER}"
      fi
    elif [ "$i" -eq "$proj_idx" ]; then
      if [ "$proj_overflow" -eq 1 ]; then
        out="${out}${UNDIM}${BOLD}${RED}${PIP_OVERFLOW}"
      else
        out="${out}${UNDIM}${PROJ}${PIP_PROJ}"
      fi
    elif [ "$i" -lt "$filled" ]; then
      gi=$((i * (GRAD_N - 1) / (pip_count - 1)))
      out="${out}${UNDIM}${_grad_palette[gi]}${pip}"
    else
      out="${out}${MUTED}${pip}"
    fi
  done
  printf '%s%s' "$out" "$RST"
}

# Color for a PR review_state (case-insensitive).
pr_state_color() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    approved) printf '%s' "$GREEN" ;;
    changes_requested) printf '%s' "$RED" ;;
    review_required | pending) printf '%s' "$YELLOW" ;;
    commented) printf '%s' "$CYAN" ;;
    *) printf '%s' "$MUTED" ;;
  esac
}

# Last two path components, with $HOME → ~ (mirrors last_two_components).
dir_display() {
  local p=$1 home=$HOME shown rel
  if [ -n "$home" ] && [ "${p#"$home"}" != "$p" ]; then
    rel=${p#"$home"}
    if [ -z "$rel" ]; then shown="~"; else shown="~$rel"; fi
  else
    shown=$p
  fi
  local IFS='/' x
  local -a parts clean
  read -ra parts <<< "$shown"
  clean=()
  for x in "${parts[@]}"; do [ -n "$x" ] && clean+=("$x"); done
  local n=${#clean[@]}
  case "$shown" in
    '~'*)
      if [ "$n" -ge 3 ]; then printf '%s/%s' "${clean[n - 2]}" "${clean[n - 1]}"; else printf '%s' "$shown"; fi
      ;;
    *)
      if [ "$n" -ge 2 ]; then printf '%s/%s' "${clean[n - 2]}" "${clean[n - 1]}"; else printf '%s' "$shown"; fi
      ;;
  esac
}

# ── Read stdin payload ──────────────────────────────────────────────────────
input=$(cat)

if ! command -v jq > /dev/null 2>&1; then
  printf '%sclaude-statusline: jq not found on PATH%s\n' "$RED" "$RST"
  exit 0
fi

# Pull every field in one jq pass as name-keyed key=value lines, parsed by
# `case` (bash 3.2 safe). Name-keyed beats positional: a Claude Code schema
# addition or a local reorder can't silently shift every field — unknown keys
# are ignored, missing keys keep their default.
fields=$(printf '%s' "$input" | jq -r '
  "used_pct=\(.context_window.used_percentage // "" | tostring)",
  "ctx_input_tokens=\(.context_window.total_input_tokens // 0 | tostring)",
  "ctx_window_size=\(.context_window.context_window_size // 0 | tostring)",
  "cache_read_tokens=\(.context_window.current_usage.cache_read_input_tokens // 0 | tostring)",
  "worktree_name=\(.worktree.name // "")",
  "project_dir=\(.workspace.project_dir // "")",
  "cwd=\(.workspace.current_dir // "")",
  "repo_host=\(.workspace.repo.host // "")",
  "repo_owner=\(.workspace.repo.owner // "")",
  "repo_name=\(.workspace.repo.name // "")",
  "model_name=\(.model.display_name // "")",
  "effort_level=\(.effort.level // "")",
  "output_style=\(.output_style.name // "")",
  "cost_usd=\(.cost.total_cost_usd // "" | tostring)",
  "duration_ms=\(.cost.total_duration_ms // 0 | tostring)",
  "lines_added=\(.cost.total_lines_added // 0 | tostring)",
  "lines_removed=\(.cost.total_lines_removed // 0 | tostring)",
  "pr_number=\(.pr.number // "" | tostring)",
  "pr_state=\(.pr.review_state // "")",
  "exceeds_200k=\(if .exceeds_200k_tokens == true then "1" else "" end)",
  "five_pct=\(.rate_limits.five_hour.used_percentage // "" | tostring)",
  "five_resets_at=\(.rate_limits.five_hour.resets_at // "" | tostring)",
  "seven_pct=\(.rate_limits.seven_day.used_percentage // "" | tostring)",
  "seven_resets_at=\(.rate_limits.seven_day.resets_at // "" | tostring)",
  "cols=\((.columns // .terminal.columns) // "" | tostring)"
' 2> /dev/null)

used_pct="" ctx_input_tokens=0 ctx_window_size=0 cache_read_tokens=0
worktree_name_input="" project_dir="" cwd_input=""
repo_host="" repo_owner="" repo_name_input=""
model_name="" effort_level="" output_style="" cost_usd="" duration_ms=0
lines_added=0
lines_removed=0 pr_number="" pr_state="" exceeds_200k="" five_pct=""
five_resets_at="" seven_pct="" seven_resets_at="" cols=""

while IFS= read -r _kv || [ -n "$_kv" ]; do
  case "$_kv" in *=*) ;; *) continue ;; esac
  _k=${_kv%%=*}
  _v=${_kv#*=}
  case "$_k" in
    used_pct) used_pct=$_v ;;
    ctx_input_tokens) ctx_input_tokens=$_v ;;
    ctx_window_size) ctx_window_size=$_v ;;
    cache_read_tokens) cache_read_tokens=$_v ;;
    worktree_name) worktree_name_input=$_v ;;
    project_dir) project_dir=$_v ;;
    cwd) cwd_input=$_v ;;
    repo_host) repo_host=$_v ;;
    repo_owner) repo_owner=$_v ;;
    repo_name) repo_name_input=$_v ;;
    model_name) model_name=$_v ;;
    effort_level) effort_level=$_v ;;
    output_style) output_style=$_v ;;
    cost_usd) cost_usd=$_v ;;
    duration_ms) duration_ms=$_v ;;
    lines_added) lines_added=$_v ;;
    lines_removed) lines_removed=$_v ;;
    pr_number) pr_number=$_v ;;
    pr_state) pr_state=$_v ;;
    exceeds_200k) exceeds_200k=$_v ;;
    five_pct) five_pct=$_v ;;
    five_resets_at) five_resets_at=$_v ;;
    seven_pct) seven_pct=$_v ;;
    seven_resets_at) seven_resets_at=$_v ;;
    cols) cols=$_v ;;
  esac
done <<< "$fields"

# Normalize numeric-ish fields.
duration_ms=$(int_prefix "$duration_ms")
lines_added=$(int_prefix "$lines_added")
lines_removed=$(int_prefix "$lines_removed")
ctx_input_tokens=$(int_prefix "$ctx_input_tokens")
ctx_window_size=$(int_prefix "$ctx_window_size")
cache_read_tokens=$(int_prefix "$cache_read_tokens")

# Terminal width: as of Claude Code v2.1.153 it arrives via the COLUMNS env var
# (statusline stdout is captured, so `tput cols` can't see the tty). Prefer a
# numeric COLUMNS; a set-but-non-numeric value falls through to any JSON-provided
# width rather than clobbering it, then to the fixed default in render_bar.
case "${COLUMNS:-}" in
  '' | *[!0-9]*) : ;;
  *) cols=$COLUMNS ;;
esac
case "$cols" in '' | *[!0-9]*) cols="" ;; esac

# Reserve chrome margin from the usable width (see CHROME_MARGIN above). Env
# override wins when set to a non-negative integer; otherwise use the default.
margin=$CHROME_MARGIN
case "${CLAUDE_STATUSLINE_CHROME_MARGIN:-}" in
  '' | *[!0-9]*) : ;;
  *) margin=$CLAUDE_STATUSLINE_CHROME_MARGIN ;;
esac
if [ -n "$cols" ]; then
  cols=$((cols - margin))
  [ "$cols" -lt 1 ] && cols=1
fi

# ── Gather git state (self-contained; deliberately not the git-data cache) ──
# GIT_OPTIONAL_LOCKS=0: this runs on every refresh in the background — it must
# never contend for index.lock with the session's own git rebase/add.
export GIT_OPTIONAL_LOCKS=0
git_is_repo=0 branch="" repo_https="" repo_name="" git_worktree_name=""
ahead=0 behind=0 staged=0 unstaged=0 untracked=0 conflict=0 stash=0

if topl=$(git rev-parse --show-toplevel 2> /dev/null) && [ -n "$topl" ]; then
  git_is_repo=1
  gdir=$(git rev-parse --git-dir 2> /dev/null)
  cdir=$(git rev-parse --git-common-dir 2> /dev/null)
  [ "$gdir" != "$cdir" ] && git_worktree_name=$(basename "$topl")

  while IFS= read -r line; do
    case "$line" in
      '# branch.head '*) branch=${line#\# branch.head } ;;
      '# branch.ab '*)
        ab=${line#\# branch.ab }
        a=${ab%% *}
        b=${ab#* }
        a=${a#+}
        b=${b#-}
        [ -n "$a" ] && ahead=$a
        [ -n "$b" ] && behind=$b
        ;;
      '? '*) untracked=$((untracked + 1)) ;;
      '1 '* | '2 '* | 'u '*)
        # Second whitespace token is the XY status pair.
        # shellcheck disable=SC2086  # intentional word-split into positional params
        set -- $line
        xy=$2
        x=${xy:0:1}
        y=${xy:1:1}
        case "$xy" in
          UU | AA | DD | AU | UA | DU | UD)
            conflict=$((conflict + 1))
            continue
            ;;
        esac
        case "$x" in M | A | D | R | C) staged=$((staged + 1)) ;; esac
        case "$y" in M | D) unstaged=$((unstaged + 1)) ;; esac
        ;;
    esac
  done < <(git status --porcelain=v2 --branch 2> /dev/null)

  # Detached HEAD fallback.
  if [ -z "$branch" ] || [ "$branch" = "(detached)" ]; then
    branch=$(git rev-parse --short HEAD 2> /dev/null)
  fi

  # Remote identity → HTTPS + repo name. Prefer Claude Code's structured
  # workspace.repo payload (correct for any host, and saves a git subprocess);
  # fall back to parsing the origin remote ourselves when it's absent.
  if [ -n "$repo_host" ] && [ -n "$repo_owner" ] && [ -n "$repo_name_input" ]; then
    repo_https="https://${repo_host}/${repo_owner}/${repo_name_input}"
    repo_name=$repo_name_input
  else
    remote=$(git remote get-url origin 2> /dev/null)
    if [ -n "$remote" ]; then
      repo_https=${remote/git@github.com:/https:\/\/github.com\/}
      repo_https=${repo_https%.git}
      repo_name=$(basename "$repo_https")
    fi
  fi

  stash=$(git stash list 2> /dev/null | grep -c .)
fi

# Autocompact threshold (env override, else 80).
ac=80
case "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" in
  '' | *[!0-9]*) : ;;
  *) if [ "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" -ge 1 ] && [ "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" -le 100 ]; then
    ac=$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  fi ;;
esac

# CWD: prefer project_dir when in a worktree.
if [ -n "$worktree_name_input" ] && [ -n "$project_dir" ]; then
  cwd=$project_dir
elif [ -n "$cwd_input" ]; then
  cwd=$cwd_input
else
  cwd=$(pwd)
fi
dir_disp=$(dir_display "$cwd")

# Line-1 name budgets: keep long branch / worktree names from blowing line 1 past
# the pane and re-triggering the very wrap CHROME_MARGIN guards against. Scale
# with width when known, with sane floors; be generous when width is unknown.
if [ -n "$cols" ]; then
  branch_max=$((cols / 3))
  [ "$branch_max" -lt 14 ] && branch_max=14
  wt_max=$((cols / 5))
  [ "$wt_max" -lt 8 ] && wt_max=8
else
  branch_max=40
  wt_max=24
fi

# ── Line 1 ──────────────────────────────────────────────────────────────────
if [ -n "$repo_name" ]; then
  id_part="${BOLD}${NEAR_WHITE}$(osc8 "$repo_https" "$repo_name")${RST}"
else
  id_part="${BOLD}${NEAR_WHITE}${dir_disp}${RST}"
fi
# One space after the repo "title"; bracket groups below append flush (no gaps).
line1="$id_part "

# Worktree name (Claude's payload first, else the git worktree dir basename).
wt=$worktree_name_input
[ -z "$wt" ] && wt=$git_worktree_name

if [ "$git_is_repo" -eq 1 ] || [ -n "$branch" ]; then
  b=$branch
  [ -z "$b" ] && b="-"
  # Truncate the *displayed* text only; the hyperlink target keeps the full ref.
  b_txt=$(trunc_mid "$b" "$branch_max")
  if [ -n "$repo_https" ] && [ -n "$branch" ]; then
    b_disp=$(osc8 "$repo_https/tree/$branch" "$b_txt")
  else
    b_disp=$b_txt
  fi
  # In a worktree, fold branch + worktree into one cell: @<branch>/<worktree>
  # (branch stays blue/linked; the /<worktree> suffix keeps worktree-magenta).
  [ -n "$wt" ] && b_disp="${b_disp}${MAGENTA}/$(trunc_mid "$wt" "$wt_max")"
  line1="${line1}${MUTED}[${BLUE}${BOLD}${SIG_BRANCH}${b_disp}${RST}${MUTED}]${RST}"
fi

if [ -n "$pr_number" ]; then
  if [ -n "$repo_https" ]; then
    pr_id=$(osc8 "$repo_https/pull/$pr_number" "${SIG_PR}${pr_number}")
  else
    pr_id="${SIG_PR}${pr_number}"
  fi
  if [ -z "$pr_state" ]; then
    line1="${line1}${MUTED}[${CYAN}${BOLD}${pr_id}${RST}${MUTED}]${RST}"
  else
    pc=$(pr_state_color "$pr_state")
    line1="${line1}${MUTED}[${CYAN}${BOLD}${pr_id}${RST}${MUTED}:${pc}${pr_state}${MUTED}]${RST}"
  fi
fi

# Counters (stash, conflict, untracked, modified, staged, ahead, behind).
counters=""
add_counter() { [ -z "$counters" ] && counters=$1 || counters="${counters}${MUTED}, ${RST}$1"; }
plur() { [ "$1" -eq 1 ] && printf '%s' "$2" || printf '%s' "$3"; }

[ "$stash" -gt 0 ] && add_counter "${MAGENTA}${stash} $(plur "$stash" stash stashes)${RST}"
[ "$conflict" -gt 0 ] && add_counter "${BOLD}${RED}${conflict} $(plur "$conflict" conflict conflicts)${RST}"
[ "$untracked" -gt 0 ] && add_counter "${CYAN}${untracked} untracked${RST}"
[ "$unstaged" -gt 0 ] && add_counter "${YELLOW}${unstaged} modified${RST}"
[ "$staged" -gt 0 ] && add_counter "${GREEN}${staged} staged${RST}"
[ "$ahead" -gt 0 ] && add_counter "${GREEN}${ahead} ahead${RST}"
[ "$behind" -gt 0 ] && add_counter "${RED}${behind} behind${RST}"
[ -n "$counters" ] && line1="${line1}${MUTED}[${RST}${counters}${MUTED}]${RST}"

if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
  line1="${line1}${MUTED}[${GREEN}${BOLD}+${lines_added}${RST}${MUTED}/${RED}${BOLD}-${lines_removed}${RST}${MUTED}]${RST}"
fi
printf '%s\n' "$line1"

# ── Line 2: model · ctx flag · effort · style · cost — distinct colors ───────
# "Opus 4.8 (1M context)" + "high" + "Explanatory" + $cost ->
#   [Opus 4.8 1M High Explanatory] $1.23 ($7.38/h)
# Cost is folded onto this line (rather than its own row) to keep the statusline
# short; a single awk pass formats the total and the per-hour burn.
money=$(awk -v c="$cost_usd" -v d="$duration_ms" 'BEGIN{
  if (c ~ /^[0-9]+(\.[0-9]+)?$/) {
    printf "$%.2f", c
    if (c+0 > 0 && d+0 >= 60000) printf " ($%.2f/h)", (c+0) / ((d+0)/3600000.0)
  }
}')

line2=""
if [ -n "$model_name" ] || [ -n "$effort_level" ] || [ -n "$output_style" ]; then
  model_short="${model_name%% (*}" # short name: drop the " (...)" suffix
  # Context flag: prefer the authoritative context_window_size — anything past
  # the 200k default becomes a flag (abbrev_num(1000000) -> "1M"). Fall back to
  # the model-name parenthetical whenever the size field yields no flag (absent,
  # or a build that reports the default size while the 1M beta is active), so the
  # extended-window indicator is never silently dropped.
  ctx_flag=""
  if [ "$ctx_window_size" -gt 200000 ]; then
    ctx_flag="$(abbrev_num "$ctx_window_size")"
  fi
  if [ -z "$ctx_flag" ]; then
    case "$model_name" in
      *\(*\)*)
        ctx_flag="${model_name#*(}"
        ctx_flag="${ctx_flag%%)*}"
        ctx_flag="${ctx_flag%% context}" # "1M context" -> "1M"
        ;;
    esac
  fi
  effort_cap=""
  [ -n "$effort_level" ] && effort_cap="$(printf '%s' "${effort_level:0:1}" | tr '[:lower:]' '[:upper:]')${effort_level:1}"

  # Space-separated segments, each its own color, skipping empties.
  seg=""
  add_seg() {
    [ -z "$1" ] && return
    [ -n "$seg" ] && seg="${seg} "
    seg="${seg}${2}${1}${RST}"
  }
  add_seg "$model_short" "$CYAN"
  add_seg "$ctx_flag" "$YELLOW"
  add_seg "$effort_cap" "$GREEN"
  add_seg "$output_style" "$MAGENTA"

  [ -n "$seg" ] && line2="${MUTED}[${RST}${seg}${MUTED}]${RST}"
fi
# Fold cost onto the model line (its own segment); stand alone if no model info.
if [ -n "$money" ]; then
  if [ -n "$line2" ]; then
    line2="${line2} ${GREEN}${money}${RST}"
  else
    line2="${GREEN}${money}${RST}"
  fi
fi
[ -n "$line2" ] && printf '%s\n' "$line2"

# ── Line 3: CTX bar ─────────────────────────────────────────────────────────
used_int=$(int_prefix "$used_pct")
ctx_bar=$(render_bar "$used_int" "$ac" "" "$cols" "$AUTOCOMPACT")

# Absolute token readout + cache-hit ratio (both from the live context_window).
# used_percentage is input-only, so this adds the raw figure and how much of the
# context is being served from the prompt cache — a session-efficiency signal.
ctx_detail=""
if [ "$ctx_input_tokens" -gt 0 ]; then
  if [ "$ctx_window_size" -gt 0 ]; then
    ctx_detail=" ${MUTED}$(abbrev_num "$ctx_input_tokens")/$(abbrev_num "$ctx_window_size")${RST}"
  else
    ctx_detail=" ${MUTED}$(abbrev_num "$ctx_input_tokens")${RST}"
  fi
  if [ "$cache_read_tokens" -gt 0 ]; then
    cache_pct=$((cache_read_tokens * 100 / ctx_input_tokens))
    [ "$cache_pct" -gt 100 ] && cache_pct=100
    ctx_detail="${ctx_detail} ${MUTED}cache ${cache_pct}%${RST}"
  fi
fi

# Escalate the pct color as it nears autocompact, and make the threshold active:
# show live headroom (N%->AC) below it, a bracket chip [AC] once crossed.
ctx_pct_color=$GREEN
ctx_warn=""
if [ "$used_int" -ge "$ac" ]; then
  ctx_pct_color=$RED
  ctx_warn=" ${MUTED}[${AUTOCOMPACT}AC${MUTED}]${RST}"
else
  [ "$used_int" -ge $((ac - 15)) ] && ctx_pct_color=$YELLOW
  ctx_detail="${ctx_detail} ${MUTED}$((ac - used_int))%->AC${RST}"
fi
[ -n "$exceeds_200k" ] && ctx_warn="${ctx_warn} ${MUTED}[${BOLD}${RED}200k+${RST}${MUTED}]${RST}"
printf -v ctx_lbl '%-3s' "CTX"
printf -v ctx_pct '%3s' "$used_int"
printf '%s%s%s %s %s%s%%%s%s%s\n' "$MUTED" "$ctx_lbl" "$RST" "$ctx_bar" "$ctx_pct_color" "$ctx_pct" "$RST" "$ctx_detail" "$ctx_warn"

# ── Lines 4-5: rate-limit windows ───────────────────────────────────────────
# One `date` call for both windows (they share the same "now").
NOW=$(date +%s)
print_window() {
  local pct_str=$1 resets_str=$2 window_min=$3 label=$4 extra=$5
  if [ -z "$pct_str" ] || [ -z "$resets_str" ]; then
    if [ "$label" = "5h" ]; then
      printf -v lbl '%-3s' "$label"
      printf '%s%s%s %sno rate-limit data yet%s\n' "$MUTED" "$lbl" "$RST" "$MUTED" "$RST"
    fi
    return
  fi
  local pct
  pct=$(int_prefix "$pct_str")
  local resets=$resets_str
  case "$resets" in *[!0-9]*) resets=0 ;; esac
  local remain_sec=$((resets > NOW ? resets - NOW : 0))
  local remain_min=$((remain_sec / 60))
  [ "$remain_min" -gt "$window_min" ] && remain_min=$window_min
  local clock_pct=$(((window_min - remain_min) * 100 / window_min))
  local proj_pct=""
  [ "$clock_pct" -gt 5 ] && proj_pct=$((pct * 100 / clock_pct))
  local delta=$((pct - clock_pct)) delta_str
  if [ "$delta" -gt 0 ]; then
    delta_str="${RED}+${delta}%${RST}"
  elif [ "$delta" -lt 0 ]; then
    delta_str="${GREEN}${delta}%${RST}"
  else delta_str="${MUTED}0%${RST}"; fi

  # Time remaining, framed as "… left" (no leading '-', which read as negative).
  local time_label
  if [ "$remain_min" -ge 1440 ]; then
    printf -v time_label '%dd %dh' "$((remain_min / 1440))" "$(((remain_min % 1440) / 60))"
  elif [ "$remain_min" -ge 60 ]; then
    printf -v time_label '%dh %dm' "$((remain_min / 60))" "$((remain_min % 60))"
  else
    printf -v time_label '%dm' "$remain_min"
  fi

  local bar
  bar=$(render_bar "$pct" "$clock_pct" "$proj_pct" "$cols" "$MARKER")
  printf -v lbl '%-3s' "$label"
  printf -v pctf '%3s' "$pct"
  printf '%s%s%s %s %s%s%%%s %s%s left%s [%s%s]%s%s\n' \
    "$MUTED" "$lbl" "$RST" "$bar" "$MUTED" "$pctf" "$RST" \
    "$MARKER" "$time_label" "$RST" "$delta_str" "$MUTED" "$RST" "$extra"
}

# 7d earns its own row only when it's the binding window (>=50% or higher than
# 5h); otherwise it rides inline on the 5h line as a compact "7d N%" badge, so a
# quiet week doesn't cost a whole bar row.
five_int=$(int_prefix "$five_pct")
seven_int=$(int_prefix "$seven_pct")
show_7d=0
if [ -n "$seven_pct" ] && [ -n "$seven_resets_at" ]; then
  if [ "$seven_int" -ge 50 ] || [ "$seven_int" -gt "$five_int" ]; then show_7d=1; fi
fi
five_extra=""
[ "$show_7d" -eq 0 ] && [ -n "$seven_pct" ] && five_extra=" ${MUTED}7d ${seven_int}%${RST}"

print_window "$five_pct" "$five_resets_at" 300 "5h" "$five_extra"
[ "$show_7d" -eq 1 ] && print_window "$seven_pct" "$seven_resets_at" 10080 "7d" ""

# Always succeed: a statusline must never signal failure to Claude Code (the
# final conditional above would otherwise leak a non-zero status when 7d hides).
exit 0
