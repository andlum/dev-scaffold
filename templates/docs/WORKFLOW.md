# Development workflow

@@projectName@@ is worked on by several agent sessions at once. The rules below exist so those
sessions don't collide — in git, in the database, or in production.

The short version: **one issue → one branch → one PR → merge@@if:deploy@@ → deploy from the button@@end@@.**

> Scaffolded from `@@scaffoldRepo@@` (`.scaffold.json` records the version). Sections below are
> yours to edit — the updater will show you a diff rather than clobbering local changes.

## Claim an issue

Work starts from an issue in @@issueTracker@@ that is specified well enough to be built without
asking questions. Claiming it means moving it to **In Progress** and assigning it before writing
any code. That status is the lock: if an issue is already In Progress, another session owns it.

## Branch

Never commit to `@@defaultBranch@@`. It takes merges from pull requests that passed their checks.

That rule is **not enforced by GitHub** unless this repo is public or on a paid plan — branch
protection and rulesets are gated behind both.

It could not be enforced there anyway. Agents run on the owner's laptop, as the owner, with the
owner's SSH key and `gh` token, so GitHub sees a single identity: any server-side rule would gate
the human equally, and any bypass granted to the human would be inherited by every agent session
acting as them.

So a small guard lives where the two *can* be told apart — the Claude Code harness.
`~/.claude/hooks/guard-default-branch.sh` runs as a `PreToolUse` hook, for agent sessions only,
and refuses:

- `git push` or `git commit` while HEAD is the default branch
- any push that targets it from elsewhere (`origin main`, `HEAD:main`, `:main`)

That's the whole list. Pushing a feature branch stays allowed; the workflow depends on it. The
owner's own terminal is not subject to any of it, which is the point. It is installed once at user
level, so it covers every repo — there is nothing to install here.

**It is deliberately this small.** Blocking `gh pr merge`, force pushes, or edits to the hook
itself defends against a session deliberately working around its own guardrail, which is not the
risk — the risk is an accident. Those cost real friction and false positives in exchange.

**What this is not.** It raises the cost of an accident; it is not a security boundary. Matching is
regex over command text, so a command that merely *mentions* a blocked phrase is refused (a false
positive, which fails safe) and a creative enough invocation slips past. Seatbelt, not a lock.

The cheapest guard needs no code at all: start each session by creating its worktree on a feature
branch, and a session is never sitting on the default branch to push from in the first place.

@@if:postgres@@
## Work in your own worktree

Parallel sessions must not share a checkout. Each session gets a git worktree, and the
integration-test database is already isolated for you: `scripts/test-db-url.sh` derives a database
name from the worktree directory, so the main checkout uses `@@dbName@@` and a worktree uses
`@@dbName@@_<worktree>`. Without this, concurrent integration runs would `TRUNCATE` each other's
tables mid-test and produce failures that look like real bugs.

Run `@@dbPrepareCommand@@` once per new worktree (and again after any schema change) to create and
migrate that database. Override with `@@envPrefix@@_TEST_DB=<name>` if you need a specific one.

## Migrations are the sharp edge of working in parallel

Two branches that each generate a migration produce the same sequence number and both append to the
migration journal — a guaranteed conflict, and one that resolves wrong if you just take both sides.

If your branch adds a migration and the default branch has moved on: rebase, **delete** your
generated migration and its journal entry, then regenerate so it is numbered after whatever landed.
Never hand-edit the SQL or the journal to renumber.
@@end@@

## Open a PR

The PR body must contain the tracker's closing keyword (e.g. `Closes @@issuePrefix@@-NNN`) so
merging closes the issue.

Run the checks yourself before opening it: `@@checks@@`@@if:postgres@@, plus the integration
suite@@end@@@@if:build@@, then the build@@end@@. That local run is the PR's gate. GitHub Actions is
rationed to stay inside the free plan's 2,000 private-repo minutes a month, so CI on GitHub does not
run on every push. It runs:

- on a PR labelled `@@ciLabel@@`, once, when it is marked ready for review (or labelled while ready).
  Use the label when a change is risky enough to want a clean-machine run before merging;
- nightly on `@@defaultBranch@@`, to catch two PRs that each passed but break together;
@@if:deploy@@
- before every deploy.
@@end@@
A commit that already passed is not run again. Don't add `push` or every-push `pull_request`
triggers to a workflow: that is what spent the minutes before.

Then stop and hand the PR over for review. Do not merge your own PR.

@@if:deploy@@
## Deploys

Merging does not deploy. The owner deploys from the button: Actions → Deploy → Run workflow on
`@@defaultBranch@@`. That runs `.github/workflows/deploy.yml`: CI (skipped if the commit already
passed), then the deploy. Deploys are serialised (`concurrency: deploy-production`, no
cancellation), so two in quick succession run in order rather than racing.

Nothing else deploys. Don't deploy by hand — it would ship the working tree, uncommitted changes
and all, with no CI in front of it.
@@end@@

## Close the loop

Once merged, the issue should be **Done**. Don't leave finished work sitting In Progress: the
status is what stops another session picking it up.

@@if:deploy@@
## Repository secrets

| Secret | Used by | How to rotate |
| --- | --- | --- |
| `FLY_API_TOKEN` | `deploy.yml` | `fly tokens create deploy -a @@deployApp@@`, then set it in GitHub → Settings → Secrets and variables → Actions |
@@end@@

## If the repo ever goes to a paid plan, or public

Enable a ruleset on `@@defaultBranch@@`: require a pull request (**0 required approvals** — GitHub
won't let you approve your own PR, so 1 would lock you out of merging your own work), require
conversation resolution, block force pushes, restrict deletions, and leave the bypass list empty.

Don't require status checks while CI is rationed: a required check only passes if CI runs on every
PR, which is the spend the rationing removed. If minutes stop being scarce, drop `types:` from the
`pull_request` trigger in `ci.yml` and the `pr-label` input, then require `Lint, typecheck, unit
tests, build`. It covers the integration suite too (`single-job`).
