import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';

const root = new URL('../dist/', import.meta.url);
const host = 'https://intents-workbench.coryparry.chatgpt.site';
const read = path => readFileSync(new URL(path, root), 'utf8');
const sitemap = read('sitemap.xml');
const routes = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map(([, url]) => new URL(url).pathname);
const fileFor = path => path === '/' ? 'index.html' : /\.[^/]+$/.test(path) ? path.slice(1) : `${path.slice(1)}.html`;
const editorial = routes.filter(route => route.startsWith('/compare') || route.startsWith('/guides/'));
const data = text => [...text.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].flatMap(([, json]) => {
  const item = JSON.parse(json);
  return item['@graph'] || [item];
});
const dmg = 'https://github.com/coryparrry/Intents/releases/download/v1.5.2/Intents-1.5.2-macOS-arm64.dmg';

test('every sitemap route resolves and all requested routes are published', () => {
  assert.equal(new Set(routes).size, routes.length);
  for (const route of ['/', '/getting-started', '/privacy', '/compare', ...['foundation-evals', 'apple-evaluations', 'promptfoo', 'deepeval', 'braintrust'].map(name => `/compare/${name}`), ...['evaluate-apple-foundation-models-mac', 'intents-mcp-coding-agents', 'install-intents-homebrew', 'on-device-llm-evaluation-macos'].map(name => `/guides/${name}`)]) {
    assert.ok(routes.includes(route), `Missing sitemap route: ${route}`);
  }
  for (const route of routes) assert.ok(existsSync(new URL(fileFor(route), root)), route);
  assert.equal([...sitemap.matchAll(/<lastmod>2026-10-26<\/lastmod>/g)].length, routes.length);
});

test('editorial pages have short answers, Markdown twins, sources, and discoverable canonical routes', () => {
  const llms = read('llms.txt');
  for (const route of editorial) {
    const html = read(fileFor(route));
    const md = read(`${fileFor(route)}.md`);
    assert.match(html, /<h2>Short answer<\/h2>/, route);
    assert.match(md, /## Short answer/, route);
    assert.ok(html.includes(`<link rel="canonical" href="${host}${route}">`), route);
    assert.ok(html.includes(`href="${host}${route}.html.md"`), route);
    assert.ok(llms.includes(host + route), route);
    for (const text of [html, md]) {
      assert.ok(text.includes(dmg), `${route}: current download`);
      assert.ok(text.includes('brew install --cask coryparrry/tap/intents'), `${route}: Homebrew`);
      assert.match(text, /26 October 2026/);
      const links = [...text.matchAll(/(?:href="|\]\()([^"\)]+)(?:"|\))/g)].map(([, url]) => url);
      assert.ok(links.some(url => url === 'https://github.com/coryparrry/Intents/issues'));
    }
    assert.match(html, /src="\/analytics.mjs"/);
    const article = data(html).find(item => ['Article', 'WebPage'].includes(item['@type']));
    assert.equal(article.dateModified, '2026-10-26');
    assert.equal(article.datePublished, '2026-10-26');
    if (route.startsWith('/compare/')) {
      const answer = html.match(/<h2>Short answer<\/h2>\s*<p>(.*?)<\/p>/s)[1];
      const words = answer.split(/\s+/).length;
      assert.ok(words >= 40 && words <= 70, `${route}: ${words} words`);
    }
  }
});

test('FAQ structured data matches the visible questions and answers', () => {
  for (const file of ['index.html', ...editorial.filter(route => route.startsWith('/compare/')).map(fileFor)]) {
    const html = read(file);
    const faq = data(html).find(item => item['@type'] === 'FAQPage');
    assert.ok(faq, file);
    assert.ok(faq.mainEntity.length >= 3 && faq.mainEntity.length <= 5);
    for (const question of faq.mainEntity) {
      assert.ok(html.includes(`>${question.name}</`), `${file}: visible question`);
      assert.ok(html.includes(`>${question.acceptedAnswer.text}</p>`), `${file}: visible answer`);
    }
  }
});

test('all public HTML and Markdown local links resolve, including nested routes and anchors', () => {
  for (const route of routes) {
    const files = [fileFor(route)];
    if (existsSync(new URL(`${fileFor(route)}.md`, root))) files.push(`${fileFor(route)}.md`);
    for (const file of files) {
      const content = read(file);
      const links = file.endsWith('.md') ? [...content.matchAll(/\]\(([^)]+)\)/g)] : [...content.matchAll(/(?:href|src)="([^"]+)"/g)];
      for (const [, link] of links) {
        const url = new URL(link, `${host}${route}`);
        if (url.origin !== host) continue;
        const target = fileFor(url.pathname);
        assert.ok(existsSync(new URL(target, root)), `${file}: ${link}`);
        if (url.hash && target.endsWith('.html')) assert.ok(read(target).includes(`id="${decodeURIComponent(url.hash.slice(1))}"`), `${file}: ${link}`);
      }
    }
  }
});

test('current product surfaces and SoftwareApplication describe the stable Intents installer', () => {
  for (const entry of readdirSync(root, { recursive: true })) {
    if (!/\.(html|md|js|mjs|txt)$/.test(entry)) continue;
    assert.doesNotMatch(read(entry), /Foundation-Evals-1\.3|current download is Foundation Evals|Intents (?:v)?1\.[34]\.0/, entry);
  }
  const app = data(read('index.html')).find(item => item['@type'] === 'SoftwareApplication');
  assert.equal(app.softwareVersion, '1.5.2');
  assert.equal(app.downloadUrl, dmg);
  assert.deepEqual(app.sameAs, ['https://github.com/coryparrry/Intents', 'https://github.com/coryparrry/homebrew-tap']);
  const manifest = JSON.parse(readFileSync(new URL('../.openai/hosting.json', import.meta.url), 'utf8'));
  assert.equal(manifest.static.not_found_handling, 'none');
});
