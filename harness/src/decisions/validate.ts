/**
 * Request and response validation for the Decisions contract.
 *
 * The response rules follow the official reference: check `type` before
 * reading fields, treat a missing key or an unexpected `type` as an error
 * rather than a default, read the optional fields through a presence check.
 * Beyond that, an answer must belong to the question that was asked — a choice
 * outside the criteria, a probability map over different keys, or a number
 * outside [0, 1] means the response is not one we can act on.
 *
 * An invalid response is an error, never a guess. The router turns it into
 * its deterministic fallback.
 */
import type { Answer, DecisionRequest, Json, Question } from './types.ts';

export class ContractError extends Error {}

export function validateRequest(request: DecisionRequest): void {
  const keys = Object.keys(request.questions);
  if (keys.length === 0) throw new ContractError('questions must be a non-empty object');
  for (const key of keys) {
    const q = request.questions[key] as Question;
    if (isEmptyCriterion(q.instructions)) throw new ContractError(`${key}: instructions are required`);
    switch (q.type) {
      case 'noul':
        if (q.criteria) {
          const extra = Object.keys(q.criteria).filter((k) => k !== 'true' && k !== 'false');
          if (extra.length > 0 || !('true' in q.criteria) || !('false' in q.criteria)) {
            throw new ContractError(`${key}: noul criteria need exactly true and false`);
          }
        }
        break;
      case 'choice':
        if (Object.keys(q.criteria).length < 2) throw new ContractError(`${key}: choice needs at least two options`);
        break;
      case 'score':
        if (!Array.isArray(q.criteria) || q.criteria.length < 2) {
          throw new ContractError(`${key}: score needs at least two ordered levels`);
        }
        break;
      default:
        throw new ContractError(`${key}: unknown question type`);
    }
  }
}

/** Parse `answers` from a raw response body against the request that produced it. */
export function parseAnswers(request: DecisionRequest, raw: unknown): Record<string, Answer> {
  if (!isRecord(raw)) throw new ContractError('answers is not an object');
  const expected = Object.keys(request.questions);
  const missing = expected.filter((k) => !(k in raw));
  const extra = Object.keys(raw).filter((k) => !(k in request.questions));
  if (missing.length > 0) throw new ContractError(`missing answers: ${missing.join(', ')}`);
  if (extra.length > 0) throw new ContractError(`unexpected answers: ${extra.join(', ')}`);

  const out: Record<string, Answer> = {};
  for (const key of expected) {
    out[key] = parseAnswer(key, request.questions[key] as Question, raw[key]);
  }
  return out;
}

function parseAnswer(key: string, question: Question, value: unknown): Answer {
  if (!isRecord(value)) throw new ContractError(`${key}: answer is not an object`);
  if (value.type !== question.type) {
    throw new ContractError(`${key}: answer type ${String(value.type)} for a ${question.type} question`);
  }
  switch (question.type) {
    case 'noul':
      return { type: 'noul', noul: unit(key, 'noul', value.noul) };
    case 'choice': {
      if (typeof value.choice !== 'string' || !(value.choice in question.criteria)) {
        throw new ContractError(`${key}: choice is not one of the options`);
      }
      const options = Object.keys(question.criteria);
      return {
        type: 'choice',
        choice: value.choice,
        ...optional('probabilities', value.probabilities, (v) => distribution(key, options, v)),
        ...optional('confidence', value.confidence, (v) => unit(key, 'confidence', v)),
      };
    }
    case 'score': {
      const levels = question.criteria.map((_, i) => String(i));
      const score = finite(key, 'score', value.score);
      if (score < 0 || score > levels.length - 1) throw new ContractError(`${key}: score outside the levels`);
      return {
        type: 'score',
        score,
        ...optional('probabilities', value.probabilities, (v) => distribution(key, levels, v)),
        ...optional('legend', value.legend, (v) => legend(key, levels, v)),
        ...optional('confidence', value.confidence, (v) => unit(key, 'confidence', v)),
      };
    }
  }
}

function optional<K extends string, T>(name: K, value: unknown, parse: (v: unknown) => T): { [P in K]?: T } {
  if (value === undefined || value === null) return {};
  return { [name]: parse(value) } as { [P in K]?: T };
}

function distribution(key: string, options: string[], value: unknown): Record<string, number> {
  if (!isRecord(value)) throw new ContractError(`${key}: probabilities is not an object`);
  sameKeys(key, 'probabilities', options, value);
  const out: Record<string, number> = {};
  for (const option of options) out[option] = unit(key, `probabilities.${option}`, value[option]);
  return out;
}

function legend(key: string, levels: string[], value: unknown): Record<string, Json> {
  if (!isRecord(value)) throw new ContractError(`${key}: legend is not an object`);
  sameKeys(key, 'legend', levels, value);
  return value as Record<string, Json>;
}

function sameKeys(key: string, field: string, expected: string[], value: Record<string, unknown>): void {
  const keys = Object.keys(value);
  if (keys.length !== expected.length || expected.some((k) => !(k in value))) {
    throw new ContractError(`${key}: ${field} keys do not match the question`);
  }
}

function unit(key: string, field: string, value: unknown): number {
  const n = finite(key, field, value);
  if (n < 0 || n > 1) throw new ContractError(`${key}: ${field} outside [0, 1]`);
  return n;
}

function finite(key: string, field: string, value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new ContractError(`${key}: ${field} is not a finite number`);
  return value;
}

function isEmptyCriterion(value: Json | undefined): boolean {
  return value === undefined || value === null || (typeof value === 'string' && value.trim() === '');
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
