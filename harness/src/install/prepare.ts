/**
 * Propose a commit as a candidate install version (GoGo-Infra#245).
 *
 *   node harness/src/install/prepare.ts <rev> [--repo DIR] [--install-dir DIR] [--skip-tests]
 *
 * Reads the commit's Git objects in `--repo` (default: the working
 * directory) — never the working tree, never the network — with the same
 * sanitized git as activation: the closure (`harness/` and the JEV send
 * scripts, D6) is written file by file into a staging directory, gets its
 * MANIFEST, has its test suite run against a copy of it, and only then is made
 * read-only and renamed into `versions/<sha>`.
 *
 * Preparing proves nothing and changes nothing that runs: whether the commit
 * is merged, and whether these bytes are its bytes, is established by the
 * owner's activation against the pinned repository (`launcher.ts`), which
 * this script deliberately does not call.
 */
import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { CLOSURE, Install, MANIFEST, buildManifest, catBlobs, git, isEntryPoint, lsTree, payloadEntries, verifyDir, verifyVersion, withTempDir } from './launcher.ts';
import type { TreeEntry } from './launcher.ts';

export type Prepared = { sha: string; manifestDigest: string; dir: string; existed: boolean };

const USAGE = 'prepare.ts <rev> [--repo DIR] [--install-dir DIR] [--skip-tests]';

export function defaultInstallDir(env: NodeJS.ProcessEnv = process.env): string {
  return env.HARNESS_INSTALL_DIR ?? join(homedir(), '.gogo-harness', 'install');
}

export function prepare(o: { repo: string; rev: string; installDir: string; runTests?: boolean }): Prepared {
  const install = Install.init(o.installDir);
  return withTempDir('harness-prepare-git-', (home) => {
    const run = (args: string[], input?: Buffer): Buffer => {
      const r = git(['-C', o.repo, ...args], { home, input });
      if (r.status !== 0) throw new Error(`git ${args[0]} in ${o.repo} failed: ${r.stderr}`);
      return r.stdout;
    };
    let sha: string;
    try {
      sha = run(['rev-parse', '--verify', '--end-of-options', `${o.rev}^{commit}`]).toString().trim();
    } catch (e) {
      throw new Error(`${o.rev} is not a commit: ${(e as Error).message}`);
    }
    const rel = `versions/${sha}`;
    if (install.stat(rel)) return { sha, manifestDigest: verifyVersion(install, sha).digest, dir: install.path(rel), existed: true };

    const entries = payloadEntries(lsTree(run, sha, CLOSURE), sha);
    const blobs = catBlobs(run, entries.map((e) => e.oid));
    install.mkdirBelow('staging');
    const staging = `staging/${sha}.${process.pid}`;
    if (install.stat(staging)) {
      install.setModeTree(staging, true);
      install.removeTree(staging);
    }
    install.mkdirBelow(staging);
    try {
      for (const e of entries) {
        let dir = staging;
        for (const part of dirname(e.path).split('/')) install.mkdirBelow((dir = `${dir}/${part}`));
        install.writeNew(`${staging}/${e.path}`, blobs.get(e.oid)!, e.mode === '100755' ? 0o755 : 0o644);
      }
      install.writeNew(`${staging}/${MANIFEST}`, buildManifest(install, staging, sha), 0o644);
      const { digest } = verifyDir(install, staging, sha);
      if (o.runTests ?? true) runSuite(run, sha, entries, (path) => install.read(`${staging}/${path}`));
      verifyDir(install, staging, sha, digest);
      // A directory moves to a new parent only while it is writable; the top goes read-only after.
      install.setModeTree(staging, false, false);
      install.mkdirBelow('versions');
      install.moveDir(staging, rel);
      install.setModeTree(rel, false);
      return { sha, manifestDigest: digest, dir: install.path(rel), existed: false };
    } catch (e) {
      if (install.stat(staging)) {
        install.setModeTree(staging, true);
        install.removeTree(staging);
      }
      throw e;
    }
  });
}

/**
 * The candidate's own tests, run on a throwaway copy of the whole commit (some
 * tests read the docs beside harness/) whose closure files are the staged
 * bytes, so what is tested is what gets installed and nothing the tests write
 * reaches it. This throwaway tree is the one place prepare writes outside the
 * install, and so the one place it uses the file system directly.
 */
function runSuite(run: (args: string[], input?: Buffer) => Buffer, sha: string, closure: TreeEntry[], staged: (path: string) => Buffer): void {
  const tree = fs.mkdtempSync(join(tmpdir(), 'harness-prepare-'));
  try {
    const inClosure = new Set(closure.map((e) => e.path));
    const all = lsTree(run, sha, []).filter((e) => !inClosure.has(e.path) && e.mode !== '160000');
    const blobs = catBlobs(run, all.map((e) => e.oid));
    const place = (path: string, write: (abs: string) => void) => {
      fs.mkdirSync(dirname(join(tree, path)), { recursive: true });
      write(join(tree, path));
    };
    for (const e of all) {
      place(e.path, (abs) => (e.mode === '120000' ? fs.symlinkSync(blobs.get(e.oid)!.toString('utf8'), abs) : fs.writeFileSync(abs, blobs.get(e.oid)!, { mode: e.mode === '100755' ? 0o755 : 0o644 })));
    }
    for (const e of closure) place(e.path, (abs) => fs.writeFileSync(abs, staged(e.path), { mode: e.mode === '100755' ? 0o755 : 0o644 }));
    // NODE_TEST_CONTEXT (set when prepare itself runs under `node --test`) turns the
    // child into a reporter for that parent, which exits 0 whatever its tests did.
    // Keys and live flags stay out: a candidate's tests never reach paid inference.
    const { NODE_TEST_CONTEXT: _parent, OPENROUTER_API_KEY: _or, ANTHROPIC_API_KEY: _an, JEV_LIVE_AUTHORIZED: _live, ...env } = process.env;
    const r = spawnSync(process.execPath, ['--test', 'test/*.test.ts'], { cwd: join(tree, 'harness'), encoding: 'utf8', env: { ...env, JEV_MODE: 'disabled' } });
    if (r.status !== 0) throw new Error(`the test suite of ${sha} failed:\n${r.stdout.slice(-4000)}${r.stderr.slice(-2000)}`);
  } finally {
    fs.rmSync(tree, { recursive: true, force: true });
  }
}

if (isEntryPoint(import.meta.url)) {
  try {
    let parsed;
    try {
      parsed = parseArgs({ allowPositionals: true, options: { repo: { type: 'string' }, 'install-dir': { type: 'string' }, 'skip-tests': { type: 'boolean' } } });
    } catch (e) {
      throw new Error(`${(e as Error).message}\nusage: ${USAGE}`);
    }
    const { values, positionals } = parsed;
    if (positionals.length !== 1) throw new Error(`usage: ${USAGE}`);
    const installDir = resolve(values['install-dir'] ?? defaultInstallDir());
    const p = prepare({ repo: values.repo ?? process.cwd(), rev: positionals[0]!, installDir, runTests: !values['skip-tests'] });
    const install = Install.open(installDir);
    const next = install.stat('bin/harness')
      ? `${install.path('bin/harness')} activate ${p.sha} --approval <link to the owner approval>`
      : `first install: the owner runs the block in docs/ai-harness.md, "Installed copy", with sha=${p.sha}`;
    process.stdout.write(`${JSON.stringify({ ...p, activate: next }, null, 2)}\n`);
  } catch (e) {
    process.stderr.write(`harness prepare: ${(e as Error).message}\n`);
    process.exit(2);
  }
}
