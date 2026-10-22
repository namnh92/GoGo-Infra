/**
 * Durable handoff (ADR-0013 D-9).
 *
 * A handoff is the record the next session — on another machine, or a person —
 * starts from. It lists what was decided and by whom (policy, JEV, fallback),
 * the evidence, what is blocked and why, and the next step. It holds no state
 * contents and no credential; it is redacted again on the way out in case a
 * caller pasted an error message that carried one.
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import type { RouterDecision } from '../router/router.ts';
import { redact } from './sanitize.ts';

export type Handoff = {
  taskId: string;
  title: string;
  status: 'in_progress' | 'blocked' | 'awaiting_approval' | 'done';
  issue?: string;
  branch?: string;
  done: string[];
  evidence: string[];
  decisions: Array<{ checkpoint: string; decision: RouterDecision }>;
  blockers: string[];
  next: string[];
};

export function renderHandoff(h: Handoff, now: Date = new Date()): string {
  const list = (items: string[]) => (items.length === 0 ? '- (none)' : items.map((i) => `- ${i}`).join('\n'));
  const decisions =
    h.decisions.length === 0
      ? '- (none)'
      : h.decisions
          .map(({ checkpoint, decision: d }) => {
            const gates = d.policyGates.map((g) => g.kind).join(', ') || 'none';
            return `- \`${checkpoint}\` → **${d.outcome}** (source: ${d.source}; policy gates: ${gates}${d.fallback ? `; fallback: ${d.errorCategory ?? 'rules'}` : ''})${d.reasons.length ? ` — ${d.reasons.join('; ')}` : ''}`;
          })
          .join('\n');
  const text = `# Handoff — ${h.title}

- Task: \`${h.taskId}\`${h.issue ? ` · Issue: ${h.issue}` : ''}${h.branch ? ` · Branch: \`${h.branch}\`` : ''}
- Status: **${h.status}**
- Written: ${now.toISOString()}

## Done
${list(h.done)}

## Evidence
${list(h.evidence)}

## Decisions
${decisions}

## Blockers
${list(h.blockers)}

## Next
${list(h.next)}
`;
  return redact(text);
}

export function writeHandoff(file: string, h: Handoff, now?: Date): void {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, renderHandoff(h, now));
}
