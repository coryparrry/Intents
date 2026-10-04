import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';

const base = 'https://intents-workbench.coryparry.chatgpt.site/';
const read = path => readFileSync(new URL(`../dist/${path}`, import.meta.url), 'utf8');
const html = read('index.html');
const graph = JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
const metadata = key => html.match(new RegExp(`<meta (?:name|property)="${key}" content="([^"]+)"`))?.[1];

test('canonical URL, sitemap, social previews and structured page agree', () => {
  const canonical = html.match(/<link rel="canonical" href="([^"]+)"/)[1];
  const sitemap = read('sitemap.xml');
  assert.equal(canonical, base);
  assert.equal(metadata('og:url'), canonical);
  assert.match(sitemap, /xmlns="http:\/\/www\.sitemaps\.org\/schemas\/sitemap\/0\.9"/);
  assert.deepEqual([...sitemap.matchAll(/<loc>(.*?)<\/loc>/g)].map(match => match[1]), [canonical, `${base}getting-started`]);
  const lastmod = sitemap.match(/<lastmod>(.*?)<\/lastmod>/)[1];
  assert.equal(new Date(lastmod).toISOString().slice(0, 10), lastmod);
  const page = graph['@graph'].find(node => node['@type'] === 'WebPage');
  assert.equal(page.url, canonical);
  assert.equal(page.name, html.match(/<title>(.*?)<\/title>/)[1]);
  assert.equal(page.description, metadata('description'));
  for (const key of ['og:image', 'twitter:image']) {
    const image = new URL(metadata(key));
    assert.equal(image.origin, new URL(base).origin);
    assert.ok(existsSync(new URL(`../dist${image.pathname}`, import.meta.url)));
  }
  assert.equal(metadata('og:image'), metadata('twitter:image'));
});

test('structured product has resolvable identities and truthful source relationships', () => {
  assert.equal(graph['@context'], 'https://schema.org');
  const nodes = graph['@graph'];
  const ids = new Set(nodes.map(node => node['@id']));
  assert.equal(ids.size, nodes.length);
  for (const match of JSON.stringify(graph).matchAll(/"@id":"([^"]+)"/g)) assert.ok(ids.has(match[1]));
  const app = nodes.find(node => node['@type'] === 'SoftwareApplication');
  const source = nodes.find(node => node['@type'] === 'SoftwareSourceCode');
  assert.equal(source.targetProduct['@id'], app['@id']);
  assert.equal(app.subjectOf['@id'], source['@id']);
  assert.ok(app.sameAs.includes(source.codeRepository));
  assert.equal(app.license, source.license);
  assert.equal(app.isAccessibleForFree, true);
  assert.ok(!('aggregateRating' in app), 'Do not invent ratings for rich results');
  assert.ok(!('softwareVersion' in app), 'Release links must not claim an unverified version');
  const body = html.slice(html.indexOf('<body>'));
  assert.match(body, /free and open source under the MIT licence/);
  assert.match(body, /macOS 27\+/);
  assert.ok(/Apple Intelligence[–-]capable/.test(body), 'Visible hardware requirement supports the schema');
  assert.match(body, /Intent Lab/);
});

test('search and AI crawlers are permitted and can find the sitemap', () => {
  const rules = read('robots.txt').split('\n').map(line => line.split('#')[0].trim()).filter(Boolean);
  assert.deepEqual(rules, ['User-agent: *', 'Allow: /', `Sitemap: ${base}sitemap.xml`]);
  assert.match(metadata('robots'), /\bindex\b/);
  assert.match(metadata('robots'), /\bfollow\b/);
  assert.doesNotMatch(html, /noindex|nofollow|nosnippet|data-nosnippet/i);
});

test('AI reading guide is linked, resolves locally and retains product limitations', () => {
  const guide = read('llms.txt');
  const markdown = read('index.html.md');
  assert.match(html, /rel="alternate" type="text\/markdown"/);
  assert.match(html, /rel="describedby" type="text\/plain"/);
  for (const text of [html, guide, markdown]) {
    for (const match of text.matchAll(/https:\/\/intents-workbench\.coryparry\.chatgpt\.site\/([^\s"<>)]*)/g)) {
      const path = match[1].split('#')[0];
      assert.ok(existsSync(new URL(`../dist/${path === 'getting-started' ? 'getting-started.html' : path || 'index.html'}`, import.meta.url)), path);
    }
  }
  assert.ok(guide.startsWith('# Intents\n'));
  for (const text of [guide, markdown]) {
    assert.match(text, /beta/i);
    assert.match(text, /macOS 27/);
    assert.match(text, /MIT/);
    assert.match(text, /Remote providers and judges use their configured services/);
    assert.match(text, /not model benchmarks/);
  }
  const staticContent = html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '').replace(/<[^>]+>/g, ' ');
  for (const phrase of ['Foundation Models', 'Intent Lab', 'MCP server', 'MIT licence', 'Download for macOS']) {
    assert.ok(staticContent.includes(phrase), `Available without JavaScript: ${phrase}`);
  }
});

test('hosting returns not found rather than the homepage for nonexistent routes', () => {
  const hosting = JSON.parse(readFileSync(new URL('../.openai/hosting.json', import.meta.url), 'utf8'));
  assert.equal(hosting.static.not_found_handling, 'none');
  assert.equal(hosting.static.directory, 'dist');
});

test('release paths and development features stay distinct across reading formats', () => {
  const app = graph['@graph'].find(node => node['@type'] === 'SoftwareApplication');
  assert.equal(app.alternateName, 'Foundation Evals');
  assert.equal(app.downloadUrl, 'https://github.com/coryparrry/Intents/releases/download/v1.3.0/Foundation-Evals-1.3.0-macOS-arm64.dmg');
  assert.match(app.description, /published v1\.3\.0 download.*Foundation Evals; Intents development source adds Review, Batch runs, and Intent Lab/);
  for (const path of ['index.html', 'index.html.md', 'llms.txt', 'getting-started.html', 'getting-started.html.md']) {
    const content = read(path);
    assert.match(content, /Foundation Evals/);
    assert.match(content, /(?:v)?1\.3\.0/);
    assert.match(content, /development|Development|Current source|current source/);
    assert.match(content, /Review/);
    assert.match(content, /Batch runs/);
    assert.match(content, /recognized text|recognized-text/);
    assert.match(content, /(?:not|does not|do not) (?:test|prove) (?:microphone|Siri)/);
  }
  for (const path of ['index.html', 'index.html.md', 'llms.txt']) {
    assert.match(read(path), /credential-free localhost/);
    assert.match(read(path), /authenticated local/);
  }
});

test('first-use guide has its own canonical identity and working local anchors', () => {
  const guide = read('getting-started.html');
  const schema = JSON.parse(guide.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
  assert.equal(schema.url, `${base}getting-started`);
  assert.match(guide, /rel="canonical" href="https:\/\/intents-workbench\.coryparry\.chatgpt\.site\/getting-started"/);
  for (const match of html.matchAll(/href="\/getting-started(?:#([^"]+))?"/g)) {
    if (match[1]) assert.ok(guide.includes(`id="${match[1]}"`), match[1]);
  }
  assert.match(guide, /Exact text/);
  assert.match(guide, /Contains text/);
  assert.match(guide, /Suite Editor/);
  assert.match(guide, /Xcode 27/);
  assert.match(guide, /not included in the v1\.3\.0 installer/);
  assert.match(guide, /release or source commit/);
});
