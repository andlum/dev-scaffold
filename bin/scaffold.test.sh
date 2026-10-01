#!/usr/bin/env bash
# End-to-end tests for scaffold.mjs: first apply, drift detection, update, and the regression that
# a staged file must never become writable just because apply ran again.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
S="$HERE/scaffold.mjs"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok() { if [[ "$2" == "$3" ]]; then printf 'PASS  %s\n' "$1"; pass=$((pass+1));
       else printf 'FAIL  %s\n        got:  %s\n        want: %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
state() { node "$S" status --dir "$1" | grep -E "[[:space:]]$2\$" | awk '{print $1}'; }

A=(--set postgres=true --set deploy=fly --set projectName=demo)

# --- first apply into an empty project -------------------------------------------------------
P="$T/fresh"; mkdir -p "$P"
node "$S" apply --dir "$P" "${A[@]}" >/dev/null
ok "fresh apply writes ci.yml"        "$([ -f "$P/.github/workflows/ci.yml" ] && echo yes)" "yes"
ok "fresh apply records manifest"     "$([ -f "$P/.scaffold.json" ] && echo yes)"           "yes"
ok "fresh apply -> unchanged"         "$(state "$P" docs/WORKFLOW.md)"                      "unchanged"
ok "test-db-url.sh is executable"     "$([ -x "$P/scripts/test-db-url.sh" ] && echo yes)"   "yes"

# --- build:false, for projects with no build script ------------------------------------------
B="$T/nobuild"; mkdir -p "$B"
node "$S" apply --dir "$B" --set build=false >/dev/null
ok "build=false emits the input"      "$(grep -c '^      build: false$' "$B/.github/workflows/ci.yml")" "1"
node "$S" apply --dir "$T/nobuild2" --set build=true >/dev/null 2>&1 || mkdir -p "$T/nobuild2"
node "$S" apply --dir "$T/nobuild2" >/dev/null
ok "build=true omits the input"       "$(grep -c 'build:' "$T/nobuild2/.github/workflows/ci.yml")"      "0"
ok "no deploy.yml without a target"   "$([ -f "$T/nobuild2/.github/workflows/deploy.yml" ] && echo yes || echo no)" "no"

# --- rationed CI (1.2.0) ------------------------------------------------------------------------
ok "ci.yml has no every-push trigger" "$(grep -cE '^  (push|pull_request):$' "$P/.github/workflows/ci.yml")" "1"
ok "ci.yml PR trigger is ready/label" "$(grep -c 'types: \[ready_for_review, labeled\]' "$P/.github/workflows/ci.yml")" "1"
ok "ci.yml default label is ci"       "$(grep -c '^      pr-label: "ci"$' "$P/.github/workflows/ci.yml")" "1"
ok "ci.yml opts in to single-job"     "$(grep -c '^      single-job: true$' "$P/.github/workflows/ci.yml")" "1"
L="$T/label"; mkdir -p "$L"
node "$S" apply --dir "$L" --set ciLabel=tier:data >/dev/null
ok "ciLabel answer reaches ci.yml"    "$(grep -c '^      pr-label: "tier:data"$' "$L/.github/workflows/ci.yml")" "1"
ok "deploy.yml is button-only"        "$(grep -c '^  push:' "$P/.github/workflows/deploy.yml")" "0"

# --- a local edit is detected as drift, and update never clobbers it --------------------------
echo "# project-specific" >> "$P/docs/WORKFLOW.md"
ok "local edit -> drifted"            "$(state "$P" docs/WORKFLOW.md)"                      "drifted"
node "$S" update --dir "$P" >/dev/null
ok "update kept the local edit"       "$(tail -1 "$P/docs/WORKFLOW.md")"                    "# project-specific"
ok "update staged the new render"     "$([ -f "$P/.scaffold/pending/docs/WORKFLOW.md" ] && echo yes)" "yes"

# REGRESSION: a staged file must stay drifted. Recording its on-disk hash would reclassify it as
# "stale" -- safe to overwrite -- and the next update would silently destroy the project's edit.
ok "still drifted after update"       "$(state "$P" docs/WORKFLOW.md)"                      "drifted"
node "$S" update --dir "$P" >/dev/null
ok "still drifted after 2nd update"   "$(state "$P" docs/WORKFLOW.md)"                      "drifted"
ok "2nd update kept the local edit"   "$(tail -1 "$P/docs/WORKFLOW.md")"                    "# project-specific"

# --- applying over a project that already had its own files ----------------------------------
Q="$T/existing"; mkdir -p "$Q/docs"
echo "our own workflow doc" > "$Q/docs/WORKFLOW.md"
node "$S" apply --dir "$Q" "${A[@]}" >/dev/null
ok "pre-existing file untouched"      "$(cat "$Q/docs/WORKFLOW.md")"                        "our own workflow doc"
ok "pre-existing -> untracked"        "$(state "$Q" docs/WORKFLOW.md)"                      "untracked"
node "$S" apply --dir "$Q" "${A[@]}" >/dev/null
ok "2nd apply still untouched"        "$(cat "$Q/docs/WORKFLOW.md")"                        "our own workflow doc"

# --- an untouched file follows the scaffold forward -------------------------------------------
# Restore from a copy, not git: `git checkout` would also discard uncommitted template edits.
TPL="$ROOT/templates/docs/WORKFLOW.md"
cp "$TPL" "$T/WORKFLOW.md.orig"
trap 'cp "$T/WORKFLOW.md.orig" "$TPL"; rm -rf "$T"' EXIT
printf '\n# added upstream\n' >> "$TPL"
R="$T/fresh2"; mkdir -p "$R"
node "$S" apply --dir "$R" "${A[@]}" >/dev/null
cp "$T/WORKFLOW.md.orig" "$TPL"
ok "untouched file -> stale"          "$(state "$R" docs/WORKFLOW.md)"                      "stale"
node "$S" update --dir "$R" >/dev/null
ok "stale file was rewritten"         "$(state "$R" docs/WORKFLOW.md)"                      "unchanged"

echo
echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
