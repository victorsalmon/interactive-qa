#!/usr/bin/env node
// lane-watch.mjs — one session-side poller for all detached lane workers.
//
// Replaces one-watchdog-heartbeat-per-worker: instead of N timers (one per
// `paseo run -d`), the parent session runs this once per supervision round
// (manually, or from a single session heartbeat). Per worker it:
//   - lists workers via `paseo ls --json` (+ `inspect` for parent linkage
//     and last-activity time),
//   - treats a running worker with no completion file past --grace-minutes
//     as silent: first silent round sends ONE follow-up ping via
//     `paseo send --no-wait` (never to self), the second silent round
//     escalates to a relaunch recommendation (printed, never auto-run).
//   - drops workers whose completion file appeared (Finished or Blocked).
//
// Completion files live in --workdir and match --done-pattern
// (default: .iqa-done-*). A .json done file should satisfy
// iqa-done.schema.json (checked by validate-done.mjs, not here); any
// matching .txt counts as a legacy completion signal.
//
// Usage:
//   node lane-watch.mjs --parent <agent-id> [--workdir <dir>]
//     [--state <path>] [--grace-minutes <n>] [--done-pattern <glob>]
//     [--worker <id> ...] [--followup-file <path>] [--dry-run] [--json]
//
// Exit codes: 0 = poll completed (escalations are findings, not errors),
// 2 = engine error (bad args, CLI missing, ls/inspect failed).
// --dry-run is fully read-only: no sends, no state writes.

import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync } from 'node:fs';
import { resolve, dirname, basename } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const WELL_KNOWN_WIN = 'C:\\Program Files\\Paseo\\resources\\bin\\paseo.cmd';

function usage() {
  return [
    'Usage: node lane-watch.mjs --parent <agent-id> [--workdir <dir>] [options]',
    '  --parent <id>       watch running workers whose ParentAgentId equals <id>',
    '  --worker <id>       also watch this explicit worker id (repeatable)',
    '  --workdir <dir>     where completion files land (default: cwd)',
    '  --state <path>      state file (default: <workdir>/.lane-watch-state.json)',
    '  --grace-minutes <n> idle grace before a worker counts as silent (default: 30)',
    '  --done-pattern <g>  completion-file glob basename (default: .iqa-done-*)',
    '  --followup-file <p> ping body file (default: generated per worker)',
    '  --dry-run           read-only: report actions, send nothing, write no state',
    '  --json              emit the poll result as JSON',
  ].join('\n');
}

function parseArgs(argv) {
  const o = {
    parent: '', workers: [], workdir: process.cwd(), state: '',
    graceMinutes: 30, donePattern: '.iqa-done-*', followupFile: '',
    dryRun: false, json: false,
  };
  const rest = [...argv];
  const need = (flag) => {
    const v = rest.shift();
    if (v === undefined || v.startsWith('--')) throw new Error(`${flag} needs a value`);
    return v;
  };
  while (rest.length) {
    const a = rest.shift();
    if (a === '--parent') o.parent = need(a);
    else if (a === '--worker') o.workers.push(need(a));
    else if (a === '--workdir') o.workdir = resolve(need(a));
    else if (a === '--state') o.state = resolve(need(a));
    else if (a === '--grace-minutes') o.graceMinutes = Number(need(a));
    else if (a === '--done-pattern') o.donePattern = need(a);
    else if (a === '--followup-file') o.followupFile = resolve(need(a));
    else if (a === '--dry-run') o.dryRun = true;
    else if (a === '--json') o.json = true;
    else if (a === '--help' || a === '-h') { o.help = true; return o; }
    else if (a.startsWith('--')) throw new Error(`unknown flag: ${a}`);
    else throw new Error(`unexpected argument: ${a}`);
  }
  if (!o.help) {
    if (!o.parent && !o.workers.length) throw new Error('need --parent <id> and/or at least one --worker <id>\n' + usage());
    if (!Number.isFinite(o.graceMinutes) || o.graceMinutes < 0) throw new Error('--grace-minutes must be a non-negative number');
  }
  if (!o.state) o.state = resolve(o.workdir, '.lane-watch-state.json');
  return o;
}

// --- Paseo CLI ---------------------------------------------------------------

function resolveCli() {
  if (process.env.PASEO_CLI && existsSync(process.env.PASEO_CLI)) return process.env.PASEO_CLI;
  if (existsSync(WELL_KNOWN_WIN)) return WELL_KNOWN_WIN;
  return 'paseo'; // PATH fallback — absent inside worker shells, fine on a session box
}

function runCli(cli, args) {
  // .cmd shims need a shell on Windows, and a spaced install path needs
  // quoting once a shell parses the command line; plain binaries do not.
  const useShell = cli.toLowerCase().endsWith('.cmd');
  const file = useShell ? `"${cli}"` : cli;
  try {
    return execFileSync(file, args, { encoding: 'utf8', shell: useShell, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (err) {
    const detail = err.stderr?.toString().trim() || err.message;
    throw new Error(`paseo ${args[0]} failed: ${detail}`);
  }
}

function listAgents(cli) {
  const raw = runCli(cli, ['ls', '--json']);
  const parsed = JSON.parse(raw);
  return Array.isArray(parsed) ? parsed : [parsed];
}

function inspectAgent(cli, id) {
  const raw = runCli(cli, ['inspect', id, '--json']);
  return JSON.parse(raw);
}

// --- Self discovery (read-only port of Get-PaseoSelfAgentId.ps1) --------------

function normalizePath(p) {
  return String(p ?? '').trim().replace(/[\\/]+$/, '').toLowerCase();
}

function resolveSelf(agents, cwd) {
  if (process.env.PASEO_AGENT_ID) return process.env.PASEO_AGENT_ID;
  const self = normalizePath(resolve(cwd));
  const running = agents.filter((a) => a.status === 'running' && a.cwd);
  let match = running.filter((a) => normalizePath(a.cwd) === self);
  if (!match.length) {
    const ancestors = running.filter((a) => {
      const c = normalizePath(a.cwd);
      return c && self.startsWith(c + '\\');
    });
    ancestors.sort((x, y) => normalizePath(y.cwd).length - normalizePath(x.cwd).length);
    if (ancestors.length === 1 || (ancestors.length > 1 &&
        normalizePath(ancestors[0].cwd).length !== normalizePath(ancestors[1].cwd).length)) {
      match = [ancestors[0]];
    }
  }
  return match.length === 1 ? match[0].id : '';
}

// --- Completion files ----------------------------------------------------------

function globToRegExp(glob) {
  const esc = glob.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.');
  return new RegExp(`^${esc}$`);
}

function loadDoneIndex(workdir, pattern) {
  // Map: worker shortId/fullId -> {file, status}. JSON done files index by
  // their agentShortId field; .txt files count as legacy signals by name.
  const index = new Map();
  const re = globToRegExp(pattern.startsWith('.') || !pattern.includes('/') ? pattern : basename(pattern));
  let names = [];
  try { names = readdirSync(workdir); } catch { return index; }
  for (const name of names) {
    if (!re.test(name)) continue;
    const full = resolve(workdir, name);
    if (name.endsWith('.json')) {
      try {
        const doc = JSON.parse(readFileSync(full, 'utf8'));
        const key = String(doc.agentShortId ?? '').trim();
        if (key) index.set(key, { file: full, status: String(doc.status ?? 'unknown') });
      } catch { /* unparsable — validator's job, not the watcher's */ }
    } else {
      index.set(name, { file: full, status: 'legacy-txt' });
    }
  }
  return index;
}

function doneFor(index, worker) {
  if (index.has(worker.id)) return index.get(worker.id);
  if (worker.shortId && index.has(worker.shortId)) return index.get(worker.shortId);
  // Legacy .txt named .iqa-done-<id>.txt keyed by full filename match.
  for (const [key, val] of index) {
    if (val.status === 'legacy-txt' &&
        (key.includes(worker.id) || (worker.shortId && key.includes(worker.shortId)))) {
      return val;
    }
  }
  return null;
}

// --- State ---------------------------------------------------------------------

function loadState(path) {
  try {
    const s = JSON.parse(readFileSync(path, 'utf8'));
    if (s && typeof s === 'object' && s.workers && typeof s.workers === 'object') return s;
  } catch { /* missing/corrupt state starts fresh — never fatal */ }
  return { version: 1, workers: {} };
}

// --- Main ----------------------------------------------------------------------

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`ERROR: ${err.message}\n`);
    process.exit(2);
  }
  if (args.help) { process.stdout.write(usage() + '\n'); process.exit(0); }

  const cli = resolveCli();
  const findings = []; // {worker, shortId, action, detail}
  const fail = (msg) => {
    if (args.json) process.stdout.write(JSON.stringify({ ok: false, error: msg, findings }) + '\n');
    else process.stderr.write(`ERROR: ${msg}\n`);
    process.exit(2);
  };

  let agents;
  try {
    agents = listAgents(cli);
  } catch (err) {
    fail(err.message);
  }
  const selfId = resolveSelf(agents, process.cwd());

  // Candidate set: parent's children + explicit workers, running only.
  const byId = new Map(agents.map((a) => [a.id, a]));
  const candidates = new Map();
  if (args.parent) {
    for (const a of agents) {
      let parentOf = a.ParentAgentId ?? a.parentAgentId ?? a.parent;
      if (parentOf === undefined && a.status === 'running') {
        // ls --json carries no parent linkage — resolve via inspect below.
        parentOf = null;
      }
      if (parentOf === args.parent) candidates.set(a.id, a);
    }
    // ls rows lack ParentAgentId: inspect each running agent to find children.
    for (const a of agents) {
      if (a.status !== 'running' || candidates.has(a.id)) continue;
      if (selfId && a.id === selfId) continue;
      try {
        const full = inspectAgent(cli, a.id);
        if ((full.ParentAgentId ?? full.parentAgentId) === args.parent) candidates.set(a.id, a);
      } catch { /* one unreadable worker never fails the poll */ }
    }
  }
  for (const id of args.workers) {
    const a = byId.get(id) ?? [...byId.values()].find((x) => x.shortId === id);
    if (!a) {
      findings.push({ worker: id, shortId: '', action: 'UNKNOWN', detail: 'id not present in paseo ls output' });
      continue;
    }
    candidates.set(a.id, a);
  }

  const doneIndex = loadDoneIndex(args.workdir, args.donePattern);
  const state = loadState(args.state);
  const now = Date.now();
  const graceMs = args.graceMinutes * 60 * 1000;

  const detailOf = (a) => {
    try {
      const full = inspectAgent(cli, a.id);
      return {
        title: full.Name ?? a.name ?? a.id,
        updatedAt: full.UpdatedAt ? Date.parse(full.UpdatedAt) : NaN,
        status: full.Status ?? a.status,
      };
    } catch {
      return { title: a.name ?? a.id, updatedAt: NaN, status: a.status };
    }
  };

  for (const [, worker] of candidates) {
    const short = worker.shortId ?? worker.id.slice(0, 7);
    if (selfId && worker.id === selfId) {
      findings.push({ worker: worker.id, shortId: short, action: 'SELF_SKIP', detail: 'candidate is the watcher itself — never self-ping' });
      continue;
    }
    const done = doneFor(doneIndex, worker);
    if (done) {
      findings.push({ worker: worker.id, shortId: short, action: 'DONE', detail: `completion file ${done.file} (status ${done.status}) — validate with validate-done.mjs, then verify and merge` });
      delete state.workers[worker.id];
      continue;
    }
    const { title, updatedAt } = detailOf(worker);
    const idleMs = Number.isFinite(updatedAt) ? now - updatedAt : NaN;
    const pastGrace = Number.isFinite(idleMs) ? idleMs > graceMs : true; // unknown activity = assume silent, say so
    if (!pastGrace) {
      findings.push({ worker: worker.id, shortId: short, action: 'WATCHING', detail: `active ${Math.round(idleMs / 60000)} min ago, inside ${args.graceMinutes} min grace` });
      continue;
    }
    const prev = state.workers[worker.id] ?? { firstSeen: new Date(now).toISOString(), silentRounds: 0, lastUpdatedAt: 0 };
    if (Number.isFinite(updatedAt) && prev.lastUpdatedAt && updatedAt > prev.lastUpdatedAt) {
      prev.silentRounds = 0; // progress since last round resets the count
    }
    prev.lastUpdatedAt = Number.isFinite(updatedAt) ? updatedAt : prev.lastUpdatedAt ?? 0;
    prev.title = title;
    prev.silentRounds += 1;
    state.workers[worker.id] = prev;

    if (prev.silentRounds === 1) {
      const body = [
        `Lane-watch follow-up for worker ${short} (${title}): no completion file in ${args.workdir} after ${args.graceMinutes} min grace.`,
        `Reply with status + ETA, or write your .iqa-done-<id>.json per iqa-done.schema.json and ping the parent.`,
        `Do not ask questions; if blocked, record the blocker in the done file.`,
      ].join(' ');
      if (args.dryRun) {
        findings.push({ worker: worker.id, shortId: short, action: 'WOULD_PING', detail: `first silent round — would send one follow-up via paseo send --no-wait ${short}` });
      } else {
        let promptFile = args.followupFile;
        try {
          if (!promptFile) {
            promptFile = resolve(args.workdir, `.lane-watch-followup-${short}.txt`);
            writeFileSync(promptFile, body + '\n', 'utf8');
          }
          runCli(cli, ['send', '--no-wait', worker.id, '--prompt-file', promptFile]);
          prev.lastFollowUp = new Date(now).toISOString();
          findings.push({ worker: worker.id, shortId: short, action: 'PINGED', detail: 'first silent round — one follow-up sent; next silent round escalates' });
        } catch (err) {
          findings.push({ worker: worker.id, shortId: short, action: 'PING_FAILED', detail: `follow-up send failed (fail-open): ${err.message}` });
        }
      }
    } else {
      findings.push({
        worker: worker.id, shortId: short, action: 'ESCALATE',
        detail: `silent for ${prev.silentRounds} rounds with no completion file — recommend relaunch: re-dispatch the brief fresh per the paseo-child-agents skill (same branch/worktree discipline), then verify. No further pings sent.`,
      });
    }
  }

  if (!args.dryRun) {
    try {
      mkdirSync(dirname(args.state), { recursive: true });
      writeFileSync(args.state, JSON.stringify(state, null, 2) + '\n', 'utf8');
    } catch (err) {
      fail(`cannot write state file ${args.state}: ${err.message}`);
    }
  }

  if (args.json) {
    process.stdout.write(JSON.stringify({ ok: true, dryRun: args.dryRun, findings }, null, 2) + '\n');
  } else {
    if (!findings.length) process.stdout.write('lane-watch: no watched workers (no children, no --worker ids, nothing to do).\n');
    for (const f of findings) process.stdout.write(`${f.action} ${f.shortId || f.worker} — ${f.detail}\n`);
    if (args.dryRun) process.stdout.write('lane-watch: dry run — no sends, no state writes.\n');
  }
  process.exit(0);
}

main();
