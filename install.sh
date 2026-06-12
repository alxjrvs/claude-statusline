#!/usr/bin/env bash
# install.sh — symlink the statusline scripts onto PATH (~/.local/bin).
set -euo pipefail
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "${HOME}/.local/bin"
chmod +x "${dir}/statusline.sh" "${dir}/subagent-statusline.sh"
ln -sf "${dir}/statusline.sh" "${HOME}/.local/bin/claude-statusline"
ln -sf "${dir}/subagent-statusline.sh" "${HOME}/.local/bin/claude-subagent-statusline"
cat << 'EOF'
Installed:
  ~/.local/bin/claude-statusline           -> statusline.sh
  ~/.local/bin/claude-subagent-statusline  -> subagent-statusline.sh

Add to ~/.claude/settings.json:
  "statusLine":         { "type": "command", "command": "~/.local/bin/claude-statusline" },
  "subagentStatusLine": { "type": "command", "command": "~/.local/bin/claude-subagent-statusline" }
EOF
