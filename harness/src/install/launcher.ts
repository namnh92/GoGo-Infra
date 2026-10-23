/**
 * Installed-harness launcher (ADR-0013 D-3, GoGo-Infra#245).
 *
 * Hooks and automation run the harness from an approved install outside
 * every checkout, never from `harness/` in a worktree the session can edit:
 *
 *   ~/.gogo-harness/install/
 *     versions/<full-sha>/MANIFEST        sha256 of every payload file
 *     versions/<full-sha>/harness/...     `git archive <sha> harness`, read-only
 *     ACTIVE                              { sha, manifestDigest } — the running version
 *     history.jsonl                       one line per activation or rollback
 *     bin/harness.mts                     bootstrap: a copy of this file from the first activation
 *
 *   node ~/.gogo-harness/install/bin/harness.mts decide --input task.json
 *   node ~/.gogo-harness/install/bin/harness.mts install-verify
 *   node ~/.gogo-harness/install/bin/harness.mts activate <full-sha> --approval <ref>   # owner, on a terminal
 *
 * Node's standard library only, and nothing from the payload is imported
 * before ACTIVE is read once, the MANIFEST digest matches it and every file
 * matches the MANIFEST (no missing, extra or linked file). A mismatch exits 2;
 * there is no fallback to a checkout and no development bypass here.
 * `prepare.ts` publishes candidates; only `activate` changes what runs.
 *
 * ACTIVE is the one switch (PR #253 review P2): the bootstrap in bin/ is
 * written once, at the first activation, and never replaced; it verifies the
 * version ACTIVE names and hands over to *that version's* launcher (`main`,
 * below — keep its signature), which then loads that version's CLI. Launcher
 * and runtime therefore always come from the same version, and an activation
 * that fails at any step before ACTIVE is renamed leaves the previous pair.
 *
 * An install inside a git checkout is refused wherever it is touched —
 * prepare, activation and every run — after resolving symlinks (PR #253
 * review P1): a checkout is where a session may write. Below the root, no
 * component on the way to a version may be a link (review r2).
 *
 * Threat model (shape review on #245): this stops edits in a checkout from
 * taking effect and the harness from approving its own change. It does not
 * stop the same OS user from rewriting payload and metadata together, or a
 * file between verification and import — that boundary is Claude Code's
 * sandbox and permissions on writes outside the workspace (ADR-0013 D-1).
 */
import { createHash } from 'node:crypto';
import { appendFileSync, chmodSync, closeSync, copyFileSync, existsSync, lstatSync, mkdirSync, openSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { hostname, userInfo } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

export const MANIFEST = 'MANIFEST';
const FULL_SHA = /^[0-9a-f]{40}$/;

/** The install cannot be trusted as it stands; the launcher exits 2. */
export class IntegrityError extends Error {}
/** The request itself is wrong (missing approval, not confirmed…); nothing changed. */
export class UsageError extends Error {}

export type Version = { sha: string; manifestDigest: string };
export type ActivationPlan = {
  action: 'activate' | 'rollback';
  from: Version | null;
  to: Version;
  approval: string;
  actor: string;
};

export function sha256(data: Buffer | string): string {
  return createHash('sha256').update(data).digest('hex');
}

/** Every regular file under `dir`, `/`-separated and sorted. A link or any other kind of entry is refused. */
export function listPayload(dir: string, skip?: string): string[] {
  const files: string[] = [];
  const walk = (rel: string) => {
    for (const name of readdirSync(rel ? join(dir, rel) : dir)) {
      const path = rel ? `${rel}/${name}` : name;
      if (path === skip) continue;
      const st = lstatSync(join(dir, path));
      if (st.isSymbolicLink()) throw new IntegrityError(`${path} is a symbolic link`);
      if (st.isDirectory()) walk(path);
      else if (st.isFile()) files.push(path);
      else throw new IntegrityError(`${path} is not a regular file`);
    }
  };
  walk('');
  return files.sort();
}

/** MANIFEST text for a version directory: the commit and the sha256 of every file under it. */
export function buildManifest(dir: string, sha: string): string {
  const files: Record<string, string> = {};
  for (const path of listPayload(dir, MANIFEST)) files[path] = sha256(readFileSync(join(dir, path)));
  return `${JSON.stringify({ schema: 1, sha, files }, null, 2)}\n`;
}

/**
 * Check a version directory against its MANIFEST and, when given, the digest
 * ACTIVE recorded for it. Returns the digest of the MANIFEST as read.
 */
export function verifyDir(dir: string, sha: string, expectedDigest?: string): { dir: string; digest: string } {
  if (!FULL_SHA.test(sha)) throw new IntegrityError(`${sha} is not a full commit SHA`);
  const top = lstatOrNull(dir);
  if (!top?.isDirectory()) throw new IntegrityError(`version ${sha} is not installed (${dir})`);
  const manifestPath = join(dir, MANIFEST);
  if (!lstatOrNull(manifestPath)?.isFile()) throw new IntegrityError(`version ${sha} has no ${MANIFEST}`);
  const text = readFileSync(manifestPath);
  const digest = sha256(text);
  if (expectedDigest !== undefined && digest !== expectedDigest) {
    throw new IntegrityError(`${MANIFEST} of ${sha} has digest ${digest}, ACTIVE expects ${expectedDigest}`);
  }
  let manifest: { schema?: unknown; sha?: unknown; files?: unknown };
  try {
    manifest = JSON.parse(text.toString('utf8')) as typeof manifest;
  } catch {
    throw new IntegrityError(`${MANIFEST} of ${sha} is not JSON`);
  }
  if (manifest.schema !== 1 || manifest.sha !== sha || typeof manifest.files !== 'object' || manifest.files === null) {
    throw new IntegrityError(`${MANIFEST} of ${sha} does not describe ${sha}`);
  }
  const expected = manifest.files as Record<string, unknown>;
  const present = listPayload(dir, MANIFEST);
  const missing = Object.keys(expected).filter((p) => !present.includes(p));
  const extra = present.filter((p) => !(p in expected));
  if (missing.length || extra.length) {
    throw new IntegrityError(`version ${sha} does not match its ${MANIFEST}: ${[...missing.map((p) => `missing ${p}`), ...extra.map((p) => `extra ${p}`)].join(', ')}`);
  }
  for (const path of present) {
    if (sha256(readFileSync(join(dir, path))) !== expected[path]) throw new IntegrityError(`${path} of ${sha} does not match its ${MANIFEST}`);
  }
  return { dir, digest };
}

export function verifyVersion(installDir: string, sha: string, expectedDigest?: string): { dir: string; digest: string } {
  if (!FULL_SHA.test(sha)) throw new IntegrityError(`${sha} is not a full commit SHA`);
  assertOwnPath(installDir, `versions/${sha}`);
  return verifyDir(join(installDir, 'versions', sha), sha, expectedDigest);
}

/**
 * Every component from the install root down to `rel` is the install's own:
 * not a symbolic link, and its real path outside every checkout (PR #253
 * review r2) — a linked `versions/` would run a payload a session can edit
 * while the install root itself looks fine.
 */
export function assertOwnPath(installDir: string, rel: string): void {
  let current = installDir;
  for (const part of rel.split('/')) {
    current = join(current, part);
    if (lstatOrNull(current)?.isSymbolicLink()) throw new IntegrityError(`${current} is a symbolic link; an install holds its own versions`);
  }
  assertOutsideCheckout(current);
}

export function readActive(installDir: string): Version {
  const file = join(installDir, 'ACTIVE');
  let parsed: { schema?: unknown; sha?: unknown; manifestDigest?: unknown };
  try {
    parsed = JSON.parse(readFileSync(file, 'utf8')) as typeof parsed;
  } catch {
    throw new IntegrityError(`no readable ACTIVE in ${installDir}; the owner activates a version first`);
  }
  if (parsed.schema !== 1 || typeof parsed.sha !== 'string' || typeof parsed.manifestDigest !== 'string') throw new IntegrityError(`ACTIVE in ${installDir} is malformed`);
  return { sha: parsed.sha, manifestDigest: parsed.manifestDigest };
}

/**
 * The git checkout (a `.git` directory, or the `.git` file of a worktree)
 * that holds `path`, judged on the real path of its nearest existing ancestor.
 */
export function checkoutAbove(path: string): string | null {
  let existing = path;
  while (!existsSync(existing) && dirname(existing) !== existing) existing = dirname(existing);
  let dir: string;
  try {
    dir = realpathSync(existing);
  } catch {
    return null;
  }
  for (; ; dir = dirname(dir)) {
    if (existsSync(join(dir, '.git'))) return dir;
    if (dirname(dir) === dir) return null;
  }
}

export function assertOutsideCheckout(installDir: string): void {
  const checkout = checkoutAbove(installDir);
  if (checkout) throw new IntegrityError(`install directory ${installDir} is inside the git checkout ${checkout}; installs live outside every checkout (HARNESS_INSTALL_DIR)`);
}

/**
 * Make `sha` the running version. The owner's confirmation sees the full SHA
 * and MANIFEST digest, old → new, and the approval reference; nothing changes
 * unless it returns true. One activation at a time (`activate.lock`). The
 * bootstrap is written only when there is none; the history line comes
 * next and ACTIVE is replaced last, by rename — the only step that changes
 * what runs. An interrupted or failed run leaves the previous version
 * running, launcher included, and a history line whose `to` is not ACTIVE
 * says an activation did not finish.
 */
export async function activate(
  o: { installDir: string; sha: string; approval: string; actor?: string; now?: () => Date },
  confirm: (plan: ActivationPlan) => Promise<boolean>,
): Promise<ActivationPlan> {
  const approval = o.approval.trim();
  if (!approval) throw new UsageError('--approval <reference to the owner approval> is required');
  assertOutsideCheckout(o.installDir);
  mkdirSync(o.installDir, { recursive: true });
  const lock = join(o.installDir, 'activate.lock');
  let fd: number;
  try {
    fd = openSync(lock, 'wx');
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === 'EEXIST') {
      throw new UsageError(`${lock} exists: another activation is running or one was interrupted; check ACTIVE against history.jsonl, then remove the lock`);
    }
    throw e;
  }
  try {
    writeFileSync(fd, `${process.pid}\n`);
    const { dir, digest } = verifyVersion(o.installDir, o.sha);
    const from = existsSync(join(o.installDir, 'ACTIVE')) ? readActive(o.installDir) : null;
    const before = readHistory(o.installDir).map((h) => h.to.sha);
    const plan: ActivationPlan = {
      action: before.includes(o.sha) && from?.sha !== o.sha ? 'rollback' : 'activate',
      from,
      to: { sha: o.sha, manifestDigest: digest },
      approval,
      actor: o.actor ?? `${userInfo().username}@${hostname()}`,
    };
    if (!(await confirm(plan))) throw new UsageError('activation not confirmed; nothing changed');

    const bin = join(o.installDir, 'bin');
    const launcher = join(bin, 'harness.mts');
    if (!existsSync(launcher)) {
      mkdirSync(bin, { recursive: true });
      const launcherTmp = join(bin, `.harness.mts.${process.pid}`);
      copyFileSync(join(dir, 'harness/src/install/launcher.ts'), launcherTmp);
      chmodSync(launcherTmp, 0o555);
      renameSync(launcherTmp, launcher);
    }

    appendFileSync(join(o.installDir, 'history.jsonl'), `${JSON.stringify({ at: (o.now?.() ?? new Date()).toISOString(), ...plan })}\n`);

    const activeTmp = join(o.installDir, `.ACTIVE.${process.pid}`);
    writeFileSync(activeTmp, `${JSON.stringify({ schema: 1, ...plan.to }, null, 2)}\n`);
    renameSync(activeTmp, join(o.installDir, 'ACTIVE'));
    return plan;
  } finally {
    closeSync(fd);
    rmSync(lock, { force: true });
  }
}

function readHistory(installDir: string): ActivationPlan[] {
  const file = join(installDir, 'history.jsonl');
  if (!existsSync(file)) return [];
  return readFileSync(file, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line) as ActivationPlan);
}

/**
 * The install this launcher belongs to: `<install>/bin/harness.mts`, or the
 * copy inside a prepared version (the first activation runs that one). A
 * launcher anywhere else — a checkout — is refused, not run.
 */
export function installRootOf(file: string): string | null {
  const real = realpathSync(file);
  if (basename(real) === 'harness.mts' && basename(dirname(real)) === 'bin') return dirname(dirname(real));
  const parts = real.split('/');
  const n = parts.length;
  if (n >= 7 && parts.slice(n - 4).join('/') === 'harness/src/install/launcher.ts' && FULL_SHA.test(parts[n - 5]!) && parts[n - 6] === 'versions') {
    return parts.slice(0, n - 6).join('/');
  }
  return null;
}

/** The version a launcher file belongs to when it runs from `versions/<sha>/…`, else null. */
function versionOf(file: string): string | null {
  const parts = realpathSync(file).split('/');
  const n = parts.length;
  return n >= 7 && parts.slice(n - 4).join('/') === 'harness/src/install/launcher.ts' && parts[n - 6] === 'versions' && FULL_SHA.test(parts[n - 5]!) ? parts[n - 5]! : null;
}

/** Verify the given ACTIVE snapshot (or read it once), then load that version's CLI. */
export async function run(installDir: string, argv: string[], snapshot?: Version): Promise<number> {
  const active = snapshot ?? readActive(installDir);
  const { dir } = verifyVersion(installDir, active.sha, active.manifestDigest);
  const cli = (await import(pathToFileURL(join(dir, 'harness/src/cli.ts')).href)) as { run(argv: string[]): Promise<number> };
  return cli.run(argv);
}

async function askOnTerminal(plan: ActivationPlan): Promise<boolean> {
  const from = plan.from ? `${plan.from.sha} (MANIFEST ${plan.from.manifestDigest})` : 'none';
  process.stderr.write(
    `${plan.action} harness install\n  from      ${from}\n  to        ${plan.to.sha} (MANIFEST ${plan.to.manifestDigest})\n  approval  ${plan.approval}\n  actor     ${plan.actor}\n`,
  );
  const expected = `${plan.from ? plan.from.sha.slice(0, 12) : 'none'} ${plan.to.sha.slice(0, 12)} ${plan.to.manifestDigest.slice(0, 12)}`;
  const rl = createInterface({ input: process.stdin, output: process.stderr });
  try {
    return (await rl.question(`Type "${expected}" (old sha, new sha, new MANIFEST digest) to confirm: `)).trim() === expected;
  } finally {
    rl.close();
  }
}

/**
 * Process entry. As the bin/ bootstrap: verify the version ACTIVE names and
 * hand over to that version's own launcher. Run directly from
 * `versions/<sha>/…` (first activation, or recovery when ACTIVE is broken):
 * only `activate` and `install-verify`, with this version's code.
 */
async function entry(argv: string[]): Promise<number> {
  const self = fileURLToPath(import.meta.url);
  const installDir = installRootOf(self);
  if (!installDir) throw new IntegrityError(`${self} is not an installed launcher; run ~/.gogo-harness/install/bin/harness.mts (docs/ai-harness.md, "Installed copy")`);
  assertOutsideCheckout(installDir);
  if (versionOf(self)) {
    if (argv[0] !== 'activate' && argv[0] !== 'install-verify') throw new UsageError('a prepared version\'s launcher only activates; run ~/.gogo-harness/install/bin/harness.mts');
    return main(argv, { installDir });
  }
  const active = readActive(installDir);
  const { dir } = verifyVersion(installDir, active.sha, active.manifestDigest);
  const own = (await import(pathToFileURL(join(dir, 'harness/src/install/launcher.ts')).href)) as { main(argv: string[], ctx: { installDir: string; active?: Version }): Promise<number> };
  return own.main(argv, { installDir, active });
}

/**
 * A version's launcher commands. Called by the bootstrap of any version, so
 * this signature is the bootstrap's contract: keep it.
 */
export async function main(argv: string[], ctx: { installDir: string; active?: Version }): Promise<number> {
  const { installDir } = ctx;
  assertOutsideCheckout(installDir);
  const [command, ...rest] = argv;
  if (command === 'activate') {
    const { values, positionals } = parseArgs({ args: rest, options: { approval: { type: 'string' } }, allowPositionals: true });
    if (positionals.length !== 1) throw new UsageError('activate <full-sha> --approval <ref>');
    if (!process.stdin.isTTY) throw new UsageError('activate asks the owner on a terminal; stdin is not one');
    const plan = await activate({ installDir, sha: positionals[0]!, approval: values.approval ?? '' }, askOnTerminal);
    process.stdout.write(`${JSON.stringify(plan, null, 2)}\n`);
    return 0;
  }
  if (command === 'install-verify') {
    const active = ctx.active ?? readActive(installDir);
    verifyVersion(installDir, active.sha, active.manifestDigest);
    process.stdout.write(`${JSON.stringify(active)}\n`);
    return 0;
  }
  return run(installDir, argv, ctx.active);
}

function lstatOrNull(path: string) {
  try {
    return lstatSync(path);
  } catch {
    return null;
  }
}

if (process.argv[1] !== undefined && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  entry(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (e: unknown) => {
      process.stderr.write(`harness install: ${(e as Error).message}\n`);
      process.exit(2);
    },
  );
}
