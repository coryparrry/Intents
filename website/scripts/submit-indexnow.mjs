import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export const origin = 'https://intents-workbench.coryparry.chatgpt.site';
export const endpoint = 'https://api.indexnow.org/indexnow';
export const keyLocation = `${origin}/indexnow-key.txt`;
const dist = new URL('../dist/', import.meta.url);

/** Normalize and deduplicate changed URLs without permitting another host or credentials. */
export function normalizeURLs(values) {
  const urls = [...new Set(values.map(value => {
    const url = new URL(value, `${origin}/`);
    assert.equal(url.origin, origin, 'IndexNow URLs must use the canonical HTTPS Site origin');
    assert.ok(!url.username && !url.password && !url.hash, 'URLs must not contain credentials or fragments');
    assert.ok(url.href !== keyLocation, 'The verification file is not a content URL');
    return url.href;
  }))];
  assert.ok(urls.length > 0 && urls.length <= 10000, 'Supply between 1 and 10,000 distinct changed URLs');
  return urls;
}

/** Read this small static sitemap for a non-submitting preview of the canonical pages. */
export function sitemapURLs(xml) {
  return normalizeURLs([...xml.matchAll(/<loc>\s*([^<]+?)\s*<\/loc>/g)].map(([, value]) => value.replaceAll('&amp;', '&')));
}

/** Build the IndexNow request from the deployed ownership key and explicit content URLs. */
export function createPayload(key, urls) {
  assert.match(key, /^[a-zA-Z0-9-]{8,128}$/, 'IndexNow key must contain 8–128 letters, digits, or hyphens');
  return { host: new URL(origin).hostname, key, keyLocation, urlList: normalizeURLs(urls) };
}

/** Verify the public key before sending one batch; report pending validation separately. */
export async function submit(payload, fetchImpl = fetch) {
  // Rebuild the envelope so callers cannot substitute a foreign host or key location.
  const request = createPayload(payload.key, payload.urlList);
  const options = { redirect: 'manual', signal: AbortSignal.timeout(30000) };
  const verification = await fetchImpl(keyLocation, options);
  assert.equal(verification.status, 200, 'Publish the IndexNow key file before submitting URLs');
  assert.equal((await verification.text()).trim(), request.key, 'The live IndexNow key differs from this checkout');
  const response = await fetchImpl(endpoint, {
    ...options,
    signal: AbortSignal.timeout(30000),
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
    body: JSON.stringify(request),
  });
  if (response.status === 200) return { status: 200, message: `Received ${request.urlList.length} URLs. Receipt does not guarantee crawling or indexing.` };
  if (response.status === 202) return { status: 202, message: `Received ${request.urlList.length} URLs; IndexNow key validation is pending. Indexing is not confirmed.` };
  const reasons = { 400: 'Invalid request', 403: 'Ownership key rejected', 422: 'Host, key, or URL mismatch', 429: 'Rate limited; do not immediately resubmit' };
  throw new Error(`IndexNow HTTP ${response.status}: ${reasons[response.status] || 'Submission failed'}`);
}

/** Keep network submission opt-in and require an explicit list of recently changed URLs. */
export async function main(args, { fetchImpl = fetch, log = console.log } = {}) {
  const send = args[0] === '--submit';
  const paths = send ? args.slice(1) : args;
  assert.ok(!paths.some(value => value.startsWith('-')), 'Usage: node scripts/submit-indexnow.mjs [--submit] [URL or /path ...]');
  assert.ok(!send || paths.length > 0, '--submit requires explicit recently added, changed, or deleted URLs');
  const urls = paths.length ? normalizeURLs(paths) : sitemapURLs(readFileSync(new URL('sitemap.xml', dist), 'utf8'));
  const key = readFileSync(new URL('indexnow-key.txt', dist), 'utf8').trim();
  const payload = createPayload(key, urls);
  if (!send) {
    log(`DRY RUN: ${urls.length} URLs; no request sent. After publication, use --submit followed by the changed paths.`);
    urls.forEach(url => log(url));
    return;
  }
  const result = await submit(payload, fetchImpl);
  log(`IndexNow HTTP ${result.status}: ${result.message}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch(error => { console.error(error.message); process.exitCode = 1; });
}
