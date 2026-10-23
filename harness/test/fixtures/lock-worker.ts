// Child for the stale-lock race test: enter the lock, record, hold, record.
import { appendFileSync } from 'node:fs';
import { withStateLock } from '../../src/runtime/lock.ts';

const [dir, log] = process.argv.slice(2) as [string, string];
await withStateLock(dir, async () => {
  appendFileSync(log, `enter ${process.pid}\n`);
  await new Promise((r) => setTimeout(r, 40));
  appendFileSync(log, `exit ${process.pid}\n`);
}, { timeoutMs: 20_000, pollMs: 1 });
