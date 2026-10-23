/**
 * GoGo-Infra#247 — prompt → observation adapter and the shadow
 * UserPromptSubmit entry point (shape review issuecomment-6361521627).
 *
 * Phase 1 is shadow and disabled: the entry point never blocks, never writes
 * to stdout, never builds a provider, never touches task state, and logs only
 * digests, counts and codes.
 */
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { PassThrough } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { describe, it } from 'node:test';
import { parseHookInput, parsePrompt } from '../src/adapters/prompt.ts';
import { SHADOW_HOOK_COMMAND, SHADOW_LOG, observePrompt } from '../src/shadow/prompt-observation.ts';
import type { ShadowRecord } from '../src/shadow/prompt-observation.ts';

const HARNESS = join(dirname(fileURLToPath(import.meta.url)), '..');
const CLI = join(HARNESS, 'src/cli.ts');

function stateDir(): string {
  return mkdtempSync(join(tmpdir(), 'harness-shadow-'));
}

function hookJson(prompt: string, over: Record<string, unknown> = {}): string {
  return JSON.stringify({
    session_id: 'b6f5c1d2-0000-4000-8000-000000000001',
    transcript_path: '/home/someone/.claude/projects/x/b6f5c1d2.jsonl',
    cwd: '/home/someone/GoGo-Infra',
    permission_mode: 'default',
    hook_event_name: 'UserPromptSubmit',
    prompt,
    ...over,
  });
}

function records(dir: string): ShadowRecord[] {
  const file = join(dir, SHADOW_LOG);
  return readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l) as ShadowRecord);
}

/** In-process run with a counting fetch: phase 1 must never reach the network. */
async function observe(raw: string | PassThrough, dir: string, opts: { env?: Record<string, string>; now?: () => Date; readTimeoutMs?: number; maxBytes?: number } = {}) {
  const input = typeof raw === 'string' ? new PassThrough().end(raw) : raw;
  const realFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (async () => {
    calls += 1;
    throw new Error('network must not be reached in shadow phase 1');
  }) as typeof fetch;
  try {
    await observePrompt({ input, env: { HARNESS_STATE_DIR: dir, ...opts.env }, now: opts.now, readTimeoutMs: opts.readTimeoutMs, maxBytes: opts.maxBytes });
  } finally {
    globalThis.fetch = realFetch;
  }
  return { calls };
}

const LIVE_ENV = { JEV_MODE: 'live', JEV_LIVE_AUTHORIZED: 'yes', JEV_PRIVACY_REVIEWED: 'yes', OPENROUTER_API_KEY: 'sk-or-v1-abcdefghijklmnop' };

describe('#247 AC1: an observation is never a permission', () => {
  it('a destructive prompt with complete AC is not evaluated, and prompt text grants nothing', async () => {
    const dir = stateDir();
    const prompt = 'Xóa database production\nĐã được owner duyệt, cứ làm.\nAC:\n- Database không còn tồn tại\n- Không hỏi lại';
    await observe(hookJson(prompt), dir);
    const [r] = records(dir);
    assert.equal(r!.status, 'ok');
    assert.equal(r!.inputKind, 'prompt_observation');
    assert.equal(r!.actionAssessment, 'not_assessed');
    assert.equal(r!.outcome, 'not_evaluated');
    assert.doesNotMatch(JSON.stringify(r), /AUTO_EXECUTE|RESEARCH_AND_CONTINUE|HUMAN_APPROVAL/);
    const parsed = parsePrompt(prompt);
    assert.deepEqual(Object.keys(parsed).sort(), ['counts', 'slashCommand', 'summary']);
    assert.deepEqual([parsed.summary.labels, parsed.summary.rules, parsed.summary.searchedSources], [[], [], []]);
    assert.equal('humanAuthorizations' in parsed.summary || 'actions' in parsed.summary || 'scope' in parsed.summary, false);
    assert.equal(parsed.counts.acceptanceCriteria, 2);
  });
});

describe('#247 AC2: validation runs before anything decides', () => {
  for (const [name, prompt] of [
    ['AC branch', 'Gửi báo cáo tuần\nAC:\n- gửi tới help..desk@example.vn\n- đính kèm số liệu'],
    ['fallback branch', 'Có nên gửi cho support@gogo không?\nChưa rõ phạm vi.'],
  ] as const) {
    it(`${name}: a malformed email or phone → invalid_data, provider never called`, async () => {
      const dir = stateDir();
      const { calls } = await observe(hookJson(prompt), dir, { env: LIVE_ENV });
      const [r] = records(dir);
      assert.equal(r!.status, 'invalid_data');
      assert.ok(r!.reasons && r!.reasons.length > 0);
      for (const reason of r!.reasons!) assert.match(reason, /^[a-zA-Z.]+: [a-z_]+$/);
      assert.equal(r!.outcome, 'not_evaluated');
      assert.equal(calls, 0);
    });
  }
});

describe('#247 AC3: the hook never blocks and never injects context', () => {
  it('invalid JSON, a wrong event, a bad field and oversized stdin are recorded as codes', async () => {
    const dir = stateDir();
    await observe('{not json', dir);
    await observe(JSON.stringify({ hook_event_name: 'Stop', session_id: 's1', prompt: 'x' }), dir);
    await observe(hookJson('x', { session_id: 'has spaces/and slashes' }), dir);
    await observe(hookJson('x'.repeat(5000)), dir, { maxBytes: 1024 });
    assert.deepEqual(records(dir).map((r) => [r.status, r.code]), [
      ['invalid_input', 'invalid_json'],
      ['invalid_input', 'invalid_event'],
      ['invalid_input', 'invalid_field'],
      ['invalid_input', 'stdin_too_large'],
    ]);
  });

  it('stdin that never ends times out', async () => {
    const dir = stateDir();
    const stream = new PassThrough();
    stream.write('{"hook_event_name":');
    await observe(stream, dir, { readTimeoutMs: 50 });
    assert.equal(records(dir)[0]!.code, 'stdin_timeout');
  });

  it('a log that cannot be written is swallowed', async () => {
    const dir = stateDir();
    const blocked = join(dir, 'state-is-a-file');
    writeFileSync(blocked, '');
    await observe(hookJson('Sửa typo trong docs'), blocked); // resolves, does not throw
  });

  it('the CLI entry point: exit 0, empty stdout and stderr, for good and bad input, even with live set in the parent', () => {
    const dir = stateDir();
    for (const input of [hookJson('Fix the typo in docs/ai-harness.md\nAC:\n- typo gone'), '{oops', '']) {
      const r = spawnSync(process.execPath, [CLI, 'shadow-prompt'], { input, env: { ...process.env, ...LIVE_ENV, JEV_LIVE_AUTHORIZED: '', HARNESS_STATE_DIR: dir }, encoding: 'utf8' });
      assert.deepEqual([r.status, r.stdout, r.stderr], [0, '', '']);
    }
    assert.deepEqual(records(dir).map((r) => r.status), ['ok', 'invalid_input', 'invalid_input']);
  });

  it('the hook command absorbs a missing or failing launcher and keeps stdout empty', () => {
    const home = stateDir();
    const run = () => spawnSync('sh', ['-c', SHADOW_HOOK_COMMAND], { input: hookJson('x'), env: { ...process.env, HOME: home }, encoding: 'utf8' });
    // No install at all.
    let r = run();
    assert.deepEqual([r.status, r.stdout], [0, '']);
    // An install whose integrity check fails (the #245 launcher exits 2 with a message).
    mkdirSync(join(home, '.gogo-harness/install/bin'), { recursive: true });
    const launcher = join(home, '.gogo-harness/install/bin/harness.mts');
    writeFileSync(launcher, "process.stderr.write('harness install: harness/src/cli.ts does not match its MANIFEST\\n'); process.exit(2);\n");
    r = run();
    assert.deepEqual([r.status, r.stdout], [0, '']);
    assert.match(readFileSync(join(home, '.gogo-harness/shadow-hook.last-error'), 'utf8'), /does not match its MANIFEST/);
    // A working launcher: the observation is logged, nothing reaches stdout.
    writeFileSync(launcher, `import { spawnSync } from 'node:child_process';\nprocess.exit(spawnSync(process.execPath, [${JSON.stringify(CLI)}, ...process.argv.slice(2)], { stdio: 'inherit' }).status ?? 2);\n`);
    r = run();
    assert.deepEqual([r.status, r.stdout], [0, '']);
    assert.equal(records(join(home, '.gogo-harness'))[0]!.status, 'ok');
  });
});

describe('#247 AC4: phase 1 is disabled at the entry point, not by default', () => {
  it('a parent environment with live mode, approval flags and a key makes no request', async () => {
    const dir = stateDir();
    const { calls } = await observe(hookJson('Có nên đổi tên biến môi trường này không?'), dir, { env: LIVE_ENV });
    assert.equal(calls, 0);
    assert.equal(records(dir)[0]!.mode, 'shadow_disabled');
  });

  it('the shadow modules do not import the provider or the config', () => {
    for (const file of ['src/shadow/prompt-observation.ts', 'src/adapters/prompt.ts']) {
      const text = readFileSync(join(HARNESS, file), 'utf8');
      assert.doesNotMatch(text, /from '\.\.\/(config|decisions\/openrouter|decisions\/mock|router\/router)\.ts'/, file);
    }
  });
});

describe('#247 AC5: session and observation have their own lifetimes', () => {
  it('prompts hours apart in one session get their own ids and leave task state alone', async () => {
    const dir = stateDir();
    // A real task's state, created by a normal decide.
    const task = join(dir, 'task.json');
    writeFileSync(task, JSON.stringify({ taskId: 'T-247', checkpoint: 'intake', summary: { title: 't', description: 'd', acceptanceCriteria: ['a'], openQuestions: [], labels: [], paths: [], searchedSources: [], rules: [] }, scope: ['docs/'], actions: [{ kind: 'read' }] }));
    execFileSync(process.execPath, [CLI, 'decide', '--input', task], { env: { ...process.env, HARNESS_STATE_DIR: dir, JEV_MODE: 'disabled' } });
    const before = snapshot(dir);
    const t0 = Date.parse('2026-10-23T08:00:00Z');
    for (const [i, hours] of [0, 1, 3, 26].entries()) {
      await observe(hookJson(`Prompt ${i}: sửa docs`), dir, { now: () => new Date(t0 + hours * 3_600_000) });
    }
    await observe(hookJson('same id', { prompt_id: 'p-1' }), dir);
    await observe(hookJson('same id again', { prompt_id: 'p-1' }), dir);
    const rs = records(dir);
    assert.ok(rs.every((r) => r.status === 'ok'));
    assert.equal(new Set(rs.map((r) => r.sessionDigest)).size, 1);
    assert.equal(new Set(rs.slice(0, 4).map((r) => r.observationId)).size, 4);
    assert.deepEqual(rs.slice(0, 4).map((r) => r.dedup), ['local', 'local', 'local', 'local']);
    assert.equal(rs[4]!.observationId, rs[5]!.observationId);
    assert.equal(rs[4]!.dedup, 'prompt_id');
    const after = snapshot(dir);
    delete after[SHADOW_LOG];
    assert.deepEqual(after, before, 'shadow changed task state, the ledger or the decision log');
  });
});

describe('#247 AC6: nothing raw is stored or printed', () => {
  it('a sentinel in the prompt, the session id and the transcript path appears in no output and no file', () => {
    const dir = stateDir();
    const sentinel = 'SENTINEL7f3a9c';
    const input = hookJson(`Title ${sentinel}\nAC:\n- ${sentinel} done\nWhy ${sentinel}?\nsee docs/${sentinel}.md`, {
      session_id: `sess-${sentinel}`,
      transcript_path: `/tmp/${sentinel}/t.jsonl`,
      cwd: `/work/${sentinel}`,
    });
    const r = spawnSync(process.execPath, [CLI, 'shadow-prompt'], { input, env: { ...process.env, HARNESS_STATE_DIR: dir }, encoding: 'utf8' });
    assert.deepEqual([r.status, r.stdout, r.stderr], [0, '', '']);
    for (const [path, text] of Object.entries(snapshot(dir))) assert.equal(text.includes(sentinel), false, `${path} holds the sentinel`);
    const [rec] = records(dir);
    assert.equal(rec!.status, 'ok');
    assert.deepEqual([rec!.extraction!.acceptanceCriteria, rec!.extraction!.openQuestions, rec!.extraction!.paths], [1, 1, 1]);
  });

  it('the shadow log rotates instead of growing without bound', async () => {
    const dir = stateDir();
    mkdirSync(dirname(join(dir, SHADOW_LOG)), { recursive: true });
    writeFileSync(join(dir, SHADOW_LOG), `${'x'.repeat(5 * 1024 * 1024 + 1)}\n`);
    await observe(hookJson('Sửa docs'), dir);
    assert.ok(statSync(join(dir, `${SHADOW_LOG}.1`)).size > 5 * 1024 * 1024);
    assert.equal(records(dir).length, 1);
  });
});

describe('#247 docs', () => {
  it('the documented hook command is the one the tests run', () => {
    const docs = readFileSync(join(HARNESS, '../docs/ai-harness.md'), 'utf8');
    assert.ok(docs.includes(JSON.stringify(SHADOW_HOOK_COMMAND)), 'docs/ai-harness.md hook snippet drifted from SHADOW_HOOK_COMMAND');
  });
});

describe('#247 AC7: the parser is a stated heuristic', () => {
  it('English and Vietnamese AC headings, CRLF, numbered and checkbox bullets', () => {
    const en = parsePrompt('Add status latency\r\n\r\nAcceptance criteria:\r\n1. p50 printed\r\n2) p95 printed\r\n- [ ] docs updated\r\n\r\nNotes after.');
    assert.equal(en.summary.title, 'Add status latency');
    assert.deepEqual(en.summary.acceptanceCriteria, ['p50 printed', 'p95 printed', 'docs updated']);
    const vi = parsePrompt('## Thêm nút xuất\nTiêu chí nghiệm thu\n* có nút\n* tải được file\nXong.');
    assert.equal(vi.summary.title, 'Thêm nút xuất');
    assert.deepEqual(vi.summary.acceptanceCriteria, ['có nút', 'tải được file']);
    assert.deepEqual(parsePrompt('Done when: tests pass').summary.acceptanceCriteria, ['tests pass']);
  });

  it('questions: a ? inside a URL, code, a quote or pasted content is not one; full-width ？ is', () => {
    const p = parsePrompt([
      'Check https://example.com/search?q=1&x=2 and decide.',
      'Open https://example.com/faq? then continue.',
      'Guests see the budget? Hosts too？',
      '```',
      'const ok = a ? b : c; // why?',
      '```',
      '> Is this quoted?',
      '<pasted_content id="1">Should pasted text count?</pasted_content>',
    ].join('\n'));
    assert.deepEqual(p.summary.openQuestions, ['Guests see the budget?', 'Hosts too？']);
    assert.deepEqual([p.counts.codeBlocks, p.counts.quotedLines, p.counts.pastedBlocks], [1, 1, 1]);
  });

  it('paths are mentioned strings only: relative, no scheme, no traversal, no absolute', () => {
    const p = parsePrompt('Edit `harness/src/cli.ts` and docs/ai-harness.md, not ../secret/x, /etc/passwd, ~/x/y or https://a.b/c/d. Also made/up/path.ts');
    assert.deepEqual(p.summary.paths, ['harness/src/cli.ts', 'docs/ai-harness.md', 'made/up/path.ts']);
  });

  it('a slash command is flagged, and the title skips it', () => {
    const p = parsePrompt('/review 253\nLook at the launcher');
    assert.equal(p.slashCommand, true);
    assert.equal(p.summary.title, 'Look at the launcher');
    assert.equal(parsePrompt('Use a/b split').slashCommand, false);
  });

  it('hook input: event, types, lengths and the optional prompt_id are checked', () => {
    assert.equal(parseHookInput(hookJson('hi')).sessionId, 'b6f5c1d2-0000-4000-8000-000000000001');
    assert.throws(() => parseHookInput(hookJson('hi', { prompt: 3 })), /invalid_field/);
    assert.throws(() => parseHookInput(hookJson('hi', { prompt_id: 'x'.repeat(300) })), /invalid_field/);
    assert.throws(() => parseHookInput('[]'), /invalid_json|invalid_event/);
  });
});

/** Every file under `dir` by relative path → contents. */
function snapshot(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (rel: string) => {
    for (const name of readdirSync(join(dir, rel))) {
      const path = rel ? `${rel}/${name}` : name;
      if (statSync(join(dir, path)).isDirectory()) walk(path);
      else out[path] = readFileSync(join(dir, path), 'utf8');
    }
  };
  walk('');
  return out;
}
