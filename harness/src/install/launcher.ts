/**
 * Installed-harness bootstrap (ADR-0013 D-3, GoGo-Infra#245).
 *
 * Hooks and automation run the harness from an approved install outside
 * every checkout, never from `harness/` in a worktree the session can edit:
 *
 *   ~/.gogo-harness/install/
 *     versions/<full-sha>/MANIFEST        sha256 + exec bit of every payload file
 *     versions/<full-sha>/harness/...     the commit's harness/, read-only
 *     versions/<full-sha>/scripts/...     the JEV send closure (D6): exec-with.sh,
 *     versions/<full-sha>/config/...        common.sh, manifest.py, secrets.manifest.yml
 *     ACTIVE                              { sha, manifestDigest } — the running version
 *     history.jsonl                       journal: intent and activated records
 *     bin/harness.mts                     this file, placed once by the owner's first install
 *     bin/harness                         launch boundary (POSIX sh), written by an activation that names --node (#272)
 *     quarantine/                         a broken ACTIVE or a damaged journal, kept as found
 *
 *   ~/.gogo-harness/install/bin/harness decide --input task.json
 *   ~/.gogo-harness/install/bin/harness install-verify
 *   ~/.gogo-harness/install/bin/harness activate <full-sha> --approval <ref> [--node <abs path>]   # owner, on a terminal
 *
 * Only `<root>/bin/harness.mts` runs; anywhere else it exits 2. It owns the
 * install's metadata: `activate` and `install-verify` are this file's code
 * whatever ACTIVE says, so a broken or tampered version never takes part in
 * replacing itself. Every other command reads ACTIVE, verifies that version
 * (MANIFEST digest, then every file) and only then imports its `cli.ts`.
 *
 * Activation proves provenance (PR #253 shape rev 3): the commit must be an
 * ancestor of `develop` fetched from the pinned repository into a private
 * temporary repository, and every installed file must equal that commit's
 * blob. `prepare.ts` proposes candidates and proves nothing. Rolling back to a
 * version this journal records as activated, with the same MANIFEST digest,
 * needs no network (owner decision D2).
 *
 * File system access goes through `Install` alone (the section marked below):
 * reads walk every component from the root — real directories owned by this
 * user with no `.git` entry, leaves regular, single-link, opened no-follow —
 * and writes are a closed list of exclusive creates, appends and renames.
 *
 * Threat model (shape review on #245): this stops edits in a checkout from
 * taking effect and the harness from approving its own change. It does not
 * stop the same OS user from rewriting payload, metadata and journal
 * together, or a directory or file between verification and import — that
 * boundary is Claude Code's sandbox and permissions on writes outside the
 * workspace (ADR-0013 D-1).
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import * as fs from 'node:fs';
import { hostname, tmpdir, userInfo } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

export const MANIFEST = 'MANIFEST';
const FULL_SHA = /^[0-9a-f]{40}$/;

/**
 * What an install holds of a commit (owner decision D6): the harness and the
 * closure its JEV send runs through. Shared by prepare, provenance and verify.
 */
export const CLOSURE_FILES = ['scripts/secrets/exec-with.sh', 'scripts/secrets/common.sh', 'scripts/lib/manifest.py', 'config/secrets.manifest.yml'] as const;
export const CLOSURE = ['harness', ...CLOSURE_FILES] as const;

export type Source = { url: string; allowLocal: boolean };
/** Where provenance comes from (owner decision D1). `allowLocal` exists for tests, which pass their own source in-process. */
export const TRUSTED_SOURCE: Source = { url: 'https://github.com/namnh92/GoGo-Infra.git', allowLocal: false };

/** The install cannot be trusted as it stands; the launcher exits 2. */
export class IntegrityError extends Error {}
/** The request itself is wrong or refused (missing approval, not confirmed, no provenance…); nothing changed. */
export class UsageError extends Error {}

export type Version = { sha: string; manifestDigest: string };
export type FileEntry = { sha256: string; exec: boolean };

export function sha256(data: Buffer | string): string {
  return createHash('sha256').update(data).digest('hex');
}

/** The id git gives these bytes as a blob. */
export function gitBlobId(data: Buffer): string {
  return createHash('sha1').update(`blob ${data.length}\0`).update(data).digest('hex');
}

// ── Install: the only code in this file that touches the file system ──────

type Stats = fs.Stats;
const uid = (): number => process.getuid?.() ?? -1;

function lstatOrNull(path: string): Stats | null {
  try {
    return fs.lstatSync(path);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === 'ENOENT') return null;
    throw e;
  }
}

function kindOf(st: Stats): string {
  if (st.isSymbolicLink()) return 'symbolic link';
  if (st.isDirectory()) return 'directory';
  if (st.isFile()) return 'regular file';
  if (st.isFIFO()) return 'fifo';
  if (st.isSocket()) return 'socket';
  return 'device';
}

/** `rel` as path components, refusing anything that could leave the install. */
function parts(rel: string): string[] {
  const p = rel.split('/');
  if (rel.startsWith('/') || p.some((x) => x === '' || x === '.' || x === '..')) throw new IntegrityError(`${rel} is not a path inside the install`);
  return p;
}

/**
 * The git checkout (a `.git` entry of any type: directory, worktree file,
 * link) at or above `path`, judged on its real path.
 */
export function checkoutAbove(path: string): string | null {
  let dir = fs.realpathSync(path);
  for (; ; dir = dirname(dir)) {
    if (lstatOrNull(join(dir, '.git'))) return dir;
    if (dirname(dir) === dir) return null;
  }
}

/** A real path, symbolic links resolved. */
export function realpath(path: string): string {
  return fs.realpathSync(path);
}

/** `fn` with a fresh private directory, removed afterwards whatever happens. */
export function withTempDir<T>(prefix: string, fn: (dir: string) => T): T {
  const dir = fs.mkdtempSync(join(tmpdir(), prefix));
  try {
    return fn(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

/** Write all of `text` to an open descriptor (the activation lock's pid). */
export function writeFd(fd: number, text: string): void {
  fs.writeSync(fd, text);
}

export function closeFd(fd: number): void {
  fs.closeSync(fd);
}

/** True when `url` is the module node was started with. */
export function isEntryPoint(url: string): boolean {
  return process.argv[1] !== undefined && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(url));
}

const TOP_DIRS = ['versions', 'bin', 'staging', 'quarantine'];

/**
 * One install root, resolved once (I-1). Reads walk from the root and never
 * join blindly (I-2); writes are the closed list below (I-2b).
 */
export class Install {
  readonly root: string;
  private constructor(root: string) {
    this.root = root;
  }

  /** An existing install: a real directory owned by this user, outside every checkout. */
  static open(root: string, o: { bootstrap?: boolean } = {}): Install {
    let real: string;
    try {
      real = fs.realpathSync(root);
    } catch {
      throw new IntegrityError(`install directory ${root} does not exist`);
    }
    const st = fs.lstatSync(real);
    if (!st.isDirectory()) throw new IntegrityError(`install directory ${real} is not a directory`);
    if (st.uid !== uid()) throw new IntegrityError(`install directory ${real} is not owned by this user`);
    const checkout = checkoutAbove(real);
    if (checkout) throw new IntegrityError(`install directory ${real} is inside the git checkout ${checkout}; installs live outside every checkout`);
    const install = new Install(real);
    for (const top of TOP_DIRS) if (lstatOrNull(join(real, top))) install.dir(top);
    if (o.bootstrap) install.leaf('bin/harness.mts');
    return install;
  }

  /** Create the root if needed, one directory at a time, each confirmed by lstat; then open it. */
  static init(root: string): Install {
    if (!root.startsWith('/')) throw new UsageError(`install directory ${root} is not an absolute path`);
    const missing: string[] = [];
    let existing = root;
    while (!lstatOrNull(existing)) {
      missing.unshift(basename(existing));
      existing = dirname(existing);
    }
    let dir = fs.realpathSync(existing);
    for (const name of missing) {
      dir = join(dir, name);
      fs.mkdirSync(dir, { mode: 0o755 });
      if (!fs.lstatSync(dir).isDirectory()) throw new IntegrityError(`${dir} is not the directory just created`);
    }
    return Install.open(dir);
  }

  /** The absolute path of `rel`, for messages and for the one import of a verified version. */
  path(rel: string): string {
    return rel ? join(this.root, ...parts(rel)) : this.root;
  }

  /** Check every directory from the root down to and including `rel`; returns its absolute path. */
  private dir(rel: string): string {
    let abs = this.root;
    if (!rel) return abs;
    let sofar = '';
    for (const part of parts(rel)) {
      abs = join(abs, part);
      sofar = sofar ? `${sofar}/${part}` : part;
      const st = lstatOrNull(abs);
      if (!st) throw new IntegrityError(`${sofar} does not exist in the install`);
      if (!st.isDirectory()) throw new IntegrityError(`${sofar} in the install is a ${kindOf(st)}, not a directory`);
      if (st.uid !== uid()) throw new IntegrityError(`${sofar} in the install is not owned by this user`);
      if (lstatOrNull(join(abs, '.git'))) throw new IntegrityError(`${sofar}/.git exists; an install holds no git checkout`);
    }
    return abs;
  }

  /** The absolute path of `rel`, its parent directories checked. */
  private below(rel: string): string {
    const p = parts(rel);
    return join(this.dir(p.slice(0, -1).join('/')), p[p.length - 1]!);
  }

  /** lstat of `rel` (never followed), or null; parents checked. */
  stat(rel: string): Stats | null {
    const p = parts(rel);
    let parent = '';
    for (const part of p.slice(0, -1)) {
      parent = parent ? `${parent}/${part}` : part;
      if (!lstatOrNull(join(this.root, parent))) return null;
    }
    return lstatOrNull(this.below(rel));
  }

  /** `rel` must be a regular file owned by this user with one link. */
  private leaf(rel: string): { abs: string; st: Stats } {
    const abs = this.below(rel);
    const st = lstatOrNull(abs);
    if (!st) throw new IntegrityError(`${rel} does not exist in the install`);
    if (!st.isFile()) throw new IntegrityError(`${rel} in the install is a ${kindOf(st)}, not a regular file`);
    if (st.uid !== uid()) throw new IntegrityError(`${rel} in the install is not owned by this user`);
    if (st.nlink !== 1) throw new IntegrityError(`${rel} in the install has ${st.nlink} hard links`);
    return { abs, st };
  }

  /** The bytes of a regular file, opened no-follow and checked to be the inode just inspected. */
  read(rel: string): Buffer {
    const { abs, st } = this.leaf(rel);
    const fd = fs.openSync(abs, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
      const opened = fs.fstatSync(fd);
      if (opened.ino !== st.ino || opened.dev !== st.dev) throw new IntegrityError(`${rel} changed while it was opened`);
      return fs.readFileSync(fd);
    } finally {
      fs.closeSync(fd);
    }
  }

  /** Where a symbolic link points, read without following it. */
  readlink(rel: string): string {
    return fs.readlinkSync(this.below(rel));
  }

  /** Entry names of a directory; a `.git` entry is refused by name. */
  list(rel: string): string[] {
    const names = fs.readdirSync(this.dir(rel)).sort();
    if (names.includes('.git')) throw new IntegrityError(`${rel}/.git exists; an install holds no git checkout`);
    return names;
  }

  mkdirBelow(rel: string, mode = 0o755): void {
    const abs = this.below(rel);
    if (!lstatOrNull(abs)) fs.mkdirSync(abs, { mode });
    this.dir(rel);
  }

  /** A new file that did not exist, never through a link. Returns its descriptor and inode. */
  createExclusive(rel: string, mode: number): { fd: number; ino: number } {
    const fd = fs.openSync(this.below(rel), fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, mode);
    return { fd, ino: fs.fstatSync(fd).ino };
  }

  /** createExclusive, write everything, fsync, close. */
  writeNew(rel: string, data: Buffer | string, mode: number): number {
    const { fd, ino } = this.createExclusive(rel, mode);
    try {
      const buf = typeof data === 'string' ? Buffer.from(data) : data;
      if (fs.writeSync(fd, buf) !== buf.length) throw new IntegrityError(`short write to ${rel}`);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    return ino;
  }

  /** One line appended in one write, to a regular single-link file that is empty or ends in a newline. */
  appendLine(rel: string, line: string): void {
    const c = fs.constants;
    const fd = fs.openSync(this.below(rel), c.O_RDWR | c.O_APPEND | c.O_CREAT | c.O_NOFOLLOW, 0o600);
    try {
      const st = fs.fstatSync(fd);
      if (!st.isFile() || st.uid !== uid() || st.nlink !== 1) throw new IntegrityError(`${rel} in the install is not a regular single-link file of this user`);
      if (st.size > 0) {
        const last = Buffer.alloc(1);
        fs.readSync(fd, last, 0, 1, st.size - 1);
        if (last[0] !== 0x0a) throw new IntegrityError(`${rel} does not end in a newline; nothing appended`);
      }
      const buf = Buffer.from(`${line}\n`);
      if (fs.writeSync(fd, buf) !== buf.length) throw new IntegrityError(`short write to ${rel}`);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
  }

  /** Replace `rel` (absent or a regular file) by a new file written beside it, by rename. */
  publish(rel: string, data: Buffer | string, mode: number): void {
    const p = parts(rel);
    const tmp = [...p.slice(0, -1), `.${p[p.length - 1]}.${process.pid}`].join('/');
    const ino = this.writeNew(tmp, data, mode);
    const target = lstatOrNull(this.below(rel));
    if (target && !target.isFile()) {
      this.unlinkOwn(tmp, ino);
      throw new IntegrityError(`${rel} in the install is a ${kindOf(target)}; not replaced`);
    }
    fs.renameSync(this.below(tmp), this.below(rel));
  }

  /** Move a regular file or a symbolic link (never opened, never followed) into quarantine/. Returns where it went. */
  quarantine(rel: string, at: Date): string {
    const st = lstatOrNull(this.below(rel));
    if (!st || !(st.isFile() || st.isSymbolicLink())) throw new IntegrityError(`${rel} is a ${st ? kindOf(st) : 'missing file'}; only a file or a link is quarantined`);
    this.mkdirBelow('quarantine', 0o700);
    let dest = `quarantine/${basename(rel)}.${at.toISOString()}`;
    for (let n = 1; lstatOrNull(this.below(dest)); n++) dest = `quarantine/${basename(rel)}.${at.toISOString()}.${n}`;
    fs.renameSync(this.below(rel), this.below(dest));
    return dest;
  }

  /** Rename a directory to a name that does not exist yet. */
  moveDir(from: string, to: string): void {
    this.dir(from);
    if (lstatOrNull(this.below(to))) throw new IntegrityError(`${to} already exists in the install`);
    fs.renameSync(this.below(from), this.below(to));
  }

  /** Unlink `rel` only if it is still the inode this process created. */
  unlinkOwn(rel: string, ino: number): boolean {
    const abs = this.below(rel);
    const st = lstatOrNull(abs);
    if (!st || st.ino !== ino) return false;
    fs.unlinkSync(abs);
    return true;
  }

  /** Remove a tree, walking it and following nothing. */
  removeTree(rel: string): void {
    const abs = this.below(rel);
    const st = lstatOrNull(abs);
    if (!st) return;
    if (!st.isDirectory()) {
      fs.unlinkSync(abs);
      return;
    }
    for (const name of fs.readdirSync(abs)) this.removeTree(`${rel}/${name}`);
    fs.rmdirSync(abs);
  }

  /**
   * Files 0444/0555 (by their exec bit) and directories 0555, or 0644/0755 and
   * 0755 when `writable`. Directories are opened before and closed after
   * their contents; nothing is followed. Only directories and leaves of this
   * user are changed, and a leaf must be a regular file with one link: a hard
   * link in a reused staging tree would otherwise change the mode of an inode
   * outside the install (#253 S4-02, the file classes of I-2b).
   */
  setModeTree(rel: string, writable: boolean, top = true): void {
    const walk = (r: string, isTop: boolean) => {
      const abs = this.below(r);
      const st = fs.lstatSync(abs);
      if (st.isSymbolicLink()) throw new IntegrityError(`${r} is a symbolic link`);
      if (st.uid !== uid()) throw new IntegrityError(`${r} in the install is not owned by this user`);
      if (!st.isDirectory()) {
        if (!st.isFile()) throw new IntegrityError(`${r} in the install is a ${kindOf(st)}, not a regular file`);
        if (st.nlink !== 1) throw new IntegrityError(`${r} in the install has ${st.nlink} hard links`);
        const exec = (st.mode & 0o100) !== 0;
        fs.chmodSync(abs, writable ? (exec ? 0o755 : 0o644) : exec ? 0o555 : 0o444);
        return;
      }
      if (writable && (top || !isTop)) fs.chmodSync(abs, 0o755);
      for (const name of fs.readdirSync(abs)) walk(`${r}/${name}`, false);
      if (!writable && (top || !isTop)) fs.chmodSync(abs, 0o555);
    };
    walk(rel, true);
  }
}

/**
 * A path outside the install (the `--node` an activation names, #272 D-2): what it resolves to
 * and whether this user may execute it. lstat first, so a dangling link reports its own error.
 * Nothing is opened or executed.
 */
export function probeExecutable(path: string): { st: Stats; executable: boolean } | { error: string } {
  try {
    fs.lstatSync(path);
    const st = fs.statSync(path);
    let executable = true;
    try {
      fs.accessSync(path, fs.constants.X_OK);
    } catch {
      executable = false;
    }
    return { st, executable };
  } catch (e) {
    return { error: (e as NodeJS.ErrnoException).code ?? (e as Error).message };
  }
}

// ── end of Install ─────────────────────────────────────────────────────────

/**
 * The one subprocess this file starts. The environment is built from scratch
 * (no GIT_*, proxy or SSL variable, no system or global config, a private
 * HOME) and only https — `file` instead when a test's source allows it — may
 * be used, without redirects or credential helpers.
 */
export function git(args: string[], o: { home: string; allowLocal?: boolean; input?: Buffer }): { status: number; stdout: Buffer; stderr: string } {
  const env = { PATH: process.env.PATH ?? '/usr/bin:/bin', HOME: o.home, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', GIT_TERMINAL_PROMPT: '0' };
  const config = ['-c', 'protocol.allow=never', '-c', `protocol.${o.allowLocal ? 'file' : 'https'}.allow=always`, '-c', 'http.followRedirects=false', '-c', 'credential.helper='];
  const r = spawnSync('git', [...config, ...args], { env, input: o.input, maxBuffer: 1024 * 1024 * 1024 });
  if (r.error) throw r.error;
  return { status: r.status ?? 128, stdout: r.stdout, stderr: r.stderr.toString().trim() };
}

export type TreeEntry = { mode: string; type: string; oid: string; path: string };

/** `git ls-tree -r --full-tree <sha> -- <paths>` through `run`, parsed. */
export function lsTree(run: (args: string[]) => Buffer, sha: string, paths: readonly string[]): TreeEntry[] {
  const out = run(['ls-tree', '-r', '-z', '--full-tree', sha, '--', ...paths]).toString('utf8');
  return out.split('\0').filter(Boolean).map((line) => {
    const tab = line.indexOf('\t');
    const [mode, type, oid] = line.slice(0, tab).split(' ') as [string, string, string];
    return { mode, type, oid, path: line.slice(tab + 1) };
  });
}

/** Blob bytes by object id, all in one `git cat-file --batch` through `run`. */
export function catBlobs(run: (args: string[], input: Buffer) => Buffer, oids: string[]): Map<string, Buffer> {
  const blobs = new Map<string, Buffer>();
  if (!oids.length) return blobs;
  const out = run(['cat-file', '--batch'], Buffer.from(`${oids.join('\n')}\n`));
  let at = 0;
  for (const oid of oids) {
    const nl = out.indexOf(0x0a, at);
    const [got, type, size] = out.subarray(at, nl).toString('utf8').split(' ');
    if (got !== oid || type !== 'blob') throw new IntegrityError(`object ${oid} is not a blob`);
    const start = nl + 1;
    const end = start + Number(size);
    blobs.set(oid, out.subarray(start, end));
    at = end + 1;
  }
  return blobs;
}

/** The closure check every tree entry passes: inside the closure, a plain or executable file. */
export function payloadEntries(entries: TreeEntry[], sha: string): TreeEntry[] {
  for (const e of entries) {
    if (e.mode === '120000') throw new IntegrityError(`${e.path} of ${sha} is a symbolic link; a payload holds files only`);
    if (e.mode === '160000') throw new IntegrityError(`${e.path} of ${sha} is a submodule; a payload holds files only`);
    if (e.mode !== '100644' && e.mode !== '100755') throw new IntegrityError(`${e.path} of ${sha} has mode ${e.mode}`);
  }
  const have = new Set(entries.map((e) => e.path));
  const absent = CLOSURE_FILES.filter((p) => !have.has(p));
  if (absent.length) throw new IntegrityError(`${sha} lacks ${absent.join(', ')}; a version ships its JEV send closure (D6)`);
  return entries;
}

function inClosure(path: string): boolean {
  return path.startsWith('harness/') || (CLOSURE_FILES as readonly string[]).includes(path);
}

/** Every regular file under `rel`, `/`-separated and sorted, with its exec bit. Links, other kinds and `.git` are refused. */
export function listPayload(install: Install, rel: string, skip?: string): Array<{ path: string; exec: boolean }> {
  const files: Array<{ path: string; exec: boolean }> = [];
  const walk = (sub: string) => {
    for (const name of install.list(sub ? `${rel}/${sub}` : rel)) {
      const path = sub ? `${sub}/${name}` : name;
      if (path === skip) continue;
      const st = install.stat(`${rel}/${path}`)!;
      if (st.isDirectory()) walk(path);
      else if (st.isFile()) files.push({ path, exec: (st.mode & 0o100) !== 0 });
      else throw new IntegrityError(`${path} is a ${kindOf(st)}, not a regular file`);
    }
  };
  walk('');
  return files.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

/** MANIFEST text (schema 2) for a version directory: the commit, and the sha256 and exec bit of every file under it. */
export function buildManifest(install: Install, rel: string, sha: string): string {
  const files: Record<string, FileEntry> = {};
  for (const { path, exec } of listPayload(install, rel, MANIFEST)) files[path] = { sha256: sha256(install.read(`${rel}/${path}`)), exec };
  return `${JSON.stringify({ schema: 2, sha, files }, null, 2)}\n`;
}

/**
 * Check a version directory against its MANIFEST and, when given, the digest
 * ACTIVE recorded for it: closure only, all four closure files, no missing or
 * extra file, every digest and exec bit. Returns the MANIFEST digest and entries.
 */
export function verifyDir(install: Install, rel: string, sha: string, expectedDigest?: string): { digest: string; files: Record<string, FileEntry> } {
  if (!FULL_SHA.test(sha)) throw new IntegrityError(`${sha} is not a full commit SHA`);
  if (!install.stat(rel)?.isDirectory()) throw new IntegrityError(`version ${sha} is not installed (${install.path(rel)})`);
  const text = install.read(`${rel}/${MANIFEST}`);
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
  if (manifest.schema !== 2 || manifest.sha !== sha || typeof manifest.files !== 'object' || manifest.files === null) {
    throw new IntegrityError(`${MANIFEST} of ${sha} does not describe ${sha} (schema 2)`);
  }
  const expected = manifest.files as Record<string, FileEntry>;
  for (const [path, e] of Object.entries(expected)) {
    if (typeof e?.sha256 !== 'string' || typeof e.exec !== 'boolean') throw new IntegrityError(`${MANIFEST} of ${sha}: ${path} has no sha256 and exec`);
    if (!inClosure(path)) throw new IntegrityError(`${MANIFEST} of ${sha} lists ${path}, outside the payload closure`);
  }
  const absent = CLOSURE_FILES.filter((p) => !(p in expected));
  if (absent.length) throw new IntegrityError(`version ${sha} lacks ${absent.join(', ')}; a version ships its JEV send closure (D6)`);
  const present = listPayload(install, rel, MANIFEST);
  const names = present.map((f) => f.path);
  const missing = Object.keys(expected).filter((p) => !names.includes(p));
  const extra = names.filter((p) => !(p in expected));
  if (missing.length || extra.length) {
    throw new IntegrityError(`version ${sha} does not match its ${MANIFEST}: ${[...missing.map((p) => `missing ${p}`), ...extra.map((p) => `extra ${p}`)].join(', ')}`);
  }
  for (const { path, exec } of present) {
    if (sha256(install.read(`${rel}/${path}`)) !== expected[path]!.sha256) throw new IntegrityError(`${path} of ${sha} does not match its ${MANIFEST}`);
    if (exec !== expected[path]!.exec) throw new IntegrityError(`${path} of ${sha} has the wrong exec bit for its ${MANIFEST}`);
  }
  return { digest, files: expected };
}

export function verifyVersion(install: Install, sha: string, expectedDigest?: string): { digest: string; files: Record<string, FileEntry> } {
  if (!FULL_SHA.test(sha)) throw new IntegrityError(`${sha} is not a full commit SHA`);
  return verifyDir(install, `versions/${sha}`, sha, expectedDigest);
}

// ── ACTIVE and the journal ─────────────────────────────────────────────────

export type ActiveState =
  | { kind: 'none' }
  | { kind: 'ok'; version: Version }
  | { kind: 'broken-file'; sha256: string; reason: string }
  | { kind: 'broken-link'; target: string };

/**
 * ACTIVE as found, never followed (I-5). A file that is not a well-formed
 * single-link record is `broken-file` (evidence: its sha256), a link is
 * `broken-link` (evidence: where it points). A directory, fifo, socket or
 * device is not something an interrupted activation leaves: refused.
 */
export function classifyActive(install: Install): ActiveState {
  const st = install.stat('ACTIVE');
  if (!st) return { kind: 'none' };
  if (st.isSymbolicLink()) return { kind: 'broken-link', target: install.readlink('ACTIVE') };
  if (!st.isFile()) throw new UsageError(`ACTIVE in ${install.root} is a ${kindOf(st)}; remove it by hand, then activate`);
  let bytes: Buffer;
  try {
    bytes = install.read('ACTIVE');
  } catch (e) {
    if (!(e instanceof IntegrityError)) throw e;
    return { kind: 'broken-file', sha256: '-', reason: e.message };
  }
  let parsed: { schema?: unknown; sha?: unknown; manifestDigest?: unknown };
  try {
    parsed = JSON.parse(bytes.toString('utf8')) as typeof parsed;
  } catch {
    return { kind: 'broken-file', sha256: sha256(bytes), reason: 'not JSON' };
  }
  if (parsed?.schema !== 1 || typeof parsed.sha !== 'string' || !FULL_SHA.test(parsed.sha) || typeof parsed.manifestDigest !== 'string') {
    return { kind: 'broken-file', sha256: sha256(bytes), reason: 'not an ACTIVE record' };
  }
  return { kind: 'ok', version: { sha: parsed.sha, manifestDigest: parsed.manifestDigest } };
}

/** ACTIVE must name a version for anything to run. */
export function readActive(install: Install): Version {
  const active = classifyActive(install);
  if (active.kind === 'ok') return active.version;
  if (active.kind === 'none') throw new IntegrityError(`no ACTIVE in ${install.root}; the owner activates a version first`);
  const evidence = active.kind === 'broken-link' ? `a symbolic link to ${active.target}` : `broken (${active.reason})`;
  throw new IntegrityError(`ACTIVE in ${install.root} is ${evidence}; the owner runs bin/harness activate`);
}

export type JournalRecord = { record: string; [k: string]: unknown };
export type Journal = { state: 'ok'; records: JournalRecord[] } | { state: 'damaged'; line: number; digest: string; parsedLines: number };

/** history.jsonl: `ok`, or `damaged` at the first line that does not parse or lacks its newline (I-5b). */
export function readJournal(install: Install): Journal {
  if (!install.stat('history.jsonl')) return { state: 'ok', records: [] };
  const bytes = install.read('history.jsonl');
  const lines = bytes.toString('utf8').split('\n');
  const complete = lines.pop() === '' ? lines : null;
  const records: JournalRecord[] = [];
  const all = complete ?? lines;
  for (const line of all) {
    let r: unknown;
    try {
      r = JSON.parse(line);
    } catch {
      return { state: 'damaged', line: records.length + 1, digest: sha256(bytes), parsedLines: records.length };
    }
    if (typeof r !== 'object' || r === null || Array.isArray(r)) return { state: 'damaged', line: records.length + 1, digest: sha256(bytes), parsedLines: records.length };
    records.push(r as JournalRecord);
  }
  if (!complete) return { state: 'damaged', line: records.length + 1, digest: sha256(bytes), parsedLines: records.length };
  return { state: 'ok', records };
}

function activatedRecords(journal: Journal): Array<{ sha: string; manifestDigest: string; at: string }> {
  if (journal.state !== 'ok') return [];
  return journal.records.filter((r) => r.record === 'activated' && typeof r.sha === 'string') as unknown as Array<{ sha: string; manifestDigest: string; at: string }>;
}

// ── Provenance ─────────────────────────────────────────────────────────────

export type Provenance = { source: string; tip: string } | { recorded: string };

/**
 * Where the bytes of `versions/<sha>` come from (I-4, I-4b). Offline only
 * when this journal is intact and records `sha` activated with this MANIFEST
 * digest (D2). Otherwise: `develop` fetched from the pinned source into a
 * private repository, `sha` an ancestor of it, and every installed file equal
 * to the commit's blob with the same exec bit, the same path set, and the
 * MANIFEST exactly what those files give.
 */
export function provenance(install: Install, sha: string, digest: string, journal: Journal, source: Source): Provenance {
  const recorded = activatedRecords(journal).filter((r) => r.sha === sha && r.manifestDigest === digest).pop();
  if (recorded) return { recorded: recorded.at };
  return withTempDir('harness-provenance-', (tmp) => {
    const run = (args: string[]) => git(args, { home: tmp, allowLocal: source.allowLocal });
    const ok = (args: string[]): Buffer => {
      const r = run([`--git-dir=${tmp}/repo.git`, ...args]);
      if (r.status !== 0) throw new IntegrityError(`git ${args[0]} failed: ${r.stderr}`);
      return r.stdout;
    };
    const init = run(['init', '--quiet', '--bare', `${tmp}/repo.git`]);
    if (init.status !== 0) throw new IntegrityError(`git init failed: ${init.stderr}`);
    const fetch = run([`--git-dir=${tmp}/repo.git`, 'fetch', '--quiet', '--no-tags', source.url, '+refs/heads/develop:refs/trusted/develop']);
    if (fetch.status !== 0) {
      throw new UsageError(`online provenance required: ${sha} was never activated here with this MANIFEST, and fetching develop from ${source.url} failed: ${fetch.stderr}`);
    }
    const tip = ok(['rev-parse', '--verify', 'refs/trusted/develop^{commit}']).toString().trim();
    const ancestor = run([`--git-dir=${tmp}/repo.git`, 'merge-base', '--is-ancestor', sha, 'refs/trusted/develop']);
    if (ancestor.status !== 0) throw new UsageError(`${sha} is not an ancestor of develop at ${source.url} (${tip}); only merged code is activated`);
    const entries = payloadEntries(lsTree(ok, sha, CLOSURE), sha);
    const rel = `versions/${sha}`;
    const installed = listPayload(install, rel, MANIFEST);
    const want = entries.map((e) => e.path).sort().join('\n');
    if (installed.map((f) => f.path).join('\n') !== want) throw new IntegrityError(`version ${sha} does not hold exactly the files of ${sha} at ${source.url}`);
    const exec = new Map(installed.map((f) => [f.path, f.exec]));
    for (const e of entries) {
      if (gitBlobId(install.read(`${rel}/${e.path}`)) !== e.oid) throw new IntegrityError(`${e.path} of ${sha} is not the blob ${e.oid} of ${sha} at ${source.url}`);
      if (exec.get(e.path) !== (e.mode === '100755')) throw new IntegrityError(`${e.path} of ${sha} has the wrong exec bit for ${sha} at ${source.url}`);
    }
    if (buildManifest(install, rel, sha) !== install.read(`${rel}/${MANIFEST}`).toString('utf8')) throw new IntegrityError(`${MANIFEST} of ${sha} is not the one its files give`);
    return { source: source.url, tip };
  });
}

// ── Activation ─────────────────────────────────────────────────────────────

export type ActivationPlan = {
  action: 'activate' | 'rollback';
  from: Version | null;
  /** ACTIVE as found: a broken one is shown with its evidence and quarantined, never followed. */
  active: 'none' | 'ok' | { broken: 'file'; sha256: string; reason: string } | { broken: 'link'; target: string };
  to: Version;
  approval: string;
  actor: string;
  provenance: Provenance;
  journal: 'ok' | { damaged: number };
  /**
   * What happens to bin/harness (#272, ADR-0013 D-3 as amended): kept byte for byte, written
   * from `--node` when absent, or rewritten when `--node` gives a different text (the old file
   * quarantined; `quarantined` is filled in after the move).
   */
  wrapper: WrapperPlan;
};

export type WrapperPlan =
  | 'kept'
  | { action: 'write'; node: string; sha256: string }
  | { action: 'rewrite'; node: string; sha256: string; from: string; fromNode: string | null; quarantined?: string };

/**
 * What the owner types: `<old-sha12|none|broken> <new-sha12> <digest12>`, plus
 * `<wrapper12>` (sha256 of the new bin/harness text) when the plan writes or rewrites it.
 */
export function confirmation(plan: ActivationPlan): string {
  const old = plan.from ? plan.from.sha.slice(0, 12) : plan.active === 'none' ? 'none' : 'broken';
  const base = `${old} ${plan.to.sha.slice(0, 12)} ${plan.to.manifestDigest.slice(0, 12)}`;
  return plan.wrapper === 'kept' ? base : `${base} ${plan.wrapper.sha256.slice(0, 12)}`;
}

/**
 * `--node` (#272 D-2): an absolute path to an existing regular file this user may execute.
 * A symbolic link is allowed and written as given, never resolved: a stable link the owner
 * maintains survives a package-manager upgrade, the versioned target behind it does not.
 * Nothing is executed here.
 */
export function checkNode(node: string): void {
  if (!node.startsWith('/') || /['\n]/.test(node)) throw new UsageError(`--node ${JSON.stringify(node)} must be an absolute path without ' or a newline`);
  const p = probeExecutable(node);
  if ('error' in p) throw new UsageError(`--node ${node}: ${p.error}; name the Node to pin into bin/harness (docs/ai-harness.md, "Node for the install")`);
  if (!p.st.isFile()) throw new UsageError(`--node ${node} is a ${kindOf(p.st)}, not a Node executable`);
  if (!p.executable) throw new UsageError(`--node ${node} is not executable by this user`);
}

/** The Node literal an existing bin/harness names, current or pre-#272 template; null if none. */
function wrapperNode(text: string): string | null {
  return text.match(/^node='([^'\n]*)'$/m)?.[1] ?? text.match(/^exec '([^'\n]*)' -- /m)?.[1] ?? null;
}

/**
 * Fixed text of the note bin/harness prints for `prompt-hook` when its Node is gone (#272 D-4,
 * owner 2026-10-28): a warning that tells Claude to ask the owner before going on without JEV.
 * The same key path as every note the TS hook writes (prompt-observation.ts hookOutput).
 */
export const NODE_MISSING_NOTE = JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'UserPromptSubmit',
    additionalContext:
      'GoGo harness · CẢNH BÁO (harness_node_missing): không bật được JEV — Node ghim trong ~/.gogo-harness/install/bin/harness không còn, prompt này không được gửi cho JEV. Claude: báo owner cảnh báo này và hỏi owner xác nhận có làm tiếp không có JEV hay không, trước khi làm bất cứ việc gì khác. Sửa (owner, trên terminal): ~/.gogo-harness/install/bin/harness activate <sha> --approval <ref> --node <đường dẫn Node tuyệt đối> (docs/ai-harness.md, Node for the install). Chi tiết: ~/.gogo-harness/prompt-hook.last-error.',
  },
});

/**
 * bin/harness: the launch boundary hooks call (I-6). `node` is the path an activation named
 * with `--node` (ADR-0013 D-3 as amended by #272). A missing interpreter is reported before
 * `exec`: for `prompt-hook` one fixed JSON line on stdout and exit 0 (the hook never blocks a
 * prompt), for anything else a message on stderr and exit 2.
 */
export function wrapperText(node: string): string {
  if (!node.startsWith('/') || /['\n]/.test(node)) throw new UsageError(`node path ${JSON.stringify(node)} cannot be written into bin/harness`);
  return `#!/bin/sh
# GoGo AI harness launch boundary (ADR-0013 D-3, GoGo-Infra#245, #272). Written by an
# activation that names --node; a later activation with --node may replace it. Node starts
# without any preload a caller's environment names, from the path fixed here.
case $0 in
*/*) ;;
*) echo "harness: run bin/harness by its path, not by name" >&2; exit 2 ;;
esac
unset CDPATH NODE_OPTIONS NODE_PATH NODE_COMPILE_CACHE NODE_REPL_EXTERNAL_MODULE
here=$(cd -P -- "\${0%/*}" && pwd -P) || exit 2
node='${node}'
if [ ! -x "$node" ]; then
  echo "harness: node interpreter $node is missing or not executable (harness_node_missing); re-activate with --node <absolute path> on a terminal (docs/ai-harness.md, \\"Node for the install\\")" >&2
  case $1 in
  prompt-hook) printf '%s\\n' '${NODE_MISSING_NOTE}'; exit 0 ;;
  esac
  exit 2
fi
exec "$node" -- "$here/harness.mts" "$@"
`;
}

/**
 * Who a left `activate.lock` belongs to (#260): the pid it records, and whether that pid still
 * runs. Only a diagnosis — the lock is never removed here, since an interrupted activation needs
 * ACTIVE compared with the journal first. A running pid may also be an unrelated process that
 * reuses it; a pid that does not run cannot be holding the lock.
 */
function lockHolder(install: Install): string {
  const interrupted = 'check ACTIVE against history.jsonl, then remove the lock';
  let text: string;
  try {
    text = install.read('activate.lock').toString('utf8');
  } catch {
    return `another activation is running or one was interrupted; ${interrupted}`;
  }
  if (text === '') return `it records no pid: an activation was interrupted before writing it, or one is starting; ${interrupted}`;
  const m = text.match(/^([1-9][0-9]{0,9})\n$/);
  if (!m) return `it does not record a pid, so it is not a lock this launcher wrote; ${interrupted}`;
  const pid = Number(m[1]);
  try {
    process.kill(pid, 0);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === 'ESRCH') return `pid ${pid}, which is no longer running, took it: an activation was interrupted; ${interrupted}`;
  }
  return `pid ${pid}, which is still running: another activation may hold it; wait for it to finish, or ${interrupted} once it has`;
}

/**
 * Make `sha` the running version (I-5, I-5b). Bootstrap code only: nothing
 * of the outgoing or incoming version is imported. Before the owner is
 * asked: the lock, ACTIVE and journal classified, the candidate verified and
 * its provenance proven. Nothing changes unless `confirm` returns true; then,
 * in order: a damaged journal quarantined and restarted, bin/harness written
 * from --node if absent or replaced if its text differs (old file to
 * quarantine/), a broken ACTIVE quarantined, the `intent` record, ACTIVE
 * replaced by rename — the only step that changes which version runs — and
 * the `activated` record. Interrupted before the ACTIVE rename, no version
 * that runs has changed (a bin/harness already written stays and matches
 * on the re-run) and re-running activation completes it. After the ACTIVE
 * rename, before `activated`, the new version stays selected without
 * completed journal evidence (#253 S4-03): re-activating it needs online
 * provenance again, and offline only an `activated` version can be chosen.
 */
export async function activate(
  o: { install: Install; sha: string; approval: string; actor?: string; now?: () => Date; source?: Source; node?: string; warn?: (m: string) => void },
  confirm: (plan: ActivationPlan) => Promise<boolean>,
): Promise<ActivationPlan> {
  const { install, sha } = o;
  const approval = o.approval.trim();
  if (!approval) throw new UsageError('--approval <reference to the owner approval> is required');
  if (!FULL_SHA.test(sha)) throw new UsageError(`${sha} is not a full commit SHA`);
  const now = o.now ?? (() => new Date());
  let lock: { fd: number; ino: number };
  try {
    lock = install.createExclusive('activate.lock', 0o600);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== 'EEXIST' && (e as NodeJS.ErrnoException).code !== 'ELOOP') throw e;
    const st = install.stat('activate.lock');
    if (st?.isSymbolicLink()) throw new UsageError(`${install.path('activate.lock')} is a symbolic link to ${install.readlink('activate.lock')}, not a lock; remove it by hand`);
    throw new UsageError(`${install.path('activate.lock')} exists: ${lockHolder(install)}`);
  }
  try {
    writeFd(lock.fd, `${process.pid}\n`);
    const active = classifyActive(install);
    const journal = readJournal(install);
    const wrapper = install.stat('bin/harness');
    if (wrapper && !wrapper.isFile()) throw new UsageError(`bin/harness in ${install.root} is a ${kindOf(wrapper)}; remove it by hand, then activate`);
    // A kept wrapper is a bin/* leaf like any other (I-2): owned, one link. A hard link
    // to a checkout file would let the checkout edit startup code (PR #253 Sol r4, S4-01).
    if (wrapper && wrapper.uid !== uid()) throw new UsageError(`bin/harness in ${install.root} is not owned by this user; remove it by hand, then activate`);
    if (wrapper && wrapper.nlink !== 1) throw new UsageError(`bin/harness in ${install.root} has ${wrapper.nlink} hard links; remove it by hand, then activate`);
    // #272 D-1/D-3: the wrapper is written only from an explicit --node, never from execPath
    // (Node resolves links in execPath, so a default would always be a versioned path).
    let wrapperPlan: WrapperPlan = 'kept';
    if (o.node !== undefined) checkNode(o.node);
    if (!wrapper) {
      if (o.node === undefined) throw new UsageError(`--node <absolute path of the Node to pin into bin/harness> is required when bin/harness is written (docs/ai-harness.md, "Node for the install")`);
      const text = wrapperText(o.node);
      wrapperPlan = { action: 'write', node: o.node, sha256: sha256(text) };
    } else if (o.node !== undefined) {
      const old = install.read('bin/harness');
      const text = wrapperText(o.node);
      if (!old.equals(Buffer.from(text))) wrapperPlan = { action: 'rewrite', node: o.node, sha256: sha256(text), from: sha256(old), fromNode: wrapperNode(old.toString('utf8')) };
    }
    const { digest } = verifyVersion(install, sha);
    const from = active.kind === 'ok' ? active.version : null;
    const prov = provenance(install, sha, digest, journal, o.source ?? TRUSTED_SOURCE);
    const plan: ActivationPlan = {
      action: activatedRecords(journal).some((r) => r.sha === sha) && from?.sha !== sha ? 'rollback' : 'activate',
      from,
      active: active.kind === 'none' || active.kind === 'ok' ? active.kind : active.kind === 'broken-link' ? { broken: 'link', target: active.target } : { broken: 'file', sha256: active.sha256, reason: active.reason },
      to: { sha, manifestDigest: digest },
      approval,
      actor: o.actor ?? `${userInfo().username}@${hostname()}`,
      provenance: prov,
      journal: journal.state === 'ok' ? 'ok' : { damaged: journal.line },
      wrapper: wrapperPlan,
    };
    if (!(await confirm(plan))) throw new UsageError('activation not confirmed; nothing changed');

    if (journal.state === 'damaged') {
      const path = install.quarantine('history.jsonl', now());
      install.appendLine('history.jsonl', JSON.stringify({ record: 'history_quarantined', path, digest: journal.digest, parsedLines: journal.parsedLines, at: now().toISOString() }));
    }
    let wrapperRecord: 'kept' | 'written' | { rewritten: string; node: string; quarantined: string } = 'kept';
    if (wrapperPlan !== 'kept' && wrapperPlan.action === 'write') {
      install.mkdirBelow('bin');
      install.publish('bin/harness', wrapperText(wrapperPlan.node), 0o555);
      wrapperRecord = 'written';
    } else if (wrapperPlan !== 'kept') {
      wrapperPlan.quarantined = install.quarantine('bin/harness', now());
      install.publish('bin/harness', wrapperText(wrapperPlan.node), 0o555);
      wrapperRecord = { rewritten: wrapperPlan.from, node: wrapperPlan.node, quarantined: wrapperPlan.quarantined };
    }
    let quarantined: string | undefined;
    if (active.kind === 'broken-file' || active.kind === 'broken-link') quarantined = install.quarantine('ACTIVE', now());
    install.appendLine('history.jsonl', JSON.stringify({
      record: 'intent', kind: plan.action, from, to: plan.to, approval, actor: plan.actor, source: prov, wrapper: wrapperRecord, at: now().toISOString(),
      ...(quarantined ? { active: plan.active, quarantined } : {}),
    }));
    install.publish('ACTIVE', `${JSON.stringify({ schema: 1, ...plan.to }, null, 2)}\n`, 0o644);
    install.appendLine('history.jsonl', JSON.stringify({ record: 'activated', sha, manifestDigest: digest, source: prov, at: now().toISOString() }));
    return plan;
  } finally {
    closeFd(lock.fd);
    if (!install.unlinkOwn('activate.lock', lock.ino)) (o.warn ?? ((m: string) => process.stderr.write(`${m}\n`)))(`harness install: ${install.path('activate.lock')} is no longer the lock this activation took; left in place`);
  }
}

async function askOnTerminal(plan: ActivationPlan): Promise<boolean> {
  const from = plan.from ? `${plan.from.sha} (MANIFEST ${plan.from.manifestDigest})` : plan.active === 'none' ? 'none' : 'none — ACTIVE is broken';
  const lines = [`${plan.action} harness install`, `  from        ${from}`];
  if (typeof plan.active === 'object') {
    lines.push(plan.active.broken === 'link'
      ? `  ACTIVE      symbolic link → ${plan.active.target} (not followed; moved to quarantine/)`
      : `  ACTIVE      file sha256 ${plan.active.sha256}, ${plan.active.reason} (moved to quarantine/)`);
  }
  if (plan.journal !== 'ok') lines.push(`  journal     history.jsonl damaged at line ${plan.journal.damaged} (moved to quarantine/, a new journal starts)`);
  lines.push(`  to          ${plan.to.sha} (MANIFEST ${plan.to.manifestDigest})`);
  lines.push('recorded' in plan.provenance ? `  provenance  recorded ${plan.provenance.recorded}` : `  provenance  ancestor of develop ${plan.provenance.tip} at ${plan.provenance.source}`);
  lines.push(`  approval    ${plan.approval}`, `  actor       ${plan.actor}`);
  const w = plan.wrapper;
  lines.push(w === 'kept'
    ? '  bin/harness kept'
    : w.action === 'write'
      ? `  bin/harness write: node ${w.node} (sha256 ${w.sha256})`
      : `  bin/harness rewrite: node ${w.fromNode ?? 'unreadable'} → ${w.node} (sha256 ${w.from} → ${w.sha256}; old file to quarantine/)`);
  process.stderr.write(`${lines.join('\n')}\n`);
  const expected = confirmation(plan);
  const rl = createInterface({ input: process.stdin, output: process.stderr });
  try {
    const what = plan.wrapper === 'kept' ? 'old sha or none/broken, new sha, new MANIFEST digest' : 'old sha or none/broken, new sha, new MANIFEST digest, new bin/harness sha256';
    return (await rl.question(`Type "${expected}" (${what}) to confirm: `)).trim() === expected;
  } finally {
    rl.close();
  }
}

// ── Entry ──────────────────────────────────────────────────────────────────

const PRELOAD = /^(--import|--require|-r|--loader|--experimental-loader)(=|$)/;
const PRELOAD_IN_OPTIONS = /(^|\s)(--import|--require|-r|--loader|--experimental-loader)(=|\s|$)/;

/**
 * Process entry (I-7). Only `<root>/bin/harness.mts` runs. `activate` and
 * `install-verify` are this file's own; every other command goes to the CLI
 * of the version ACTIVE names, once it is verified.
 */
export async function entry(argv: string[]): Promise<number> {
  // Diagnostic only: a preload has already run by the time this line does.
  // bin/harness, which clears NODE_OPTIONS before node starts, is the boundary.
  if (process.execArgv.some((a) => PRELOAD.test(a)) || PRELOAD_IN_OPTIONS.test(process.env.NODE_OPTIONS ?? '')) {
    throw new IntegrityError('node was started with a preload (--import, --require or --loader); that code has already run. Start the harness through bin/harness');
  }
  const self = realpath(fileURLToPath(import.meta.url));
  if (basename(self) !== 'harness.mts' || basename(dirname(self)) !== 'bin') {
    throw new IntegrityError(`${self} is not an installed launcher; run ~/.gogo-harness/install/bin/harness (docs/ai-harness.md, "Installed copy")`);
  }
  const install = Install.open(dirname(dirname(self)), { bootstrap: true });
  const [command, ...rest] = argv;
  if (command === 'activate') {
    const { values, positionals } = parseArgs({ args: rest, options: { approval: { type: 'string' }, node: { type: 'string' } }, allowPositionals: true });
    if (positionals.length !== 1) throw new UsageError('activate <full-sha> --approval <ref> [--node <absolute path>]');
    if (!process.stdin.isTTY) throw new UsageError('activate asks the owner on a terminal; stdin is not one');
    const plan = await activate({ install, sha: positionals[0]!, approval: values.approval ?? '', ...(values.node !== undefined ? { node: values.node } : {}) }, askOnTerminal);
    process.stdout.write(`${JSON.stringify(plan, null, 2)}\n`);
    return 0;
  }
  const active = readActive(install);
  verifyVersion(install, active.sha, active.manifestDigest);
  if (command === 'install-verify') {
    process.stdout.write(`${JSON.stringify(active)}\n`);
    return 0;
  }
  const cli = (await import(pathToFileURL(install.path(`versions/${active.sha}/harness/src/cli.ts`)).href)) as { run(argv: string[]): Promise<number> };
  return cli.run(argv);
}

if (isEntryPoint(import.meta.url)) {
  entry(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (e: unknown) => {
      process.stderr.write(`harness install: ${(e as Error).message}\n`);
      process.exit(2);
    },
  );
}
