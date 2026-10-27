/**
 * Owner opt-in for sending prompts to JEV (GoGo-Infra#247, owner decision
 * 2026-10-23, issuecomment-6362221699). Off by default.
 *
 *   node <launcher> jev-prompt setup            # allow `#jev` on single prompts
 *   node <launcher> jev-prompt on [--for 8h]    # every prompt, for at most 24 h
 *   node <launcher> jev-prompt off              # stop sending (no terminal needed)
 *   node <launcher> jev-prompt status
 *
 * `setup` and `on` are the owner's consent and run on a terminal only: the
 * owner reads what will be sent where and types a confirmation. They record
 * the consent and, for `on`, an expiry after which sending stops by itself.
 * Every change is a history line. No wrapper is recorded (PR #254 shape rev
 * 3, I6): the key always comes through `scripts/secrets/exec-with.sh` of the
 * install the hook runs from, checked against its MANIFEST before each send
 * (prompt-observation.ts) — consent, the environment or a flag never choose
 * what runs. A schema-1 file, which named a wrapper, is not consent any more:
 * the owner runs `setup` again.
 *
 * Same limit as the install (#245): a session running as the same OS user
 * can write these files too. That boundary is Claude Code's permissions on
 * writes outside the workspace; this file records consent, it cannot prove it.
 */
import { appendFileSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { LockTimeoutError, withStateLock } from '../runtime/lock.ts';
import { hostname, homedir, userInfo } from 'node:os';
import { dirname, join } from 'node:path';
import { createInterface } from 'node:readline/promises';

export const OPTIN_FILE = 'jev-prompt.json';
export const OPTIN_HISTORY = 'jev-prompt-history.jsonl';
export const SESSIONS_FILE = 'prompt-hook/sessions.json';
export const OPTIN_LIMITS = { defaultHours: 8, maxHours: 24, sessionCalls: 20, sessionKeepDays: 7 } as const;

export type OptIn = { schema: 2; enabledUntil: string | null; updatedAt: string; actor: string };
export type OptInPlan = { action: 'setup' | 'on'; enabledUntil: string | null; actor: string };

export function stateDirOf(env: Record<string, string | undefined>): string {
  return env.HARNESS_STATE_DIR ?? join(homedir(), '.gogo-harness');
}

export function readOptIn(stateDir: string): OptIn | null {
  try {
    const o = JSON.parse(readFileSync(join(stateDir, OPTIN_FILE), 'utf8')) as Partial<OptIn>;
    if (o.schema !== 2 || (o.enabledUntil !== null && typeof o.enabledUntil !== 'string')) return null;
    return o as OptIn;
  } catch {
    return null;
  }
}

/** Whether every prompt is sent right now: `on` and not expired. */
export function optInActive(o: OptIn | null, now: Date): boolean {
  return o !== null && o.enabledUntil !== null && Date.parse(o.enabledUntil) > now.getTime();
}

/** `setup` or `on`, after the owner confirms the plan. */
export async function grantOptIn(
  o: { stateDir: string; action: 'setup' | 'on'; hours?: number; actor?: string; now?: () => Date },
  confirm: (plan: OptInPlan) => Promise<boolean>,
): Promise<OptIn> {
  const now = o.now?.() ?? new Date();
  let enabledUntil: string | null = null;
  if (o.action === 'on') {
    const hours = o.hours ?? OPTIN_LIMITS.defaultHours;
    if (!Number.isFinite(hours) || hours <= 0 || hours > OPTIN_LIMITS.maxHours) throw new Error(`--for must be between 1 and ${OPTIN_LIMITS.maxHours} hours`);
    enabledUntil = new Date(now.getTime() + hours * 3_600_000).toISOString();
  } else {
    // setup keeps an `on` that is still running.
    const current = readOptIn(o.stateDir);
    enabledUntil = optInActive(current, now) ? current!.enabledUntil : null;
  }
  const plan: OptInPlan = { action: o.action, enabledUntil, actor: o.actor ?? actorName() };
  if (!(await confirm(plan))) throw new Error('not confirmed; nothing changed');
  const next: OptIn = { schema: 2, enabledUntil: plan.enabledUntil, updatedAt: now.toISOString(), actor: plan.actor };
  write(o.stateDir, next, plan.action, now);
  return next;
}

/** Stop sending every prompt. Turning off needs no confirmation; `#jev` keeps working if set up. */
export function revokeOptIn(stateDir: string, now = new Date(), actor = actorName()): OptIn | null {
  const current = readOptIn(stateDir);
  if (!current) return null;
  const next: OptIn = { ...current, enabledUntil: null, updatedAt: now.toISOString(), actor };
  write(stateDir, next, 'off', now);
  return next;
}

function write(stateDir: string, next: OptIn, action: string, now: Date): void {
  mkdirSync(stateDir, { recursive: true });
  appendFileSync(join(stateDir, OPTIN_HISTORY), `${JSON.stringify({ at: now.toISOString(), action, actor: next.actor, enabledUntil: next.enabledUntil })}\n`);
  const tmp = join(stateDir, `.${OPTIN_FILE}.${process.pid}`);
  writeFileSync(tmp, `${JSON.stringify(next, null, 2)}\n`);
  renameSync(tmp, join(stateDir, OPTIN_FILE));
}

export type SessionAdmission = 'ok' | 'cap' | 'unreadable' | 'busy';

type SessionTable = Record<string, { calls: number; last: string }>;

function isSessionTable(v: unknown): v is SessionTable {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return false;
  return Object.values(v).every((e: unknown) => {
    if (typeof e !== 'object' || e === null || Array.isArray(e)) return false;
    const { calls, last } = e as Record<string, unknown>;
    return Number.isSafeInteger(calls) && (calls as number) >= 0 && typeof last === 'string' && !Number.isNaN(Date.parse(last));
  });
}

/**
 * One more JEV call for this session, if its cap allows (#247 review: a cap
 * per session before live; the $2/month account budget stays shared and is
 * enforced by the ledger). Sessions idle for a week are forgotten.
 *
 * One transaction across processes (PR #254 review P2): read, check and
 * increment run under their own lock (`prompt-hook/harness.lock`, not the
 * decide lock, which the live child takes next), held for that step only,
 * and the table is replaced by rename. A table that cannot be read, or any
 * entry of it that is not `{ calls: safe non-negative integer, last: a
 * date }`, is `unreadable` — nothing is pruned, reset or admitted until the
 * owner removes the file; a lock not obtained in 2 s is `busy`.
 */
export async function takeSessionCall(stateDir: string, sessionDigest: string, now: Date): Promise<SessionAdmission> {
  const file = join(stateDir, SESSIONS_FILE);
  mkdirSync(dirname(file), { recursive: true });
  try {
    return await withStateLock(
      dirname(file),
      async (): Promise<SessionAdmission> => {
        let table: SessionTable = {};
        let raw: string | null = null;
        try {
          raw = readFileSync(file, 'utf8');
        } catch (e) {
          if ((e as NodeJS.ErrnoException).code !== 'ENOENT') return 'unreadable';
        }
        if (raw !== null) {
          try {
            const parsed: unknown = JSON.parse(raw);
            // The whole table, before anything is read, pruned or written (PR #254 S-02).
            if (!isSessionTable(parsed)) return 'unreadable';
            table = parsed;
          } catch {
            return 'unreadable';
          }
        }
        const cutoff = now.getTime() - OPTIN_LIMITS.sessionKeepDays * 86_400_000;
        for (const [k, v] of Object.entries(table)) if (Date.parse(v.last) < cutoff) delete table[k];
        const entry = table[sessionDigest] ?? { calls: 0, last: now.toISOString() };
        if (entry.calls >= OPTIN_LIMITS.sessionCalls) return 'cap';
        table[sessionDigest] = { calls: entry.calls + 1, last: now.toISOString() };
        const tmp = `${file}.${process.pid}`;
        writeFileSync(tmp, `${JSON.stringify(table)}\n`);
        renameSync(tmp, file);
        return 'ok';
      },
      { timeoutMs: 2_000, pollMs: 5 },
    );
  } catch (e) {
    if (e instanceof LockTimeoutError) return 'busy';
    throw e;
  }
}

/** `jev-prompt <setup|on|off|status>` — returns the exit code; prints to stdout/stderr like the rest of the CLI. */
export async function jevPromptCommand(args: string[], env: Record<string, string | undefined>): Promise<number> {
  const stateDir = stateDirOf(env);
  const [sub, ...rest] = args;
  if (sub === 'status') {
    const o = readOptIn(stateDir);
    process.stdout.write(`${JSON.stringify({ setUp: o !== null, active: optInActive(o, new Date()), enabledUntil: o?.enabledUntil ?? null }, null, 2)}\n`);
    return 0;
  }
  if (sub === 'off') {
    const o = revokeOptIn(stateDir);
    process.stdout.write(`${JSON.stringify({ active: false, setUp: o !== null })}\n`);
    return 0;
  }
  if (sub !== 'setup' && sub !== 'on') {
    process.stderr.write('harness: jev-prompt setup|on [--for 8h]|off|status\n');
    return 2;
  }
  // Options before the terminal check: a flag that is not this command's (`--wrapper`, gone in
  // PR #254 rev 3) is refused the same way with or without a terminal, and never recorded.
  let forFlag: string | undefined;
  for (let i = 0; i < rest.length; i++) {
    if (sub === 'on' && rest[i] === '--for' && i + 1 < rest.length) forFlag = rest[++i];
    else {
      process.stderr.write(`harness: unknown option ${rest[i]}\n`);
      return 2;
    }
  }
  if (!process.stdin.isTTY) {
    process.stderr.write('harness: jev-prompt setup/on asks the owner on a terminal; stdin is not one\n');
    return 2;
  }
  const hours = forFlag === undefined ? undefined : Number(forFlag.replace(/h$/i, ''));
  try {
    const o = await grantOptIn({ stateDir, action: sub, hours }, askOnTerminal);
    process.stdout.write(`${JSON.stringify(o, null, 2)}\n`);
    return 0;
  } catch (e) {
    process.stderr.write(`harness: ${(e as Error).message}\n`);
    return 2;
  }
}

/** What the owner reads before typing the confirmation (I10: D5 grammar and the closure, as in docs/ai-harness.md). */
export function consentText(plan: OptInPlan): string {
  const scope = plan.action === 'on' ? `MỌI prompt cho tới ${plan.enabledUntil}` : 'chỉ prompt có `#jev`';
  return [
    `jev-prompt ${plan.action}`,
    `  gửi:      ${scope}`,
    '  #jev:     chỉ tính khi là dòng không trống đầu tiên của prompt',
    '            gõ `#jev`, Shift+Enter, rồi mới dán — phần dán nằm trong <pasted_content>, nên #jev dán vào không bao giờ bật gửi',
    '  aws:      phiên Claude Code cần AWS_PROFILE đọc được key (vd. `AWS_PROFILE=gogobootstrap claude`); thiếu thì không gửi',
    '  #nojev:   ở bất kỳ dòng nào, kể cả trong code hay pasted content, chặn gửi prompt đó',
    '  tới:      OpenRouter, model typesafe/jev-1.14 — bản tóm tắt đã qua sanitizer (credential, email, số điện thoại bị thay; dữ liệu sai định dạng thì không gửi)',
    '  key:      qua `scripts/secrets/exec-with.sh` của bản cài đang chạy, kiểm MANIFEST trước mỗi lần gửi; chỉ vào một tiến trình con mỗi lần gửi',
    '  kết quả:  gợi ý ngắn chèn vào context — chỉ tư vấn, không chặn prompt, không cấp quyền',
    '  lưu ý:    privacy review + DPA cho prompt thật CHƯA xong (GoGo-Infra#244); bạn xác nhận tự chịu trách nhiệm với prompt mình gửi',
    `  ghi bởi:  ${plan.actor}`,
    '',
  ].join('\n');
}

async function askOnTerminal(plan: OptInPlan): Promise<boolean> {
  process.stderr.write(consentText(plan));
  const expected = plan.action === 'on' ? 'on' : 'setup';
  const rl = createInterface({ input: process.stdin, output: process.stderr });
  try {
    return (await rl.question(`Gõ "${expected}" để xác nhận: `)).trim() === expected;
  } finally {
    rl.close();
  }
}

function actorName(): string {
  return `${userInfo().username}@${hostname()}`;
}
