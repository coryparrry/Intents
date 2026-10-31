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

test('sitemap routes are unique, resolve, and include the main product pages', () => {
  assert.equal(new Set(routes).size, routes.length);
  for (const route of ['/', '/getting-started', '/privacy']) {
    assert.ok(routes.includes(route), `Missing sitemap route: ${route}`);
  }
  for (const route of routes) assert.ok(existsSync(new URL(fileFor(route), root)), route);
});

test('editorial pages publish readable alternatives, install links, and canonical routes', () => {
  const llms = read('llms.txt');
  for (const route of editorial) {
    const html = read(fileFor(route));
    const md = read(`${fileFor(route)}.md`);
    assert.ok(html.includes(`<link rel="canonical" href="${host}${route}">`), route);
    assert.ok(html.includes(`href="${host}${route}.html.md"`), route);
    assert.ok(llms.includes(host + route), route);
    for (const text of [html, md]) {
      assert.ok(text.includes(dmg), `${route}: current download`);
      assert.ok(text.includes('brew install --cask coryparrry/tap/intents'), `${route}: Homebrew`);
      const links = [...text.matchAll(/(?:href="|\]\()([^"\)]+)(?:"|\))/g)].map(([, url]) => url);
      assert.ok(links.some(url => url === 'https://github.com/coryparrry/Intents/issues'));
    }
    assert.match(html, /src="\/analytics.mjs"/);
  }
});

test('FAQ structured data matches the visible questions and answers', () => {
  for (const file of ['index.html', ...editorial.filter(route => route.startsWith('/compare/') || route === '/guides/fm-cli-to-repeatable-evals').map(fileFor)]) {
    const html = read(file);
    const faq = data(html).find(item => item['@type'] === 'FAQPage');
    assert.ok(faq, file);
    assert.ok(faq.mainEntity.length > 0);
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
  assert.deepEqual(app.sameAs, ['https://github.com/coryparrry/Intents', 'https://github.com/coryparrry/homebrew-tap', 'https://coryparry.dev/projects/intents']);
  assert.deepEqual(app.alternateName, ['Foundation Evals', 'Intents for Apple Foundation Models']);
  assert.equal(app.offers.price, '0');
  assert.equal(app.installUrl, 'https://github.com/coryparrry/homebrew-tap');
  const manifest = JSON.parse(readFileSync(new URL('../.openai/hosting.json', import.meta.url), 'utf8'));
  assert.equal(manifest.static.not_found_handling, 'none');
});

test('every public page links the project home and preserves showcase canonicals and app aliases', () => {
  for (const file of readdirSync(root, { recursive: true }).filter(file => file.endsWith('.html'))) {
    const html = read(file);
    assert.ok(html.includes('href="https://coryparry.dev/projects/intents"'), file);
    assert.doesNotMatch(html, /Intent Lab|intents\.app|aggregateRating/, file);
    const canonical = html.match(/<link rel="canonical" href="([^"]+)"/);
    assert.ok(canonical, file);
    assert.equal(new URL(canonical[1]).origin, host, file);
    assert.ok(routes.includes(new URL(canonical[1]).pathname), `${file}: missing from sitemap`);
    for (const node of data(html)) {
      const app = node['@type'] === 'SoftwareApplication' ? node : node.about;
      if (app?.['@type'] === 'SoftwareApplication') assert.ok(app.alternateName.includes('Foundation Evals'), file);
    }
    const alternate = html.match(/<link rel="alternate" type="text\/markdown" href="([^"]+)"/);
    assert.ok(alternate, `${file}: Markdown alternate link`);
    assert.equal(alternate[1], `${host}/${file}.md`, file);
    assert.ok(existsSync(new URL(`${file}.md`, root)), `${file}: Markdown alternate`);
  }
});
