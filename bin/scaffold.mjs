#!/usr/bin/env node
// Applies and re-applies the copied part of the scaffold.
//
// Most of the scaffold is NOT copied — CI lives in reusable workflows this repo hosts, and the
// git guard is a user-level Claude Code hook. What is left is the handful of files below, which
// genuinely cannot be referenced remotely. Those need an update story, which is this script.
//
// The core idea: .scaffold.json records the hash of each file AS WRITTEN. On update we compare the
// file on disk to that record to tell "the project edited this" from "the scaffold moved on".
//
//   status  what would change, and why
//   apply   first install
//   update  rewrite files the project has not touched; stage the rest for a human/agent merge
//
// Drifted files are never overwritten. They are rendered to .scaffold/pending/<path> instead and
// merging is left to whoever runs this — that judgment ("this project deleted the migrations
// section on purpose") is exactly what a diff algorithm gets wrong.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, existsSync, mkdirSync, chmodSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const VERSION = readFileSync(join(ROOT, "VERSION"), "utf8").trim();
const MANIFEST = ".scaffold.json";

const DEFAULTS = {
  projectName: null,
  scaffoldRepo: "andlum/dev-scaffold",
  scaffoldRef: "v1",
  defaultBranch: "main",
  packageManager: "pnpm",
  nodeVersion: "24",
  checks: "lint typecheck test",
  buildEnv: "",
  postgres: false,
  dbUser: "postgres",
  dbPassword: "postgres",
  dbName: "test",
  dbBaseUrl: "postgres://postgres:postgres@localhost:5432",
  dbPrepareCommand: "",
  integrationCommand: "pnpm test:integration",
  envPrefix: "APP",
  deploy: "",
  deployApp: "",
  issueTracker: "GitHub Issues",
  issuePrefix: "GH",
};

// path -> { template, when, mode }
const FILES = [
  { out: ".github/workflows/ci.yml", tpl: "templates/.github/workflows/ci.yml" },
  { out: "docs/WORKFLOW.md", tpl: "templates/docs/WORKFLOW.md" },
  { out: ".github/workflows/deploy.yml", tpl: "templates/.github/workflows/deploy.yml", when: (a) => a.deploy === "fly" },
  { out: "scripts/test-db-url.sh", tpl: "templates/scripts/test-db-url.sh", when: (a) => a.postgres, mode: 0o755 },
];

const truthy = (v) => v !== undefined && v !== null && v !== false && v !== "" && v !== "false";
const sha = (s) => createHash("sha256").update(s).digest("hex");

function render(tpl, vars) {
  let out = tpl;
  // Whole-line blocks first, so the conditional's own lines vanish with it.
  out = out.replace(/^@@if:(\w+)@@[ \t]*\r?\n([\s\S]*?)^@@end@@[ \t]*\r?\n/gm, (_m, k, body) =>
    truthy(vars[k]) ? body : "",
  );
  // Then inline / mid-sentence conditionals.
  out = out.replace(/@@if:(\w+)@@([\s\S]*?)@@end@@/g, (_m, k, body) => (truthy(vars[k]) ? body : ""));
  out = out.replace(/@@(\w+)@@/g, (m, k) => (k in vars ? String(vars[k]) : m));
  return out;
}

function plan(answers) {
  return FILES.filter((f) => !f.when || f.when(answers)).map((f) => ({
    ...f,
    content: render(readFileSync(join(ROOT, f.tpl), "utf8"), answers),
  }));
}

function loadManifest(dir) {
  const p = join(dir, MANIFEST);
  if (!existsSync(p)) return null;
  return JSON.parse(readFileSync(p, "utf8"));
}

/**
 * new       — not on disk yet
 * unchanged — on disk and identical to what we would write
 * stale     — on disk, untouched since we wrote it, but the scaffold has moved on: safe to rewrite
 * drifted   — the project edited it; rewriting would destroy that work
 * untracked — exists on disk but we have no record of writing it (a pre-existing file)
 */
function classify(dir, manifest, file) {
  const abs = join(dir, file.out);
  if (!existsSync(abs)) return "new";
  const disk = readFileSync(abs, "utf8");
  if (disk === file.content) return "unchanged";
  const recorded = manifest?.files?.[file.out];
  if (!recorded) return "untracked";
  return sha(disk) === recorded ? "stale" : "drifted";
}

function write(dir, rel, content, mode) {
  const abs = join(dir, rel);
  mkdirSync(dirname(abs), { recursive: true });
  writeFileSync(abs, content);
  if (mode) chmodSync(abs, mode);
}

function parseArgs(argv) {
  const out = { _: [], set: {} };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--set") {
      const [k, ...rest] = argv[++i].split("=");
      out.set[k] = rest.join("=");
    } else if (a === "--answers") out.answers = argv[++i];
    else if (a === "--dir") out.dir = argv[++i];
    else if (a === "--dry-run") out.dryRun = true;
    else if (a === "--force") out.force = true;
    else out._.push(a);
  }
  return out;
}

function coerce(v) {
  if (v === "true") return true;
  if (v === "false") return false;
  return v;
}

function resolveAnswers(dir, args) {
  const manifest = loadManifest(dir);
  let answers = { ...DEFAULTS, ...(manifest?.answers ?? {}) };
  if (args.answers) answers = { ...answers, ...JSON.parse(readFileSync(args.answers, "utf8")) };
  for (const [k, v] of Object.entries(args.set)) answers[k] = coerce(v);
  if (!answers.projectName) answers.projectName = dir.split("/").filter(Boolean).pop();
  return { answers, manifest };
}

function saveManifest(dir, answers, files) {
  const manifest = {
    scaffold: { repo: answers.scaffoldRepo, ref: answers.scaffoldRef, version: VERSION },
    answers,
    files: Object.fromEntries(files.map((f) => [f.out, sha(f.content)])),
  };
  writeFileSync(join(dir, MANIFEST), JSON.stringify(manifest, null, 2) + "\n");
}

const cmd = process.argv[2];
const args = parseArgs(process.argv.slice(3));
const dir = resolve(args.dir ?? process.cwd());

if (!cmd || ["-h", "--help", "help"].includes(cmd)) {
  console.log(`scaffold ${VERSION}

  scaffold status [--dir D]
  scaffold apply  [--dir D] [--answers a.json] [--set key=value ...] [--dry-run] [--force]
  scaffold update [--dir D] [--set key=value ...] [--dry-run]

Answers (current defaults):
${Object.entries(DEFAULTS)
  .map(([k, v]) => `  ${k.padEnd(20)} ${JSON.stringify(v)}`)
  .join("\n")}`);
  process.exit(0);
}

const { answers, manifest } = resolveAnswers(dir, args);
const files = plan(answers);
const states = files.map((f) => ({ file: f, state: classify(dir, manifest, f) }));

if (cmd === "status") {
  if (manifest) console.log(`applied: ${manifest.scaffold.version}   current: ${VERSION}\n`);
  else console.log(`not applied here (current scaffold ${VERSION})\n`);
  for (const { file, state } of states) console.log(`  ${state.padEnd(10)} ${file.out}`);
  const drift = states.filter((s) => s.state === "drifted" || s.state === "untracked");
  if (drift.length) console.log(`\n${drift.length} file(s) need a merge; \`update\` will stage them under .scaffold/pending/.`);
  process.exit(0);
}

if (cmd === "apply" || cmd === "update") {
  const written = [];
  const staged = [];
  for (const { file, state } of states) {
    const overwritable = state === "new" || state === "unchanged" || state === "stale" || (args.force && cmd === "apply");
    if (overwritable) {
      if (!args.dryRun) write(dir, file.out, file.content, file.mode);
      if (state !== "unchanged") written.push(`${state.padEnd(10)} ${file.out}`);
    } else {
      const pending = join(".scaffold/pending", file.out);
      if (!args.dryRun) write(dir, pending, file.content, file.mode);
      staged.push(`${state.padEnd(10)} ${file.out}  ->  ${pending}`);
    }
  }
  // Record only what is actually on disk, so a staged file stays "drifted" until it is merged.
  if (!args.dryRun) {
    const onDisk = files.map((f) => ({
      out: f.out,
      content: existsSync(join(dir, f.out)) ? readFileSync(join(dir, f.out), "utf8") : f.content,
    }));
    saveManifest(dir, answers, onDisk);
  }
  console.log(written.length ? "written:\n  " + written.join("\n  ") : "nothing to write");
  if (staged.length) {
    console.log("\nstaged for merge (NOT applied — the project edited these):\n  " + staged.join("\n  "));
    console.log("\nMerge each, delete .scaffold/pending, then re-run `scaffold status`.");
  }
  if (args.dryRun) console.log("\n(dry run — nothing written)");
  process.exit(0);
}

console.error(`unknown command: ${cmd}`);
process.exit(1);
