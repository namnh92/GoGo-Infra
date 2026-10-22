/**
 * Budget ledger and billing separation (ADR-0013 D-7).
 *
 * Three accounts that never share a number:
 *   claude_max     — the interactive Claude Code subscription. Not metered in
 *                    USD here; counted in sessions so it is visible, never
 *                    summed with an API bill.
 *   anthropic_api  — headless automation on ANTHROPIC_API_KEY.
 *   openrouter_jev — JEV decisions on OPENROUTER_API_KEY.
 *
 * The limits are local targets, not provider-side caps: a promotional credit
 * is not a hard stop, and OpenRouter/Anthropic spend limits are set at their
 * consoles by a person (ADR-0013 "Owner actions"). The ledger stops this
 * harness from spending past its target; it cannot stop anything else.
 *
 * Amount precedence: reported > estimated > unknown. An unknown amount is
 * counted at the per-call ceiling against the budget (so it can only make the
 * harness stop sooner) and reported as unknown, never as $0.
 */
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { DecisionUsage } from '../decisions/types.ts';

export type Account = 'claude_max' | 'anthropic_api' | 'openrouter_jev';

export type AccountBudget = {
  /** Monthly target in USD; `null` for an account not metered in USD. */
  limitUsd: number | null;
  /** Held back from the limit; the harness stops at limit − reserve. */
  reserveUsd: number;
  /** What one call is counted at when its cost is unknown. */
  unknownCallCeilingUsd: number;
};

export const DEFAULT_BUDGETS: Record<Account, AccountBudget> = {
  claude_max: { limitUsd: null, reserveUsd: 0, unknownCallCeilingUsd: 0 },
  anthropic_api: { limitUsd: 100, reserveUsd: 10, unknownCallCeilingUsd: 1 },
  // $0.042 per 1M input tokens, output free (OpenRouter model page, 2026-10-22):
  // an 8k-char state is ~3k tokens ≈ $0.00013. The ceiling is ~8× that.
  openrouter_jev: { limitUsd: 2, reserveUsd: 0, unknownCallCeilingUsd: 0.001 },
};

export type LedgerEntry = {
  ts: string;
  account: Account;
  costUsd: number | null;
  costStatus: DecisionUsage['costStatus'];
  ref: string;
};

export type BudgetState = 'ok' | 'warning' | 'exhausted' | 'not_metered';

export type BudgetStatus = {
  account: Account;
  month: string;
  limitUsd: number | null;
  reserveUsd: number;
  reportedUsd: number;
  estimatedUsd: number;
  unknownCount: number;
  /** reported + estimated + unknownCount × ceiling. */
  committedUsd: number;
  /** limit − reserve − committed; `null` when not metered. */
  remainingUsd: number | null;
  state: BudgetState;
  calls: number;
};

export const WARNING_RATIO = 0.8;

export class BudgetLedger {
  readonly month: string;
  readonly #file: string | null;
  readonly #budgets: Record<Account, AccountBudget>;
  #entries: LedgerEntry[];

  /** `stateDir` null keeps the ledger in memory (tests, dry runs). */
  constructor(options: { stateDir: string | null; budgets?: Partial<Record<Account, AccountBudget>>; now?: Date }) {
    const now = options.now ?? new Date();
    this.month = now.toISOString().slice(0, 7);
    this.#budgets = { ...DEFAULT_BUDGETS, ...options.budgets };
    this.#file = options.stateDir ? join(options.stateDir, `ledger-${this.month}.json`) : null;
    this.#entries = this.#file ? load(this.#file) : [];
  }

  status(account: Account): BudgetStatus {
    const budget = this.#budgets[account];
    const mine = this.#entries.filter((e) => e.account === account);
    const sum = (status: LedgerEntry['costStatus']) =>
      mine.filter((e) => e.costStatus === status).reduce((acc, e) => acc + (e.costUsd ?? 0), 0);
    const reportedUsd = sum('reported');
    const estimatedUsd = sum('estimated');
    const unknownCount = mine.filter((e) => e.costStatus === 'unknown').length;
    const committedUsd = reportedUsd + estimatedUsd + unknownCount * budget.unknownCallCeilingUsd;
    const calls = mine.filter((e) => e.costStatus !== 'not_sent').length;
    if (budget.limitUsd === null) {
      return { account, month: this.month, limitUsd: null, reserveUsd: 0, reportedUsd, estimatedUsd, unknownCount, committedUsd, remainingUsd: null, state: 'not_metered', calls };
    }
    const spendable = budget.limitUsd - budget.reserveUsd;
    const remainingUsd = spendable - committedUsd;
    const state: BudgetState = remainingUsd <= 0 ? 'exhausted' : committedUsd >= spendable * WARNING_RATIO ? 'warning' : 'ok';
    return { account, month: this.month, limitUsd: budget.limitUsd, reserveUsd: budget.reserveUsd, reportedUsd, estimatedUsd, unknownCount, committedUsd, remainingUsd, state, calls };
  }

  /** May one more call, counted at its ceiling, start? */
  canSpend(account: Account, estimateUsd?: number): boolean {
    const s = this.status(account);
    if (s.remainingUsd === null) return true;
    return s.remainingUsd - (estimateUsd ?? this.#budgets[account].unknownCallCeilingUsd) >= 0;
  }

  record(account: Account, usage: Pick<DecisionUsage, 'costUsd' | 'costStatus'>, ref: string): void {
    if (usage.costStatus === 'not_sent') return;
    const costUsd = usage.costStatus === 'unknown' ? null : usage.costUsd;
    this.#entries.push({ ts: new Date().toISOString(), account, costUsd, costStatus: usage.costStatus, ref });
    if (this.#file) save(this.#file, this.#entries);
  }
}

function load(file: string): LedgerEntry[] {
  try {
    const parsed = JSON.parse(readFileSync(file, 'utf8')) as { entries?: LedgerEntry[] };
    return Array.isArray(parsed.entries) ? parsed.entries : [];
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === 'ENOENT') return [];
    // A ledger we cannot read is not an empty ledger: refuse to spend on it.
    throw new Error(`budget ledger ${file} is unreadable; fix or move it before spending`);
  }
}

function save(file: string, entries: LedgerEntry[]): void {
  mkdirSync(join(file, '..'), { recursive: true });
  const tmp = `${file}.tmp`;
  writeFileSync(tmp, JSON.stringify({ entries }, null, 2));
  renameSync(tmp, file);
}

export type BillingMode = 'interactive' | 'automation';
export type BillingCheck = { ok: boolean; problems: string[] };

/**
 * Keep the three billing paths apart (ADR-0013 D-7).
 *
 * Interactive Claude Code runs on the Max subscription; an ANTHROPIC_API_KEY in
 * that environment can move the session onto API billing, so it is refused
 * there. Automation must have its own key, and must not reach Anthropic
 * through OpenRouter or reuse the OpenRouter key.
 */
export function checkBillingSeparation(mode: BillingMode, env: Record<string, string | undefined>): BillingCheck {
  const problems: string[] = [];
  const anthropic = env.ANTHROPIC_API_KEY;
  const openrouter = env.OPENROUTER_API_KEY;
  if (mode === 'interactive' && anthropic) {
    problems.push('ANTHROPIC_API_KEY is set in an interactive session: Claude Code may bill the API instead of the Max subscription');
  }
  if (mode === 'automation' && !anthropic) problems.push('automation needs ANTHROPIC_API_KEY (via exec-with.sh), none is set');
  if (anthropic && openrouter && anthropic === openrouter) problems.push('ANTHROPIC_API_KEY and OPENROUTER_API_KEY hold the same value');
  if (anthropic?.startsWith('sk-or-')) problems.push('ANTHROPIC_API_KEY holds an OpenRouter key');
  if (/openrouter\.ai/i.test(env.ANTHROPIC_BASE_URL ?? '')) {
    problems.push('ANTHROPIC_BASE_URL routes Anthropic traffic through OpenRouter; not the default and not authorized');
  }
  return { ok: problems.length === 0, problems };
}
