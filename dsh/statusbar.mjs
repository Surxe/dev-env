/**
 * dsh-tui status bar — a single dim line above the prompt, mirroring the
 * Claude Code status bar (dev-env/statusline.py) as closely as the DeepSeek
 * Harness allows:
 *
 *     <host>  ·  <model>  ·  ctx N%  ·  <repo>
 *
 * This is NOT the Claude protocol (an external script fed status JSON on
 * stdin). dsh-tui renders its status line from in-process "status
 * contributions": a plugin calls `ctx.tuiStatus.set(key, text)` and the host
 * joins every keyed contribution into one dim, truncated line (see
 * dsh-adapter/status.d.ts). The scalar seam offers no per-segment color, so
 * unlike statusline.py the percentages are plain (the rich `registerView`
 * React seam would be needed for color, deliberately not used here).
 *
 * Data sources (all read defensively; a segment is omitted, never faked, when
 * its source is not yet available, and the whole update is wrapped so a status
 * contribution can never take the TUI down):
 *   - host   : Node os.hostname() — this box (ethan-debian / home-server).
 *   - model  : session.requestHeader().config.model.
 *   - ctx N% : latest assistant/message usage.input / requestContext().contextWindow.
 *   - repo   : the active repo under /srv/dev/repos, from the launch cwd.
 *
 * Mounted as a local `./statusbar.mjs` row in the dsh-tui profile's
 * cordis.patch.yml (see dev-env/dsh/cordis.patch.yml), deployed by dev-env's
 * install.sh (deploy_dsh_statusbar). Self-contained: presets/plugins are copied
 * outside the package, so this file imports only Node builtins.
 */

import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';

export const name = 'dev-status-bar';

// All of Ethan's repos live directly under this root (mirrors statusline.py).
const REPOS_ROOT = '/srv/dev/repos';
const STATUS_KEY = 'dev-status';
const SEP = ' · '; // matches the host's own " · " join, harmless if doubled

// Opt-in breadcrumb log (DSH_STATUSBAR_DEBUG=1) — the TUI owns the screen, so
// there is nowhere to print; this is the only way to see what the plugin did.
const DEBUG = !!process.env.DSH_STATUSBAR_DEBUG;
const DEBUG_LOG = process.env.DSH_STATUSBAR_DEBUG_LOG || '/tmp/dsh-statusbar.log';
function dbg(msg) {
  if (!DEBUG) return;
  try {
    fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] ${msg}\n`);
  } catch {
    /* ignore */
  }
}

// --- pure helpers (unit-tested via --selftest) -----------------------------

/** This machine's short hostname (e.g. ethan-debian), or ''. */
export function hostName() {
  try {
    return String(os.hostname() || '').split('.', 1)[0];
  } catch {
    return '';
  }
}

/** The repo name if `cwd` is inside REPOS_ROOT/<name>, else '' (the repos root
 *  itself, or anywhere outside, yields '' — statusline.py falls back to a
 *  transcript here, but dsh has no equivalent, so we simply omit the segment). */
export function repoFromCwd(cwd) {
  if (!cwd) return '';
  const norm = path.normalize(cwd);
  const prefix = REPOS_ROOT + path.sep;
  if (!norm.startsWith(prefix)) return '';
  return norm.slice(prefix.length).split(path.sep, 1)[0] || '';
}

/** The launch cwd dsh is working in. DSH_CWD wins (the preset's fs-local cwd),
 *  else the process cwd. */
function currentCwd() {
  return process.env.DSH_CWD || process.cwd() || '';
}

/** The active model id from the folded request header, or ''. */
function modelOf(session) {
  try {
    const header = session && typeof session.requestHeader === 'function' ? session.requestHeader() : undefined;
    return (header && header.config && header.config.model) || '';
  } catch {
    return '';
  }
}

/** The most recent input (context) token count from assistant/message usage, or
 *  undefined. This is the same quantity the TUI divides by the context window
 *  for its own meter (channel.tokens.input). */
function latestInputTokens(session) {
  try {
    const events = session && session.events;
    if (!Array.isArray(events)) return undefined;
    for (let i = events.length - 1; i >= 0; i--) {
      const e = events[i];
      if (e && e.type === 'assistant/message' && e.data && e.data.usage) {
        const u = e.data.usage;
        const v = u.input ?? u.inputTokens ?? u.promptTokens;
        if (typeof v === 'number' && Number.isFinite(v)) return v;
      }
    }
  } catch {
    /* fall through */
  }
  return undefined;
}

/** Context-window fullness percent (0-100), or undefined when either the window
 *  or the used-token count is not yet known. */
function contextPct(session) {
  try {
    const ctxObj = session && typeof session.requestContext === 'function' ? session.requestContext() : undefined;
    const win = ctxObj && ctxObj.contextWindow;
    const used = latestInputTokens(session);
    if (typeof win === 'number' && win > 0 && typeof used === 'number') {
      return Math.max(0, Math.min(100, Math.round((used / win) * 100)));
    }
  } catch {
    /* fall through */
  }
  return undefined;
}

/** Build the status line for a session (may be undefined before one exists).
 *  Segments whose source is unavailable are omitted, exactly like statusline.py.
 *  Returns '' when nothing is renderable. */
export function computeLine(session, env = {}) {
  const parts = [];

  const host = env.host !== undefined ? env.host : hostName();
  if (host) parts.push(host);

  const model = modelOf(session);
  if (model) parts.push(model);

  const pct = contextPct(session);
  if (pct !== undefined) parts.push(`ctx ${pct}%`);

  const repo = repoFromCwd(env.cwd !== undefined ? env.cwd : currentCwd());
  if (repo) parts.push(repo);

  return parts.join(SEP);
}

// --- cordis plugin ----------------------------------------------------------

export function apply(ctx) {
  dbg('apply: enter');

  let wired = false;

  // Wire the render loop against a resolved tuiStatus seam. Guarded so the two
  // resolution paths below (inject callback + immediate soft-get) only set up
  // once, whichever wins the race.
  const wire = (status, how) => {
    if (wired) return;
    if (!status || typeof status.set !== 'function') {
      dbg(`wire(${how}): tuiStatus not available`);
      return;
    }
    wired = true;
    dbg(`wire(${how}): tuiStatus resolved — starting`);

    let activeSession;
    const render = (session) => {
      try {
        const line = computeLine(session);
        dbg(`render: ${JSON.stringify(line)}`);
        status.set(STATUS_KEY, line || undefined, ctx); // empty clears the key
      } catch (e) {
        dbg(`render: threw ${e && e.stack ? e.stack : e}`); // never crash the TUI
      }
    };

    // Seed immediately: host + repo are known before any session event fires.
    render(undefined);

    ctx.on('session/created', (session) => {
      activeSession = session;
      render(session);
    });
    ctx.on('session/event', (session) => {
      activeSession = session;
      render(session);
    });
    ctx.on('session/disposed', (session) => {
      if (activeSession === session) activeSession = undefined;
      render(activeSession);
    });

    // Clear our contribution on fiber teardown.
    ctx.effect(
      () => () => {
        try {
          status.set(STATUS_KEY, undefined, ctx);
        } catch {
          /* ignore */
        }
      },
      'dev-status-bar clear',
    );
  };

  // Primary path: ctx.inject runs the callback once tuiStatus is actually
  // available (and re-runs on reload) — the working-activity pattern, immune to
  // mount-order timing. Fall back to an immediate soft-get in case inject is a
  // no-op on this host.
  try {
    ctx.inject(['tuiStatus'], (injCtx) => {
      dbg('inject: callback fired');
      const status = injCtx.tuiStatus ?? (typeof injCtx.get === 'function' ? injCtx.get('tuiStatus', false) : undefined);
      wire(status, 'inject');
    });
  } catch (e) {
    dbg(`inject: threw ${e && e.message ? e.message : e}`);
  }
  try {
    const status = ctx.tuiStatus ?? (typeof ctx.get === 'function' ? ctx.get('tuiStatus', false) : undefined);
    wire(status, 'get');
  } catch (e) {
    dbg(`get: threw ${e && e.message ? e.message : e}`);
  }
}

export default apply;

// --- self-test --------------------------------------------------------------
// Run: node statusbar.mjs --selftest   (exits non-zero on any failure)

function selftest() {
  let ok = true;
  const check = (label, cond) => {
    if (!cond) {
      console.error(`FAIL: ${label}`);
      ok = false;
    } else {
      console.log(`ok: ${label}`);
    }
  };

  // repoFromCwd
  check('repo inside a repo', repoFromCwd('/srv/dev/repos/my-system') === 'my-system');
  check('repo nested path', repoFromCwd('/srv/dev/repos/dev-env/lib') === 'dev-env');
  check('repos root -> none', repoFromCwd('/srv/dev/repos') === '');
  check('outside -> none', repoFromCwd('/home/dev') === '');
  check('empty -> none', repoFromCwd('') === '');

  // computeLine with a mock session (fixed host/cwd so it is deterministic)
  const session = {
    requestHeader: () => ({ config: { model: 'deepseek-chat' } }),
    requestContext: () => ({ contextWindow: 128000 }),
    events: [
      { type: 'user/message', data: {} },
      { type: 'assistant/message', data: { usage: { input: 32000, output: 1200 } } },
    ],
  };
  const full = computeLine(session, { host: 'ethan-debian', cwd: '/srv/dev/repos/steam-price-tracker' });
  check('full line has host', full.includes('ethan-debian'));
  check('full line has model', full.includes('deepseek-chat'));
  check('full line has ctx 25%', full.includes('ctx 25%')); // 32000/128000
  check('full line has repo', full.includes('steam-price-tracker'));
  check('full line single line', full && !full.includes('\n'));

  // Bare: no header/context yet, launched from repos root -> host only.
  const bare = computeLine(undefined, { host: 'ethan-debian', cwd: '/srv/dev/repos' });
  check('bare line is host only', bare === 'ethan-debian');

  // No context window -> ctx segment omitted, no crash.
  const noWin = computeLine(
    { requestHeader: () => ({ config: { model: 'm' } }), requestContext: () => ({}), events: [] },
    { host: 'h', cwd: '/tmp' },
  );
  check('no ctx segment without window', !noWin.includes('ctx '));

  return ok;
}

if (process.argv.includes('--selftest')) {
  process.exit(selftest() ? 0 : 1);
}
