import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { mapAnswers, THRESHOLDS } from '../src/router/router.ts';
import type { RouterInput } from '../src/router/router.ts';
import { intakeAnswers, summary } from './helpers.ts';

/**
 * ADR-0013 D-10, option B (owner decision 2026-10-23): a person approves when the
 * most probable risk level reaches riskApprovalLevel OR P(level ≥ riskApprovalLevel)
 * reaches riskApprovalMinP. Distributions are the ones JEV returned in the live probe
 * runs on GoGo-Infra#241 (2026-10-23), rounded as reported.
 */
type P4 = [number, number, number, number];
const risk = (p: P4) => ({
  type: 'score',
  score: p[1] + 2 * p[2] + 3 * p[3],
  probabilities: { '0': p[0], '1': p[1], '2': p[2], '3': p[3] },
  confidence: Math.max(...p),
});

const input: RouterInput = {
  taskId: 'T-1',
  checkpoint: 'ambiguity',
  summary: summary({ openQuestions: ['q'], searchedSources: [] }),
  actions: [{ kind: 'read' }],
};

const decide = (p: P4) => mapAnswers(input, { ...intakeAnswers(), risk: risk(p) } as never, null);

describe('risk gate (D-10 option B)', () => {
  it('keeps the gate at level 2 and adds a 0.5 cumulative floor', () => {
    assert.equal(THRESHOLDS.riskApprovalLevel, 2);
    assert.equal(THRESHOLDS.riskApprovalMinP, 0.5);
  });

  it('a flat distribution whose argmax is "serious" still escalates (probe p04: no approval is dropped)', () => {
    // .32/.24/.34/.10: argmax 2, P(≥2) = 0.44 — escalated before, escalates now.
    const d = decide([0.32, 0.24, 0.34, 0.1]);
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
    assert.match(d.reasons[0] ?? '', /risk level 2 ≥ 2/);
  });

  it('every serious live probe escalates', () => {
    for (const p of [
      [0.22, 0.22, 0.48, 0.08],
      [0.01, 0.42, 0.5, 0.07],
      [0, 0, 0.57, 0.43],
      [0, 0, 0.08, 0.92],
      [0, 0, 0.38, 0.62],
    ] as const) {
      assert.equal(decide([...p]).outcome, 'HUMAN_APPROVAL', `P=${p.join('/')}`);
    }
  });

  it('mass split across 1 and 3 escalates even though level 1 is the argmax', () => {
    // .10/.40/.10/.40: argmax 1 (tie broken low) passed before; P(≥2) = 0.5 escalates now.
    const d = decide([0.1, 0.4, 0.1, 0.4]);
    assert.equal(d.outcome, 'HUMAN_APPROVAL');
    assert.match(d.reasons[0] ?? '', /P\(risk ≥ 2\) = 0\.5 ≥ 0\.5/);
  });

  it('low-risk live probes do not escalate on risk', () => {
    for (const p of [
      [0.83, 0.17, 0, 0],
      [0.06, 0.94, 0, 0],
      [0.35, 0.45, 0.19, 0.01],
    ] as const) {
      const d = decide([...p]);
      assert.ok(!d.reasons.some((r) => /JEV (risk level|P\(risk)/.test(r)), `P=${p.join('/')}: ${d.reasons.join('; ')}`);
    }
  });

  it('without a distribution it falls back to the rounded position', () => {
    const at = (score: number) => mapAnswers(input, { ...intakeAnswers(), risk: { type: 'score', score } } as never, null);
    assert.equal(at(1.6).outcome, 'HUMAN_APPROVAL');
    assert.notEqual(at(1.4).outcome, 'HUMAN_APPROVAL');
  });
});
