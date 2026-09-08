#!/usr/bin/env bash
#
# Prints the Postgres URL this checkout should use for integration tests.
#
# Agent sessions run in parallel git worktrees but share one local Postgres. A single shared test
# database would let concurrent integration runs TRUNCATE each other mid-test — flaky failures that
# read as real bugs. So the main checkout keeps `@@dbName@@` and every other worktree gets its own,
# derived from the worktree directory name.
#
# Overrides, highest precedence first:
#   TEST_DATABASE_URL — the whole URL. CI sets this to its service container.
#   @@envPrefix@@_TEST_DB — database name only, against the local Postgres.
set -euo pipefail

if [[ -n "${TEST_DATABASE_URL:-}" ]]; then
  echo "$TEST_DATABASE_URL"
  exit 0
fi

base="${@@envPrefix@@_TEST_DB_BASE_URL:-@@dbBaseUrl@@}"

if [[ -n "${@@envPrefix@@_TEST_DB:-}" ]]; then
  echo "$base/${@@envPrefix@@_TEST_DB}"
  exit 0
fi

root="$(git rev-parse --show-toplevel)"
# --git-common-dir points at the main checkout's .git for every linked worktree, and may be
# relative, so resolve it before taking its parent.
main_root="$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")"

if [[ "$root" == "$main_root" ]]; then
  echo "$base/@@dbName@@"
else
  slug="$(basename "$root" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | cut -c1-40)"
  echo "$base/@@dbName@@_${slug}"
fi
