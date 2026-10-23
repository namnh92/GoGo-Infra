/**
 * GoGo-Infra#245 — the harness runs from an approved install outside every
 * checkout (ADR-0013 D-3, shape review issuecomment-6361431692).
 *
 * Each case builds a throwaway origin + checkout whose harness/ is this
 * tree's src/ and package.json, prepares commits from it into a temporary
 * install directory and drives the production launcher in a new process.
 * Disabled JEV only: nothing here reaches a provider.
 */
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { appendFileSync, chmodSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, describe, it } from 'node:test';
import { evaluatePolicy } from '../src/policy/policy.ts';
import { activate, readActive, verifyVersion } from '../src/install/launcher.ts';
import type { ActivationPlan } from '../src/install/launcher.ts';
import { prepare } from '../src/install/prepare.ts';

const HARNESS = join(dirname(fileURLToPath(import.meta.url)), '..');
const ROUTER = 'harness/src/router/router.ts';
// The intake rule that settles a fully specified task (router.ts rulesOutcome).
const RULE = "return { outcome: 'AUTO_EXECUTE', reasons: ['acceptance criteria stated";
const TAMPERED = "return { outcome: 'HUMAN_APPROVAL', reasons: ['acceptance criteria stated";

const roots: string[] = [];
after(() => {
  for (const root of roots) {
    writable(root);
    rmSync(root, { recursive: true, force: true });
  }
});

/** Prepared versions are read-only; give the owner bit back so the temp tree can go. */
function writable(path: string): void {
  if (!existsSync(path)) return;
  const st = lstatSync(path);
  if (st.isSymbolicLink()) return;
  chmodSync(path, st.isDirectory() ? 0o755 : 0o644);
  if (st.isDirectory()) for (const name of readdirSync(path)) writable(join(path, name));
}

function git(cwd: string, ...args: string[]): string {
  return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

type World = { root: string; work: string; install: string; state: string; task: string };

/** origin (bare) with develop = commit A holding this tree's harness runtime; `work` is a clone of it. */
function world(): World {
  const root = mkdtempSync(join(tmpdir(), 'harness-install-'));
  roots.push(root);
  const origin = join(root, 'origin.git');
  const work = join(root, 'work');
  git(root, 'init', '--quiet', '--bare', '--initial-branch=develop', origin);
  git(root, 'clone', '--quiet', origin, work);
  git(work, 'config', 'user.email', 'test@example.invalid');
  git(work, 'config', 'user.name', 'harness test');
  git(work, 'checkout', '--quiet', '-B', 'develop');
  cpSync(join(HARNESS, 'src'), join(work, 'harness/src'), { recursive: true });
  cpSync(join(HARNESS, 'package.json'), join(work, 'harness/package.json'));
  commit(work, 'A');
  const task = join(root, 'task.json');
  writeFileSync(task, JSON.stringify({
    taskId: 'T-245',
    checkpoint: 'intake',
    summary: { title: 'Fix a typo in docs', description: 'One word.', acceptanceCriteria: ['typo fixed'], openQuestions: [], labels: ['docs'], paths: ['docs/'], searchedSources: [], rules: [] },
    scope: ['docs/'],
    actions: [{ kind: 'read' }],
  }));
  return { root, work, install: join(root, 'install'), state: join(root, 'state'), task };
}

function commit(work: string, message: string, push = true): string {
  git(work, 'add', '-A');
  git(work, 'commit', '--quiet', '-m', message);
  if (push) git(work, 'push', '--quiet', 'origin', 'HEAD:develop');
  return git(work, 'rev-parse', 'HEAD');
}

const yes = async () => true;
function prep(w: World, rev = 'HEAD') {
  return prepare({ repo: w.work, rev, installDir: w.install, runTests: false });
}
async function activateAs(w: World, sha: string, approval = 'https://github.com/namnh92/GoGo-Infra/issues/245#test'): Promise<ActivationPlan> {
  return activate({ installDir: w.install, sha, approval, actor: 'owner@test' }, yes);
}

/** A new process through the production launcher, as a hook would start it. */
function launch(w: World, args: string[] = ['decide', '--input', w.task], env: Record<string, string> = {}) {
  return spawnSync(process.execPath, [join(w.install, 'bin/harness.mts'), ...args], {
    cwd: w.work,
    env: { ...process.env, HARNESS_STATE_DIR: w.state, JEV_MODE: 'disabled', ...env },
    encoding: 'utf8',
  });
}

function outcome(r: { stdout: string }): string {
  return (JSON.parse(r.stdout) as { outcome: string }).outcome;
}

function tamperCheckoutRouter(w: World): void {
  const file = join(w.work, ROUTER);
  const text = readFileSync(file, 'utf8');
  assert.ok(text.includes(RULE), 'the intake rule this test tampers with moved; update RULE');
  writeFileSync(file, text.replace(RULE, TAMPERED));
}

describe('#245 AC: the installed copy does not follow edits in the checkout', () => {
  it('an edited router in the worktree changes the checkout CLI, not the installed launcher', async () => {
    const w = world();
    const a = prep(w);
    await activateAs(w, a.sha);
    assert.equal(launch(w).status, 0);
    tamperCheckoutRouter(w);
    // Baseline: a launcher pointing at the checkout picks the edit up (this is what #245 removes).
    const fromCheckout = spawnSync(process.execPath, [join(w.work, 'harness/src/cli.ts'), 'decide', '--input', w.task], {
      cwd: w.work,
      env: { ...process.env, HARNESS_STATE_DIR: join(w.root, 'state-checkout'), JEV_MODE: 'disabled' },
      encoding: 'utf8',
    });
    assert.equal(outcome(fromCheckout), 'HUMAN_APPROVAL');
    // Production launcher, new process: still version A's verdict.
    const r = launch(w);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(outcome(r), 'AUTO_EXECUTE');
  });

  it('the launcher inside a checkout refuses to run instead of loading checkout code', () => {
    const w = world();
    const r = spawnSync(process.execPath, [join(w.work, 'harness/src/install/launcher.ts'), 'decide', '--input', w.task], {
      cwd: w.work,
      env: { ...process.env, HARNESS_STATE_DIR: w.state, JEV_MODE: 'disabled', HARNESS_DEV: '1' },
      encoding: 'utf8',
    });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /not an installed launcher/);
    assert.equal(existsSync(join(w.state, 'decisions.jsonl')), false);
  });
});

describe('#245 integrity: a mismatch stops before the payload loads', () => {
  const cases: Array<[string, (dir: string, w: World) => void]> = [
    ['an edited runtime file', (dir) => {
      chmodSync(join(dir, ROUTER), 0o644);
      // Side effect on import: proves the payload never ran.
      appendFileSync(join(dir, ROUTER), `\nimport { writeFileSync as __w } from 'node:fs'; __w(${JSON.stringify(join(dir, '..', '..', '..', 'LOADED'))}, 'x');\n`);
    }],
    ['an extra file', (dir) => {
      chmodSync(join(dir, 'harness/src'), 0o755);
      writeFileSync(join(dir, 'harness/src/extra.ts'), 'export {};\n');
    }],
    ['a missing file', (dir) => {
      chmodSync(join(dir, 'harness/src/runtime'), 0o755);
      unlinkSync(join(dir, 'harness/src/runtime/handoff.ts'));
    }],
    ['a symbolic link in the payload', (dir) => {
      chmodSync(join(dir, 'harness/src'), 0o755);
      symlinkSync('/etc/hosts', join(dir, 'harness/src/link.ts'));
    }],
    ['an edited MANIFEST', (dir) => {
      chmodSync(join(dir, 'MANIFEST'), 0o644);
      appendFileSync(join(dir, 'MANIFEST'), '\n');
    }],
    ['an ACTIVE digest that does not match', (_dir, w) => {
      const file = join(w.install, 'ACTIVE');
      const active = JSON.parse(readFileSync(file, 'utf8')) as Record<string, unknown>;
      writeFileSync(file, JSON.stringify({ ...active, manifestDigest: '0'.repeat(64) }));
    }],
  ];
  for (const [name, tamper] of cases) {
    it(`${name} → exit 2, no decision, no checkout fallback, HARNESS_DEV ignored`, async () => {
      const w = world();
      const a = prep(w);
      await activateAs(w, a.sha);
      tamper(a.dir, w);
      const r = launch(w, undefined, { HARNESS_DEV: '1' });
      assert.equal(r.status, 2, r.stdout);
      assert.match(r.stderr, /harness install:/);
      assert.equal(r.stdout, '');
      assert.equal(existsSync(join(w.root, 'LOADED')), false, 'payload module ran before verification');
      assert.equal(existsSync(join(w.state, 'decisions.jsonl')), false);
    });
  }

  it('a missing ACTIVE is an error, not a fallback', () => {
    const w = world();
    prep(w);
    mkdirSync(join(w.install, 'bin'), { recursive: true });
    cpSync(join(HARNESS, 'src/install/launcher.ts'), join(w.install, 'bin/harness.mts'));
    const r = launch(w);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /ACTIVE/);
  });

  it('leftovers of an interrupted activation do not change what runs', async () => {
    const w = world();
    const a = prep(w);
    await activateAs(w, a.sha);
    writeFileSync(join(w.install, `.ACTIVE.${process.pid}`), '{"schema":1,"sha":"garbage"}');
    mkdirSync(join(w.install, 'staging/half-written'), { recursive: true });
    const r = launch(w);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(readActive(w.install).sha, a.sha);
  });
});

describe('#245 prepare: only merged commits, from Git objects, verified before publishing', () => {
  it('publishes a read-only version whose MANIFEST covers every payload file, package.json included', () => {
    const w = world();
    const a = prep(w);
    assert.equal(a.sha, git(w.work, 'rev-parse', 'HEAD'));
    assert.equal(verifyVersion(w.install, a.sha, a.manifestDigest).digest, a.manifestDigest);
    const files = Object.keys((JSON.parse(readFileSync(join(a.dir, 'MANIFEST'), 'utf8')) as { files: Record<string, string> }).files);
    assert.ok(files.includes('harness/package.json'));
    assert.ok(files.includes('harness/src/cli.ts'));
    assert.equal(lstatSync(join(a.dir, 'harness/src/cli.ts')).mode & 0o222, 0);
    assert.equal(existsSync(join(w.install, 'ACTIVE')), false, 'prepare must not activate');
  });

  it('installs the commit, not the working tree', () => {
    const w = world();
    tamperCheckoutRouter(w);
    const a = prep(w);
    assert.ok(readFileSync(join(a.dir, ROUTER), 'utf8').includes(RULE));
  });

  it('refuses a commit that is not on the remote develop', () => {
    const w = world();
    git(w.work, 'checkout', '--quiet', '-b', 'side');
    writeFileSync(join(w.work, 'harness/NOTE'), 'unmerged\n');
    const side = commit(w.work, 'side', false);
    assert.throws(() => prep(w, side), /not an ancestor/);
    assert.equal(existsSync(join(w.install, 'versions', side)), false);
  });

  it('stops when the remote cannot be fetched instead of trusting a stale ref', () => {
    const w = world();
    git(w.work, 'remote', 'set-url', 'origin', join(w.root, 'gone.git'));
    assert.throws(() => prep(w), /fetch/);
  });

  it("runs the candidate's own tests beside its commit's docs and publishes nothing when they fail", () => {
    const w = world();
    mkdirSync(join(w.work, 'harness/test'));
    mkdirSync(join(w.work, 'docs'));
    writeFileSync(join(w.work, 'docs/ai-harness.md'), 'operating guide\n');
    writeFileSync(join(w.work, 'harness/test/docs.test.ts'), "import { readFileSync } from 'node:fs';\nimport { test } from 'node:test';\ntest('docs beside harness/', () => { readFileSync('../docs/ai-harness.md'); });\n");
    const good = commit(w.work, 'tests pass');
    assert.equal(prepare({ repo: w.work, rev: good, installDir: w.install }).sha, good);
    writeFileSync(join(w.work, 'harness/test/fail.test.ts'), "import { test } from 'node:test';\ntest('fails', () => { throw new Error('candidate is broken'); });\n");
    const bad = commit(w.work, 'tests fail');
    assert.throws(() => prepare({ repo: w.work, rev: bad, installDir: w.install }), /test suite of .* failed[\s\S]*candidate is broken/);
    assert.equal(existsSync(join(w.install, 'versions', bad)), false);
    assert.deepEqual(readdirSync(join(w.install, 'staging')), []);
  });

  it('refuses a payload with a symbolic link', () => {
    const w = world();
    symlinkSync('../package.json', join(w.work, 'harness/src/link.json'));
    const sha = commit(w.work, 'link');
    assert.throws(() => prep(w, sha), /symbolic link/);
    assert.equal(existsSync(join(w.install, 'versions', sha)), false);
  });
});

describe('#245 activation: an owner act, recorded, reversible', () => {
  it('prepare B leaves A running; activate B switches; rollback to A is recorded', async () => {
    const w = world();
    const a = prep(w);
    await activateAs(w, a.sha);
    // B: a merged change that does alter the verdict.
    tamperCheckoutRouter(w);
    const bSha = commit(w.work, 'B');
    const b = prep(w, bSha);
    assert.equal(outcome(launch(w)), 'AUTO_EXECUTE', 'preparing B changed the running version');
    const toB = await activateAs(w, b.sha, 'approval-B');
    assert.deepEqual([toB.action, toB.from?.sha, toB.to.sha], ['activate', a.sha, b.sha]);
    assert.equal(outcome(launch(w)), 'HUMAN_APPROVAL');
    const back = await activateAs(w, a.sha, 'approval-rollback');
    assert.equal(back.action, 'rollback');
    assert.equal(outcome(launch(w)), 'AUTO_EXECUTE');
    const history = readFileSync(join(w.install, 'history.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l) as Record<string, unknown>);
    assert.deepEqual(history.map((h) => [h.action, (h.to as { sha: string }).sha, h.approval, h.actor]), [
      ['activate', a.sha, 'https://github.com/namnh92/GoGo-Infra/issues/245#test', 'owner@test'],
      ['activate', b.sha, 'approval-B', 'owner@test'],
      ['rollback', a.sha, 'approval-rollback', 'owner@test'],
    ]);
    assert.equal((history[2]!.from as { manifestDigest: string }).manifestDigest, b.manifestDigest);
  });

  it('the confirmation sees full SHA and digest, old → new, and a refusal changes nothing', async () => {
    const w = world();
    const a = prep(w);
    let seen: ActivationPlan | undefined;
    await assert.rejects(activate({ installDir: w.install, sha: a.sha, approval: 'x', actor: 'o' }, async (plan) => {
      seen = plan;
      return false;
    }), /not confirmed/);
    assert.deepEqual(seen && [seen.from, seen.to.sha, seen.to.manifestDigest], [null, a.sha, a.manifestDigest]);
    assert.equal(existsSync(join(w.install, 'ACTIVE')), false);
    assert.equal(existsSync(join(w.install, 'history.jsonl')), false);
  });

  it('refuses without an approval reference, for an unprepared SHA, and while another activation holds the lock', async () => {
    const w = world();
    const a = prep(w);
    await assert.rejects(activate({ installDir: w.install, sha: a.sha, approval: ' ' }, yes), /approval/);
    await assert.rejects(activate({ installDir: w.install, sha: 'f'.repeat(40), approval: 'x' }, yes), /not installed/);
    await assert.rejects(activate({ installDir: w.install, sha: 'HEAD', approval: 'x' }, yes), /full commit SHA/);
    writeFileSync(join(w.install, 'activate.lock'), '1\n');
    await assert.rejects(activate({ installDir: w.install, sha: a.sha, approval: 'x' }, yes), /activate\.lock/);
    assert.equal(existsSync(join(w.install, 'ACTIVE')), false);
  });

  it('a corrupted candidate is refused at activation', async () => {
    const w = world();
    const a = prep(w);
    chmodSync(join(a.dir, ROUTER), 0o644);
    appendFileSync(join(a.dir, ROUTER), '\n');
    await assert.rejects(activateAs(w, a.sha), /harness\/src\/router\/router\.ts/);
    assert.equal(existsSync(join(w.install, 'ACTIVE')), false);
  });

  it('the installed launcher asks on a terminal only', async () => {
    const w = world();
    const a = prep(w);
    await activateAs(w, a.sha);
    const r = launch(w, ['activate', a.sha, '--approval', 'x']);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /terminal/);
  });

  it('verify reports the running version', async () => {
    const w = world();
    const a = prep(w);
    await activateAs(w, a.sha);
    const r = launch(w, ['install-verify']);
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(JSON.parse(r.stdout), { sha: a.sha, manifestDigest: a.manifestDigest });
  });
});

describe('#245 the install directory is outside the checkout, so writing to it is a hard gate', () => {
  it('a declared edit of an installed file is unknown, whatever the label', () => {
    const w = world();
    const target = join(w.install, 'versions', 'a'.repeat(40), ROUTER);
    for (const kind of ['edit_in_scope', 'edit_out_of_scope', 'update_handoff'] as const) {
      const v = evaluatePolicy({ actions: [{ kind, target }], scope: [''], repoRoot: w.work, humanAuthorizations: ['edit_out_of_scope'] });
      assert.equal(v.outcome, 'HUMAN_APPROVAL');
      assert.deepEqual(v.gates.map((g) => g.kind), ['unknown']);
    }
  });
});

/** `cp -R` copies a read-only tree as a non-root user too (it makes directories writable while filling them). */
function copyTree(from: string, to: string): void {
  execFileSync('cp', ['-R', from, to]);
}

describe('#253 review P1: an install inside a git checkout is refused', () => {
  it('prepare refuses an install directory inside a checkout', () => {
    const w = world();
    assert.throws(() => prepare({ repo: w.work, rev: 'HEAD', installDir: join(w.work, 'install'), runTests: false }), /inside the git checkout/);
    assert.equal(existsSync(join(w.work, 'install/versions')), false);
  });

  it('activate refuses one too', async () => {
    const w = world();
    const a = prep(w);
    const inside = join(w.work, 'install-copy');
    copyTree(w.install, inside);
    await assert.rejects(activate({ installDir: inside, sha: a.sha, approval: 'x' }, yes), /inside the git checkout/);
    assert.equal(existsSync(join(inside, 'ACTIVE')), false);
  });

  const places: Array<[string, (w: World) => string]> = [
    ['a checkout (.git directory)', (w) => join(w.work, 'install-copy')],
    ['a worktree (.git file)', (w) => {
      const wt = join(w.root, 'worktree');
      mkdirSync(wt);
      writeFileSync(join(wt, '.git'), 'gitdir: /elsewhere/.git/worktrees/x\n');
      return join(wt, 'install-copy');
    }],
  ];
  for (const [i, [name, place]] of places.entries()) {
    it(`a working install copied into ${name} refuses to run, directly and through a symlink`, async () => {
      const w = world();
      const a = prep(w);
      await activateAs(w, a.sha);
      assert.equal(launch(w, ['install-verify']).status, 0);
      const inside = place(w);
      copyTree(w.install, inside);
      const link = join(w.root, `install-link-${i}`);
      symlinkSync(inside, link);
      for (const launcher of [join(inside, 'bin/harness.mts'), join(link, 'bin/harness.mts')]) {
        const r = spawnSync(process.execPath, [launcher, 'install-verify'], { cwd: w.root, encoding: 'utf8' });
        assert.equal(r.status, 2, `${launcher} ran`);
        assert.match(r.stderr, /inside the git checkout/);
      }
    });
  }
});

describe('#253 review P2: ACTIVE alone switches launcher and runtime', () => {
  const VERIFY_LINE = 'process.stdout.write(`${JSON.stringify(active)}\\n`);';

  it('a failure after the owner confirmed leaves launcher and ACTIVE on the previous version', async () => {
    const w = world();
    const a = prep(w);
    await activateAs(w, a.sha);
    const bin = join(w.install, 'bin/harness.mts');
    const before = readFileSync(bin);
    tamperCheckoutRouter(w);
    appendFileSync(join(w.work, 'harness/src/install/launcher.ts'), '// launcher B\n'); // B's launcher differs from A's
    const b = prep(w, commit(w.work, 'B'));
    // activate() runs in this process: a directory where it writes ACTIVE's temp file makes
    // the last step fail with EISDIR, after confirmation, history and (before the fix) the launcher.
    mkdirSync(join(w.install, `.ACTIVE.${process.pid}`));
    await assert.rejects(activateAs(w, b.sha), /EISDIR/);
    assert.equal(readActive(w.install).sha, a.sha);
    assert.deepEqual(readFileSync(bin), before, 'the launcher changed although the activation failed');
    const r = launch(w);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(outcome(r), 'AUTO_EXECUTE');
  });

  it('the launcher code that runs is the active version\'s; bin/harness.mts is not rewritten', async () => {
    const w = world();
    const a = prep(w);
    await activateAs(w, a.sha);
    const bin = join(w.install, 'bin/harness.mts');
    const before = readFileSync(bin);
    // B changes the launcher in a way install-verify shows.
    const file = join(w.work, 'harness/src/install/launcher.ts');
    const text = readFileSync(file, 'utf8');
    assert.ok(text.includes(VERIFY_LINE), 'the install-verify line moved; update VERIFY_LINE');
    writeFileSync(file, text.replace(VERIFY_LINE, "process.stdout.write(`${JSON.stringify({ ...active, launcher: 'B' })}\\n`);"));
    const b = prep(w, commit(w.work, 'B'));
    await activateAs(w, b.sha, 'approval-B');
    assert.deepEqual(readFileSync(bin), before);
    assert.deepEqual(JSON.parse(launch(w, ['install-verify']).stdout), { sha: b.sha, manifestDigest: b.manifestDigest, launcher: 'B' });
    await activateAs(w, a.sha, 'approval-rollback');
    assert.deepEqual(JSON.parse(launch(w, ['install-verify']).stdout), { sha: a.sha, manifestDigest: a.manifestDigest });
  });
});
