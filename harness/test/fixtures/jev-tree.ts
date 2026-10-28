// A version tree for the prompt hook tests (PR #254 shape rev 3, I6): the four closure files and a
// MANIFEST as #253 writes it, passed to observePrompt as `treeRoot`. The wrapper is a stand-in
// unless a test copies the real files in.
import { createHash } from 'node:crypto';
import { chmodSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { WRAPPER_CLOSURE } from '../../src/shadow/prompt-observation.ts';

export const CLOSURE = WRAPPER_CLOSURE;

/** MANIFEST schema 2 (`files[path] = { sha256, exec }`) for `paths`, default the four closure files. */
export function writeManifest(tree: string, paths: readonly string[] = CLOSURE): void {
  const files: Record<string, { sha256: string; exec: boolean }> = {};
  // The exec bit as found, like the launcher's buildManifest (#253 schema 2).
  for (const p of paths) files[p] = { sha256: createHash('sha256').update(readFileSync(join(tree, p))).digest('hex'), exec: (statSync(join(tree, p)).mode & 0o100) !== 0 };
  writeFileSync(join(tree, 'MANIFEST'), `${JSON.stringify({ schema: 2, sha: 'f'.repeat(40), files }, null, 2)}\n`);
}

/**
 * Stand-in for scripts/secrets/exec-with.sh, same arguments; hands the
 * command the key and preloads `stub`. Paths are literal: the child
 * environment is an allowlist, so there is no environment seam.
 */
export function standInWrapper(stub: string, before = ''): string {
  return `#!/bin/sh
# Stand-in for scripts/secrets/exec-with.sh: tools <path> -- <command…>
${before}[ "$1" = tools ] && [ "$2" = ai-harness/openrouter-api-key ] && [ "$3" = -- ] || exit 9
shift 3
node="$1"; shift
OPENROUTER_API_KEY=sk-or-v1-faketestkeyfaketest exec "$node" --import '${stub}' "$@"
`;
}

/** A fetch stub that logs each request to `fetchLog` and answers `answers`. */
export function fetchStub(fetchLog: string, answers: unknown): string {
  return `import { appendFileSync } from 'node:fs';
globalThis.fetch = async (url, init) => {
  appendFileSync(${JSON.stringify(fetchLog)}, JSON.stringify({ url: String(url), hasKey: Boolean(process.env.OPENROUTER_API_KEY), body: JSON.parse(init.body) }) + '\\n');
  return new Response(JSON.stringify({ id: 'gen-1', model: 'typesafe/jev-1.14-20261014', provider: 'TypeSafe', answers: ${JSON.stringify(answers)}, usage: { input_tokens: 100, output_tokens: 20, cost: 0.00003 } }), { status: 200, headers: { 'content-type': 'application/json' } });
};
`;
}

/** `<tree>` with the wrapper body given, stand-in other closure files, and its MANIFEST. Returns the wrapper path. */
export function closureTree(tree: string, wrapperBody: string): string {
  for (const p of CLOSURE) mkdirSync(join(tree, dirname(p)), { recursive: true });
  const wrapper = join(tree, CLOSURE[0]);
  writeFileSync(wrapper, wrapperBody);
  chmodSync(wrapper, 0o755);
  writeFileSync(join(tree, CLOSURE[1]), '# stand-in common.sh\n');
  writeFileSync(join(tree, CLOSURE[2]), 'import os\n');
  writeFileSync(join(tree, CLOSURE[3]), 'parameters: []\n');
  writeManifest(tree);
  return wrapper;
}
