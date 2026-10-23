/**
 * Owner opt-in for sending prompts to JEV (GoGo-Infra#247, owner decision
 * 2026-10-23, issuecomment-6362221699). Off by default.
 *
 *   node <launcher> jev-prompt setup [--wrapper <exec-with.sh>]   # allow `#jev` on single prompts
 *   node <launcher> jev-prompt on [--for 8h] [--wrapper …]       # every prompt, for at most 24 h
 *   node <launcher> jev-prompt off                                # stop sending (no terminal needed)
 *   node <launcher> jev-prompt status
 *
 * `setup` and `on` are the owner's consent and run on a terminal only: the
 * owner reads what will be sent where and types a confirmation. They record
 * the secrets wrapper the key comes through (scripts/secrets/exec-with.sh,
 * so the key reaches one child process and nothing else) and, for `on`, an
 * expiry after which sending stops by itself. Every change is a history line.
 *
 * Same limit as the install (#245): a session running as the same OS user
 * can write these files too. That boundary is Claude Code's permissions on
 * writes outside the workspace; this file records consent, it cannot prove it.
 */
import { accessSync, appendFileSync, constants, existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { hostname, homedir, userInfo } from 'node:os';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';

export const OPTIN_FILE = 'jev-prompt.json';
export const OPTIN_HISTORY = 'jev-prompt-history.jsonl';
export const SESSIONS_FILE = 'prompt-hook/sessions.json';
export const OPTIN_LIMITS = { defaultHours: 8, maxHours: 24, sessionCalls: 20, sessionKeepDays: 7 } as const;

export type OptIn = { schema: 1; wrapper: string; enabledUntil: string | null; updatedAt: string; actor: string };
export type OptInPlan = { action: 'setup' | 'on'; wrapper: string; enabledUntil: string | null; actor: string };

export function stateDirOf(env: Record<string, string | undefined>): string {
  return env.HARNESS_STATE_DIR ?? join(homedir(), '.gogo-harness');
}

export function readOptIn(stateDir: string): OptIn | null {
  try {
    const o = JSON.parse(readFileSync(join(stateDir, OPTIN_FILE), 'utf8')) as Partial<OptIn>;
    if (o.schema !== 1 || typeof o.wrapper !== 'string' || (o.enabledUntil !== null && typeof o.enabledUntil !== 'string')) return null;
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
  o: { stateDir: string; action: 'setup' | 'on'; wrapper: string; hours?: number; actor?: string; now?: () => Date },
  confirm: (plan: OptInPlan) => Promise<boolean>,
): Promise<OptIn> {
  if (!isAbsolute(o.wrapper)) throw new Error('--wrapper must be an absolute path');
  try {
    accessSync(o.wrapper, constants.X_OK);
  } catch {
    throw new Error(`${o.wrapper} is not an executable file`);
  }
  const now = o.now?.() ?? new Date();
  let enabledUntil: string | null = null;
  if (o.action === 'on') {
    const hours = o.hours ?? OPTIN_LIMITS.defaultHours;
    if (!Number.isFinite(hours) || hours <= 0 || hours > OPTIN_LIMITS.maxHours) throw new Error(`--for must be between 1 and ${OPTIN_LIMITS.maxHours} hours`);
    enabledUntil = new Date(now.getTime() + hours * 3_600_000).toISOString();
  } else {
    // setup keeps an `on` that is still running; it only (re)records the wrapper.
    const current = readOptIn(o.stateDir);
    enabledUntil = optInActive(current, now) ? current!.enabledUntil : null;
  }
  const plan: OptInPlan = { action: o.action, wrapper: o.wrapper, enabledUntil, actor: o.actor ?? actorName() };
  if (!(await confirm(plan))) throw new Error('not confirmed; nothing changed');
  const next: OptIn = { schema: 1, wrapper: plan.wrapper, enabledUntil: plan.enabledUntil, updatedAt: now.toISOString(), actor: plan.actor };
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
  appendFileSync(join(stateDir, OPTIN_HISTORY), `${JSON.stringify({ at: now.toISOString(), action, actor: next.actor, wrapper: next.wrapper, enabledUntil: next.enabledUntil })}\n`);
  const tmp = join(stateDir, `.${OPTIN_FILE}.${process.pid}`);
  writeFileSync(tmp, `${JSON.stringify(next, null, 2)}\n`);
  renameSync(tmp, join(stateDir, OPTIN_FILE));
}

/**
 * One more JEV call for this session, if its cap allows (#247 review: a cap
 * per session before live; the $2/month account budget stays shared and is
 * enforced by the ledger). Sessions idle for a week are forgotten.
 */
export function takeSessionCall(stateDir: string, sessionDigest: string, now: Date): boolean {
  const file = join(stateDir, SESSIONS_FILE);
  let table: Record<string, { calls: number; last: string }> = {};
  try {
    table = JSON.parse(readFileSync(file, 'utf8')) as typeof table;
  } catch {
    // first call, or unreadable: start over — the account budget still bounds spend
  }
  const cutoff = now.getTime() - OPTIN_LIMITS.sessionKeepDays * 86_400_000;
  for (const [k, v] of Object.entries(table)) if (Date.parse(v.last) < cutoff) delete table[k];
  const entry = table[sessionDigest] ?? { calls: 0, last: now.toISOString() };
  if (entry.calls >= OPTIN_LIMITS.sessionCalls) return false;
  table[sessionDigest] = { calls: entry.calls + 1, last: now.toISOString() };
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, `${JSON.stringify(table)}\n`);
  return true;
}

/** `jev-prompt <setup|on|off|status>` — returns the exit code; prints to stdout/stderr like the rest of the CLI. */
export async function jevPromptCommand(args: string[], env: Record<string, string | undefined>, cwd = process.cwd()): Promise<number> {
  const stateDir = stateDirOf(env);
  const [sub, ...rest] = args;
  const flag = (name: string) => {
    const i = rest.indexOf(name);
    return i >= 0 ? rest[i + 1] : undefined;
  };
  if (sub === 'status') {
    const o = readOptIn(stateDir);
    process.stdout.write(`${JSON.stringify({ setUp: o !== null, active: optInActive(o, new Date()), enabledUntil: o?.enabledUntil ?? null, wrapper: o?.wrapper ?? null }, null, 2)}\n`);
    return 0;
  }
  if (sub === 'off') {
    const o = revokeOptIn(stateDir);
    process.stdout.write(`${JSON.stringify({ active: false, setUp: o !== null })}\n`);
    return 0;
  }
  if (sub !== 'setup' && sub !== 'on') {
    process.stderr.write('harness: jev-prompt setup|on [--for 8h]|off|status [--wrapper <exec-with.sh>]\n');
    return 2;
  }
  if (!process.stdin.isTTY) {
    process.stderr.write('harness: jev-prompt setup/on asks the owner on a terminal; stdin is not one\n');
    return 2;
  }
  const wrapper = flag('--wrapper') ? resolve(flag('--wrapper')!) : findWrapper(cwd);
  if (!wrapper) {
    process.stderr.write('harness: no scripts/secrets/exec-with.sh above this directory; pass --wrapper <path>\n');
    return 2;
  }
  const forFlag = flag('--for');
  const hours = forFlag === undefined ? undefined : Number(forFlag.replace(/h$/i, ''));
  try {
    const o = await grantOptIn({ stateDir, action: sub, wrapper, hours }, askOnTerminal);
    process.stdout.write(`${JSON.stringify(o, null, 2)}\n`);
    return 0;
  } catch (e) {
    process.stderr.write(`harness: ${(e as Error).message}\n`);
    return 2;
  }
}

function findWrapper(start: string): string | null {
  for (let dir = resolve(start); ; dir = dirname(dir)) {
    const candidate = join(dir, 'scripts/secrets/exec-with.sh');
    if (existsSync(join(dir, '.git')) && existsSync(candidate) && statSync(candidate).isFile()) return candidate;
    if (dirname(dir) === dir) return null;
  }
}

async function askOnTerminal(plan: OptInPlan): Promise<boolean> {
  const scope = plan.action === 'on' ? `MỌI prompt cho tới ${plan.enabledUntil} (trừ prompt có #nojev)` : 'chỉ prompt có #jev';
  process.stderr.write(
    [
      `jev-prompt ${plan.action}`,
      `  gửi:      ${scope}`,
      '  tới:      OpenRouter, model typesafe/jev-1.14 — bản tóm tắt đã qua sanitizer (credential, email, số điện thoại bị thay; dữ liệu sai định dạng thì không gửi)',
      '  key:      qua wrapper, chỉ vào một tiến trình con mỗi lần gửi',
      `  wrapper:  ${plan.wrapper}`,
      '  kết quả:  gợi ý ngắn chèn vào context — chỉ tư vấn, không chặn prompt, không cấp quyền',
      '  lưu ý:    privacy review + DPA cho prompt thật CHƯA xong (GoGo-Infra#244); bạn xác nhận tự chịu trách nhiệm với prompt mình gửi',
      `  ghi bởi:  ${plan.actor}`,
      '',
    ].join('\n'),
  );
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
