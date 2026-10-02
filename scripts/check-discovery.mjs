import assert from 'node:assert/strict';

const base = 'https://intents-workbench.coryparry.chatgpt.site/';
const checks = [
  ['', 'Intents discovery verification', /text\/html/, 'application/ld+json'],
  ['', 'Googlebot', /text\/html/, 'Apple Foundation Models'],
  ['', 'bingbot', /text\/html/, 'Apple Foundation Models'],
  ['', 'OAI-SearchBot', /text\/html/, 'Apple Foundation Models'],
  ['', 'Claude-SearchBot', /text\/html/, 'Apple Foundation Models'],
  ['robots.txt', 'OAI-SearchBot', /text\/plain/, 'User-agent: *'],
  ['sitemap.xml', 'Googlebot', /(?:application|text)\/xml/, `<loc>${base}</loc>`],
  ['llms.txt', 'Claude-SearchBot', /text\/plain/, '# Intents'],
  ['index.html.md', 'ChatGPT-User', /text\/(?:markdown|plain)/, '# Intents'],
];

// These anonymous requests test delivery with representative user-agent headers.
// They do not prove that a provider's actual crawler IPs have visited or indexed it.
const results = await Promise.allSettled(checks.map(async ([path, userAgent, type, content]) => {
  const response = await fetch(new URL(path, base), {
    headers: { 'User-Agent': userAgent }, redirect: 'manual', signal: AbortSignal.timeout(30000),
  });
  assert.equal(response.status, 200, `${path || '/'} (${userAgent}): HTTP ${response.status}`);
  assert.match(response.headers.get('content-type') || '', type, `${path || '/'} content type`);
  assert.doesNotMatch(response.headers.get('x-robots-tag') || '', /noindex|none|nosnippet/i);
  const body = await response.text();
  assert.ok(body.includes(content), `${path || '/'} must deliver product content, not a login or challenge`);
  if (!path) {
    assert.match(body, /<meta name="robots" content="index, follow/);
    assert.match(body, /<link rel="canonical" href="https:\/\/intents-workbench\.coryparry\.chatgpt\.site\/"/);
  }
  return `${path || '/'} · ${userAgent}: 200, readable, no indexing block`;
}));
for (const result of results) {
  if (result.status === 'fulfilled') console.log(`PASS ${result.value}`);
  else { console.error(`FAIL ${result.reason.message}`); process.exitCode = 1; }
}
