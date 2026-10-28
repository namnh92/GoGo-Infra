/**
 * GoGo-Infra#245 — the harness runs from an approved install outside every
 * checkout (ADR-0013 D-3; PR #253 shape rev 3).
 *
 * Each case builds a throwaway origin + checkout whose commit holds this
 * tree's harness runtime and the JEV send closure (D6), prepares commits from
 * it into a temporary install directory and drives the production bootstrap
 * in a new process. The world's own launcher.ts names that throwaway origin
 * as its trusted source (`TRUSTED_SOURCE`, `file` allowed instead of
 * `https`): the bootstrap's CLI has no source option, and nothing here may
 * reach GitHub. In-process activations pass the same source through the
 * `source` seam. Disabled JEV only: nothing here reaches a provider.
 */
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { appendFileSync, chmodSync, cpSync, existsSync, linkSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, describe, it } from 'node:test';
import { evaluatePolicy } from '../src/policy/policy.ts';
import { CLOSURE_FILES, Install, NODE_MISSING_NOTE, activate, buildManifest, confirmation, gitBlobId, readActive, readJournal, sha256, verifyVersion, wrapperText } from '../src/install/launcher.ts';
import type { ActivationPlan, Source } from '../src/install/launcher.ts';
import { prepare } from '../src/install/prepare.ts';

const HARNESS = join(dirname(fileURLToPath(import.meta.url)), '..');
const REPO = join(HARNESS, '..');
const NODE = realpathSync(process.execPath);
const ROUTER = 'harness/src/router/router.ts';
// The intake rule that settles a fully specified task (router.ts rulesOutcome).
const RULE = "return { outcome: 'AUTO_EXECUTE', reasons: ['acceptance criteria stated";
const TAMPERED = "return { outcome: 'HUMAN_APPROVAL', reasons: ['acceptance criteria stated";
const SOURCE_LINE = "export const TRUSTED_SOURCE: Source = { url: 'https://github.com/namnh92/GoGo-Infra.git', allowLocal: false };";
const APPROVAL = 'https://github.com/namnh92/GoGo-Infra/issues/245#test';

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
  if (st.isSymbolicLink() || !(st.isDirectory() || st.isFile())) return;
  chmodSync(path, st.isDirectory() ? 0o755 : (st.mode & 0o100 ? 0o755 : 0o644));
  if (st.isDirectory()) for (const name of readdirSync(path)) writable(join(path, name));
}

function git(cwd: string, ...args: string[]): string {
  return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

type World = { root: string; origin: string; work: string; install: string; state: string; task: string; source: Source };

/** origin (bare) with develop = commit A: this tree's harness runtime, the four closure files, a launcher trusting `origin`. */
function world(): World {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'harness-install-')));
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
  for (const f of CLOSURE_FILES) {
    mkdirSync(dirname(join(work, f)), { recursive: true });
    cpSync(join(REPO, f), join(work, f));
  }
  const launcher = join(work, 'harness/src/install/launcher.ts');
  const text = readFileSync(launcher, 'utf8');
  assert.ok(text.includes(SOURCE_LINE), 'TRUSTED_SOURCE moved or changed; update SOURCE_LINE');
  writeFileSync(launcher, text.replace(SOURCE_LINE, `export const TRUSTED_SOURCE: Source = { url: ${JSON.stringify(origin)}, allowLocal: true };`));
  commit(work, 'A');
  const task = join(root, 'task.json');
  writeFileSync(task, JSON.stringify({
    taskId: 'T-245',
    checkpoint: 'intake',
    summary: { title: 'Fix a typo in docs', description: 'One word.', acceptanceCriteria: ['typo fixed'], openQuestions: [], labels: ['docs'], paths: ['docs/'], searchedSources: [], rules: [] },
    scope: ['docs/'],
    actions: [{ kind: 'read' }],
  }));
  return { root, origin, work, install: join(root, 'install'), state: join(root, 'state'), task, source: { url: origin, allowLocal: true } };
}

function commit(work: string, message: string, push = true): string {
  git(work, 'add', '-A');
  git(work, 'commit', '--quiet', '-m', message);
  if (push) git(work, 'push', '--quiet', 'origin', 'HEAD:develop');
  return git(work, 'rev-parse', 'HEAD');
}

const yes = async () => true;
const open = (w: World) => Install.open(w.install);
function prep(w: World, rev = 'HEAD') {
  return prepare({ repo: w.work, rev, installDir: w.install, runTests: false });
}
/** The bootstrap as the owner's first-install block places it: the commit's launcher.ts blob, 0555. */
function seed(w: World, sha: string): void {
  mkdirSync(join(w.install, 'bin'), { recursive: true });
  writeFileSync(join(w.install, 'bin/harness.mts'), execFileSync('git', ['-C', w.origin, 'cat-file', 'blob', `${sha}:harness/src/install/launcher.ts`]), { mode: 0o555 });
}
async function activateAs(w: World, sha: string, approval = APPROVAL, extra: Partial<Parameters<typeof activate>[0]> = {}, confirm: (plan: ActivationPlan) => Promise<boolean> = yes): Promise<ActivationPlan> {
  return activate({ install: open(w), sha, approval, actor: 'owner@test', source: w.source, node: NODE, ...extra }, confirm);
}
/** prepare, place the bootstrap and activate: a working install of HEAD. */
async function installed(w: World) {
  const a = prep(w);
  seed(w, a.sha);
  await activateAs(w, a.sha);
  return a;
}
async function withB(w: World, change: (w: World) => void = tamperCheckoutRouter) {
  const a = await installed(w);
  change(w);
  const b = prep(w, commit(w.work, 'B'));
  return { a, b };
}

/** A new process through the installed launch boundary, as a hook would start it. */
function launch(w: World, args: string[] = ['decide', '--input', w.task], env: Record<string, string> = {}, cwd = w.work) {
  return spawnSync(join(w.install, 'bin/harness'), args, {
    cwd,
    env: { ...process.env, HARNESS_STATE_DIR: w.state, JEV_MODE: 'disabled', ...env },
    encoding: 'utf8',
  });
}

/**
 * The owner on a terminal: run `cmd` on a pseudo-terminal, wait for the
 * confirmation prompt and type what it asks for (or `answer`).
 */
const OWNER = String.raw`
import os, pty, re, select, sys, time
answer, cmd = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
out, sent, status, end = b"", False, None, time.time() + 120
while status is None:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b""
        out += data
        if not sent:
            m = re.search(rb'Type "([^"]+)"', out)
            if m:
                os.write(fd, (m.group(1) if answer == "-" else answer.encode()) + b"\n")
                sent = True
        if data:
            continue
    wpid, st = os.waitpid(pid, os.WNOHANG)
    if wpid:
        status = os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st)
    elif time.time() > end:
        os.kill(pid, 9)
        status = 124
sys.stdout.buffer.write(out)
sys.exit(status)
`;
function owner(cmd: string[], o: { answer?: string; env?: Record<string, string>; cwd?: string } = {}) {
  const r = spawnSync('python3', ['-I', '-c', OWNER, o.answer ?? '-', ...cmd], { cwd: o.cwd ?? tmpdir(), env: { ...process.env, ...o.env }, encoding: 'utf8' });
  return { status: r.status, out: r.stdout + r.stderr };
}
/**
 * `bin/harness activate <sha> --node <node>` (or the bootstrap directly), confirmed on a
 * terminal. `node: null` leaves `--node` out (#272 D-1).
 */
function ownerActivates(w: World, sha: string, o: { via?: 'wrapper' | 'bootstrap'; answer?: string; node?: string | null } = {}) {
  const cmd = o.via === 'bootstrap' ? [NODE, join(w.install, 'bin/harness.mts')] : [join(w.install, 'bin/harness')];
  const node = o.node === undefined ? NODE : o.node;
  return owner([...cmd, 'activate', sha, '--approval', APPROVAL, ...(node === null ? [] : ['--node', node])], { answer: o.answer, env: { HARNESS_STATE_DIR: w.state } });
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

function journal(w: World): Array<Record<string, unknown>> {
  return readFileSync(join(w.install, 'history.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l) as Record<string, unknown>);
}

/** Import side effect: a file appears when this module is loaded. */
function marker(path: string): string {
  return `\nimport { writeFileSync as __w } from 'node:fs'; __w(${JSON.stringify(path)}, 'x');\n`;
}

/** A directory with a `.git` beside the install: what an agent session can write. */
function agentCheckout(w: World): string {
  const checkout = join(w.root, 'agent-checkout');
  mkdirSync(join(checkout, '.git'), { recursive: true });
  return checkout;
}

/** `cp -R` copies a read-only tree as a non-root user too (it makes directories writable while filling them). */
function copyTree(from: string, to: string): void {
  execFileSync('cp', ['-R', from, to]);
}

describe('#245 AC: the installed copy does not follow edits in the checkout', () => {
  it('an edited router in the worktree changes the checkout CLI, not the installed harness', async () => {
    const w = world();
    await installed(w);
    assert.equal(launch(w).status, 0);
    tamperCheckoutRouter(w);
    // Baseline: running the checkout picks the edit up (this is what #245 removes).
    const fromCheckout = spawnSync(process.execPath, [join(w.work, 'harness/src/cli.ts'), 'decide', '--input', w.task], {
      cwd: w.work,
      env: { ...process.env, HARNESS_STATE_DIR: join(w.root, 'state-checkout'), JEV_MODE: 'disabled' },
      encoding: 'utf8',
    });
    assert.equal(outcome(fromCheckout), 'HUMAN_APPROVAL');
    const r = launch(w);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(outcome(r), 'AUTO_EXECUTE');
  });

  it('the launcher inside a checkout, or a copy in a version, refuses to run (not an installed launcher)', async () => {
    const w = world();
    const a = await installed(w);
    for (const launcher of [join(w.work, 'harness/src/install/launcher.ts'), join(a.dir, 'harness/src/install/launcher.ts')]) {
      const r = spawnSync(process.execPath, [launcher, 'decide', '--input', w.task], {
        cwd: w.work,
        env: { ...process.env, HARNESS_STATE_DIR: w.state, JEV_MODE: 'disabled', HARNESS_DEV: '1' },
        encoding: 'utf8',
      });
      assert.equal(r.status, 2, launcher);
      assert.match(r.stderr, /not an installed launcher/);
    }
    // The trusted bootstrap bytes at bin/harness.mts of a checkout: refused for where they are.
    const checkout = agentCheckout(w);
    mkdirSync(join(checkout, 'bin'));
    cpSync(join(w.install, 'bin/harness.mts'), join(checkout, 'bin/harness.mts'));
    const r = spawnSync(process.execPath, [join(checkout, 'bin/harness.mts'), 'install-verify'], { cwd: w.root, encoding: 'utf8' });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /inside the git checkout/);
    assert.equal(existsSync(join(w.state, 'decisions.jsonl')), false);
  });
});

describe('#245 integrity: a mismatch stops before the payload loads', () => {
  const cases: Array<[string, (dir: string, w: World) => void]> = [
    ['an edited runtime file', (dir, w) => {
      chmodSync(join(dir, ROUTER), 0o644);
      // Side effect on import: proves the payload never ran.
      appendFileSync(join(dir, ROUTER), marker(join(w.root, 'LOADED')));
    }],
    ['an extra file', (dir) => {
      chmodSync(join(dir, 'harness/src'), 0o755);
      writeFileSync(join(dir, 'harness/src/extra.ts'), 'export {};\n');
    }],
    ['a planted scripts/lib/re.py', (dir) => {
      chmodSync(join(dir, 'scripts/lib'), 0o755);
      writeFileSync(join(dir, 'scripts/lib/re.py'), 'raise SystemExit(3)\n');
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
    ['a hard-linked ACTIVE (nlink 2)', (_dir, w) => {
      linkSync(join(w.install, 'ACTIVE'), join(w.root, 'ACTIVE-second-link'));
    }],
    ['an empty .git directory inside versions/<sha>/harness/', (dir) => {
      chmodSync(join(dir, 'harness'), 0o755);
      mkdirSync(join(dir, 'harness/.git'));
    }],
  ];
  for (const [name, tamper] of cases) {
    it(`${name} → exit 2, no decision, no checkout fallback, HARNESS_DEV ignored`, async () => {
      const w = world();
      const a = await installed(w);
      tamper(a.dir, w);
      for (const args of [['install-verify'], ['decide', '--input', w.task]]) {
        const r = launch(w, args, { HARNESS_DEV: '1' });
        assert.equal(r.status, 2, r.stdout);
        assert.match(r.stderr, /harness install:/);
        assert.equal(r.stdout, '');
      }
      assert.equal(existsSync(join(w.root, 'LOADED')), false, 'payload module ran before verification');
      assert.equal(existsSync(join(w.state, 'decisions.jsonl')), false);
    });
  }

  it('a missing ACTIVE is an error, not a fallback', () => {
    const w = world();
    const a = prep(w);
    seed(w, a.sha);
    const r = spawnSync(process.execPath, [join(w.install, 'bin/harness.mts'), 'decide', '--input', w.task], { cwd: w.work, encoding: 'utf8' });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /no ACTIVE/);
  });

  it('leftovers of an interrupted activation do not change what runs', async () => {
    const w = world();
    const a = await installed(w);
    writeFileSync(join(w.install, `.ACTIVE.${process.pid}`), '{"schema":1,"sha":"garbage"}');
    mkdirSync(join(w.install, 'staging/half-written'), { recursive: true });
    const r = launch(w);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(readActive(open(w)).sha, a.sha);
  });
});

describe('#245 prepare: from Git objects, closure included, proves nothing', () => {
  it('publishes a read-only version whose MANIFEST (schema 2) covers harness/ and the four closure files', () => {
    const w = world();
    const a = prep(w);
    assert.equal(a.sha, git(w.work, 'rev-parse', 'HEAD'));
    assert.equal(verifyVersion(open(w), a.sha, a.manifestDigest).digest, a.manifestDigest);
    const m = JSON.parse(readFileSync(join(a.dir, 'MANIFEST'), 'utf8')) as { schema: number; files: Record<string, { sha256: string; exec: boolean }> };
    assert.equal(m.schema, 2);
    for (const f of ['harness/package.json', 'harness/src/cli.ts', ...CLOSURE_FILES]) assert.ok(f in m.files, f);
    assert.deepEqual(Object.keys(m.files).filter((p) => !p.startsWith('harness/')).sort(), [...CLOSURE_FILES].sort());
    assert.equal(m.files['scripts/secrets/exec-with.sh']!.exec, true);
    assert.equal(m.files['harness/src/cli.ts']!.exec, false);
    assert.equal(lstatSync(join(a.dir, 'scripts/secrets/exec-with.sh')).mode & 0o777, 0o555);
    assert.equal(lstatSync(join(a.dir, 'harness/src/cli.ts')).mode & 0o777, 0o444);
    assert.equal(existsSync(join(w.install, 'ACTIVE')), false, 'prepare must not activate');
  });

  it('installs the commit, not the working tree', () => {
    const w = world();
    tamperCheckoutRouter(w);
    const a = prep(w);
    assert.ok(readFileSync(join(a.dir, ROUTER), 'utf8').includes(RULE));
  });

  it('refuses a commit that lacks any closure file', () => {
    for (const missing of CLOSURE_FILES) {
      const w = world();
      git(w.work, 'rm', '--quiet', missing);
      const sha = commit(w.work, `without ${missing}`);
      assert.throws(() => prep(w, sha), new RegExp(`lacks ${missing.replace(/\./g, '\\.')}`));
      assert.equal(existsSync(join(w.install, 'versions', sha)), false);
    }
  });

  it('has no --remote or --branch: usage, exit 2', () => {
    const w = world();
    git(w.work, 'checkout', '--quiet', '-b', 'feature');
    writeFileSync(join(w.work, 'harness/NOTE'), 'feature only\n');
    const f = commit(w.work, 'feature', false);
    for (const opt of [['--branch', 'feature'], ['--remote', 'x']]) {
      const r = spawnSync(process.execPath, [join(w.work, 'harness/src/install/prepare.ts'), f, '--install-dir', w.install, '--skip-tests', ...opt], { cwd: w.work, encoding: 'utf8' });
      assert.equal(r.status, 2, r.stdout);
      assert.match(r.stderr, /usage: prepare\.ts/);
    }
    assert.equal(existsSync(join(w.install, 'versions', f)), false);
  });

  it('prepares from local objects with the origin unreachable; activation then refuses (prepare proves nothing)', async () => {
    const w = world();
    rmSync(w.origin, { recursive: true, force: true });
    const a = prep(w);
    assert.equal(existsSync(a.dir), true);
    let asked = false;
    await assert.rejects(activateAs(w, a.sha, APPROVAL, {}, async () => (asked = true)), /online provenance required/);
    assert.equal(asked, false);
    assert.equal(existsSync(join(w.install, 'ACTIVE')), false);
  });

  it("runs the candidate's own tests beside its commit's docs and publishes nothing when they fail", () => {
    const w = world();
    mkdirSync(join(w.work, 'harness/test'));
    mkdirSync(join(w.work, 'docs'));
    writeFileSync(join(w.work, 'docs/ai-harness.md'), 'operating guide\n');
    writeFileSync(join(w.work, 'harness/test/docs.test.ts'), "import { readFileSync } from 'node:fs';\nimport { test } from 'node:test';\ntest('docs beside harness/', () => { readFileSync('../docs/ai-harness.md'); readFileSync('../scripts/lib/manifest.py'); });\n");
    const good = commit(w.work, 'tests pass');
    assert.equal(prepare({ repo: w.work, rev: good, installDir: w.install }).sha, good);
    writeFileSync(join(w.work, 'harness/test/fail.test.ts'), "import { test } from 'node:test';\ntest('fails', () => { throw new Error('candidate is broken'); });\n");
    const bad = commit(w.work, 'tests fail');
    assert.throws(() => prepare({ repo: w.work, rev: bad, installDir: w.install }), /test suite of .* failed[\s\S]*candidate is broken/);
    assert.equal(existsSync(join(w.install, 'versions', bad)), false);
    assert.deepEqual(readdirSync(join(w.install, 'staging')), []);
  });

  // #253 S4-02 (#260): a reused staging/<sha>.<pid> is made writable before removal; a leaf that
  // is not an owned regular single-link file is refused, and the inode outside keeps its mode.
  for (const [name, plant, refused] of [
    ['a hard link to a file outside the install', (leaf: string, outside: string) => linkSync(outside, leaf), /hard link/],
    ['a FIFO', (leaf: string) => execFileSync('mkfifo', [leaf]), /not a regular file/],
  ] as const) {
    it(`a reused staging tree holding ${name} is refused, nothing outside is chmod-ed`, () => {
      const w = world();
      prep(w);
      writeFileSync(join(w.work, 'harness/src/b.ts'), 'export {};\n');
      const sha = commit(w.work, 'B');
      const outside = join(w.root, 'outside.txt');
      writeFileSync(outside, 'owner file\n', { mode: 0o600 });
      const staging = join(w.install, 'staging', `${sha}.${process.pid}`);
      mkdirSync(join(staging, 'harness'), { recursive: true });
      plant(join(staging, 'harness/leaf'), outside);
      assert.throws(() => prep(w, sha), refused);
      assert.equal(lstatSync(outside).mode & 0o777, 0o600);
      assert.equal(existsSync(join(w.install, 'versions', sha)), false);
    });
  }

  it('refuses a payload with a symbolic link', () => {
    const w = world();
    symlinkSync('../package.json', join(w.work, 'harness/src/link.json'));
    const sha = commit(w.work, 'link');
    assert.throws(() => prep(w, sha), /symbolic link/);
    assert.equal(existsSync(join(w.install, 'versions', sha)), false);
  });
});

describe('#253 rev 3 I-4: activation proves provenance against the pinned develop', () => {
  /** A commit on `side`, never merged into develop. */
  function side(w: World): string {
    git(w.work, 'checkout', '--quiet', '-b', 'side');
    writeFileSync(join(w.work, 'harness/NOTE'), 'unmerged\n');
    return commit(w.work, 'side', false);
  }

  it('a commit on a side branch, prepared from local objects, is refused before the owner is asked', async () => {
    const w = world();
    const s = side(w);
    const p = prep(w, s);
    let asked = false;
    await assert.rejects(activateAs(w, p.sha, APPROVAL, {}, async () => (asked = true)), /not an ancestor of develop/);
    assert.equal(asked, false);
    assert.equal(existsSync(join(w.install, 'ACTIVE')), false);
  });

  it('a version edited after prepare, its MANIFEST rebuilt to match, is refused: the bytes are not the commit\'s blobs', async () => {
    const w = world();
    const a = prep(w);
    writable(a.dir);
    const file = join(a.dir, ROUTER);
    writeFileSync(file, readFileSync(file, 'utf8').replace(RULE, TAMPERED));
    unlinkSync(join(a.dir, 'MANIFEST'));
    writeFileSync(join(a.dir, 'MANIFEST'), buildManifest(open(w), `versions/${a.sha}`, a.sha));
    await assert.rejects(activateAs(w, a.sha), /is not the blob/);
    assert.equal(existsSync(join(w.install, 'ACTIVE')), false);
  });

  it('a PATH git shim that fetches feature after every fetch does not move the ancestry basis', async () => {
    const w = world();
    git(w.work, 'checkout', '--quiet', '-b', 'feature');
    writeFileSync(join(w.work, 'harness/NOTE'), 'feature only\n');
    const f = commit(w.work, 'feature', false);
    git(w.work, 'push', '--quiet', 'origin', 'HEAD:feature');
    const p = prep(w, f);
    const real = execFileSync('/bin/sh', ['-c', 'command -v git'], { encoding: 'utf8' }).trim();
    const shim = join(w.root, 'shim');
    mkdirSync(shim);
    writeFileSync(join(shim, 'git'), `#!/bin/sh
"${real}" "$@"; s=$?
gd=; for a in "$@"; do case $a in --git-dir=*) gd=$a ;; esac; done
case " $* " in *" fetch "*) "${real}" $gd -c protocol.file.allow=always fetch --quiet ${JSON.stringify(w.origin)} refs/heads/feature; echo shim-ran >>${JSON.stringify(join(w.root, 'SHIM'))} ;; esac
exit $s
`, { mode: 0o755 });
    const saved = process.env.PATH;
    process.env.PATH = `${shim}:${saved}`;
    try {
      await assert.rejects(activateAs(w, p.sha), /not an ancestor of develop/);
    } finally {
      process.env.PATH = saved;
    }
    assert.equal(existsSync(join(w.root, 'SHIM')), true, 'the shim did not run; the case proves nothing');
  });

  for (const [name, env] of [
    ['GIT_CONFIG_COUNT insteadOf', (w: World, evil: string) => ({ GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: `url.${evil}.insteadOf`, GIT_CONFIG_VALUE_0: w.origin })],
    ['~/.gitconfig insteadOf', (w: World, evil: string) => {
      const home = join(w.root, 'home');
      mkdirSync(home, { recursive: true });
      writeFileSync(join(home, '.gitconfig'), `[url "${evil}"]\n\tinsteadOf = ${w.origin}\n`);
      return { HOME: home };
    }],
    ['GIT_DIR', (_w: World, evil: string) => ({ GIT_DIR: evil })],
  ] as const) {
    it(`${name} pointing at a repository whose develop holds the commit changes nothing`, async () => {
      const w = world();
      const s = side(w);
      const p = prep(w, s);
      const evil = join(w.root, 'evil.git');
      git(w.root, 'init', '--quiet', '--bare', '--initial-branch=develop', evil);
      git(w.work, 'push', '--quiet', evil, 'HEAD:develop');
      const vars = env(w, evil) as Record<string, string>;
      const saved = { ...process.env };
      Object.assign(process.env, vars);
      try {
        await assert.rejects(activateAs(w, p.sha), /not an ancestor of develop/);
      } finally {
        for (const k of Object.keys(vars)) if (saved[k] === undefined) delete process.env[k]; else process.env[k] = saved[k];
      }
    });
  }
});

describe('#253 rev 3 I-4b: offline only to a completed activation (D2)', () => {
  it('a never-activated SHA is refused offline; an activated one with the same digest rolls back offline, recorded', async () => {
    const w = world();
    const { a, b } = await withB(w);
    rmSync(w.origin, { recursive: true, force: true });
    await assert.rejects(activateAs(w, b.sha), /online provenance required/);
    const back = await activateAs(w, a.sha);
    assert.equal(back.action, 'activate', 'A is ACTIVE: re-activating it is not a rollback');
    assert.ok('recorded' in back.provenance);
    assert.equal(readActive(open(w)).sha, a.sha);
  });

  it('rollback offline to an activated version; a digest that differs, or a damaged journal, needs the network', async () => {
    const w = world();
    const { a, b } = await withB(w);
    await activateAs(w, b.sha);
    const offline = { ...w, source: { url: join(w.root, 'gone.git'), allowLocal: true } };
    const back = await activateAs(offline, a.sha, 'approval-rollback');
    assert.equal(back.action, 'rollback');
    assert.match(String((back.provenance as { recorded: string }).recorded), /^\d{4}-/);
    // The journal records A with another digest: not the same bytes, not eligible.
    const file = join(w.install, 'history.jsonl');
    writeFileSync(file, readFileSync(file, 'utf8').replaceAll(`"manifestDigest":"${a.manifestDigest}"`, `"manifestDigest":"${'1'.repeat(64)}"`));
    await assert.rejects(activateAs(offline, a.sha), /online provenance required/);
    // A damaged journal: nothing in it counts.
    await activateAs(w, b.sha);
    appendFileSync(file, '{"record":"activ');
    await assert.rejects(activateAs(offline, b.sha), /online provenance required/);
  });

  it('post-crash: an intent without its activated record grants nothing offline; online completes it', async () => {
    const w = world();
    const { a, b } = await withB(w);
    appendFileSync(join(w.install, 'history.jsonl'), `${JSON.stringify({ record: 'intent', kind: 'activate', from: { sha: a.sha, manifestDigest: a.manifestDigest }, to: { sha: b.sha, manifestDigest: b.manifestDigest }, approval: 'x', actor: 'o', source: { source: w.origin, tip: b.sha }, at: '2026-10-26T00:00:00.000Z' })}\n`);
    const offline = { ...w, source: { url: join(w.root, 'gone.git'), allowLocal: true } };
    await assert.rejects(activateAs(offline, b.sha), /online provenance required/);
    assert.equal(readActive(open(w)).sha, a.sha);
    const done = await activateAs(w, b.sha);
    assert.ok('tip' in done.provenance);
    assert.deepEqual(journal(w).slice(-3).map((r) => [r.record, (r.to as { sha?: string } | undefined)?.sha ?? r.sha]), [['intent', b.sha], ['intent', b.sha], ['activated', b.sha]]);
  });
});

describe('#245 activation: an owner act, recorded, reversible', () => {
  it('prepare B leaves A running; activate B switches; rollback to A is recorded in the journal', async () => {
    const w = world();
    const { a, b } = await withB(w);
    assert.equal(outcome(launch(w)), 'AUTO_EXECUTE', 'preparing B changed the running version');
    const toB = await activateAs(w, b.sha, 'approval-B');
    assert.deepEqual([toB.action, toB.from?.sha, toB.to.sha], ['activate', a.sha, b.sha]);
    assert.equal(outcome(launch(w)), 'HUMAN_APPROVAL');
    const back = await activateAs(w, a.sha, 'approval-rollback');
    assert.equal(back.action, 'rollback');
    assert.equal(outcome(launch(w)), 'AUTO_EXECUTE');
    const h = journal(w);
    assert.deepEqual(h.map((r) => [r.record, r.kind ?? null, (r.to as { sha?: string } | undefined)?.sha ?? r.sha, r.approval ?? null]), [
      ['intent', 'activate', a.sha, APPROVAL],
      ['activated', null, a.sha, null],
      ['intent', 'activate', b.sha, 'approval-B'],
      ['activated', null, b.sha, null],
      ['intent', 'rollback', a.sha, 'approval-rollback'],
      ['activated', null, a.sha, null],
    ]);
    assert.equal((h[4]!.from as { manifestDigest: string }).manifestDigest, b.manifestDigest);
    assert.equal(h[4]!.actor, 'owner@test');
  });

  it('the confirmation sees full SHA and digest, old → new, and a refusal changes nothing', async () => {
    const w = world();
    const a = prep(w);
    let seen: ActivationPlan | undefined;
    await assert.rejects(activateAs(w, a.sha, 'x', {}, async (plan) => {
      seen = plan;
      return false;
    }), /not confirmed/);
    assert.deepEqual(seen && [seen.from, seen.to.sha, seen.to.manifestDigest], [null, a.sha, a.manifestDigest]);
    // #272 Q-6: the plan writes bin/harness, so the typed string also binds its text.
    assert.deepEqual(seen!.wrapper, { action: 'write', node: NODE, sha256: sha256(wrapperText(NODE)) });
    assert.equal(confirmation(seen!), `none ${a.sha.slice(0, 12)} ${a.manifestDigest.slice(0, 12)} ${sha256(wrapperText(NODE)).slice(0, 12)}`);
    assert.equal(confirmation({ ...seen!, wrapper: 'kept' }), `none ${a.sha.slice(0, 12)} ${a.manifestDigest.slice(0, 12)}`);
    for (const f of ['ACTIVE', 'history.jsonl', 'bin/harness', 'activate.lock']) assert.equal(existsSync(join(w.install, f)), false, f);
  });

  it('refuses without an approval reference, for an unprepared SHA, and while another activation holds the lock', async () => {
    const w = world();
    const a = prep(w);
    await assert.rejects(activateAs(w, a.sha, ' '), /approval/);
    await assert.rejects(activateAs(w, 'f'.repeat(40)), /not installed/);
    await assert.rejects(activateAs(w, 'HEAD'), /full commit SHA/);
    writeFileSync(join(w.install, 'activate.lock'), '1\n');
    await assert.rejects(activateAs(w, a.sha), /activate\.lock exists/);
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
    const a = await installed(w);
    const r = launch(w, ['activate', a.sha, '--approval', 'x']);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /terminal/);
  });

  it('verify reports the running version', async () => {
    const w = world();
    const a = await installed(w);
    const r = launch(w, ['install-verify']);
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(JSON.parse(r.stdout), { sha: a.sha, manifestDigest: a.manifestDigest });
  });

  it('on a terminal: a wrong answer changes nothing, the right one activates', async () => {
    const w = world();
    const { a, b } = await withB(w);
    const wrong = ownerActivates(w, b.sha, { answer: 'yes' });
    assert.equal(wrong.status, 2, wrong.out);
    assert.match(wrong.out, /not confirmed; nothing changed/);
    assert.equal(readActive(open(w)).sha, a.sha);
    const right = ownerActivates(w, b.sha);
    assert.equal(right.status, 0, right.out);
    assert.match(right.out, new RegExp(`Type "${a.sha.slice(0, 12)} ${b.sha.slice(0, 12)} ${b.manifestDigest.slice(0, 12)}"`));
    assert.equal(readActive(open(w)).sha, b.sha);
  });
});

describe('#253 rev 3 I-5: ACTIVE is classified, never followed', () => {
  /** ACTIVE replaced by a link to a checkout file that names B. */
  function linkActiveTo(w: World, b: { sha: string; manifestDigest: string }): string {
    const evil = join(agentCheckout(w), 'ACTIVE-evil');
    writeFileSync(evil, JSON.stringify({ schema: 1, sha: b.sha, manifestDigest: b.manifestDigest }));
    rmSync(join(w.install, 'ACTIVE'));
    symlinkSync(evil, join(w.install, 'ACTIVE'));
    return evil;
  }

  it('ACTIVE a symbolic link into a checkout naming B: nothing runs', async () => {
    const w = world();
    const { b } = await withB(w);
    linkActiveTo(w, b);
    const r = launch(w);
    assert.equal(r.status, 2, r.stdout);
    assert.match(r.stderr, /symbolic link/);
    assert.equal(existsSync(join(w.state, 'decisions.jsonl')), false);
  });

  it('activate with a linked ACTIVE: from null, link shown and quarantined unfollowed, target untouched', async () => {
    const w = world();
    const { a, b } = await withB(w);
    const evil = linkActiveTo(w, b);
    const before = readFileSync(evil);
    let seen: ActivationPlan | undefined;
    const plan = await activateAs(w, a.sha, APPROVAL, {}, async (p) => {
      seen = p;
      return true;
    });
    assert.equal(plan.from, null);
    assert.deepEqual(plan.active, { broken: 'link', target: evil });
    assert.match(confirmation(seen!), /^broken /);
    const q = readdirSync(join(w.install, 'quarantine'));
    assert.equal(q.length, 1);
    assert.equal(readlinkSync(join(w.install, 'quarantine', q[0]!)), evil);
    assert.deepEqual(readFileSync(evil), before);
    assert.equal(lstatSync(join(w.install, 'ACTIVE')).isFile(), true);
    assert.equal(outcome(launch(w)), 'AUTO_EXECUTE');
  });

  for (const bad of ['{', '{"schema":2}']) {
    it(`ACTIVE = ${bad}: bin/harness activate recovers on a terminal, from none, the file kept byte for byte`, async () => {
      const w = world();
      const a = await installed(w);
      writeFileSync(join(w.install, 'ACTIVE'), bad);
      assert.equal(launch(w).status, 2);
      const r = ownerActivates(w, a.sha);
      assert.equal(r.status, 0, r.out);
      assert.match(r.out, /Type "broken /);
      const q = readdirSync(join(w.install, 'quarantine'));
      assert.equal(q.length, 1);
      assert.equal(readFileSync(join(w.install, 'quarantine', q[0]!), 'utf8'), bad);
      const intent = journal(w).filter((x) => x.record === 'intent').pop()!;
      assert.equal(intent.from, null);
      assert.equal((intent.active as { sha256: string }).sha256, sha256(bad));
      assert.equal(launch(w).status, 0);
    });
  }

  for (const kind of ['directory', 'fifo'] as const) {
    it(`ACTIVE a ${kind}: activate refuses "remove it by hand", nothing changes; run exits 2`, async () => {
      const w = world();
      const a = await installed(w);
      const h = readFileSync(join(w.install, 'history.jsonl'));
      rmSync(join(w.install, 'ACTIVE'));
      if (kind === 'directory') mkdirSync(join(w.install, 'ACTIVE'));
      else execFileSync('mkfifo', [join(w.install, 'ACTIVE')]);
      await assert.rejects(activateAs(w, a.sha), new RegExp(`ACTIVE in .* is a ${kind}; remove it by hand`));
      assert.deepEqual(readFileSync(join(w.install, 'history.jsonl')), h);
      assert.equal(existsSync(join(w.install, 'quarantine')), false);
      assert.equal(existsSync(join(w.install, 'activate.lock')), false);
      const r = launch(w, ['install-verify']);
      assert.equal(r.status, 2);
      assert.match(r.stderr, new RegExp(`is a ${kind}`));
    });
  }

  it("bootstrap-owned activation: A's edited CLI blocks decide, not activate B; neither version's code runs to switch", async () => {
    const w = world();
    const { a, b } = await withB(w, (w) => {
      tamperCheckoutRouter(w);
      appendFileSync(join(w.work, 'harness/src/install/launcher.ts'), marker(join(w.root, 'B_LAUNCHER_RAN')));
    });
    writable(a.dir);
    appendFileSync(join(a.dir, 'harness/src/cli.ts'), marker(join(w.root, 'A_CLI_RAN')));
    const r = launch(w);
    assert.equal(r.status, 2, 'decide ran an edited A');
    const act = ownerActivates(w, b.sha);
    assert.equal(act.status, 0, act.out);
    assert.match(act.out, new RegExp(`"sha": "${a.sha}"`));
    assert.equal(existsSync(join(w.root, 'A_CLI_RAN')), false);
    assert.equal(existsSync(join(w.root, 'B_LAUNCHER_RAN')), false);
    assert.equal(outcome(launch(w)), 'HUMAN_APPROVAL');
  });
});

describe('#253 rev 3 I-5b: the journal', () => {
  it('a truncated last line: quarantined byte for byte, a new journal starts; offline rollback only to what it records', async () => {
    const w = world();
    const { a, b } = await withB(w);
    await activateAs(w, b.sha);
    await activateAs(w, a.sha); // B is now activated in the old journal
    writeFileSync(join(w.work, 'harness/NOTE'), 'C\n');
    const c = prep(w, commit(w.work, 'C'));
    appendFileSync(join(w.install, 'history.jsonl'), '{"record":"intent","kind":"activ');
    const damaged = readFileSync(join(w.install, 'history.jsonl'));
    const repair = await activateAs(w, c.sha);
    assert.deepEqual(repair.journal, { damaged: 7 });
    const q = readdirSync(join(w.install, 'quarantine')).filter((n) => n.startsWith('history.jsonl.'));
    assert.equal(q.length, 1);
    assert.deepEqual(readFileSync(join(w.install, 'quarantine', q[0]!)), damaged);
    assert.deepEqual(journal(w).map((r) => r.record), ['history_quarantined', 'intent', 'activated']);
    assert.equal(journal(w)[0]!.parsedLines, 6);
    await activateAs(w, a.sha);
    const offline = { ...w, source: { url: join(w.root, 'gone.git'), allowLocal: true } };
    assert.equal((await activateAs(offline, c.sha)).action, 'rollback');
    // B was activated before the repair: the new journal does not say so.
    await assert.rejects(activateAs(offline, b.sha), /online provenance required/);
  });

  it('history.jsonl a symbolic link into a checkout: refused, nothing written anywhere', async () => {
    const w = world();
    const a = prep(w);
    const target = join(agentCheckout(w), 'history');
    writeFileSync(target, '');
    symlinkSync(target, join(w.install, 'history.jsonl'));
    await assert.rejects(activateAs(w, a.sha), /symbolic link/);
    assert.equal(readFileSync(target, 'utf8'), '');
    assert.equal(existsSync(join(w.install, 'ACTIVE')), false);
  });

  it('a pre-placed .ACTIVE.<pid> link is refused by the exclusive create; the link target stays empty', async () => {
    const w = world();
    const a = prep(w);
    const target = join(agentCheckout(w), 'evil');
    writeFileSync(target, '');
    symlinkSync(target, join(w.install, `.ACTIVE.${process.pid}`));
    await assert.rejects(activateAs(w, a.sha), /EEXIST/);
    assert.equal(readFileSync(target, 'utf8'), '');
    assert.equal(existsSync(join(w.install, 'ACTIVE')), false);
  });
});

describe('#253 rev 3 I-2b: the activation lock', () => {
  it('a symbolic link at activate.lock is refused, and the message names it', async () => {
    const w = world();
    const a = prep(w);
    symlinkSync(join(w.root, 'elsewhere'), join(w.install, 'activate.lock'));
    await assert.rejects(activateAs(w, a.sha), /activate\.lock is a symbolic link to .*elsewhere/);
    assert.equal(existsSync(join(w.root, 'elsewhere')), false);
  });

  it('released after success and after failure; a lock replaced mid-run is left in place, with a warning', async () => {
    const w = world();
    const a = prep(w);
    await activateAs(w, a.sha);
    assert.equal(existsSync(join(w.install, 'activate.lock')), false);
    await assert.rejects(activateAs(w, a.sha, APPROVAL, {}, async () => false), /not confirmed/);
    assert.equal(existsSync(join(w.install, 'activate.lock')), false);
    const warnings: string[] = [];
    await activateAs(w, a.sha, APPROVAL, { warn: (m) => warnings.push(m) }, async () => {
      unlinkSync(join(w.install, 'activate.lock'));
      writeFileSync(join(w.install, 'activate.lock'), 'someone else\n');
      return true;
    });
    assert.equal(readFileSync(join(w.install, 'activate.lock'), 'utf8'), 'someone else\n');
    assert.match(warnings.join('\n'), /no longer the lock this activation took; left in place/);
  });
});

describe('#253 rev 3 I-1/I-2: no .git anywhere in the install', () => {
  for (const loc of ['versions', 'versions/<sha>', 'bin', 'staging', 'quarantine']) {
    it(`a .git directory or file at ${loc}/ → prepare, activate and run exit 2`, async () => {
      const w = world();
      const a = await installed(w);
      const dir = join(w.install, loc.replace('<sha>', a.sha));
      mkdirSync(dir, { recursive: true });
      chmodSync(dir, 0o755);
      for (const kind of ['directory', 'file']) {
        if (kind === 'directory') mkdirSync(join(dir, '.git'));
        else writeFileSync(join(dir, '.git'), 'gitdir: /elsewhere\n');
        const r = launch(w, ['install-verify']);
        assert.equal(r.status, 2, `${kind}: ${r.stdout}`);
        assert.match(r.stderr, /\.git exists/);
        await assert.rejects(activateAs(w, a.sha), /\.git exists/);
        assert.throws(() => prep(w, a.sha), /\.git exists/);
        rmSync(join(dir, '.git'), { recursive: true });
      }
    });
  }
});

describe('#253 rev 3 I-6: bin/harness is the launch boundary', () => {
  it('a hook environment with NODE_OPTIONS=--import and NODE_PATH: the preload never runs', async () => {
    const w = world();
    await installed(w);
    const mjs = join(w.root, 'marker.mjs');
    writeFileSync(mjs, `import { writeFileSync } from 'node:fs'; writeFileSync(${JSON.stringify(join(w.root, 'PRELOAD_RAN'))}, 'x');\n`);
    const r = launch(w, undefined, { NODE_OPTIONS: `--import ${mjs}`, NODE_PATH: w.root });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(existsSync(join(w.root, 'PRELOAD_RAN')), false);
  });

  it('node --import marker bin/harness.mts → exit 2, no decision (diagnostic: the marker has already run)', async () => {
    const w = world();
    await installed(w);
    const mjs = join(w.root, 'marker.mjs');
    writeFileSync(mjs, `import { writeFileSync } from 'node:fs'; writeFileSync(${JSON.stringify(join(w.root, 'PRELOAD_RAN'))}, 'x');\n`);
    const r = spawnSync(process.execPath, ['--import', mjs, join(w.install, 'bin/harness.mts'), 'decide', '--input', w.task], { cwd: w.work, env: { ...process.env, HARNESS_STATE_DIR: w.state, JEV_MODE: 'disabled' }, encoding: 'utf8' });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /preload/);
    assert.equal(existsSync(join(w.state, 'decisions.jsonl')), false);
    // The marker did run: refusing afterwards is a diagnostic, bin/harness is the boundary.
    assert.equal(existsSync(join(w.root, 'PRELOAD_RAN')), true);
  });

  it('run from a checkout with decoys in cwd and on PATH: the installed harness runs; relative --input is the caller\'s; $0 without a slash exits 2', async () => {
    const w = world();
    await installed(w);
    const ran = join(w.root, 'DECOY_RAN');
    const decoy = `#!/bin/sh\necho x >>${JSON.stringify(ran)}\nexit 9\n`;
    mkdirSync(join(w.work, 'bin'), { recursive: true });
    writeFileSync(join(w.work, 'bin/harness.mts'), marker(ran));
    writeFileSync(join(w.work, 'harness.mts'), marker(ran));
    const path = join(w.root, 'decoys');
    mkdirSync(path);
    for (const tool of ['node', 'cat', 'env', 'dirname']) writeFileSync(join(path, tool), decoy, { mode: 0o755 });
    cpSync(w.task, join(w.work, 'task-rel.json'));
    const r = launch(w, ['decide', '--input', 'task-rel.json'], { PATH: `${path}:${process.env.PATH}` });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(outcome(r), 'AUTO_EXECUTE');
    assert.equal(existsSync(ran), false);
    const bare = spawnSync('/bin/sh', ['harness', 'install-verify'], { cwd: join(w.install, 'bin'), encoding: 'utf8' });
    assert.equal(bare.status, 2);
    assert.match(bare.stderr, /by its path/);
  });

  it('#272 T-4 (D-3): without --node, or with the same text, bin/harness is kept; another --node rewrites it after confirmation, the old file quarantined and journaled', async () => {
    const w = world();
    const { a, b } = await withB(w);
    const wrapper = readFileSync(join(w.install, 'bin/harness'), 'utf8');
    const boot = readFileSync(join(w.install, 'bin/harness.mts'));
    assert.equal(wrapper, wrapperText(NODE));
    assert.equal(lstatSync(join(w.install, 'bin/harness')).mode & 0o777, 0o555);
    // (a) no --node: kept byte for byte.
    const toB = await activateAs(w, b.sha, APPROVAL, { node: undefined });
    assert.equal(toB.wrapper, 'kept');
    assert.equal(confirmation(toB).split(' ').length, 3);
    assert.equal(journal(w).filter((r) => r.record === 'intent').pop()!.wrapper, 'kept');
    // (b) same --node, same template: kept.
    const back = await activateAs(w, a.sha, APPROVAL, { node: NODE });
    assert.equal(back.wrapper, 'kept');
    assert.equal(readFileSync(join(w.install, 'bin/harness'), 'utf8'), wrapper);
    assert.deepEqual(readFileSync(join(w.install, 'bin/harness.mts')), boot);
    // (c) another --node (a stable link): refused confirmation changes nothing; confirmed rewrites.
    const m = join(w.root, 'stable', 'node');
    mkdirSync(dirname(m));
    symlinkSync(NODE, m);
    await assert.rejects(activateAs(w, b.sha, APPROVAL, { node: m }, async () => false), /not confirmed/);
    assert.equal(readFileSync(join(w.install, 'bin/harness'), 'utf8'), wrapper);
    const at = new Date('2026-10-28T12:00:00.000Z');
    const plan = await activateAs(w, b.sha, APPROVAL, { node: m, now: () => at });
    assert.ok(plan.wrapper !== 'kept' && plan.wrapper.action === 'rewrite');
    assert.deepEqual([plan.wrapper.node, plan.wrapper.fromNode, plan.wrapper.from, plan.wrapper.sha256], [m, NODE, sha256(wrapper), sha256(wrapperText(m))]);
    assert.equal(confirmation(plan).split(' ')[3], sha256(wrapperText(m)).slice(0, 12));
    const quarantined = `quarantine/harness.${at.toISOString()}`;
    assert.equal(plan.wrapper.quarantined, quarantined);
    assert.equal(readFileSync(join(w.install, quarantined), 'utf8'), wrapper);
    const now = readFileSync(join(w.install, 'bin/harness'), 'utf8');
    assert.equal(now, wrapperText(m));
    assert.match(now, new RegExp(`^node='${m.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}'$`, 'm'));
    const st = lstatSync(join(w.install, 'bin/harness'));
    assert.deepEqual([st.mode & 0o777, st.nlink], [0o555, 1]);
    assert.deepEqual(journal(w).filter((r) => r.record === 'intent').pop()!.wrapper, { rewritten: sha256(wrapper), node: m, quarantined });
    assert.equal(readJournal(open(w)).state, 'ok');
    assert.deepEqual(readFileSync(join(w.install, 'bin/harness.mts')), boot);
    assert.equal(launch(w, ['install-verify']).status, 0);
  });

  it('#272 T-4 (d): an owner-written bin/harness is kept without --node; with --node it is rewritten only after confirmation, the original quarantined unchanged', async () => {
    const w = world();
    const a = prep(w);
    seed(w, a.sha);
    const own = "#!/bin/sh\n# the owner's own\n";
    writeFileSync(join(w.install, 'bin/harness'), own, { mode: 0o555 });
    await assert.rejects(activateAs(w, a.sha, APPROVAL, {}, async () => false), /not confirmed/);
    assert.equal(readFileSync(join(w.install, 'bin/harness'), 'utf8'), own);
    const at = new Date('2026-10-28T13:00:00.000Z');
    const plan = await activateAs(w, a.sha, APPROVAL, { now: () => at });
    assert.ok(plan.wrapper !== 'kept' && plan.wrapper.action === 'rewrite' && plan.wrapper.fromNode === null);
    assert.equal(readFileSync(join(w.install, `quarantine/harness.${at.toISOString()}`), 'utf8'), own);
    assert.equal(readFileSync(join(w.install, 'bin/harness'), 'utf8'), wrapperText(NODE));
  });

  it('a pre-existing regular bin/harness is kept; a link or directory there, or a pre-placed bin/.harness.<pid> link, is refused', async () => {
    const w = world();
    const a = prep(w);
    seed(w, a.sha);
    writeFileSync(join(w.install, 'bin/harness'), '#!/bin/sh\n# the owner\'s own\n', { mode: 0o555 });
    await activateAs(w, a.sha, APPROVAL, { node: undefined });
    assert.equal(readFileSync(join(w.install, 'bin/harness'), 'utf8'), "#!/bin/sh\n# the owner's own\n");
    for (const make of [(p: string) => symlinkSync('/bin/sh', p), (p: string) => mkdirSync(p)]) {
      rmSync(join(w.install, 'bin/harness'), { force: true, recursive: true });
      make(join(w.install, 'bin/harness'));
      await assert.rejects(activateAs(w, a.sha), /bin\/harness in .* is a (symbolic link|directory); remove it by hand/);
    }
    rmSync(join(w.install, 'bin/harness'), { force: true, recursive: true });
    const target = join(w.root, 'evil-wrapper');
    symlinkSync(target, join(w.install, `bin/.harness.${process.pid}`));
    await assert.rejects(activateAs(w, a.sha), /EEXIST/);
    assert.equal(existsSync(target), false);
    assert.equal(existsSync(join(w.install, 'bin/harness')), false);
  });

  it('S4-01: a hard-linked bin/harness (e.g. to a checkout file) is refused, not kept', async () => {
    const w = world();
    const a = prep(w);
    seed(w, a.sha);
    const outside = join(w.root, 'checkout-wrapper');
    writeFileSync(outside, '#!/bin/sh\n# edited in a checkout\n', { mode: 0o555 });
    linkSync(outside, join(w.install, 'bin/harness'));
    await assert.rejects(activateAs(w, a.sha), /bin\/harness in .* has 2 hard links; remove it by hand/);
    assert.equal(existsSync(join(w.install, 'ACTIVE')), false);
  });

  it('interrupted after the wrapper, after the intent, after the ACTIVE rename: activating again completes', async () => {
    // After the wrapper: bin/ holds both files, nothing else happened.
    const w = world();
    const a = prep(w);
    seed(w, a.sha);
    writeFileSync(join(w.install, 'bin/harness'), wrapperText(NODE), { mode: 0o555 });
    const wrapper = readFileSync(join(w.install, 'bin/harness'));
    const one = ownerActivates(w, a.sha, { via: 'bootstrap' });
    assert.equal(one.status, 0, one.out);
    assert.deepEqual(readFileSync(join(w.install, 'bin/harness')), wrapper);
    // After the intent: B's intent is written, ACTIVE is still A.
    tamperCheckoutRouter(w);
    const b = prep(w, commit(w.work, 'B'));
    const intent = (to: string, digest: string) => `${JSON.stringify({ record: 'intent', kind: 'activate', from: { sha: a.sha, manifestDigest: a.manifestDigest }, to: { sha: to, manifestDigest: digest }, approval: 'x', actor: 'o', source: { source: w.origin, tip: to }, at: '2026-10-26T00:00:00.000Z' })}\n`;
    appendFileSync(join(w.install, 'history.jsonl'), intent(b.sha, b.manifestDigest));
    const two = ownerActivates(w, b.sha, { via: 'bootstrap' });
    assert.equal(two.status, 0, two.out);
    assert.deepEqual(journal(w).filter((r) => r.record === 'intent' && (r.to as { sha: string }).sha === b.sha).length, 2);
    // After the rename: ACTIVE is A again, written by hand, with A's intent and no activated record.
    appendFileSync(join(w.install, 'history.jsonl'), intent(a.sha, a.manifestDigest));
    unlinkSync(join(w.install, 'ACTIVE'));
    writeFileSync(join(w.install, 'ACTIVE'), `${JSON.stringify({ schema: 1, sha: a.sha, manifestDigest: a.manifestDigest }, null, 2)}\n`);
    const three = ownerActivates(w, a.sha, { via: 'bootstrap' });
    assert.equal(three.status, 0, three.out);
    const last = journal(w).slice(-3).map((r) => [r.record, (r.to as { sha?: string } | undefined)?.sha ?? r.sha]);
    assert.deepEqual(last, [['intent', a.sha], ['intent', a.sha], ['activated', a.sha]]);
    assert.deepEqual(readFileSync(join(w.install, 'bin/harness')), wrapper);
  });
});

describe('#253 rev 3 I-8: the JEV send closure ships and is verified (D6)', () => {
  for (const f of CLOSURE_FILES) {
    it(`${f} tampered after activation → install-verify and decide exit 2`, async () => {
      const w = world();
      const a = await installed(w);
      const file = join(a.dir, f);
      chmodSync(file, 0o644);
      appendFileSync(file, '\n# tampered\n');
      for (const args of [['install-verify'], ['decide', '--input', w.task]]) {
        const r = launch(w, args);
        assert.equal(r.status, 2, r.stdout);
        assert.match(r.stderr, new RegExp(`${f.replace(/\./g, '\\.')} of ${a.sha}`));
      }
    });
  }

  it('a MANIFEST whose entries carry no exec bit, digest kept consistent, is refused', async () => {
    const w = world();
    const a = await installed(w);
    writable(a.dir);
    const m = JSON.parse(readFileSync(join(a.dir, 'MANIFEST'), 'utf8')) as { files: Record<string, { sha256: string }> };
    const flat = { ...m, files: Object.fromEntries(Object.entries(m.files).map(([p, e]) => [p, { sha256: e.sha256 }])) };
    const text = `${JSON.stringify(flat, null, 2)}\n`;
    writeFileSync(join(a.dir, 'MANIFEST'), text);
    writeFileSync(join(w.install, 'ACTIVE'), JSON.stringify({ schema: 1, sha: a.sha, manifestDigest: sha256(text) }));
    const r = launch(w, ['install-verify']);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /has no sha256 and exec/);
  });
});

describe('#253 rev 3 I-7b: the first install, as documented, under a hostile environment', () => {
  const BLOCK = `/usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" /bin/sh -euc '
sha="<sha>"
node="<node>"
root="<root>"
approval="<approval>"
g() {
  env -i PATH=/usr/bin:/bin HOME="$tmp" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \\
    git -c protocol.allow=never -c protocol.https.allow=always -c http.followRedirects=false -c credential.helper= "$@"
}
tmp=$(mktemp -d)
g clone --quiet --bare --branch develop --single-branch https://github.com/namnh92/GoGo-Infra.git "$tmp/src.git"
g --git-dir="$tmp/src.git" merge-base --is-ancestor "$sha" develop
mkdir -p "$root/bin"
test ! -e "$root/bin/harness.mts"
new=$(mktemp "$root/bin/.harness.mts.XXXXXX")
g --git-dir="$tmp/src.git" cat-file blob "$sha:harness/src/install/launcher.ts" >"$new"
chmod 555 "$new"
mv "$new" "$root/bin/harness.mts"
rm -rf "$tmp"
env -i PATH=/usr/bin:/bin HOME="$HOME" "$node" "$root/bin/harness.mts" activate "$sha" --approval "$approval" --node "$node"
'
`;

  const UPGRADE_MOVE = `root="<root>"
mkdir -p "$root/quarantine"
mv "$root/bin/harness.mts" "$root/quarantine/bin-harness.mts.$(date -u +%Y%m%dT%H%M%SZ)"
`;

  it('docs/ai-harness.md holds exactly this block', () => {
    const docs = readFileSync(join(REPO, 'docs/ai-harness.md'), 'utf8');
    assert.ok(docs.includes(`\`\`\`sh\n${BLOCK}\`\`\`\n`), 'the first-install block in docs/ai-harness.md differs from the one this test runs');
  });

  it('run with preloads, NODE_PATH, insteadOf (env and ~/.gitconfig) and PATH decoys: the true bootstrap, ACTIVE, no marker', () => {
    const w = world();
    const a = prep(w);
    // The evil repository: develop holds a launcher that announces itself.
    const evil = join(w.root, 'evil.git');
    git(w.work, 'checkout', '--quiet', '-b', 'evil');
    appendFileSync(join(w.work, 'harness/src/install/launcher.ts'), marker(join(w.root, 'EVIL_RAN')));
    commit(w.work, 'evil', false);
    git(w.root, 'init', '--quiet', '--bare', '--initial-branch=develop', evil);
    git(w.work, 'push', '--quiet', '--force', evil, 'HEAD:develop');
    const home = join(w.root, 'home');
    mkdirSync(home);
    writeFileSync(join(home, '.gitconfig'), `[url "${evil}"]\n\tinsteadOf = ${w.origin}\n`);
    const mjs = join(w.root, 'marker.mjs');
    writeFileSync(mjs, `import { writeFileSync } from 'node:fs'; writeFileSync(${JSON.stringify(join(w.root, 'PRELOAD_RAN'))}, 'x');\n`);
    const decoys = join(w.root, 'decoys');
    mkdirSync(decoys);
    for (const tool of ['git', 'node']) writeFileSync(join(decoys, tool), `#!/bin/sh\necho x >>${JSON.stringify(join(w.root, 'DECOY_RAN'))}\nexit 9\n`, { mode: 0o755 });
    // The block as documented, slots filled; the URL is this world's origin and file stands in for https.
    const block = BLOCK.replace('<sha>', a.sha).replace('<node>', NODE).replace('<root>', w.install).replace('<approval>', APPROVAL)
      .replace('https://github.com/namnh92/GoGo-Infra.git', w.origin).replace('protocol.https.allow=always', 'protocol.file.allow=always');
    const r = owner(['/bin/bash', '-c', block], {
      cwd: w.work,
      env: {
        HOME: home,
        PATH: `${decoys}:${process.env.PATH}`,
        NODE_OPTIONS: `--import ${mjs}`,
        NODE_PATH: w.root,
        GIT_CONFIG_COUNT: '1',
        GIT_CONFIG_KEY_0: `url.${evil}.insteadOf`,
        GIT_CONFIG_VALUE_0: w.origin,
      },
    });
    assert.equal(r.status, 0, r.out);
    for (const m of ['PRELOAD_RAN', 'EVIL_RAN', 'DECOY_RAN']) assert.equal(existsSync(join(w.root, m)), false, m);
    const blob = execFileSync('git', ['-C', w.origin, 'cat-file', 'blob', `${a.sha}:harness/src/install/launcher.ts`]);
    assert.deepEqual(readFileSync(join(w.install, 'bin/harness.mts')), blob);
    assert.equal(gitBlobId(readFileSync(join(w.install, 'bin/harness.mts'))), git(w.origin, 'rev-parse', `${a.sha}:harness/src/install/launcher.ts`));
    assert.equal(readActive(open(w)).sha, a.sha);
    assert.equal(readFileSync(join(w.install, 'bin/harness'), 'utf8'), wrapperText(NODE));
    assert.equal(launch(w).status, 0);
  });

  it('#272 T-6 (D-6): bootstrap upgrade — quarantine bin/harness.mts, run the block again with a newer SHA: new bootstrap, ACTIVE moves, bin/harness kept', () => {
    const w = world();
    const a = prep(w);
    const fill = (sha: string) => BLOCK.replace('<sha>', sha).replace('<node>', NODE).replace('<root>', w.install).replace('<approval>', APPROVAL)
      .replace('https://github.com/namnh92/GoGo-Infra.git', w.origin).replace('protocol.https.allow=always', 'protocol.file.allow=always');
    let r = owner(['/bin/bash', '-c', fill(a.sha)], { cwd: w.work });
    assert.equal(r.status, 0, r.out);
    assert.match(r.out, /bin\/harness write: node /);
    const wrapper = readFileSync(join(w.install, 'bin/harness'), 'utf8');
    // B: the launcher differs by a comment.
    appendFileSync(join(w.work, 'harness/src/install/launcher.ts'), '\n// bootstrap B\n');
    const b = prep(w, commit(w.work, 'B'));
    // A second run without the quarantine step refuses: the bootstrap is placed once.
    r = owner(['/bin/bash', '-c', fill(b.sha)], { cwd: w.work });
    assert.notEqual(r.status, 0, r.out);
    assert.equal(readActive(open(w)).sha, a.sha);
    // The documented bootstrap move, verbatim, on an install that has no quarantine/ yet (PR #275 Sol r1 F-01).
    assert.ok(readFileSync(join(REPO, 'docs/ai-harness.md'), 'utf8').includes(`\`\`\`sh\n${UPGRADE_MOVE}\`\`\`\n`), 'the bootstrap-upgrade block in docs/ai-harness.md differs from the one this test runs');
    assert.equal(existsSync(join(w.install, 'quarantine')), false);
    const mv = spawnSync('/bin/sh', ['-euc', UPGRADE_MOVE.replace('<root>', w.install)], { encoding: 'utf8' });
    assert.equal(mv.status, 0, mv.stderr);
    assert.equal(existsSync(join(w.install, 'bin/harness.mts')), false);
    assert.equal(readdirSync(join(w.install, 'quarantine')).filter((f) => f.startsWith('bin-harness.mts.')).length, 1);
    r = owner(['/bin/bash', '-c', fill(b.sha)], { cwd: w.work });
    assert.equal(r.status, 0, r.out);
    assert.match(r.out, /bin\/harness kept/);
    assert.equal(gitBlobId(readFileSync(join(w.install, 'bin/harness.mts'))), git(w.origin, 'rev-parse', `${b.sha}:harness/src/install/launcher.ts`));
    assert.equal(readActive(open(w)).sha, b.sha);
    assert.equal(readFileSync(join(w.install, 'bin/harness'), 'utf8'), wrapper);
    assert.equal(launch(w, ['install-verify']).status, 0);
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

describe('#253 review P1: an install inside a git checkout is refused', () => {
  it('prepare refuses an install directory inside a checkout', () => {
    const w = world();
    assert.throws(() => prepare({ repo: w.work, rev: 'HEAD', installDir: join(w.work, 'install'), runTests: false }), /inside the git checkout/);
    assert.equal(existsSync(join(w.work, 'install/versions')), false);
  });

  it('activate refuses one too', async () => {
    const w = world();
    prep(w);
    const inside = join(w.work, 'install-copy');
    copyTree(w.install, inside);
    assert.throws(() => Install.open(inside), /inside the git checkout/);
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
      await installed(w);
      assert.equal(launch(w, ['install-verify']).status, 0);
      const inside = place(w);
      copyTree(w.install, inside);
      const link = join(w.root, `install-link-${i}`);
      symlinkSync(inside, link);
      for (const launcher of [join(inside, 'bin/harness'), join(link, 'bin/harness')]) {
        const r = spawnSync(launcher, ['install-verify'], { cwd: w.root, encoding: 'utf8' });
        assert.equal(r.status, 2, `${launcher} ran`);
        assert.match(r.stderr, /inside the git checkout/);
      }
    });
  }
});

describe('#253 review P2: ACTIVE alone switches what runs', () => {
  it('a failure after the owner confirmed leaves ACTIVE, bootstrap and wrapper as they were', async () => {
    const w = world();
    const { a, b } = await withB(w);
    const before = [readFileSync(join(w.install, 'bin/harness.mts')), readFileSync(join(w.install, 'bin/harness'))];
    // A directory where ACTIVE's temp file goes makes the last step fail, after confirmation and the intent.
    mkdirSync(join(w.install, `.ACTIVE.${process.pid}`));
    await assert.rejects(activateAs(w, b.sha), /EEXIST/);
    assert.equal(readActive(open(w)).sha, a.sha);
    assert.deepEqual([readFileSync(join(w.install, 'bin/harness.mts')), readFileSync(join(w.install, 'bin/harness'))], before);
    assert.equal(journal(w).at(-1)!.record, 'intent');
    const r = launch(w);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(outcome(r), 'AUTO_EXECUTE');
  });
});

describe('#253 review r2 P1: no link from the install root to a version', () => {
  /** A checkout holding a copy of `w.install/versions`, and a second install whose `versions` links to it. */
  function linkedVersions(w: World): { checkout: string; linked: string } {
    const checkout = agentCheckout(w);
    copyTree(join(w.install, 'versions'), join(checkout, 'versions'));
    const linked = join(w.root, 'install-linked');
    mkdirSync(linked);
    symlinkSync(join(checkout, 'versions'), join(linked, 'versions'));
    return { checkout, linked };
  }

  it('activate refuses a version reached through a link into a checkout', async () => {
    const w = world();
    const a = prep(w);
    const { linked } = linkedVersions(w);
    await assert.rejects(async () => activate({ install: Install.open(linked), sha: a.sha, approval: 'x', source: w.source }, yes), /symbolic link/);
    assert.equal(existsSync(join(linked, 'ACTIVE')), false);
  });

  it('a working install whose versions/ links into a checkout does not run the checkout payload', async () => {
    const w = world();
    const a = await installed(w);
    const { checkout, linked } = linkedVersions(w);
    copyTree(join(w.install, 'bin'), join(linked, 'bin'));
    writeFileSync(join(linked, 'ACTIVE'), readFileSync(join(w.install, 'ACTIVE')));
    // The checkout copy is what a session could edit: make it announce that it ran.
    const cli = join(checkout, 'versions', a.sha, 'harness/src/cli.ts');
    chmodSync(cli, 0o644);
    appendFileSync(cli, marker(join(w.root, 'CHECKOUT_PAYLOAD_RAN')));
    const r = spawnSync(join(linked, 'bin/harness'), ['install-verify'], { cwd: w.root, encoding: 'utf8' });
    assert.equal(r.status, 2, r.stdout);
    assert.match(r.stderr, /symbolic link/);
    assert.equal(existsSync(join(w.root, 'CHECKOUT_PAYLOAD_RAN')), false);
  });

  it('prepare refuses to publish through a linked versions/ directory', () => {
    const w = world();
    prep(w);
    const { linked } = linkedVersions(w);
    tamperCheckoutRouter(w);
    const b = commit(w.work, 'B');
    assert.throws(() => prepare({ repo: w.work, rev: b, installDir: linked, runTests: false }), /symbolic link/);
  });
});

describe('#253 rev 3 structure: one door to the file system, one to subprocesses', () => {
  const launcher = readFileSync(join(HARNESS, 'src/install/launcher.ts'), 'utf8');
  const preparer = readFileSync(join(HARNESS, 'src/install/prepare.ts'), 'utf8');

  /** The text of `function <name>(` up to the closing brace at column 0. */
  function body(text: string, start: string): string {
    const i = text.indexOf(start);
    assert.ok(i >= 0, `${start} not found`);
    return text.slice(i, text.indexOf('\n}\n', i) + 3);
  }

  it('node:fs is used inside the Install section of launcher.ts only, and in prepare.ts inside runSuite only', () => {
    const begin = launcher.indexOf('// ── Install:');
    const end = launcher.indexOf('// ── end of Install');
    assert.ok(begin > 0 && end > begin);
    const outside = launcher.slice(0, begin) + launcher.slice(end);
    assert.deepEqual(outside.match(/\bfs\.\w+/g) ?? [], []);
    assert.equal((outside.match(/from 'node:fs'/g) ?? []).length, 1, 'node:fs imported once, as `fs`');
    const suite = body(preparer, 'function runSuite(');
    assert.deepEqual(preparer.replace(suite, '').match(/\bfs\.\w+/g) ?? [], []);
  });

  it('child_process only in git() and runSuite', () => {
    const g = body(launcher, 'export function git(');
    assert.deepEqual(launcher.replace(g, '').match(/\bspawnSync\(|\bexecFileSync\(|\bexecSync\(|\bspawn\(|\bexec\(/g) ?? [], []);
    const suite = body(preparer, 'function runSuite(');
    assert.deepEqual(preparer.replace(suite, '').match(/\bspawnSync\(|\bexecFileSync\(|\bexecSync\(|\bspawn\(|\bexec\(/g) ?? [], []);
  });

  it('no FETCH_HEAD, --remote, --branch, tar, seed, versionOf or main(', () => {
    for (const [name, text] of [['launcher.ts', launcher], ['prepare.ts', preparer]] as const) {
      for (const word of [/FETCH_HEAD/, /--remote/, /--branch/, /\btar\b/, /\bseed\b/, /versionOf/, /\bmain\(/]) assert.doesNotMatch(text, word, `${name}: ${word}`);
    }
  });
});

describe('#272: bin/harness pins the Node the owner names, and says so when it is gone', () => {
  const hookStdin = (prompt: string) => JSON.stringify({ session_id: 's-272', transcript_path: '/tmp/t.jsonl', hook_event_name: 'UserPromptSubmit', prompt });
  const linkTo = (w: World, name: string) => {
    const l = join(w.root, name, 'bin', 'node');
    mkdirSync(dirname(l), { recursive: true });
    symlinkSync(NODE, l);
    return l;
  };

  it('T-1 (D-1, AC-1 regression anchor): no bin/harness and no --node → refused before the owner is asked, nothing written', async () => {
    const w = world();
    const a = prep(w);
    seed(w, a.sha);
    let asked = false;
    await assert.rejects(activateAs(w, a.sha, APPROVAL, { node: undefined }, async () => (asked = true)), /--node <absolute path of the Node to pin into bin\/harness> is required/);
    assert.equal(asked, false);
    const r = ownerActivates(w, a.sha, { via: 'bootstrap', node: null });
    assert.equal(r.status, 2, r.out);
    assert.match(r.out, /--node/);
    assert.doesNotMatch(r.out, /Type "/);
    assert.deepEqual(readdirSync(join(w.install, 'bin')), ['harness.mts']);
    for (const f of ['ACTIVE', 'history.jsonl', 'activate.lock']) assert.equal(existsSync(join(w.install, f)), false, f);
  });

  it('T-2 (D-1, D-2, AC-1): --node a stable link → bin/harness names the link itself, not the versioned file behind it, and runs', async () => {
    const w = world();
    const a = prep(w);
    seed(w, a.sha);
    const l = linkTo(w, 'opt');
    assert.notEqual(l, NODE);
    const r = ownerActivates(w, a.sha, { via: 'bootstrap', node: l });
    assert.equal(r.status, 0, r.out);
    assert.match(r.out, new RegExp(`bin/harness write: node ${l.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} `));
    const text = readFileSync(join(w.install, 'bin/harness'), 'utf8');
    assert.equal(text, wrapperText(l));
    assert.ok(text.includes(`node='${l}'\n`));
    assert.equal(text.includes(NODE), false, 'the resolved target must not be written');
    const v = launch(w, ['install-verify']);
    assert.equal(v.status, 0, v.stderr);
    assert.equal((JSON.parse(v.stdout) as { sha: string }).sha, a.sha);
    // The same through activate(): the plan carries the literal.
    const w2 = world();
    const a2 = prep(w2);
    seed(w2, a2.sha);
    const l2 = linkTo(w2, 'opt');
    const plan = await activateAs(w2, a2.sha, APPROVAL, { node: l2 });
    assert.deepEqual(plan.wrapper, { action: 'write', node: l2, sha256: sha256(wrapperText(l2)) });
  });

  it('T-3 (D-2): a relative, quoted, missing, dangling, directory or non-executable --node is refused before the owner is asked', async () => {
    const w = world();
    const a = prep(w);
    seed(w, a.sha);
    const dir = join(w.root, 'nodes');
    mkdirSync(dir);
    const plain = join(dir, 'plain');
    writeFileSync(plain, '#!/bin/sh\n', { mode: 0o644 });
    const dangling = join(dir, 'dangling');
    symlinkSync(join(dir, 'gone'), dangling);
    for (const [node, why] of [
      ['node', /absolute path/],
      [`${dir}/it's`, /absolute path/],
      [join(dir, 'missing'), /ENOENT/],
      [dangling, /ENOENT/],
      [dir, /is a directory/],
      [plain, /not executable/],
    ] as const) {
      let asked = false;
      await assert.rejects(activateAs(w, a.sha, APPROVAL, { node }, async () => (asked = true)), why, node);
      assert.equal(asked, false, node);
    }
    assert.deepEqual(readdirSync(join(w.install, 'bin')), ['harness.mts']);
    assert.equal(existsSync(join(w.install, 'ACTIVE')), false);
  });

  it('T-5 (D-4, AC-3): Node gone → prompt-hook prints one fixed warning (same key path as a TS note) and exits 0; any other command exits 2 on stderr', async () => {
    const w = world();
    await installed(w);
    const env = { ...process.env, HOME: w.root, HARNESS_STATE_DIR: w.state, JEV_MODE: 'disabled' };
    // A note from the TS hook on the working install: the key path to match.
    const ts = spawnSync(join(w.install, 'bin/harness'), ['prompt-hook'], { cwd: w.work, env, input: hookStdin('#jev\nĐổi tên biến PORT?'), encoding: 'utf8' });
    assert.equal(ts.status, 0, ts.stderr);
    const tsNote = JSON.parse(ts.stdout) as { hookSpecificOutput: Record<string, unknown> };
    // The post-#272 wrapper whose Node has since disappeared.
    const gone = join(w.root, 'gone', 'bin', 'node');
    chmodSync(join(w.install, 'bin'), 0o755);
    rmSync(join(w.install, 'bin/harness'), { force: true });
    writeFileSync(join(w.install, 'bin/harness'), wrapperText(gone), { mode: 0o555 });
    const r = spawnSync(join(w.install, 'bin/harness'), ['prompt-hook'], { cwd: w.work, env, input: hookStdin('#jev\nĐổi tên biến PORT?'), encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout, `${NODE_MISSING_NOTE}\n`);
    assert.equal(r.stdout.trim().split('\n').length, 1);
    const note = JSON.parse(r.stdout) as { hookSpecificOutput: { hookEventName: string; additionalContext: string } };
    assert.deepEqual(Object.keys(note).sort(), Object.keys(tsNote).sort());
    assert.deepEqual(Object.keys(note.hookSpecificOutput).sort(), Object.keys(tsNote.hookSpecificOutput).sort());
    assert.equal(note.hookSpecificOutput.hookEventName, 'UserPromptSubmit');
    const text = note.hookSpecificOutput.additionalContext;
    for (const part of ['CẢNH BÁO', 'harness_node_missing', 'hỏi owner xác nhận', '--node']) assert.ok(text.includes(part), part);
    assert.ok(text.length <= 900, `${text.length} chars`);
    assert.match(r.stderr, /harness_node_missing/);
    assert.ok(r.stderr.includes(gone));
    for (const args of [['decide', '--input', w.task], ['install-verify'], []]) {
      const d = spawnSync(join(w.install, 'bin/harness'), args, { cwd: w.work, env, encoding: 'utf8' });
      assert.deepEqual([d.status, d.stdout], [2, ''], args.join(' '));
      assert.ok(d.stderr.includes(gone), args.join(' '));
    }
  });
});
