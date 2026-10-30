import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const canonical = 'https://intents-workbench.coryparry.chatgpt.site/';
const args = process.argv.slice(2);
if (args.length && (args.length !== 2 || args[0] !== '--base')) throw new Error('Usage: node scripts/check-discovery.mjs [--base URL]');
const base = args[1] || canonical;
const indexNowKey = readFileSync(new URL('../dist/indexnow-key.txt', import.meta.url), 'utf8').trim();
const checks = [
  ['', 'Intents discovery verification', /text\/html/, 'application/ld+json'],
  ['', 'Googlebot', /text\/html/, 'Apple Foundation Models'],
  ['', 'bingbot', /text\/html/, 'Apple Foundation Models'],
  ['', 'OAI-SearchBot', /text\/html/, 'Apple Foundation Models'],
  ['', 'Claude-SearchBot', /text\/html/, 'Apple Foundation Models'],
  ['robots.txt', 'OAI-SearchBot', /text\/plain/, 'User-agent: *'],
  ['sitemap.xml', 'Googlebot', /(?:application|text)\/xml/, `<loc>${canonical}</loc>`],
  ['llms.txt', 'Claude-SearchBot', /text\/plain/, 'Intents 1.5.2'],
  ['indexnow-key.txt', 'Intents IndexNow verification', /text\/plain/, indexNowKey],
  ['index.html.md', 'ChatGPT-User', /text\/(?:markdown|plain)/, '# Intents'],
  ['getting-started.html', 'OAI-SearchBot', /text\/html/, 'Intents 1.5.2'],
  ['getting-started.html.md', 'Claude-SearchBot', /text\/(?:markdown|plain)/, '# Get started with Intents'],
  ['compare.html', 'OAI-SearchBot', /text\/html/, 'Intents 1.5.2'],
  ['compare/apple-evaluations.html', 'OAI-SearchBot', /text\/html/, 'Intents 1.5.2'],
  ['compare/foundation-evals.html', 'OAI-SearchBot', /text\/html/, 'Foundation Evals is now Intents'],
  ['compare/apple-fm-python-sdk.html', 'OAI-SearchBot', /text\/html/, 'Intents 1.5.2'],
  ['guides/fm-cli-to-repeatable-evals.html', 'Claude-SearchBot', /text\/html/, 'Intents 1.5.2'],
  ['guides/evaluate-apple-foundation-models-mac.html', 'Claude-SearchBot', /text\/html/, 'Intents 1.5.2'],
  ['privacy.html', 'Googlebot', /text\/html/, 'Website privacy'],
  ['seo-check-missing-page', 'Googlebot', null, null, 404],
];

// These anonymous requests test delivery with representative user-agent headers.
// They do not prove that a provider's actual crawler IPs have visited or indexed it.
const results = await Promise.allSettled(checks.map(async ([path, userAgent, type, content, status = 200]) => {
  const requestUrl = new URL(path, base);
  const requestOptions = {
    headers: { 'User-Agent': userAgent }, redirect: 'manual', signal: AbortSignal.timeout(30000),
  };
  let response = await fetch(requestUrl, requestOptions);
  if (path.endsWith('.html') && [301, 302, 307, 308].includes(response.status)) {
    // Sites normalizes .html to the extensionless public route. Follow only
    // that exact same-origin redirect; login or challenge redirects still fail.
    const target = new URL(response.headers.get('location') || '', requestUrl);
    assert.equal(target.href, new URL(path.slice(0, -5), base).href, 'Guide redirect must use its public route');
    response = await fetch(target, requestOptions);
  }
  assert.equal(response.status, status, `${path || '/'} (${userAgent}): expected ${status}, got ${response.status}`);
  if (type) assert.match(response.headers.get('content-type') || '', type, `${path || '/'} content type`);
  if (status === 200) assert.doesNotMatch(response.headers.get('x-robots-tag') || '', /noindex|none|nosnippet/i);
  const body = await response.text();
  if (path === 'indexnow-key.txt') assert.equal(body.trim(), indexNowKey, 'IndexNow ownership key must match this checkout');
  if (content) assert.ok(body.includes(content), `${path || '/'} must deliver product content, not a login or challenge`);
  if (!path) {
    assert.match(body, /<meta name="robots" content="index, follow/);
    assert.match(body, /<link rel="canonical" href="https:\/\/intents-workbench\.coryparry\.chatgpt\.site\/"/);
  }
  if (path.endsWith('.html')) {
    assert.ok(body.includes(`<link rel="canonical" href="${canonical}${path.slice(0, -5)}"`), 'Guide canonical must use its delivered public route');
  }
  if ((!path || path.endsWith('.html') || path.endsWith('.md') || path === 'llms.txt') && path !== 'privacy.html') {
    assert.ok(body.includes('Intents 1.5.2'), `${path || '/'} must identify the current release`);
    assert.doesNotMatch(body, /Foundation-Evals-1\.3|current download is Foundation Evals|Intents (?:v)?1\.[34]\.0/);
  }
  if (path === 'sitemap.xml' || path === 'llms.txt') {
    for (const route of ['compare', 'guides/evaluate-apple-foundation-models-mac', 'compare/foundation-evals', 'compare/apple-fm-python-sdk', 'guides/fm-cli-to-repeatable-evals']) assert.ok(body.includes(canonical + route), `Missing discovery route: ${route}`);
  }
  if (path === 'llms.txt' || !path || path.endsWith('.html')) assert.match(body, /(?:href="|:\s)https:\/\/coryparry\.dev\/projects\/intents(?:["\s]|$)/, 'Missing exact project-home link');
  return `${path || '/'} · ${userAgent}: ${status}${status === 200 ? ', readable, no indexing block' : ', correctly not found'}`;
}));
for (const result of results) {
  if (result.status === 'fulfilled') console.log(`PASS ${result.value}`);
  else { console.error(`FAIL ${result.reason.message}`); process.exitCode = 1; }
}
