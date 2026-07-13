#!/usr/bin/env bash
# claude-statusline snapshot tests.
#
#   test/run.sh            # run all cases, diff against golden snapshots
#   test/run.sh --update   # regenerate the golden snapshots
#
# Most cases render in a throwaway NON-git temp dir so the git segments stay
# empty and output is fully determined by the payload + env (the process pwd,
# not the payload, drives git detection). One case renders in a throwaway git
# repo to exercise long-branch truncation. Content snapshots are ANSI-stripped
# (layout/content regressions — the class this suite exists to catch); color
# behavior is checked separately by presence/absence assertions.
#
# Determinism: HOME is pinned off-tree so dir_display never abbreviates to '~',
# resets_at is a far-future sentinel so "time left" pins to the full window and
# cancels out the real clock, and COLUMNS is fixed per case.

set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$(pwd)
SCRIPT="$ROOT/statusline.sh"
GOLDEN_DIR="$ROOT/test/golden"
mkdir -p "$GOLDEN_DIR"

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

FAR_FUTURE=9999999999 # resets_at sentinel (year 2286): always in the future
PASS=0 FAIL=0

strip_ansi() { sed $'s/\033\[[0-9;]*m//g; s/\033\]8;;[^\007]*\007//g'; }

# run_sl <cols> <payload>  — render in the current directory with pinned env.
run_sl() {
  COLUMNS=$1 HOME=/home/tester COLORTERM=truecolor TERM=xterm-256color \
    NO_COLOR='' CMUX_SURFACE_ID='' CMUX_BUNDLE_ID='' \
    CLAUDE_AUTOCOMPACT_PCT_OVERRIDE='' CLAUDE_STATUSLINE_CHROME_MARGIN='' \
    bash "$SCRIPT" <<< "$2"
}

# snapshot <name> <cols> <payload> — compare ANSI-stripped output to golden.
snapshot() {
  local name=$1 cols=$2 payload=$3
  local golden="$GOLDEN_DIR/$name.txt" actual
  actual=$(run_sl "$cols" "$payload" | strip_ansi)
  if [ "$UPDATE" -eq 1 ]; then
    printf '%s\n' "$actual" > "$golden"
    printf 'updated  %s\n' "$name"
    return
  fi
  if [ ! -f "$golden" ]; then
    printf 'MISSING  %s (run --update)\n' "$name"
    FAIL=$((FAIL + 1))
    return
  fi
  if diff -u "$golden" <(printf '%s\n' "$actual") > /tmp/sl_diff.$$ 2>&1; then
    printf 'ok       %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf 'FAIL     %s\n' "$name"
    cat /tmp/sl_diff.$$
    FAIL=$((FAIL + 1))
  fi
  rm -f /tmp/sl_diff.$$
}

# assert <name> <cond-desc> — bump counters from an externally evaluated result.
assert() {
  if [ "$2" -eq 0 ]; then
    printf 'ok       %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf 'FAIL     %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

# ── Payloads ─────────────────────────────────────────────────────────────────
DIR='"workspace":{"current_dir":"/work/DevEnv/claude-statusline"}'

P_NORMAL='{'"$DIR"',"context_window":{"used_percentage":42,"total_input_tokens":420000,"context_window_size":1000000,"current_usage":{"cache_read_input_tokens":360000}},"model":{"display_name":"Opus 4.8 (1M context)"},"effort":{"level":"high"},"output_style":{"name":"Explanatory"},"cost":{"total_cost_usd":1.23,"total_duration_ms":600000},"pr":{"number":3,"review_state":"changes_requested"},"rate_limits":{"five_hour":{"used_percentage":73,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":45,"resets_at":'"$FAR_FUTURE"'}}}'

P_SEVEN_BINDING='{'"$DIR"',"context_window":{"used_percentage":20,"total_input_tokens":40000,"context_window_size":200000},"model":{"display_name":"Sonnet 5"},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":60,"resets_at":'"$FAR_FUTURE"'}}}'

P_AUTOCOMPACT='{'"$DIR"',"context_window":{"used_percentage":82,"total_input_tokens":170000,"context_window_size":200000,"current_usage":{"cache_read_input_tokens":120000}},"exceeds_200k_tokens":true,"model":{"display_name":"Sonnet 5"},"effort":{"level":"medium"},"cost":{"total_cost_usd":0.44,"total_duration_ms":120000},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":12,"resets_at":'"$FAR_FUTURE"'}}}'

P_NEAR_AC='{'"$DIR"',"context_window":{"used_percentage":70,"total_input_tokens":140000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"},"effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":5,"resets_at":'"$FAR_FUTURE"'}}}'

P_FRESH='{"workspace":{"current_dir":"/work/scratch/tmp"},"context_window":{"used_percentage":3,"total_input_tokens":8000,"context_window_size":200000},"model":{"display_name":"Haiku 4.5"}}'

# ── Cases (non-git) ────────────────────────────────────────────────────────
NONGIT=$(mktemp -d)
trap 'rm -rf "$NONGIT" "$GITREPO"' EXIT
cd "$NONGIT" || exit 2

snapshot normal          120 "$P_NORMAL"
snapshot seven-binding   120 "$P_SEVEN_BINDING"
snapshot autocompact     120 "$P_AUTOCOMPACT"
snapshot near-ac         120 "$P_NEAR_AC"
snapshot fresh-no-rate   120 "$P_FRESH"
snapshot narrow          60  "$P_NORMAL"

# ── Color-mode assertions (non-git) ─────────────────────────────────────────
esc=$(printf '\033')

out_color=$(run_sl 120 "$P_NORMAL")
case "$out_color" in *"${esc}["*) c=0 ;; *) c=1 ;; esac
assert "color: emits ANSI by default" "$c"

out_nocolor=$(COLUMNS=120 HOME=/home/tester NO_COLOR=1 bash "$SCRIPT" <<< "$P_NORMAL")
case "$out_nocolor" in *"${esc}["*) c=1 ;; *) c=0 ;; esac
assert "NO_COLOR: emits no ANSI" "$c"
# ...and the plain content still renders (bar fill + a known token present).
case "$out_nocolor" in *"420k/1M"*) c=0 ;; *) c=1 ;; esac
assert "NO_COLOR: content intact" "$c"

# Non-truecolor terminals get the 256-color ramp (38;5;) not truecolor (38;2;).
out_256=$(COLUMNS=120 HOME=/home/tester COLORTERM='' TERM=xterm-256color bash "$SCRIPT" <<< "$P_NORMAL")
case "$out_256" in *"${esc}[38;5;"*) c=0 ;; *) c=1 ;; esac
assert "256-color: uses indexed ramp" "$c"
case "$out_256" in *"${esc}[38;2;"*) c=1 ;; *) c=0 ;; esac
assert "256-color: no truecolor escapes" "$c"

# Must always exit 0 — in BOTH 7d states (the trailing conditional is a trap).
run_sl 120 "$P_NORMAL" > /dev/null; assert "exit 0 when 7d hidden" "$?"
run_sl 120 "$P_SEVEN_BINDING" > /dev/null; assert "exit 0 when 7d shown" "$?"

# ── Width discipline: no line may exceed COLUMNS ─────────────────────────────
# The bars stretch to fill the row, so the width math must reserve room for each
# line's *trailing* text (the CTX token/cache/AC/200k+ readout is the widest and
# once ran the bar off the right edge). This is the regression guard for that:
# render at many widths, incl. a worst-case CTX payload, and fail if the visible
# (ANSI-stripped) width of ANY line exceeds COLUMNS. Runs in the non-git temp dir
# so line 1 stays short and the bar lines are what's under test.
#
# Floor at 60 cols: MIN_PIP_COUNT keeps the bar readable (>=12 pips) rather than
# collapsing it, so a very narrow pane whose fixed readout is itself wider than
# the pane will still overflow by design — that's the readable-bar backstop, not
# a width-math bug. 60 is the narrowest width the snapshot cases exercise.
P_WIDE='{'"$DIR"',"context_window":{"used_percentage":92,"total_input_tokens":185000,"context_window_size":200000,"current_usage":{"cache_read_input_tokens":185000}},"exceeds_200k_tokens":true,"model":{"display_name":"Opus 4.8"},"effort":{"level":"high"},"rate_limits":{"five_hour":{"used_percentage":63,"resets_at":'"$FAR_FUTURE"'},"seven_day":{"used_percentage":80,"resets_at":'"$FAR_FUTURE"'}}}'
widest_line() { awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'; }
overflow=0
for pw in "$P_NORMAL" "$P_AUTOCOMPACT" "$P_WIDE"; do
  for w in 60 80 100 120 160 200; do
    max=$(run_sl "$w" "$pw" | strip_ansi | widest_line)
    [ "$max" -gt "$w" ] && overflow=1
  done
done
assert "width: no line exceeds COLUMNS (all payloads/widths)" "$overflow"

# ── Long-branch truncation (git) ────────────────────────────────────────────
GITREPO=$(mktemp -d)
# core.hooksPath=/dev/null + --no-verify keep any globally-configured hooks
# (e.g. gitleaks) from firing and leaking output into the test run.
(
  cd "$GITREPO" || exit 2
  git init -q
  git checkout -q -b feature/some-really-long-branch-name-goes-here 2> /dev/null
  : > f.txt
  git add f.txt
  git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q --no-verify -m init
) > /dev/null 2>&1 || { printf 'FAIL     git fixture setup\n'; FAIL=$((FAIL + 1)); }
cd "$GITREPO" || exit 2
# Payload supplies a stable title dir; git supplies the (long) branch.
P_LONGBRANCH='{"workspace":{"current_dir":"/work/proj/claude-statusline"},"context_window":{"used_percentage":10,"total_input_tokens":20000,"context_window_size":200000},"model":{"display_name":"Opus 4.8"}}'
snapshot longbranch-trunc 100 "$P_LONGBRANCH"

# ── Summary ──────────────────────────────────────────────────────────────────
cd "$ROOT" || exit 2
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
