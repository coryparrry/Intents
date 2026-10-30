import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createPayload, endpoint, keyLocation, main, normalizeURLs, origin, sitemapURLs, submit } from '../scripts/submit-indexnow.mjs';

const key = '0123456789abcdef0123456789abcdef';
const payload = createPayload(key, ['/', '/compare']);

test('the published ownership file contains a valid key and is excluded from the sitemap', () => {
  const liveKey = readFileSync(new URL('../dist/indexnow-key.txt', import.meta.url), 'utf8').trim();
  assert.match(liveKey, /^[a-f0-9]{32}$/);
  const xml = readFileSync(new URL('../dist/sitemap.xml', import.meta.url), 'utf8');
  assert.ok(!sitemapURLs(xml).some(url => url === keyLocation));
  assert.equal(createPayload(liveKey, sitemapURLs(xml)).host, new URL(origin).hostname);
});

test('URL normalization deduplicates paths and accepts a removed same-host URL', () => {
  assert.deepEqual(normalizeURLs(['/compare', `${origin}/compare`, '/retired-page']), [`${origin}/compare`, `${origin}/retired-page`]);
  assert.deepEqual(sitemapURLs(`<urlset><url><loc>${origin}/search?a=1&amp;b=2</loc></url></urlset>`), [`${origin}/search?a=1&b=2`]);
});

test('invalid hosts, credentials, fragments, empty batches, and oversized batches fail locally', () => {
  for (const urls of [[], ['https://example.com/'], [`${origin}.example.com/`], ['//example.com/'], [origin.replace('https:', 'http:')], [`https://name:password@${new URL(origin).host}/`], ['/compare#private'], [keyLocation], Array.from({ length: 10001 }, (_, i) => `/page-${i}`)]) {
    assert.throws(() => normalizeURLs(urls));
  }
  for (const invalid of ['', 'short', 'has a space', 'x'.repeat(129)]) assert.throws(() => createPayload(invalid, ['/']));
});

test('dry runs never perform network requests; submission requires explicit changed paths', async () => {
  const logs = [];
  const dependencies = { fetchImpl: async () => { throw new Error('Unexpected network call'); }, log: message => logs.push(message) };
  await main([], dependencies);
  assert.match(logs[0], /DRY RUN: 15 URLs; no request sent/);
  await main(['/compare'], dependencies);
  assert.equal(logs.at(-1), `${origin}/compare`);
  await assert.rejects(main(['--submit'], dependencies), /requires explicit/);
  await assert.rejects(main(['--unknown'], dependencies), /Usage:/);
});

test('verification precedes a single POST with the canonical envelope', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    return calls.length === 1 ? new Response(`${key}\n`) : new Response('', { status: 200 });
  };
  const result = await submit({ ...payload, host: 'other.example', keyLocation: 'https://other.example/key.txt' }, fetchImpl);
  assert.equal(result.status, 200);
  assert.match(result.message, /does not guarantee/);
  assert.deepEqual(calls.map(call => call.url), [keyLocation, endpoint]);
  assert.equal(calls[0].options.redirect, 'manual');
  assert.equal(calls[1].options.method, 'POST');
  assert.equal(calls[1].options.headers['Content-Type'], 'application/json; charset=utf-8');
  assert.deepEqual(JSON.parse(calls[1].options.body), payload);
});

test('missing, redirected, or mismatched live keys prevent notification', async () => {
  for (const verification of [new Response('', { status: 404 }), new Response('', { status: 302 }), new Response('different-key')]) {
    let count = 0;
    await assert.rejects(submit(payload, async () => { count++; return verification; }));
    assert.equal(count, 1);
  }
});

test('202 reports pending key validation instead of confirmed indexing', async () => {
  const result = await submit(payload, async url => url === keyLocation ? new Response(key) : new Response('', { status: 202 }));
  assert.equal(result.status, 202);
  assert.match(result.message, /validation is pending/);
  assert.match(result.message, /Indexing is not confirmed/);
});

test('rejections and network failures are surfaced without automatic retries', async () => {
  for (const status of [400, 403, 422, 429, 500]) {
    let count = 0;
    await assert.rejects(submit(payload, async () => { count++; return count === 1 ? new Response(key) : new Response('', { status }); }), new RegExp(`HTTP ${status}`));
    assert.equal(count, 2);
  }
  await assert.rejects(submit(payload, async () => { throw new Error('Network unavailable'); }), /Network unavailable/);
});
