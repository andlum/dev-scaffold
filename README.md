# dev-scaffold

The branch → PR → green CI → merge → deploy workflow, shared across projects.

Extracted from [kata](https://github.com/andlum/kata), where it evolved.

## The design constraint

Every file copied into a project is a file that must be re-synced forever. So most of this is not
copied:

| Piece | Mechanism | How an update reaches projects |
| --- | --- | --- |
| CI jobs | reusable workflow (`.github/workflows/node-ci.yml`) | automatically, on the next run |
| Fly deploy | reusable workflow (`.github/workflows/fly-deploy.yml`) | automatically, on the next run |
| Default-branch git guard | user-level Claude Code hook (`hooks/`) | `hooks/install.sh`, once per machine |
| Caller workflows, `docs/WORKFLOW.md`, `scripts/test-db-url.sh` | copied (`templates/`) | `bin/scaffold.mjs update` |

Only the last row needs a re-apply, and it is four files.

## Use it

Consume CI from a project — this is the whole integration:

```yaml
# .github/workflows/ci.yml
name: CI
on: [pull_request, workflow_call]
jobs:
  ci:
    uses: andlum/dev-scaffold/.github/workflows/node-ci.yml@v1
    with:
      checks: "lint typecheck test"
      postgres: true
```

Install the git guard, once per machine:

```bash
hooks/install.sh
```

Scaffold the copied files into a project:

```bash
node ~/Dev/dev-scaffold/bin/scaffold.mjs apply --set deploy=fly --set postgres=true
node ~/Dev/dev-scaffold/bin/scaffold.mjs status
```

`node bin/scaffold.mjs --help` lists every answer and its default.

## Updating a project

`.scaffold.json` records the hash of each file **as written**, which is what lets the updater tell
"the project edited this" from "the scaffold moved on".

```
$ node ~/Dev/dev-scaffold/bin/scaffold.mjs status
applied: 1.0.0   current: 1.1.0

  stale      .github/workflows/ci.yml     # untouched since apply — safe to rewrite
  drifted    docs/WORKFLOW.md             # the project edited it — needs a merge
  unchanged  scripts/test-db-url.sh
```

`update` rewrites `stale` files and renders `drifted` ones to `.scaffold/pending/<path>` for a
human or agent to merge. Drifted files are never overwritten: drift is usually deliberate, and
deciding what to keep is judgment, not a diff.

## Tests

```bash
hooks/guard-default-branch.test.sh
```

## Versioning

`v1` is a moving tag. Backwards-compatible changes move it; renaming a job or a `workflow_call`
input breaks every consumer at once, so those get a new major tag instead.
