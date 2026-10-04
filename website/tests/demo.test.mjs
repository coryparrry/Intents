import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { cases, spans, filterCases, resolveSelection, escapeHTML } from '../dist/demo-data.mjs';

test('search matches case names, prompts, and responses without case sensitivity', () => {
  assert.deepEqual(filterCases(cases,'all','  FRIDAY ').map(item => item.id),['correction']);
  assert.deepEqual(filterCases(cases,'all','compatible constraint').map(item => item.id),['constraint']);
  assert.deepEqual(filterCases(cases,'all','Café Royal').map(item => item.id),['preference']);
});

test('status and search filters intersect rather than leak unrelated results', () => {
  const mixed = [...cases,{id:'failure',name:'Friday failure',prompt:'Friday',response:'Thursday',status:'failed'}];
  assert.deepEqual(filterCases(mixed,'passed','Friday').map(item => item.id),['correction']);
  assert.deepEqual(filterCases(mixed,'failed','Friday').map(item => item.id),['failure']);
  assert.equal(filterCases(cases,'failed','').length,0);
  assert.equal(filterCases(cases,'issues','').length,0);
});

test('empty search restores all cases and unmatched input returns no cases', () => {
  assert.equal(filterCases(cases,'all','  ').length,3);
  assert.equal(filterCases(cases,'all','no-such-result').length,0);
  assert.equal(filterCases(cases,'all','<script>').length,0);
});

test('selection cannot retain a stale response after filtering', () => {
  const filtered = filterCases(cases,'all','Friday');
  assert.equal(resolveSelection(filtered,'preference').id,'correction');
  assert.equal(resolveSelection([],'correction'),null);
  assert.equal(resolveSelection(cases,'constraint').id,'constraint');
});

test('model text is escaped before insertion into HTML', () => {
  assert.equal(escapeHTML('<img src=x onerror="alert(1)"> & \'x\''),'&lt;img src=x onerror=&quot;alert(1)&quot;&gt; &amp; &#39;x&#39;');
});

test('recorded trace has 13 unique spans with bounded expanded-scale bars', () => {
  assert.equal(spans.length,13);
  assert.equal(new Set(spans.map(span => span.name)).size,13);
  for(const span of spans) {
    assert.ok(span.x >= 0 && span.width > 0 && span.x + span.width <= 100);
    assert.ok(span.duration && span.start && span.end);
  }
  assert.equal(spans.find(span => span.name === 'Generate response').duration,'2.68 s');
  assert.equal(spans.find(span => span.name === 'Score response').duration,'9.00 s');
});

test('local assets and section links in the published HTML resolve', () => {
  const html = readFileSync(new URL('../dist/index.html',import.meta.url),'utf8');
  for(const [,path] of html.matchAll(/(?:src|href)="(\/[^"#]+)(?:#[^"]*)?"/g)) {
    assert.ok(existsSync(fileURLToPath(new URL(`../dist${path === '/getting-started' ? '/getting-started.html' : path}`,import.meta.url))),path);
  }
  const ids = new Set([...html.matchAll(/id="([^"]+)"/g)].map(match => match[1]));
  for(const [,id] of html.matchAll(/href="#([^"]+)"/g)) assert.ok(ids.has(id),id);
  assert.equal([...html.matchAll(/<h1\b/g)].length,1);
});

test('all rendered icon names exist in the vendored native icon sprite', () => {
  const sprite = readFileSync(new URL('../dist/assets/icons.svg',import.meta.url),'utf8');
  const icons = new Set([...sprite.matchAll(/id="([^"]+)"/g)].map(match => match[1]));
  const html = readFileSync(new URL('../dist/index.html',import.meta.url),'utf8');
  for(const [,name] of html.matchAll(/icons.svg#([^"\s]+)/g)) assert.ok(icons.has(name),name);
  for(const span of spans) assert.ok(icons.has(span.icon),span.icon);
});
