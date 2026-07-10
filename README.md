# claude-statusline

A self-contained [Claude Code](https://claude.com/claude-code) statusline + subagent
statusline, each a single bash script. No Rust, no extra binaries — just `git` and `jq`.
Targets macOS system bash (3.2) so it's a portable drop-in.

## What it shows

```
claude-statusline [@main] [#42:approved] [1 untracked, 2 modified] [+42/-7]
[Opus 4.8 1M High Explanatory]
CTX ####--------------------|-----  13% 128k/1M cache 78%
5h  |###########------------------  40% -3h 12m [+8%]
7d  |#####-------------------------  22% -5d 06h [-3%]
[$1.23 ($7.38/h) 45% api]
```

Pure ASCII (`#` fill, `-` track, `|` clock/threshold, `*` burn projection) — no Nerd Font
required. Bars size themselves to the terminal via the `COLUMNS` env var.

- **Line 1** — repo (links to GitHub), branch, worktree, PR + review state, git counters (stash/conflict/untracked/modified/staged/ahead/behind), session churn `+added/-removed`.
- **Line 2** — model, context-window flag (`1M` for the extended window), reasoning effort, and output style.
- **Line 3** — context window with a blackbody-gradient bar; an amber cell marks the autocompact threshold, `AC` when crossed, `200k+` past 200k tokens. Trailing `Nk/Nk` is tokens-in-context / window size, and `cache N%` is the share served from the prompt cache.
- **Lines 4–5** — 5-hour and 7-day rate-limit windows. The blue pip is the wall-clock position in the window; the yellow pip projects end-of-window usage at the current burn rate; `[+N%]` is usage-vs-clock delta.
- **Line 6** — session cost, `$/h` burn rate, and `N% api` (share of wall-clock spent waiting on the API), all read straight from the stdin JSON.

Repo/branch/PR cells are OSC8 hyperlinks — ⌘-click them in a supporting terminal.

`subagent-statusline.sh` renders the agent-panel task line (one jq pass; integer token
counts like `12k`).

## Requirements

- `git` and `jq` on `PATH`.
- No special font — output is pure ASCII.
- Claude Code v2.1.153+ for `COLUMNS`-based bar sizing (older versions fall back to a fixed width).
- Works with macOS system bash (3.2) and newer.

## Install

```sh
git clone https://github.com/alxjrvs/claude-statusline ~/Code/claude-statusline
~/Code/claude-statusline/install.sh
```

`install.sh` symlinks both scripts into `~/.local/bin`, then add to `~/.claude/settings.json`:

```json
{
  "statusLine":         { "type": "command", "command": "~/.local/bin/claude-statusline", "refreshInterval": 15 },
  "subagentStatusLine": { "type": "command", "command": "~/.local/bin/claude-subagent-statusline" }
}
```

`refreshInterval` is recommended here: status lines are otherwise event-driven, so the
time-based cells (the 5h/7d clock pips, `time left`, and the burn projection) would
freeze while the session sits idle. A 15s timer keeps them live. Omit it to update only
on events.

## Notes

- The 5h/7d windows show `rate_limits unavailable` until you've made a request in the session that populates them.
- The statusline writes nothing to disk — every cell is rendered from the JSON Claude Code passes on stdin.
- Set the autocompact marker with `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (1–100); defaults to 80.
