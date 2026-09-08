---
name: scaffold
description: Apply or update the shared branch/CI/deploy workflow scaffold in a project — reusable GitHub Actions CI, deploy-on-merge, a default-branch git guard, and a WORKFLOW.md. Use when setting up CI on a new project, moving a project to the PR-based workflow, or pulling newer scaffold changes into a project that already has it.
---

# Scaffold

Most of this scaffold is **not** copied into projects, and that is the point — copied files have to
be re-synced forever.

| Piece | Lives where | Updating it |
| --- | --- | --- |
| CI jobs | reusable workflow in `andlum/dev-scaffold` | push to the scaffold; every project on the same tag picks it up on its next run |
| Deploy job | reusable workflow in `andlum/dev-scaffold` | same |
| Git guard | `~/.claude/hooks/` (user level) | `hooks/install.sh`, once per machine |
| Caller workflows, `WORKFLOW.md`, `test-db-url.sh` | copied into the project | `scaffold update` (below) |

Only the last row needs this skill.

## 1. Locate the scaffold

```bash
SCAFFOLD=~/Dev/dev-scaffold
[ -d "$SCAFFOLD" ] || git clone https://github.com/andlum/dev-scaffold "$SCAFFOLD"
git -C "$SCAFFOLD" pull --ff-only
```

## 2. Pick the verb

Run `node "$SCAFFOLD/bin/scaffold.mjs" status` in the target repo first, always.

- No `.scaffold.json` → **apply** (first install)
- `.scaffold.json` present → **update**

## 3. Applying to a new project

Infer answers from the repo rather than asking. Run `scaffold.mjs --help` for the full list with
defaults; only pass what differs.

| Answer | Infer from |
| --- | --- |
| `packageManager` | lockfile (`pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`) |
| `nodeVersion` | `.nvmrc`, `engines.node`, or the current major |
| `checks` | which of `lint`/`typecheck`/`test` exist in `package.json` scripts |
| `postgres` | a postgres service in `docker-compose.yml`, or a `*.itest.*` test suite |
| `dbName`, `envPrefix`, `dbBaseUrl` | existing test-db setup, else derive from the project name |
| `deploy` | `fly.toml` → `fly`; otherwise leave empty |
| `defaultBranch` | `git symbolic-ref --short refs/remotes/origin/HEAD` |

Ask the user only for what the repo cannot answer: the issue tracker and its key prefix, and
whether merges to the default branch should deploy.

`buildEnv` is the one thing you cannot detect. Most projects need a placeholder for an env var the
build imports but never uses (a DB URL, an API key). Apply without it, run the build, and add it
only if the build fails on a missing variable.

If the project runs a formatter over everything (Prettier, dprint), exempt the generated files
rather than reformatting them — `.github/workflows/` in `.prettierignore` or equivalent. Running
the formatter over them makes them differ from the template, which marks them permanently
`drifted` and turns every future update into a manual merge.

After applying, verify rather than assume:

```bash
node -e 'require("js-yaml")' 2>/dev/null || true   # or: gh workflow list
git add -A && git status --short
```

Tell the user which repository secrets they must set themselves (e.g. `FLY_API_TOKEN`) — you
cannot set those.

## 4. Updating a project that already has it

`scaffold update` writes files the project has not touched and **stages** the rest:

```
written:
  stale      .github/workflows/ci.yml

staged for merge (NOT applied — the project edited these):
  drifted    docs/WORKFLOW.md  ->  .scaffold/pending/docs/WORKFLOW.md
```

For each staged file, diff it against the live one and merge **by hand, keeping project-specific
content**:

```bash
diff -u docs/WORKFLOW.md .scaffold/pending/docs/WORKFLOW.md
```

Drift is usually deliberate — a project deleted a section that does not apply to it, or added one
that only applies to it. Carry the scaffold's *new* material across; do not restore material the
project removed on purpose. When done, `rm -rf .scaffold/pending` and re-run `scaffold status` to
confirm everything reads `unchanged`.

## 5. Changing the scaffold itself

Edit `templates/` or `.github/workflows/` in the scaffold repo, bump `VERSION`, commit, then move
the `v1` tag so consuming projects pick it up:

```bash
git tag -f v1 && git push -f origin v1
```

Move `v1` only for backwards-compatible changes. Renaming a job, or removing or renaming a
`workflow_call` input, breaks every consumer at once — cut `v2` instead and update projects
deliberately.
