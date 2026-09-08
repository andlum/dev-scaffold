#!/usr/bin/env bash
#
# PreToolUse guard. Keeps agent sessions off the repo's default branch.
#
# Installed once at USER level (~/.claude/settings.json), not per repo: it resolves everything it
# needs from $CLAUDE_PROJECT_DIR at call time, so one copy covers every repository, including ones
# that don't exist yet. There is nothing to scaffold into a project for this.
#
# Why a Claude Code hook rather than GitHub branch protection: agent sessions run on the owner's
# laptop, as the owner, with the owner's SSH key and token, so GitHub sees a single identity and
# any server-side rule would gate the owner identically. A hook applies to agent tool calls only,
# never the owner's own terminal.
#
# Deliberately minimal. It catches the accident -- a session committing or pushing while sitting on
# the default branch -- and nothing else. This is not a security boundary.
set -uo pipefail

INPUT=$(cat)
[[ "$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')" == "Bash" ]] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$COMMAND" ]] && exit 0
c=$(printf '%s' "$COMMAND" | tr '\n' ' ')

# Worktrees set CLAUDE_PROJECT_DIR to their own root, so this resolves per session.
dir="${CLAUDE_PROJECT_DIR:-.}"
g() { git -C "$dir" "$@" 2>/dev/null; }

# Not a git repo -- nothing to guard.
g rev-parse --git-dir >/dev/null || exit 0

# The default branch, in descending order of trustworthiness. `origin/HEAD` is what the remote
# actually says; the rest are fallbacks for a repo with no remote (or an unfetched one).
default="$(g symbolic-ref --quiet --short refs/remotes/origin/HEAD)"
default="${default#origin/}"
if [[ -z "$default" ]]; then
  for candidate in main master trunk; do
    if g show-ref --verify --quiet "refs/heads/$candidate"; then default="$candidate"; break; fi
  done
fi
[[ -z "$default" ]] && default="$(g config --get init.defaultBranch)"
[[ -z "$default" ]] && default="main"

# A detached or unreadable HEAD is treated as not-default.
branch="$(g symbolic-ref --quiet --short HEAD)"

# Projects override the guidance in .claude/workflow.conf (GUARD_ADVICE=...). Read, never sourced.
advice="Branch first, then open a pull request."
conf="$dir/.claude/workflow.conf"
if [[ -f "$conf" ]]; then
  v="$(grep -m1 '^GUARD_ADVICE=' "$conf" | cut -d= -f2- | sed 's/^"//; s/"$//')"
  [[ -n "$v" ]] && advice="$v"
elif [[ -f "$dir/docs/WORKFLOW.md" ]]; then
  advice="$advice See docs/WORKFLOW.md."
fi

block() {
  printf 'BLOCKED by guard-default-branch.sh: %s\n\n%s\n' "$1" "$advice" >&2
  exit 2
}

verb() { grep -qE "(^|[;&|(]|&&|\|\|)[[:space:]]*git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*$1\b" <<<"$c"; }

if [[ -n "$branch" && "$branch" == "$default" ]]; then
  verb push   && block "push while on $default"
  verb commit && block "commit while on $default"
fi

if verb push && grep -qE "\bpush\b.*([[:space:]:]${default}([[:space:]]|$)|:${default}\b)" <<<"$c"; then
  block "push targeting $default"
fi

exit 0
