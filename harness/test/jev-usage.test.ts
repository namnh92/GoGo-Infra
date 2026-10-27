/**
 * GoGo-Infra#260 (acceptance of #245/#247, 2026-10-27): what the owner must
 * know to use `#jev`, said where they read it — docs/ai-harness.md and the
 * `jev-prompt setup` consent box.
 *
 * - `#jev` is typed as the first line. Claude Code wraps pasted text in
 *   `<pasted_content>`, so a pasted `#jev` is never line 1 and never opts in.
 * - The hook passes `AWS_*` from the Claude Code process, so a send needs the
 *   session started with an `AWS_PROFILE` that can read the key.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, it } from 'node:test';
import { consentText } from '../src/shadow/jev-optin.ts';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '../..');

describe('#260: typing #jev and AWS_PROFILE are stated to the owner', () => {
  const docs = readFileSync(join(REPO, 'docs/ai-harness.md'), 'utf8');
  const hookSection = docs.slice(docs.indexOf('## Prompt hook and JEV opt-in'));

  it('docs: #jev is typed, a pasted one never opts in, the session needs AWS_PROFILE', () => {
    const flat = hookSection.replace(/\s+/g, ' ');
    assert.match(flat, /[Tt]ype `#jev` as the first line/);
    assert.match(flat, /pasted `#jev` .*never opts in/);
    assert.match(flat, /AWS_PROFILE=\S+ claude`/);
  });

  it('consent box: same two facts, for setup and on', () => {
    for (const action of ['setup', 'on'] as const) {
      const text = consentText({ action, enabledUntil: action === 'on' ? '2026-10-27T18:00:00.000Z' : null, actor: 'owner@test' });
      assert.match(text, /gõ `#jev`/, action);
      assert.match(text, /<pasted_content>.*không bao giờ bật gửi/, action);
      assert.match(text, /AWS_PROFILE/, action);
    }
  });
});
