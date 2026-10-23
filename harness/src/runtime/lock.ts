/**
 * One checkpoint transaction at a time per state directory (PR #242 r2 F-04).
 *
 * `decide` loads the task counters and the monthly ledger, checks limits,
 * may wait on inference, then writes both back. Two overlapping processes
 * would each pass the limits on the same snapshot and the last writer would
 * erase the other's attempt or charge. The lock spans the whole transaction,
 * and covers every task, because the ledger is shared across tasks.
 *
 * A lockfile created with O_EXCL, holding the owner's pid and a random token.
 * A live holder is waited for, up to a timeout, then the call fails — it never
 * proceeds unlocked.
 *
 * Taking over a dead holder's lock is itself exclusive (PR #242 r3 F-04): two
 * waiters can both see the same dead pid, and an unconditional unlink by the
 * slower one would delete the faster one's fresh lock. Recovery therefore runs
 * under a second O_EXCL file and removes the lock only if it still holds the
 * exact content that was seen dead. Release removes the lock only if it is
 * still ours.
 */
import { randomUUID } from 'node:crypto';
import { closeSync, mkdirSync, openSync, readFileSync, statSync, unlinkSync, writeSync } from 'node:fs';
import { join } from 'node:path';

export const LOCK_FILE = 'harness.lock';
/** A recovery that has not finished in this long belongs to a process that died mid-recovery. */
const RECOVERY_STALE_MS = 5_000;

export class LockTimeoutError extends Error {}

export async function withStateLock<T>(
  stateDir: string,
  fn: () => Promise<T>,
  options: { timeoutMs?: number; pollMs?: number } = {},
): Promise<T> {
  const file = join(stateDir, LOCK_FILE);
  mkdirSync(stateDir, { recursive: true });
  const mine = `${process.pid}\n${randomUUID()}\n${new Date().toISOString()}\n`;
  const deadline = Date.now() + (options.timeoutMs ?? 60_000);
  for (;;) {
    if (createExclusive(file, mine)) break;
    const seen = readOrNull(file);
    if (seen !== null && holderIsGone(seen)) {
      recoverStale(file, seen);
      continue;
    }
    if (Date.now() >= deadline) throw new LockTimeoutError(`${file} is held by another decide; not proceeding unlocked`);
    await new Promise((r) => setTimeout(r, options.pollMs ?? 25));
  }
  try {
    return await fn();
  } finally {
    if (readOrNull(file) === mine) {
      try {
        unlinkSync(file);
      } catch {
        // already gone: nothing to release
      }
    }
  }
}

/**
 * Remove `file` only if it still holds `seen`, the content observed with a
 * dead holder — under an exclusive recovery file, so no two waiters compare
 * and delete at once. Returns whether this call removed it.
 */
export function recoverStale(file: string, seen: string): boolean {
  const recovery = `${file}.recover`;
  if (!createExclusive(recovery, `${process.pid}\n`)) {
    clearAbandonedRecovery(recovery);
    return false;
  }
  try {
    if (readOrNull(file) !== seen) return false;
    unlinkSync(file);
    return true;
  } finally {
    try {
      unlinkSync(recovery);
    } catch {
      // nothing to clean up
    }
  }
}

function clearAbandonedRecovery(recovery: string): void {
  try {
    const content = readOrNull(recovery);
    if (content !== null && holderIsGone(content) && Date.now() - statSync(recovery).mtimeMs > RECOVERY_STALE_MS) {
      unlinkSync(recovery);
    }
  } catch {
    // raced with its owner: it is being handled
  }
}

function createExclusive(file: string, content: string): boolean {
  let fd: number;
  try {
    fd = openSync(file, 'wx');
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === 'EEXIST') return false;
    throw e;
  }
  try {
    writeSync(fd, content);
  } finally {
    closeSync(fd);
  }
  return true;
}

function readOrNull(file: string): string | null {
  try {
    return readFileSync(file, 'utf8');
  } catch {
    return null;
  }
}

function holderIsGone(content: string): boolean {
  const pid = Number(content.split('\n')[0]);
  if (!Number.isInteger(pid) || pid <= 0) return false; // half-written: treat as held
  try {
    process.kill(pid, 0);
    return false;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === 'ESRCH';
  }
}
