/**
 * The judgments the harness asks JEV, per checkpoint (ADR-0013 D-4).
 *
 * Each question is one narrow judgment over the sanitized task summary in
 * `state`. Facts the harness already holds — which actions are gated, how many
 * attempts were made, whether the budget allows a call — are never asked; the
 * policy engine and the loop controller own them. Question keys are for code
 * and are not sent to the model as meaning, so every question carries its own.
 */
import type { ChoiceQuestion, NoulQuestion, Question, ScoreQuestion } from '../decisions/types.ts';

export type Checkpoint = 'intake' | 'scope_change' | 'ambiguity' | 'repeated_failure' | 'review_planning';
export const CHECKPOINTS: readonly Checkpoint[] = ['intake', 'scope_change', 'ambiguity', 'repeated_failure', 'review_planning'];

export const TASK_KIND: ChoiceQuestion = {
  type: 'choice',
  instructions: 'What kind of engineering work does `task` ask for?',
  criteria: {
    bugfix: 'Correct behaviour that is wrong today.',
    feature: 'Add a capability that does not exist yet.',
    refactor: 'Restructure code without changing behaviour.',
    docs: 'Write or correct documentation only.',
    test: 'Add or repair tests only.',
    investigation: 'Find out why something happens or how it works, without a change decided yet.',
    ops: 'Change infrastructure, deployment, secrets or provider configuration.',
    not_stated: 'The task does not say enough to tell.',
  },
};

export const CLARITY: ScoreQuestion = {
  type: 'score',
  instructions:
    'How completely does `task` (title, description, acceptance_criteria, open_questions) define what done means for an engineer who can read the repository?',
  criteria: [
    'The goal itself is unclear: two engineers would build different things.',
    'The goal is clear but there is no way to tell when it is done.',
    'Goal and done are clear; remaining details can be found in the repository, docs or issues.',
    'Goal, done and approach are fully specified.',
  ],
};

export const MISSING_CONTEXT: ChoiceQuestion = {
  type: 'choice',
  instructions:
    'What does an engineer still need before starting `task`? `context_already_searched` lists what was already looked at. Judge what is missing, not what is merely unmentioned.',
  criteria: {
    none: 'Nothing material is missing.',
    discoverable: 'Missing facts are of the kind found by reading code, docs, issues or earlier handoffs.',
    product_decision: 'A product, pricing, UX or policy choice that only the owner can make and the sources do not settle.',
    access: 'Credentials, an account, paid usage or another permission the engineer does not hold.',
  },
};

export const REVERSIBLE_DEFAULT: NoulQuestion = {
  type: 'noul',
  instructions:
    'Do `task` and `project_rules` already authorize a safe default for the open question — one that can be undone later without data loss, cost or user-visible harm?',
  criteria: {
    true: 'A specific default is named or clearly implied by the task or the rules, and choosing it is reversible.',
    false: 'No default is authorized, or every option is hard to undo.',
  },
};

export const RISK: ScoreQuestion = {
  type: 'score',
  instructions:
    'If the change described by `task` were wrong, how bad would the consequence be for GoGo users, data or money?',
  criteria: [
    'Contained: a failing test or a reverted commit, nothing reaches users.',
    'Limited: a development environment or an internal tool misbehaves until fixed.',
    'Serious: user data, privacy, money, authentication or a shared environment is affected.',
    'Severe: production outage, data loss, leaked credentials or a legal exposure.',
  ],
};

export const WORKFLOW: ChoiceQuestion = {
  type: 'choice',
  instructions: 'Which way of working fits `task` best right now?',
  criteria: {
    implement: 'Implement directly within the stated scope.',
    research_first: 'Read code, docs or issues first, then implement.',
    spike: 'Build a small throwaway experiment to learn before committing to an approach.',
    clarify: 'Ask the owner first; implementing now would likely be wasted.',
  },
};

export const REVIEW_LEVEL: ChoiceQuestion = {
  type: 'choice',
  instructions: 'What review should the change described by `task` get before a person accepts it?',
  criteria: {
    self_review: 'An adversarial re-read of the diff plus the automated checks is enough.',
    targeted_review: 'One focused automated or peer review of the risky part.',
    human_review: 'A person with domain ownership must review the change itself.',
  },
};

export const FAILURE_NATURE: ChoiceQuestion = {
  type: 'choice',
  instructions:
    'Given `failure` and `task`, what kind of failure is this? A failure in code the task changes is in scope even if the error appears elsewhere.',
  criteria: {
    fixable_in_scope: 'Caused by the change itself or code the task owns; a different fix can resolve it.',
    environment: 'Caused by the environment, a dependency download, a runner or a service outside the code.',
    outside_scope: 'Caused by code or a decision the task does not own, or needs an owner decision to resolve.',
  },
};

export function questionsFor(checkpoint: Checkpoint): Record<string, Question> {
  switch (checkpoint) {
    case 'intake':
    case 'scope_change':
    case 'ambiguity':
      return {
        task_kind: TASK_KIND,
        clarity: CLARITY,
        missing_context: MISSING_CONTEXT,
        reversible_default: REVERSIBLE_DEFAULT,
        risk: RISK,
        workflow: WORKFLOW,
      };
    case 'repeated_failure':
      return { failure_nature: FAILURE_NATURE, risk: RISK };
    case 'review_planning':
      return { review_level: REVIEW_LEVEL, risk: RISK };
  }
}
