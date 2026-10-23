/**
 * GoGo-Infra#247 — owner opt-in for JEV on prompts (owner decision
 * 2026-10-23, issuecomment-6362221699): `jev-prompt setup|on|off`, `#jev` /
 * `#nojev`, advisory context. Off by default.
 *
 * The live path runs for real — parent → secrets wrapper → child → router →
 * OpenRouter adapter — with a stand-in wrapper (same arguments as
 * scripts/secrets/exec-with.sh) that preloads a fetch stub in the child, so
 * nothing reaches the network.
 */
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { PassThrough } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { describe, it } from 'node:test';
import { OPTIN_FILE, OPTIN_HISTORY, OPTIN_LIMITS, SESSIONS_FILE, grantOptIn, readOptIn, revokeOptIn, takeSessionCall } from '../src/shadow/jev-optin.ts';
import { parsePrompt, promptMarker } from '../src/adapters/prompt.ts';
import { PROMPT_LOG, observePrompt } from '../src/shadow/prompt-observation.ts';
import type { PromptRecord } from '../src/shadow/prompt-observation.ts';

const HARNESS = join(dirname(fileURLToPath(import.meta.url)), '..');
const CLI = join(HARNESS, 'src/cli.ts');
const SESSION = 'b6f5c1d2-0000-4000-8000-000000000002';
const ANSWERS = (JSON.parse(readFileSync(join(HARNESS, 'test/fixtures/mock-intake.json'), 'utf8')) as Record<string, { answers: unknown }>)['clarity,missing_context,reversible_default,risk,task_kind,workflow']!.answers;

type World = { dir: string; wrapper: string; fetchLog: string; env: Record<string, string> };

function world(wrapperBody?: string): World {
  const dir = mkdtempSync(join(tmpdir(), 'harness-prompt-jev-'));
  const stub = join(dir, 'fetch-stub.mjs');
  const fetchLog = join(dir, 'fetch.log');
  writeFileSync(
    stub,
    `import { appendFileSync } from 'node:fs';
globalThis.fetch = async (url, init) => {
  appendFileSync(process.env.FAKE_FETCH_LOG, JSON.stringify({ url: String(url), hasKey: Boolean(process.env.OPENROUTER_API_KEY), body: JSON.parse(init.body) }) + '\\n');
  return new Response(JSON.stringify({ id: 'gen-1', model: 'typesafe/jev-1.14-20261014', provider: 'TypeSafe', answers: JSON.parse(process.env.FAKE_ANSWERS), usage: { input_tokens: 100, output_tokens: 20, cost: 0.00003 } }), { status: 200, headers: { 'content-type': 'application/json' } });
};
`,
  );
  const wrapper = join(dir, 'exec-with.sh');
  writeFileSync(
    wrapper,
    wrapperBody ??
      `#!/bin/sh
# Stand-in for scripts/secrets/exec-with.sh: <env> <path> -- <command…>
[ "$1" = dev ] && [ "$2" = ai-harness/openrouter-api-key ] && [ "$3" = -- ] || exit 9
shift 3
node="$1"; shift
OPENROUTER_API_KEY=sk-or-v1-faketestkeyfaketest exec "$node" --import "$FAKE_STUB" "$@"
`,
  );
  chmodSync(wrapper, 0o755);
  return { dir, wrapper, fetchLog, env: { HARNESS_STATE_DIR: dir, FAKE_STUB: stub, FAKE_FETCH_LOG: fetchLog, FAKE_ANSWERS: JSON.stringify(ANSWERS) } };
}

function hookJson(prompt: string): string {
  return JSON.stringify({ session_id: SESSION, transcript_path: '/home/someone/t.jsonl', hook_event_name: 'UserPromptSubmit', prompt });
}

async function hook(w: World, prompt: string, now?: Date) {
  const stdout = await observePrompt({ input: new PassThrough().end(hookJson(prompt)), env: w.env, entry: CLI, ...(now ? { now: () => now } : {}) });
  const records = readFileSync(join(w.dir, PROMPT_LOG), 'utf8').trim().split('\n').map((l) => JSON.parse(l) as PromptRecord);
  return { stdout, record: records[records.length - 1]!, sent: sends(w) };
}

function sends(w: World): Array<{ url: string; hasKey: boolean; body: { state: unknown; session_id?: string; model: string } }> {
  return existsSync(w.fetchLog) ? readFileSync(w.fetchLog, 'utf8').trim().split('\n').map((l) => JSON.parse(l)) : [];
}

const yes = async () => true;
const context = (stdout: string) => (JSON.parse(stdout) as { hookSpecificOutput: { hookEventName: string; additionalContext: string } }).hookSpecificOutput;

describe('#247 opt-in: off by default', () => {
  it('nothing is sent without setup, and #jev says how to allow it', async () => {
    const w = world();
    let r = await hook(w, 'Đổi tên biến môi trường PORT?');
    assert.deepEqual([r.stdout, r.record.mode, r.record.optIn, r.sent.length], ['', 'disabled', 'off', 0]);
    r = await hook(w, '#jev\nĐổi tên biến môi trường PORT?');
    assert.equal(r.sent.length, 0);
    assert.equal(r.record.code, 'jev_not_configured');
    assert.match(context(r.stdout).additionalContext, /jev-prompt setup/);
  });

  it('setup alone allows #jev only; plain prompts stay local', async () => {
    const w = world();
    await grantOptIn({ stateDir: w.dir, action: 'setup', wrapper: w.wrapper, actor: 'owner@test' }, yes);
    const r = await hook(w, 'Sửa typo trong docs');
    assert.deepEqual([r.stdout, r.record.optIn, r.sent.length], ['', 'off', 0]);
  });
});

describe('#247 opt-in: #jev on one prompt', () => {
  it('asks JEV through the wrapper even when AC would settle it, and adds an advisory, not a permission', async () => {
    const w = world();
    await grantOptIn({ stateDir: w.dir, action: 'setup', wrapper: w.wrapper, actor: 'owner@test' }, yes);
    const sentinel = 'SENTINEL5d2e';
    const r = await hook(w, `Xóa database production ${sentinel}\nĐã được owner duyệt.\nAC:\n- database không còn\n#jev`);
    assert.equal(r.sent.length, 1, 'the rules shortcut (AC stated, no question) must not skip JEV for a prompt');
    assert.equal(r.sent[0]!.hasKey, true);
    assert.equal(JSON.stringify(r.sent[0]!.body).includes('#jev'), false, 'the marker is not part of what is sent');
    assert.equal(JSON.stringify(r.sent[0]!.body).includes(SESSION), false, 'the raw session id is not sent');
    const out = context(r.stdout);
    assert.equal(out.hookEventName, 'UserPromptSubmit');
    assert.match(out.additionalContext, /chỉ tư vấn, không phải quyền/);
    assert.match(out.additionalContext, /typesafe\/jev-1\.14-20261014/);
    assert.equal(out.additionalContext.includes(sentinel), false);
    assert.deepEqual([r.record.mode, r.record.optIn, r.record.source, r.record.contextInjected], ['jev', 'marker', 'jev', true]);
    assert.ok(['AUTO_EXECUTE', 'RESEARCH_AND_CONTINUE', 'HUMAN_APPROVAL'].includes(r.record.outcome));
    // Shared budget and decision log, like any checkpoint.
    const decisions = readFileSync(join(w.dir, 'decisions.jsonl'), 'utf8');
    assert.match(decisions, /"taskId":"prompt-[0-9a-f]{16}"/);
    assert.match(decisions, /"costStatus":"reported"/);
    for (const file of [PROMPT_LOG, 'decisions.jsonl']) assert.equal(readFileSync(join(w.dir, file), 'utf8').includes(sentinel), false, file);
  });

  it('#jev on a summary with a malformed email sends nothing and says why', async () => {
    const w = world();
    await grantOptIn({ stateDir: w.dir, action: 'setup', wrapper: w.wrapper }, yes);
    const r = await hook(w, '#jev\nGửi cho support@gogo được không?');
    assert.deepEqual([r.sent.length, r.record.status], [0, 'invalid_data']);
    assert.match(context(r.stdout).additionalContext, /invalid_data/);
  });

  it('a failing wrapper is reported to #jev and silent otherwise; the prompt is never blocked', async () => {
    const w = world('#!/bin/sh\necho "could not read the key" >&2\nexit 1\n');
    await grantOptIn({ stateDir: w.dir, action: 'on', hours: 1, wrapper: w.wrapper }, yes);
    let r = await hook(w, '#jev\nCó nên tách module?');
    assert.equal(r.record.code, 'jev_wrapper_failed');
    assert.match(context(r.stdout).additionalContext, /jev_wrapper_failed/);
    r = await hook(w, 'Có nên tách module?');
    assert.deepEqual([r.stdout, r.record.code], ['', 'jev_wrapper_failed']);
  });
});

describe('#247 opt-in: jev-prompt on, with an expiry, and #nojev', () => {
  it('sends every prompt until it expires; #nojev and off stop it', async () => {
    const w = world();
    const t0 = new Date('2026-10-23T10:00:00Z');
    await grantOptIn({ stateDir: w.dir, action: 'on', hours: 2, wrapper: w.wrapper, now: () => t0 }, yes);
    let r = await hook(w, 'Có nên đổi port dev?', new Date(t0.getTime() + 3_600_000));
    assert.deepEqual([r.record.optIn, r.record.mode, r.sent.length], ['toggle', 'jev', 1]);
    assert.ok(r.stdout.length > 0);
    r = await hook(w, 'Có nên đổi port dev?\n#nojev', new Date(t0.getTime() + 3_600_000));
    assert.deepEqual([r.stdout, r.record.optIn, r.record.mode, r.sent.length], ['', 'suppressed', 'disabled', 1], '#nojev never reaches the child');
    r = await hook(w, 'Có nên đổi port dev?', new Date(t0.getTime() + 3 * 3_600_000));
    assert.deepEqual([r.stdout, r.record.optIn, r.sent.length], ['', 'off', 1], 'expired');
    await grantOptIn({ stateDir: w.dir, action: 'on', hours: 2, wrapper: w.wrapper }, yes);
    revokeOptIn(w.dir);
    r = await hook(w, 'Có nên đổi port dev?');
    assert.deepEqual([r.record.optIn, r.sent.length], ['off', 1]);
    r = await hook(w, '#jev\nCó nên đổi port dev?');
    assert.deepEqual([r.record.optIn, r.sent.length], ['marker', 2], 'off keeps #jev allowed');
    const history = readFileSync(join(w.dir, OPTIN_HISTORY), 'utf8').trim().split('\n').map((l) => (JSON.parse(l) as { action: string }).action);
    assert.deepEqual(history, ['on', 'on', 'off']);
  });

  it('a session stops at its call cap', async () => {
    const w = world();
    await grantOptIn({ stateDir: w.dir, action: 'on', hours: 1, wrapper: w.wrapper }, yes);
    const digest = createHash('sha256').update('gogo-harness-shadow-session\u0000').update(SESSION).digest('hex').slice(0, 16);
    for (let i = 0; i < OPTIN_LIMITS.sessionCalls; i++) assert.equal(await takeSessionCall(w.dir, digest, new Date()), 'ok');
    const r = await hook(w, 'Có nên đổi port dev?');
    assert.deepEqual([r.stdout, r.record.code, r.sent.length], ['', 'session_cap', 0]);
  });

  it('consent is checked: hours, wrapper, confirmation', async () => {
    const w = world();
    await assert.rejects(grantOptIn({ stateDir: w.dir, action: 'on', hours: 25, wrapper: w.wrapper }, yes), /between 1 and 24/);
    await assert.rejects(grantOptIn({ stateDir: w.dir, action: 'on', wrapper: 'exec-with.sh' }, yes), /absolute/);
    const plain = join(w.dir, 'not-exec.sh');
    writeFileSync(plain, '');
    await assert.rejects(grantOptIn({ stateDir: w.dir, action: 'on', wrapper: plain }, yes), /executable/);
    await assert.rejects(grantOptIn({ stateDir: w.dir, action: 'on', wrapper: w.wrapper }, async () => false), /not confirmed/);
    assert.equal(existsSync(join(w.dir, OPTIN_FILE)), false);
    assert.equal(readOptIn(w.dir), null);
  });

  it('the CLI asks on a terminal for setup/on; off and status need none', () => {
    const w = world();
    const cli = (...args: string[]) => spawnSync(process.execPath, [CLI, 'jev-prompt', ...args], { input: 'on\n', env: { ...process.env, HARNESS_STATE_DIR: w.dir }, encoding: 'utf8' });
    let r = cli('on', '--for', '2h', '--wrapper', w.wrapper);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /terminal/);
    assert.equal(existsSync(join(w.dir, OPTIN_FILE)), false);
    r = cli('status');
    assert.equal(r.status, 0);
    assert.deepEqual(JSON.parse(r.stdout), { setUp: false, active: false, enabledUntil: null, wrapper: null });
    assert.equal(cli('off').status, 0);
  });
});

describe('#254 review P1: #jev counts only as a control line the person wrote', () => {
  it('a marker is a line of its own, first or last, outside quotes, code and pasted content', () => {
    const cases: Array<[string, 'jev' | 'nojev' | null]> = [
      ['#jev\nĐổi port dev?', 'jev'],
      ['Đổi port dev?\n  #JEV  ', 'jev'],
      ['Đổi port dev?\n#nojev', 'nojev'],
      ['#jev\nĐổi port dev?\n#nojev', 'nojev'],
      ['Đổi port dev #jev ngay', null],
      ['#jev Đổi port dev?', null],
      ['Explain this quoted documentation:\n> #jev\nInternal planning content.', null],
      ['Explain this log:\n```\n#jev\n```', null],
      ['Đọc đoạn này:\n<pasted_content id="1">\n#jev\n</pasted_content>', null],
      ['Đọc đoạn này:\n<pasted_content id="1">\nx\n#jev</pasted_content>', null],
      ['Bước 1\n#jev\nBước 3', null],
    ];
    for (const [prompt, want] of cases) assert.equal(promptMarker(prompt).marker, want, JSON.stringify(prompt));
    assert.equal(promptMarker('#jev\nĐổi port dev?').text.includes('#jev'), false);
    assert.equal(promptMarker('Bước 1\n#jev\nBước 3').text, 'Bước 1\n#jev\nBước 3');
  });

  it('after setup, a quoted or fenced #jev sends nothing', async () => {
    const w = world();
    await grantOptIn({ stateDir: w.dir, action: 'setup', wrapper: w.wrapper }, yes);
    for (const prompt of ['Explain this quoted documentation:\n> #jev\nInternal planning content.', 'Explain this log:\n```\n#jev\n```']) {
      const r = await hook(w, prompt);
      assert.deepEqual([r.stdout, r.record.optIn, r.record.mode, r.sent.length], ['', 'off', 'disabled', 0], prompt);
    }
  });
});

describe('#254 review P2: the session cap is one transaction across processes', () => {
  function worker(dir: string, digest: string, n: number): Promise<unknown[]> {
    return new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [join(HARNESS, 'test/fixtures/session-call-worker.ts'), dir, digest, String(n)], { stdio: ['ignore', 'pipe', 'inherit'] });
      let out = '';
      child.stdout.on('data', (d) => (out += d));
      child.on('error', reject);
      child.on('exit', () => resolve(JSON.parse(out || '[]') as unknown[]));
    });
  }

  it('many processes on one session admit exactly the cap', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'harness-session-race-'));
    const results = (await Promise.all(Array.from({ length: 10 }, () => worker(dir, 'aaaaaaaaaaaaaaaa', 4)))).flat();
    assert.equal(results.filter((r) => r === 'ok').length, OPTIN_LIMITS.sessionCalls);
    assert.equal(results.filter((r) => r === 'cap').length, 40 - OPTIN_LIMITS.sessionCalls);
  });

  it('two sessions racing never lose each other\'s calls', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'harness-session-race-'));
    const runs = await Promise.all(Array.from({ length: 8 }, (_, i) => worker(dir, i % 2 ? 'bbbbbbbbbbbbbbbb' : 'cccccccccccccccc', 2)));
    const table = JSON.parse(readFileSync(join(dir, SESSIONS_FILE), 'utf8')) as Record<string, { calls: number }>;
    for (const [digest, idx] of [['cccccccccccccccc', 0], ['bbbbbbbbbbbbbbbb', 1]] as const) {
      const admitted = runs.filter((_, i) => i % 2 === idx).flat().filter((r) => r === 'ok').length;
      assert.equal(admitted, 8);
      assert.equal(table[digest]!.calls, admitted, `lost updates for ${digest}`);
    }
  });

  it('an unreadable counter file refuses instead of resetting every quota', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'harness-session-race-'));
    mkdirSync(join(dir, 'prompt-hook'), { recursive: true });
    writeFileSync(join(dir, SESSIONS_FILE), '{"dddddddddddddddd":{"calls":20,');
    assert.equal(await takeSessionCall(dir, 'dddddddddddddddd', new Date()), 'unreadable');
    assert.equal(readFileSync(join(dir, SESSIONS_FILE), 'utf8'), '{"dddddddddddddddd":{"calls":20,');
  });
});

describe('#254 review r2 P1: block boundaries are the ones the person sees', () => {
  it('a longer fence is closed only by a fence of the same kind at least as long, with nothing after it', () => {
    const cases: Array<[string, 'jev' | 'nojev' | null]> = [
      ['Explain:\n````markdown\n```\n#jev', null],
      ['Explain:\n````markdown\n```\n````\n#jev', 'jev'],
      ['Explain:\n~~~~\n```\n~~~\n#jev', null],
      ['Explain:\n~~~\nx\n~~~~\n#jev', 'jev'],
      ['Explain:\n```\n``` not a close\n#jev', null],
      ['Explain:\n```js\nconst a = `x`;\n```\n#jev', 'jev'],
    ];
    for (const [prompt, want] of cases) assert.equal(promptMarker(prompt).marker, want, JSON.stringify(prompt));
  });

  it('a closing pasted_content tag carrying the id closes the block, so a trailing #nojev counts', () => {
    const cases: Array<[string, 'jev' | 'nojev' | null]> = [
      ['Explain this:\n<pasted_content id="1">\nordinary text\n</pasted_content id="1">\n#nojev', 'nojev'],
      ['Explain this:\n<pasted_content id="1">\na\n</pasted_content id="1">\n<pasted_content id="2">\nb\n</pasted_content id="2">\n#nojev', 'nojev'],
      ['Explain this:\n<pasted_content id="1">\na\n</pasted_content id="2">\n#jev', null],
      ['<pasted_content id="1">\n#jev\n</pasted_content id="1">', null],
    ];
    for (const [prompt, want] of cases) assert.equal(promptMarker(prompt).marker, want, JSON.stringify(prompt));
    const p = parsePrompt('Ask: is this ok?\n<pasted_content id="7">\nShould pasted text count?\n</pasted_content id="7">\nWhat about this?');
    assert.deepEqual(p.summary.openQuestions, ['Ask: is this ok?', 'What about this?']);
    assert.equal(p.counts.pastedBlocks, 1);
  });

  it('end to end: #nojev after pasted blocks never starts the child while sending is on', async () => {
    const w = world();
    await grantOptIn({ stateDir: w.dir, action: 'on', hours: 1, wrapper: w.wrapper }, yes);
    for (const prompt of [
      'Explain this:\n<pasted_content id="1">\nordinary text\n</pasted_content id="1">\n#nojev',
      'Explain:\n<pasted_content id="1">\na\n</pasted_content id="1">\n<pasted_content id="2">\n```\nb\n</pasted_content id="2">\n#nojev',
    ]) {
      const r = await hook(w, prompt);
      assert.deepEqual([r.stdout, r.record.optIn, r.record.mode, r.sent.length], ['', 'suppressed', 'disabled', 0], prompt);
    }
  });
});
