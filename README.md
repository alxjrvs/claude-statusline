# claude-statusline

A self-contained [Claude Code](https://claude.com/claude-code) statusline + subagent
statusline, each a single bash script. No Rust, no extra binaries — just `git` and `jq`.
Targets macOS system bash (3.2) so it's a portable drop-in.

## What it shows

```
claude-statusline [@main] [#42:approved] [1 untracked, 2 modified] [+42/-7]
[Opus 4.8 1M High Explanatory] $1.23 ($7.38/h)
CTX ####--------------------|-----  13% 128k/1M cache 78% 67%->AC
5h  |###########------------------  40% 3h 12m left [+8%] 7d 22%
```

Pure ASCII (`#` fill, `-` track, `|` clock/threshold, `*` burn projection) — no Nerd Font
required. Bars size themselves to the terminal via the `COLUMNS` env var, holding back a
small margin so they never overrun Claude's own chrome. The layout stays compact: 3–5
lines, with cost folded onto the model line and the 7-day window shown only when it's the
binding one.

- **Line 1** — repo (links to GitHub), branch, worktree, PR + review state, git counters (stash/conflict/untracked/modified/staged/ahead/behind), session churn `+added/-removed`. Long branch/worktree names are middle-ellipsized (`feature/some-l..name-here`) to a width budget so line 1 never wraps.
- **Line 2** — model, context-window flag (`1M` for the extended window), reasoning effort, output style, and session cost + `$/h` burn rate.
- **Line 3** — context window with a blackbody-gradient bar; an amber cell marks the autocompact threshold. The `%` escalates green→amber→red as it approaches; below the threshold a `N%->AC` badge shows live headroom, and once crossed a `[AC]` chip (plus `[200k+]` past 200k tokens). Trailing `Nk/Nk` is tokens-in-context / window size, and `cache N%` is the share served from the prompt cache.
- **Line 4** — the 5-hour rate-limit window. The blue pip is the wall-clock position in the window; the yellow pip projects end-of-window usage at the current burn rate; `time left` counts down to the reset; `[+N%]` is usage-vs-clock delta. When the 7-day window isn't binding it rides here as a compact `7d N%` badge.
- **Line 5** — the 7-day window, shown as its own bar only when it's ≥50% or busier than the 5-hour window.

Repo/branch/PR cells are OSC8 hyperlinks — ⌘-click them in a supporting terminal.

Colors honor [`NO_COLOR`](https://no-color.org) and degrade to a 256-color ramp on
terminals without truecolor (`COLORTERM`); the ASCII pip shapes keep the bars legible even
with color off entirely.

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

- The 5h window shows `no rate-limit data yet` until you've made a request in the session that populates it.
- The statusline writes nothing to disk — every cell is rendered from the JSON Claude Code passes on stdin.
- Set the autocompact marker with `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` (1–100); defaults to 80.
- Tune the right-edge chrome reserve with `CLAUDE_STATUSLINE_CHROME_MARGIN` (columns held back from the bar width); defaults to 8. Set `0` to fill edge-to-edge.

## Tests

`test/run.sh` renders the script against fixture payloads and diffs the ANSI-stripped
output against golden snapshots in `test/golden/`, plus color-mode and exit-code
assertions. Run `test/run.sh` to check, `test/run.sh --update` to refresh the snapshots
after an intentional change.
