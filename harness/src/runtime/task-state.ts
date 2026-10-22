/**
 * Per-task state between CLI checkpoint calls (PR #242 F-02).
 *
 * Each `decide` is its own process, so the loop counters and the decision
 * cache live in a file keyed by task id under HARNESS_STATE_DIR. Without it
 * the third repeated failure of a task reads as the first, and unchanged
 * context is asked again on every call.
 */
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { RouterDecision } from '../router/router.ts';
import type { LoopSnapshot } from './loop.ts';

export type TaskState = { taskId: string; loop: LoopSnapshot | null; cache: Array<[string, RouterDecision]> };

/** Readable and collision-free: `GoGo-BE#709` and `GoGo-BE_709` get different files. */
export function taskStateFile(stateDir: string, taskId: string): string {
  const slug = taskId.replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 60);
  const digest = createHash('sha256').update(taskId).digest('hex').slice(0, 12);
  return join(stateDir, 'tasks', `${slug}-${digest}.json`);
}

export function loadTaskState(stateDir: string, taskId: string): TaskState {
  const file = taskStateFile(stateDir, taskId);
  try {
    const parsed = JSON.parse(readFileSync(file, 'utf8')) as TaskState;
    if (parsed.taskId !== taskId) throw new Error(`task state ${file} belongs to ${parsed.taskId}`);
    return parsed;
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === 'ENOENT') return { taskId, loop: null, cache: [] };
    // Unreadable counters are not fresh counters: refuse rather than reset the limits.
    throw new Error(`task state ${file} is unreadable; fix or move it before continuing`);
  }
}

export function saveTaskState(stateDir: string, state: TaskState): void {
  const file = taskStateFile(stateDir, state.taskId);
  mkdirSync(join(stateDir, 'tasks'), { recursive: true });
  const tmp = `${file}.tmp`;
  writeFileSync(tmp, JSON.stringify(state, null, 2));
  renameSync(tmp, file);
}
