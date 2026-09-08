#!/usr/bin/env bash
# Exercises guard-default-branch.sh against the cases in the .tsv beside it.
# Column 1 picks the fixture repo. The `trunk*` fixtures have a real remote whose HEAD points at
# `trunk`, which is what proves the guard reads the default branch rather than assuming `main`.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/guard-default-branch.sh"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

mk() { # mk <name> <default-branch> <checkout-branch> <with-remote>
  local d="$FIX/$1" b="$2" co="$3" remote="$4"
  git init -q -b "$b" "$d"
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  if [[ "$remote" == yes ]]; then
    git init -q --bare -b "$b" "$d.origin"
    git -C "$d" remote add origin "$d.origin"
    git -C "$d" push -q origin "$b"
    git -C "$d" remote set-head origin "$b"
  fi
  [[ "$co" != "$b" ]] && git -C "$d" checkout -q -b "$co"
  return 0
}

mk feature   main  some-feature no
mk main      main  main         no
mk trunk     trunk trunk        yes
mk trunkfeat trunk some-feature yes

pass=0; fail=0
while IFS=$'\t' read -r kind name payload want; do
  [[ -z "${kind:-}" ]] && continue
  out=$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$FIX/$kind" bash "$HOOK" 2>&1)
  got=$?
  if [[ "$got" == "$want" ]]; then
    printf 'PASS  [%-9s] %-36s exit=%s\n' "$kind" "$name" "$got"; pass=$((pass+1))
  else
    printf 'FAIL  [%-9s] %-36s exit=%s want=%s\n        %s\n' "$kind" "$name" "$got" "$want" "${out%%$'\n'*}"; fail=$((fail+1))
  fi
done < "$HERE/guard-default-branch.cases.tsv"

echo
echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
