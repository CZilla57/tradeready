// clientIp (src/appCors.js): Cloudflare's cf-connecting-ip always wins over a
// caller-supplied x-forwarded-for, which Cloudflare appends to rather than
// replaces. x-forwarded-for is only a fallback for runs without the edge.

const { test, before } = require('node:test');
const assert = require('node:assert/strict');

let clientIp;
before(async () => {
  ({ clientIp } = await import('../src/appCors.js'));
});

function fakeC(headers) {
  const lower = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
  return { req: { header: (name) => lower[name.toLowerCase()] } };
}

test('cf-connecting-ip wins over a spoofed x-forwarded-for', () => {
  assert.equal(clientIp(fakeC({ 'x-forwarded-for': '1.2.3.4, 203.0.113.9', 'cf-connecting-ip': '203.0.113.9' })), '203.0.113.9');
});

test('x-forwarded-for first entry is the fallback without the edge header', () => {
  assert.equal(clientIp(fakeC({ 'x-forwarded-for': ' 198.51.100.7 , 10.0.0.1' })), '198.51.100.7');
});

test('a blank edge header falls back, and nothing at all is "unknown"', () => {
  assert.equal(clientIp(fakeC({ 'cf-connecting-ip': '  ', 'x-forwarded-for': '198.51.100.7' })), '198.51.100.7');
  assert.equal(clientIp(fakeC({})), 'unknown');
  assert.equal(clientIp(fakeC({ 'x-forwarded-for': ' , ' })), 'unknown');
});
