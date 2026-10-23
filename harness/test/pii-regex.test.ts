/**
 * The two formats the outbound data contract claims (owner decision 2026-10-23: phones and emails are
 * checked by regex), plus the one plain 8+-digit shape. Anchored; valid means the whole token matches.
 */
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { EMAIL, ISO_DATE_TIME, VN_PHONE } from '../src/runtime/sanitize.ts';

describe('VN_PHONE', () => {
  const valid = [
    '0912345678', '0912 345 678', '0912.345.678', '0912-345-678', '091 234 5678', '0 912 345 678', '0 9 1 2 3 4 5 6 7 8',
    '0312345678', '0512345678', '0712345678', '0812345678',
    '02838221234', '028 3822 1234', '028.3822.1234', '024 3826 1234', '0243 826 1234', '0 28 3822 1234',
    '84912345678', '84 912 345 678', '840912345678', '84 0 912 345 678', '84 0 28 3822 1234',
    '+84912345678', '+84 912 345 678', '+84.912.345.678', '+84-912-345-678', '+84 0 912 345 678', '+84 0912345678', '+84 28 3822 1234', '+84 0 28 3822 1234',
    '0084912345678', '0084 912 345 678', '0084 0 912 345 678',
  ];
  const invalid = [
    '091234567', '09123456789', '0912 345 678 9', '0112345678', '0412345678', '0612345678', '0012345678',
    '0283822123', '028382212345', '912345678', '912 345 678',
    '+ 84 912 345 678', '+84  912 345 678', '+84 - 912 - 345 - 678', '8 4 912 345 678', '0 0 8 4 912 345 678', '+8 4 912 345 678',
    '+1 415 555 0133', '+44 20 7946 0958', '+1 (415) 555-0133',
    '0912345678a', 'a0912345678', '0912345678 0912345678', '0912,345,678', '(0912345678)', '0912/345/678',
    '2026-10-22', '1729580000000', '',
  ];
  for (const t of valid) it(`accepts ${JSON.stringify(t)}`, () => assert.ok(VN_PHONE.test(t)));
  for (const t of invalid) it(`rejects ${JSON.stringify(t)}`, () => assert.ok(!VN_PHONE.test(t)));
});

describe('EMAIL', () => {
  const valid = ['a@b.vn', 'an.nguyen@example.com', 'x_y+z@sub.example.co', '1a@b.vn', 'first.last@a-b.example.org', 'A%B@x-y.z.museum', '0912345678an@b.vn'];
  const invalid = [
    'a@b.vn@c.vn', 'a..b@c.vn', 'a@@b.vn', '.a@b.vn', 'a.@b.vn', 'a@-b.vn', 'a@b-.vn', 'a@b..vn', 'a@b.v', 'a@b', '@b.vn', 'a@', 'a@b.vn.', 'a@b.vn1', 'a@b.vn-', 'a@b.vn0912345678',
    "o'neil@example.com", 'a b@c.vn', 'a@b .vn', 'a@b.v n', 'a@.vn', 'a@b.', 'ab.vn', '@', '',
  ];
  for (const t of valid) it(`accepts ${JSON.stringify(t)}`, () => assert.ok(EMAIL.test(t)));
  for (const t of invalid) it(`rejects ${JSON.stringify(t)}`, () => assert.ok(!EMAIL.test(t)));
});

describe('ISO_DATE_TIME (the one plain 8+-digit shape)', () => {
  for (const t of ['2026-10-22', '2026-10-22T10:30:00Z', '2026-10-22 10:30', '2026-10-22T10:30:00.123+07:00', '2026-10-22T10:30:00-0700']) it(`accepts ${JSON.stringify(t)}`, () => assert.ok(ISO_DATE_TIME.test(t)));
  for (const t of ['20261022', '2026-10-22 0912345678', '2026-10-2210', '1729580000000', '0912345678', '2026-10-22T']) it(`rejects ${JSON.stringify(t)}`, () => assert.ok(!ISO_DATE_TIME.test(t)));
});
