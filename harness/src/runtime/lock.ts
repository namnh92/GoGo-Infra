/**
 * One checkpoint transaction at a time per state directory (PR #242 r2 F-04).
 *
 * `decide` loads the task counters and the monthly ledger, checks limits,
 * may wait on inference, then writes both back. Two overlapping processes
 * would each pass the limits on the same snapshot and the last writer would
 * erase the other's attempt or charge. The lock spans the whole transaction,
 * and covers every task, because the ledger is shared across tasks.
 *
 * A lockfile created with O_EXCL, holding the owner's pid. A lock whose pid
 * is gone is stale and is taken over; a live holder is waited for, up to a
 * timeout, then the call fails — it never proceeds unlocked.
 */
import { closeSync, mkdirSync, openSync, readFileSync, unlinkSync, writeSync } from 'node:fs';
import { join } from 'node:path';

export const LOCK_FILE = 'harness.lock';

export class LockTimeoutError extends Error {}

export async function withStateLock<T>(stateDir: string, fn: () => Promise<T>, options: { timeoutMs?: number; pollMs?: number } = {}): Promise<T> {
  const file = join(stateDir, LOCK_FILE);
  mkdirSync(stateDir, { recursive: true });
  const deadline = Date.now() + (options.timeoutMs ?? 60_000);
  for (;;) {
    try {
      const fd = openSync(file, 'wx');
      writeSync(fd, `${process.pid}\n${new Date().toISOString()}\n`);
      closeSync(fd);
      break;
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'EEXIST') throw e;
      if (holderIsGone(file)) {
        try {
          unlinkSync(file);
        } catch {
          // another waiter removed it first; retry the create
        }
        continue;
      }
      if (Date.now() >= deadline) throw new LockTimeoutError(`${file} is held by another decide; not proceeding unlocked`);
      await new Promise((r) => setTimeout(r, options.pollMs ?? 25));
    }
  }
  try {
    return await fn();
  } finally {
    try {
      unlinkSync(file);
    } catch {
      // already gone: nothing to release
    }
  }
}

function holderIsGone(file: string): boolean {
  let pid: number;
  try {
    pid = Number(readFileSync(file, 'utf8').split('\n')[0]);
  } catch {
    return false; // being written right now: treat as held
  }
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return false;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === 'ESRCH';
  }
}
