// Child for the session-cap race test (PR #254 review P2): take `n` calls and print the results.
import { takeSessionCall } from '../../src/shadow/jev-optin.ts';

const [dir, digest, n] = process.argv.slice(2) as [string, string, string];
const results: unknown[] = [];
for (let i = 0; i < Number(n); i++) results.push(await takeSessionCall(dir, digest, new Date()));
process.stdout.write(JSON.stringify(results));
