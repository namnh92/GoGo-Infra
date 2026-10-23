/**
 * Harness CLI — the checkpoint entry point for a Claude Code session or an
 * automation job.
 *
 *   node harness/src/cli.ts decide  --input task.json [--fixture fixture.json]
 *   node harness/src/cli.ts status
 *   node harness/src/cli.ts billing --mode interactive|automation
 *   node harness/src/cli.ts handoff --input handoff.json --out docs/handoffs/<file>.md
 *   node harness/src/cli.ts prompt-hook < hook.json   # #247 UserPromptSubmit hook: always exit 0
 *   node harness/src/cli.ts jev-prompt setup|on [--for 8h]|off|status   # owner opt-in for prompts
 *
 * Live mode, through the SSM wrapper so the key reaches this process only:
 *
 *   JEV_MODE=live JEV_LIVE_AUTHORIZED=yes JEV_PRIVACY_REVIEWED=yes \
 *     ./scripts/secrets/exec-with.sh dev ai-harness/openrouter-api-key -- \
 *     node harness/src/cli.ts decide --input task.json
 *
 * The outcome is advisory (ADR-0013 D-1): the input declares its own actions
 * and authorizations. Write actions are re-classified from their targets,
 * spelled from `repoRoot` (default: the working directory) and placed in the
 * checkout that directory belongs to — `cd harness` does not turn
 * `src/cli.ts` into an ordinary in-scope file (PR #242 A-F-03).
 *
 * Exit codes: 0 AUTO_EXECUTE, 10 RESEARCH_AND_CONTINUE, 20 HUMAN_APPROVAL,
 * 2 usage or configuration error — so a hook or a script can branch on it.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { createProvider, loadConfig } from './config.ts';
import type { MockFixture, MockOutcome } from './decisions/mock.ts';
import { DecisionRouter } from './router/router.ts';
import type { RouterInput } from './router/router.ts';
import { BudgetLedger, checkBillingSeparation } from './runtime/budget.ts';
import type { BillingMode } from './runtime/budget.ts';
import { writeHandoff } from './runtime/handoff.ts';
import type { Handoff } from './runtime/handoff.ts';
import { LoopController } from './runtime/loop.ts';
import { JsonlSink, summarize } from './runtime/metrics.ts';
import { withStateLock } from './runtime/lock.ts';
import { loadTaskState, saveTaskState } from './runtime/task-state.ts';
import { jevPromptCommand } from './shadow/jev-optin.ts';
import { runLiveChild } from './shadow/prompt-live.ts';
import { observePrompt } from './shadow/prompt-observation.ts';

const EXIT = { AUTO_EXECUTE: 0, RESEARCH_AND_CONTINUE: 10, HUMAN_APPROVAL: 20 } as const;

async function main(argv: string[]): Promise<number> {
  const [command, ...rest] = argv;
  // Prompt hook (#247): before argument parsing and config, so neither the environment nor a
  // bad flag can turn sending on, print, or exit non-zero; only the owner's opt-in sends.
  if (command === 'prompt-hook') {
    if (rest[0] === '--live-child') {
      const at = rest.indexOf('--observation');
      process.stdout.write(`${JSON.stringify(await runLiveChild({ input: process.stdin, env: process.env, observationId: rest[at + 1] ?? '' }))}\n`);
      return 0;
    }
    process.stdout.write(await observePrompt({ input: process.stdin, env: process.env }));
    return 0;
  }
  if (command === 'jev-prompt') return jevPromptCommand(rest, process.env);
  const { values } = parseArgs({
    args: rest,
    options: { input: { type: 'string' }, fixture: { type: 'string' }, out: { type: 'string' }, mode: { type: 'string' } },
  });
  const config = loadConfig(process.env);
  const sink = new JsonlSink(join(config.stateDir, 'decisions.jsonl'));

  switch (command) {
    case 'decide': {
      if (!values.input) throw new Usage('decide needs --input <task.json>');
      const input = JSON.parse(readFileSync(values.input, 'utf8')) as RouterInput;
      // The directory the targets are spelled from; the policy engine finds the checkout root above it.
      input.repoRoot ??= process.cwd();
      const fixture = values.fixture ? fixtureFrom(values.fixture) : undefined;
      // Load, check limits, decide and persist under one lock (PR #242 r2 F-04):
      // the ledger and the task counters are read inside it, never before.
      const decision = await withStateLock(config.stateDir, async () => {
        const ledger = new BudgetLedger({ stateDir: config.stateDir, budgets: config.budgets });
        const saved = loadTaskState(config.stateDir, input.taskId);
        const loop = new LoopController({}, Date.now, saved.loop ?? undefined);
        const cache = new Map(saved.cache);
        const persist = () => saveTaskState(config.stateDir, { taskId: input.taskId, loop: loop.snapshot(), cache: [...cache] });
        const router = new DecisionRouter({ provider: createProvider(config, process.env, fixture), ledger, loop, sink, cache, persist });
        const result = await router.decide(input);
        persist();
        return result;
      });
      process.stdout.write(`${JSON.stringify(decision, null, 2)}\n`);
      return EXIT[decision.outcome];
    }
    case 'status': {
      const ledger = new BudgetLedger({ stateDir: config.stateDir, budgets: config.budgets });
      const status = { month: ledger.month, budgets: (['openrouter_jev', 'anthropic_api', 'claude_max'] as const).map((a) => ledger.status(a)), decisions: summarize(sink.read()) };
      process.stdout.write(`${JSON.stringify(status, null, 2)}\n`);
      return 0;
    }
    case 'billing': {
      const mode = (values.mode ?? 'interactive') as BillingMode;
      if (mode !== 'interactive' && mode !== 'automation') throw new Usage('--mode is interactive or automation');
      const check = checkBillingSeparation(mode, process.env);
      process.stdout.write(`${JSON.stringify(check, null, 2)}\n`);
      return check.ok ? 0 : 20;
    }
    case 'handoff': {
      if (!values.input || !values.out) throw new Usage('handoff needs --input <handoff.json> --out <file.md>');
      writeHandoff(values.out, JSON.parse(readFileSync(values.input, 'utf8')) as Handoff);
      return 0;
    }
    default:
      throw new Usage('commands: decide | status | billing | handoff | prompt-hook | jev-prompt');
  }
}

/** A fixture file maps checkpoint → outcome, so a dry run exercises every path without a key. */
function fixtureFrom(file: string): MockFixture {
  const table = JSON.parse(readFileSync(file, 'utf8')) as Record<string, MockOutcome>;
  return (request) => {
    const keys = Object.keys(request.questions).sort().join(',');
    const outcome = table[keys] ?? table['*'];
    if (!outcome) throw new Error(`fixture has no entry for questions ${keys}`);
    return outcome;
  };
}

class Usage extends Error {}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (e: unknown) => {
    process.stderr.write(`harness: ${(e as Error).message}\n`);
    process.exit(2);
  },
);
