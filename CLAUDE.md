# CLAUDE.md

This file guides Claude Code (claude.ai/code) when working in this repository.

## What This Is

A self-contained **Claude Code statusline**, shipped as two standalone bash scripts —
no Rust, no build step, no extra binaries beyond `git` and `jq`. Targets macOS system
bash (3.2) so it's a portable drop-in.

- **`statusline.sh`** — the main statusline. Reads Claude Code's statusline JSON on
  stdin and emits 2–4 colored lines (identity/config row, a context-window bar, and the
  5h/7d rate-limit windows). Pure ASCII pips (`#`/`-`/`|`/`*`), so no Nerd Font is
  required; colors honor `NO_COLOR` and degrade to a 256-color ramp off truecolor.
- **`subagent-statusline.sh`** — the agent-panel status line. Reads subagent JSON on
  stdin and emits `{"tasks":[...]}` in a single `jq` pass.
- **`install.sh`** — symlinks both scripts into `~/.local/bin` as `claude-statusline`
  and `claude-subagent-statusline`.

The `README.md` is the user-facing reference for what each cell means.

## How it's consumed

alxjrvs installs this into **every** Claude Code session via his dotFiles repo, not by
running `install.sh` directly. The dotFiles `claude_statusline` boom hook
(`hooks/claude_statusline.ts`) clones this repo beside the dotFiles checkout, `git pull
--ff-only`s it on each `boom apply`, and runs `install.sh` — which symlinks the scripts
to `~/.local/bin/claude-statusline` + `~/.local/bin/claude-subagent-statusline`.
`~/.claude/settings.json` then points `statusLine` / `subagentStatusLine` at those
`~/.local/bin` paths.

Practical consequence: **this repo is a live dependency of his whole toolchain.** A break
here degrades the statusline in every session on the next `boom apply`. Keep changes
conservative and green.

## Test / lint locally

```sh
bash test/run.sh              # snapshot suite: render vs. test/golden/, + color/exit/width asserts
bash test/run.sh --update     # regenerate golden snapshots after an INTENTIONAL output change
shellcheck -x *.sh test/run.sh
shfmt -d -i 2 -ci -sr *.sh test/run.sh   # -d = diff (dry-run); -w to apply
```

`test/run.sh` renders `statusline.sh` against fixture payloads in a throwaway non-git
(and one git) temp dir and diffs the ANSI-stripped output against `test/golden/*.txt`. It
also asserts color-mode behavior (ANSI on by default, none under `NO_COLOR`, indexed ramp
off truecolor), that the script always exits 0, and that no rendered line exceeds
`COLUMNS`. CI (`.github/workflows/ci.yml`) runs the same shellcheck + shfmt + `test/run.sh`
on every push/PR via mise.

The shfmt flags (`-i 2 -ci -sr`) match alxjrvs's dotFiles convention — that's the
canonical format for this repo; run `shfmt -w` before committing.

## Gotchas

- **Golden snapshots are ANSI-stripped.** They catch layout/content regressions, not
  color. After an intentional change to the rendered text, run `test/run.sh --update` and
  review the diff before committing. Color behavior is covered by separate presence/absence
  assertions in `run.sh`, not the goldens.
- **Determinism in tests** depends on pinned env: `HOME` off-tree (so `~` abbreviation is
  stable), a far-future `resets_at` sentinel (so "time left" pins to the full window and
  cancels the real clock), and a fixed `COLUMNS` per case. Don't introduce wall-clock or
  `$HOME`-relative output without pinning it in `run.sh`.
- **Autocompact marker defaults to 80%.** The amber threshold cell / `N%->AC` headroom /
  `[AC]` chip assume autocompact fires at 80% of the context window. That matches the
  dotFiles setup, which sets `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80`. Override the marker with
  `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (1–100) if a session's real threshold differs, or the
  marker will point at the wrong cell.
- **Bash 3.2 only.** No associative arrays, no `${var^^}`, no `mapfile`. The scripts use
  parallel indexed arrays and `tr` for case-folding on purpose — keep new code 3.2-safe so
  it runs on macOS system bash.
- **A statusline must never fail.** `statusline.sh` ends with `exit 0`, and missing JSON
  fields degrade to a dropped segment rather than an error. Preserve that: a non-zero exit
  or stderr noise leaks into Claude Code's UI.
- **`COLUMNS` chrome margin.** Bars fill the pane minus `CHROME_MARGIN` (default 8) so they
  don't overrun Claude's own UI hints and force a wrap. Tune with
  `CLAUDE_STATUSLINE_CHROME_MARGIN`.
