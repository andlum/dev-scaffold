#!/usr/bin/env bash
# Installs the default-branch guard at USER level, so it covers every repo on this machine.
# Idempotent: safe to re-run after pulling a new version of the scaffold.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"

mkdir -p "$DEST"
cp "$HERE/guard-default-branch.sh" "$DEST/"
chmod +x "$DEST/guard-default-branch.sh"
echo "installed $DEST/guard-default-branch.sh"

[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

CMD='"$HOME"/.claude/hooks/guard-default-branch.sh'
if jq -e --arg c "$CMD" '.hooks.PreToolUse[]?.hooks[]?|select(.command==$c)' "$SETTINGS" >/dev/null 2>&1; then
  echo "already wired in $SETTINGS"
  exit 0
fi

tmp="$(mktemp)"
jq --arg c "$CMD" '
  .hooks //= {} |
  .hooks.PreToolUse //= [] |
  .hooks.PreToolUse += [{matcher: "Bash", hooks: [{type: "command", command: $c}]}]
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
echo "wired PreToolUse hook in $SETTINGS"
