#!/usr/bin/env node
// validate-done.mjs — check an IQA lane done file.
//
// Three checks, in order:
//   1. schema-valid against the sibling iqa-done.schema.json
//      (plus: Blocked requires a non-empty blocker)
//   2. branch exists on the git remote (default: origin)
//   3. every evidence file exists (evidencePaths + reportPath when present,
//      resolved relative to --workdir, default: the done file's directory)
//
// Plus terse-handoff WARNs (never failures): summary ≤280 chars, lane
// report ≤60 lines — the handoff stays small enough to paste into a
// parent prompt without blowing its context.
//
// Usage:
//   node validate-done.mjs <done-file> [--remote <name>] [--workdir <dir>] [--json]
//
// Exit codes: 0 = valid (warnings allowed), 1 = validation failure,
// 2 = engine error (bad args, unreadable files, unreachable remote).
// No dependencies. No writes. Never prints secret values — the done file
// must not contain any (see the schema description).

import { readFileSync, existsSync } from 'node:fs';
import { dirname, resolve, isAbsolute } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCHEMA_PATH = resolve(HERE, 'iqa-done.schema.json');
const SHA_RE = /^[0-9a-f]{7,40}$/;

function usage() {
  return [
    'Usage: node validate-done.mjs <done-file> [--remote <name>] [--workdir <dir>] [--json]',
    '  <done-file>  path to the .iqa-done-<id>.json file to check',
    '  --remote     git remote to check the branch against (default: origin)',
    '  --workdir    base dir for relative evidence paths (default: done file dir)',
    '  --json       emit the result as JSON instead of human-readable lines',
  ].join('\n');
}

function parseArgs(argv) {
  const out = { file: '', remote: 'origin', workdir: '', json: false };
  const rest = [...argv];
  while (rest.length) {
    const a = rest.shift();
    if (a === '--remote') out.remote = rest.shift() ?? '';
    else if (a === '--workdir') out.workdir = rest.shift() ?? '';
    else if (a === '--json') out.json = true;
    else if (a === '--help' || a === '-h') { out.help = true; return out; }
    else if (a.startsWith('--')) throw new Error(`unknown flag: ${a}`);
    else if (!out.file) out.file = a;
    else throw new Error(`unexpected argument: ${a}`);
  }
  if (!out.help && !out.file) throw new Error('missing <done-file>\n' + usage());
  if (!out.help && !out.remote) throw new Error('empty --remote');
  return out;
}

// --- Minimal draft-07-shaped validation, driven by the schema file ---------

function fail(errors, path, msg) { errors.push(`${path}: ${msg}`); }

function checkSchema(schema, doc) {
  const errors = [];
  const warnings = [];
  const props = schema.properties ?? {};
  for (const key of schema.required ?? []) {
    if (doc[key] === undefined) fail(errors, key, 'missing required property');
  }
  for (const [key, value] of Object.entries(doc)) {
    const spec = props[key];
    if (!spec) {
      if (schema.additionalProperties === false) fail(errors, key, 'unknown property');
      continue;
    }
    const path = key;
    const types = Array.isArray(spec.type) ? spec.type : [spec.type];
    const actual = Array.isArray(value) ? 'array' : (value === null ? 'null' : typeof value);
    if (spec.type && !types.includes(actual)) {
      fail(errors, path, `expected ${types.join('/')} but got ${actual}`);
      continue;
    }
    if (spec.const !== undefined && value !== spec.const) {
      fail(errors, path, `must equal ${JSON.stringify(spec.const)}`);
    }
    if (spec.enum && !spec.enum.includes(value)) {
      fail(errors, path, `must be one of ${spec.enum.join(', ')}`);
    }
    if (spec.minLength !== undefined && typeof value === 'string' && value.length < spec.minLength) {
      fail(errors, path, `must be at least ${spec.minLength} characters`);
    }
    if (spec.pattern && typeof value === 'string' && !(new RegExp(spec.pattern).test(value))) {
      fail(errors, path, `must match ${spec.pattern}`);
    }
    if (actual === 'array' && spec.items) {
      value.forEach((item, i) => {
        if (spec.items.type && typeof item !== spec.items.type) {
          fail(errors, `${path}[${i}]`, `expected ${spec.items.type}`);
          return;
        }
        if (spec.items.minLength !== undefined && item.length < spec.items.minLength) {
          fail(errors, `${path}[${i}]`, 'must not be empty');
        }
        if (spec.items.pattern && !(new RegExp(spec.items.pattern).test(item))) {
          fail(errors, `${path}[${i}]`, `must match ${spec.items.pattern}`);
        }
      });
    }
    if (actual === 'object' && spec.additionalProperties) {
      const allowed = Array.isArray(spec.additionalProperties.type)
        ? spec.additionalProperties.type
        : [spec.additionalProperties.type];
      for (const [k, v] of Object.entries(value)) {
        const t = typeof v;
        if (!allowed.includes(t)) fail(errors, `${path}.${k}`, `expected ${allowed.join('/')} but got ${t}`);
      }
    }
  }
  // Cross-field rules the JSON Schema shape cannot express alone.
  if (doc.status === 'Blocked' && (!doc.blocker || !doc.blocker.trim())) {
    fail(errors, 'blocker', 'required when status is Blocked (owner + what is needed)');
  }
  if (doc.status === 'Finished') {
    if (Array.isArray(doc.shas) && doc.shas.length === 0) {
      warnings.push('shas: Finished with no SHAs — expected at least one pushed commit');
    }
    if (Array.isArray(doc.evidencePaths) && doc.evidencePaths.length === 0) {
      warnings.push('evidencePaths: Finished with no evidence paths');
    }
    if (doc.evidencePaths?.length && !doc.reportPath) {
      warnings.push('reportPath: omitted — expected the lane report path on Finished');
    }
  }
  // Terse-handoff envelope (token compression): the done JSON is the machine
  // handoff and the summary is the doorbell — both stay small. WARN-only
  // (warnings allowed, exit 0): a verbose worker still delivered.
  if (typeof doc.summary === 'string' && doc.summary.length > 280) {
    warnings.push(`summary: ${doc.summary.length} chars — keep the doorbell one line (≤280 chars)`);
  }
  // SHA shape double-check independent of the schema pattern (defense in depth).
  if (Array.isArray(doc.shas)) {
    doc.shas.forEach((s, i) => {
      if (typeof s === 'string' && !SHA_RE.test(s)) fail(errors, `shas[${i}]`, 'must be 7-40 lowercase hex chars');
    });
  }
  return { errors, warnings };
}

// --- Remote + filesystem checks ---------------------------------------------

function branchExistsOnRemote(remote, branch) {
  // ls-remote prints "<sha>\trefs/heads/<branch>" per match; empty = absent.
  // Throwing here means unreachable remote or missing git — an engine error,
  // never a pass (fail-closed: unverifiable is not fresh/valid).
  const out = execFileSync('git', ['ls-remote', '--heads', remote, branch], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return out.trim().length > 0;
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`ERROR: ${err.message}\n`);
    process.exit(2);
  }
  if (args.help) { process.stdout.write(usage() + '\n'); process.exit(0); }

  const results = []; // {check, status: PASS|FAIL|WARN|ERROR, detail}
  const failClosed = (check, detail) => { results.push({ check, status: 'ERROR', detail }); };

  let schema;
  try {
    schema = JSON.parse(readFileSync(SCHEMA_PATH, 'utf8'));
  } catch (err) {
    process.stderr.write(`ERROR: cannot read schema at ${SCHEMA_PATH}: ${err.message}\n`);
    process.exit(2);
  }

  const donePath = resolve(args.file);
  let doc;
  try {
    doc = JSON.parse(readFileSync(donePath, 'utf8'));
  } catch (err) {
    failClosed('schema-valid', `cannot read/parse ${donePath}: ${err.message}`);
    return emit(args, results, 2);
  }
  if (doc === null || typeof doc !== 'object' || Array.isArray(doc)) {
    results.push({ check: 'schema-valid', status: 'FAIL', detail: 'top level must be a JSON object' });
    return emit(args, results, 1);
  }

  const { errors, warnings } = checkSchema(schema, doc);
  if (errors.length) {
    results.push({ check: 'schema-valid', status: 'FAIL', detail: errors.join('; ') });
  } else {
    results.push({ check: 'schema-valid', status: 'PASS', detail: `status=${doc.status} branch=${doc.branch} shas=${doc.shas.length}` });
  }
  for (const w of warnings) results.push({ check: 'schema-shape', status: 'WARN', detail: w });

  // Branch check runs even when the schema failed — it names the drift either way.
  try {
    if (typeof doc.branch === 'string' && doc.branch) {
      if (branchExistsOnRemote(args.remote, doc.branch)) {
        results.push({ check: 'branch-exists-on-origin', status: 'PASS', detail: `${doc.branch} found on ${args.remote}` });
      } else {
        results.push({ check: 'branch-exists-on-origin', status: 'FAIL', detail: `${doc.branch} not found on ${args.remote}` });
      }
    } else {
      results.push({ check: 'branch-exists-on-origin', status: 'FAIL', detail: 'no branch to check (schema error above)' });
    }
  } catch (err) {
    const msg = err.stderr?.toString().trim() || err.message;
    failClosed('branch-exists-on-origin', `could not query ${args.remote}: ${msg}`);
    return emit(args, results, 2);
  }

  const base = args.workdir ? resolve(args.workdir) : dirname(donePath);
  const candidates = [
    ...(Array.isArray(doc.evidencePaths) ? doc.evidencePaths : []),
    ...(typeof doc.reportPath === 'string' && doc.reportPath ? [doc.reportPath] : []),
  ].filter((p) => typeof p === 'string' && p);
  if (!candidates.length) {
    results.push({ check: 'evidence-files-exist', status: 'WARN', detail: 'no evidence paths listed' });
  } else {
    const missing = candidates
      .map((p) => ({ rel: p, abs: isAbsolute(p) ? p : resolve(base, p) }))
      .filter(({ abs }) => !existsSync(abs));
    if (missing.length) {
      results.push({ check: 'evidence-files-exist', status: 'FAIL', detail: `missing: ${missing.map((m) => m.rel).join(', ')}` });
    } else {
      results.push({ check: 'evidence-files-exist', status: 'PASS', detail: `${candidates.length} file(s) present` });
    }
  }

  // Terse-handoff envelope, report half (WARN-only): lane reports stay
  // ≤60 lines — status/commits/gates/deferred with cited paths, never
  // pasted contents, logs, or diffs. Unreadable here is the evidence
  // check's business, not this one's.
  if (typeof doc.reportPath === 'string' && doc.reportPath) {
    const abs = isAbsolute(doc.reportPath) ? doc.reportPath : resolve(base, doc.reportPath);
    try {
      const lines = readFileSync(abs, 'utf8').split('\n').length;
      if (lines > 60) {
        results.push({ check: 'report-terseness', status: 'WARN', detail: `${lines} lines — keep lane reports ≤60 (status/commits/gates/deferred; cite paths, never paste contents/logs/diffs)` });
      }
    } catch { /* evidence-files-exist already reported the missing file */ }
  }

  const failed = results.some((r) => r.status === 'FAIL');
  const errored = results.some((r) => r.status === 'ERROR');
  return emit(args, results, errored ? 2 : failed ? 1 : 0);
}

function emit(args, results, code) {
  if (args.json) {
    process.stdout.write(JSON.stringify({ valid: code === 0, results }, null, 2) + '\n');
  } else {
    for (const r of results) process.stdout.write(`${r.status} ${r.check} — ${r.detail}\n`);
  }
  process.exit(code);
}

main();
