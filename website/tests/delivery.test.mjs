import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const root = new URL('../dist/', import.meta.url);
const html = readFileSync(new URL('index.html', root), 'utf8');

test('first paint has the exact authored stylesheet cascade without network dependencies', () => {
  const css = ['styles.css', 'native.css'].map(path => readFileSync(new URL(path, root), 'utf8')).join('\n');
  const blocks = [...html.matchAll(/<style id="site-styles">\n([\s\S]*?)<\/style>/g)];
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0][1], css);
  assert.doesNotMatch(html, /<link\b[^>]*rel="stylesheet"/);
  assert.doesNotMatch(css, /@import\b/);
  assert.ok(html.indexOf('<style id="site-styles">') < html.indexOf('<body>'));
  assert.match(html, /<link rel="modulepreload" href="\/demo-data\.mjs">/);
});

test('responsive icon candidates exist at their declared dimensions with bounded delivery size', () => {
  const images = [...html.matchAll(/<img\b[^>]*srcset="([^"]+)"[^>]*>/g)];
  assert.equal(images.length, 2);
  const original = readFileSync(new URL('assets/intents-icon.png', root));
  for (const [, srcset] of images) {
    for (const candidate of srcset.split(',')) {
      const [path, width] = candidate.trim().split(/\s+/);
      const png = readFileSync(new URL(path.slice(1), root));
      assert.equal(png.subarray(1, 4).toString(), 'PNG');
      assert.equal(png.readUInt32BE(16), Number.parseInt(width));
      assert.equal(png.readUInt32BE(20), Number.parseInt(width));
      if (Number.parseInt(width) <= 74) assert.ok(png.length < original.length / 4);
    }
  }
  assert.doesNotMatch(images[0][0], /loading="lazy"/, 'The first visible brand icon must not load lazily');
  assert.match(images[1][0], /loading="lazy"/);
  const favicon = readFileSync(new URL('assets/favicon.png', root));
  assert.equal(favicon.readUInt32BE(16), 96);
  assert.equal(favicon.readUInt32BE(20), 96);
});
