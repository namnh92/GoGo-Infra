/**
 * Publish a merged commit as a candidate install version (GoGo-Infra#245).
 *
 *   node harness/src/install/prepare.ts <rev> [--install-dir DIR] [--remote origin] [--branch develop] [--skip-tests]
 *
 * Fetches the branch first and refuses when the fetch fails or the commit is
 * not an ancestor of what was fetched — a stale remote-tracking ref says
 * nothing about what is merged now. The payload comes from the commit's Git
 * objects (`git archive`), never the working tree, lands in a staging
 * directory, gets its MANIFEST, has its test suite run against a copy of it,
 * and only then is made read-only and renamed into `versions/<sha>`.
 *
 * Preparing never changes what runs. The owner activates with the installed
 * launcher (`launcher.ts`), which this script deliberately does not call.
 */
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { MANIFEST, assertOutsideCheckout, assertOwnPath, buildManifest, verifyDir, verifyVersion } from './launcher.ts';

export type Prepared = { sha: string; manifestDigest: string; dir: string; existed: boolean };

export function defaultInstallDir(env: NodeJS.ProcessEnv = process.env): string {
  return env.HARNESS_INSTALL_DIR ?? join(homedir(), '.gogo-harness', 'install');
}

export function prepare(o: { repo: string; rev: string; installDir: string; remote?: string; branch?: string; runTests?: boolean }): Prepared {
  // PR #253 review P1: never publish into a directory a session may write.
  assertOutsideCheckout(o.installDir);
  const remote = o.remote ?? 'origin';
  const branch = o.branch ?? 'develop';
  const git = (...args: string[]) => execFileSync('git', ['-C', o.repo, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();

  let tip: string;
  try {
    git('fetch', '--quiet', remote, `refs/heads/${branch}`);
    tip = git('rev-parse', '--verify', 'FETCH_HEAD^{commit}');
  } catch (e) {
    throw new Error(`fetch ${remote} ${branch} failed, so whether ${o.rev} is merged is unknown: ${stderrOf(e)}`);
  }
  let sha: string;
  try {
    sha = git('rev-parse', '--verify', `${o.rev}^{commit}`);
  } catch (e) {
    throw new Error(`${o.rev} is not a commit: ${stderrOf(e)}`);
  }
  const ancestor = spawnSync('git', ['-C', o.repo, 'merge-base', '--is-ancestor', sha, tip]);
  if (ancestor.status !== 0) throw new Error(`${sha} is not an ancestor of ${remote}/${branch} (${tip}); only merged code is installed`);

  const dir = join(o.installDir, 'versions', sha);
  if (existsSync(dir)) return { sha, manifestDigest: verifyVersion(o.installDir, sha).digest, dir, existed: true };
  // PR #253 review r2: never stage or publish through a link out of the install.
  assertOwnPath(o.installDir, 'versions');
  assertOwnPath(o.installDir, 'staging');

  const staging = join(o.installDir, 'staging', `${sha}.${process.pid}`);
  rmSync(staging, { recursive: true, force: true });
  mkdirSync(staging, { recursive: true });
  try {
    const tar = execFileSync('git', ['-C', o.repo, 'archive', '--format=tar', sha, 'harness'], { maxBuffer: 256 * 1024 * 1024 });
    const x = spawnSync('tar', ['-x', '-C', staging], { input: tar });
    if (x.status !== 0) throw new Error(`extracting ${sha} failed: ${x.stderr.toString()}`);
    writeFileSync(join(staging, MANIFEST), buildManifest(staging, sha));
    const { digest } = verifyDir(staging, sha);
    if (o.runTests ?? true) runSuite(o.repo, sha, staging);
    verifyDir(staging, sha, digest);
    readOnly(staging);
    mkdirSync(join(o.installDir, 'versions'), { recursive: true });
    // A directory moves to a new parent only while it is writable; the top goes read-only after.
    renameSync(staging, dir);
    chmodSync(dir, 0o555);
    return { sha, manifestDigest: digest, dir, existed: false };
  } catch (e) {
    if (existsSync(staging)) ownerWritable(staging);
    rmSync(staging, { recursive: true, force: true });
    throw e;
  }
}

/** Give the owner write back so a half-published staging directory can be removed. */
function ownerWritable(path: string): void {
  if (lstatSync(path).isDirectory()) {
    chmodSync(path, 0o755);
    for (const name of readdirSync(path)) ownerWritable(join(path, name));
  }
}

/**
 * The candidate's own tests, run on a throwaway copy of the whole commit (some
 * tests read the docs beside harness/) whose harness/ is the staged bytes, so
 * what is tested is what gets installed and nothing the tests write reaches it.
 */
function runSuite(repo: string, sha: string, staging: string): void {
  const tree = mkdtempSync(join(tmpdir(), 'harness-prepare-'));
  try {
    const tar = execFileSync('git', ['-C', repo, 'archive', '--format=tar', sha], { maxBuffer: 1024 * 1024 * 1024 });
    const x = spawnSync('tar', ['-x', '-C', tree], { input: tar });
    if (x.status !== 0) throw new Error(`extracting ${sha} for its tests failed: ${x.stderr.toString()}`);
    rmSync(join(tree, 'harness'), { recursive: true, force: true });
    cpSync(join(staging, 'harness'), join(tree, 'harness'), { recursive: true });
    // NODE_TEST_CONTEXT (set when prepare itself runs under `node --test`) turns the
    // child into a reporter for that parent, which exits 0 whatever its tests did.
    // Keys and live flags stay out: a candidate's tests never reach paid inference.
    const { NODE_TEST_CONTEXT: _parent, OPENROUTER_API_KEY: _or, ANTHROPIC_API_KEY: _an, JEV_LIVE_AUTHORIZED: _live, ...env } = process.env;
    const r = spawnSync(process.execPath, ['--test', 'test/*.test.ts'], { cwd: join(tree, 'harness'), encoding: 'utf8', env: { ...env, JEV_MODE: 'disabled' } });
    if (r.status !== 0) throw new Error(`the test suite of ${sha} failed:\n${r.stdout.slice(-4000)}${r.stderr.slice(-2000)}`);
  } finally {
    rmSync(tree, { recursive: true, force: true });
  }
}

/** Files 0444, directories 0555, deepest first; the top directory stays writable until it is renamed. */
function readOnly(top: string): void {
  const walk = (dir: string) => {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      if (lstatSync(path).isDirectory()) {
        walk(path);
        chmodSync(path, 0o555);
      } else {
        chmodSync(path, 0o444);
      }
    }
  };
  walk(top);
}

function stderrOf(e: unknown): string {
  const stderr = (e as { stderr?: Buffer | string }).stderr;
  return (stderr ? stderr.toString() : (e as Error).message).trim();
}

if (process.argv[1] !== undefined && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  try {
    const { values, positionals } = parseArgs({
      allowPositionals: true,
      options: { 'install-dir': { type: 'string' }, remote: { type: 'string' }, branch: { type: 'string' }, 'skip-tests': { type: 'boolean' } },
    });
    if (positionals.length !== 1) throw new Error('prepare.ts <rev> [--install-dir DIR] [--remote origin] [--branch develop] [--skip-tests]');
    const installDir = values['install-dir'] ?? defaultInstallDir();
    const p = prepare({ repo: process.cwd(), rev: positionals[0]!, installDir, remote: values.remote, branch: values.branch, runTests: !values['skip-tests'] });
    const first = !existsSync(join(installDir, 'ACTIVE'));
    const launcher = first ? join(p.dir, 'harness/src/install/launcher.ts') : join(installDir, 'bin/harness.mts');
    process.stdout.write(`${JSON.stringify({ ...p, activate: `node ${launcher} activate ${p.sha} --approval <link to the owner approval>` }, null, 2)}\n`);
  } catch (e) {
    process.stderr.write(`harness prepare: ${(e as Error).message}\n`);
    process.exit(2);
  }
}
