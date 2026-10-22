import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';

const read = path => readFileSync(new URL(`../dist/${path}`, import.meta.url), 'utf8');
const html = read('index.html');

test('published HTML and AI reading guides resolve their local links', () => {
  const guide = read('llms.txt');
  const markdown = read('index.html.md');
  for (const text of [html, guide, markdown]) {
    for (const match of text.matchAll(/https:\/\/intents-workbench\.coryparry\.chatgpt\.site\/([^\s"<>)]*)/g)) {
      const path = match[1].split('#')[0];
      assert.ok(existsSync(new URL(`../dist/${path === 'getting-started' ? 'getting-started.html' : path || 'index.html'}`, import.meta.url)), path);
    }
  }
});

test('homepage first-use guide links resolve to published section anchors', () => {
  const guide = read('getting-started.html');
  for (const match of html.matchAll(/href="\/getting-started(?:#([^"]+))?"/g)) {
    if (match[1]) assert.ok(guide.includes(`id="${match[1]}"`), match[1]);
  }
});

test('Mac App Intent content identifies the unshipped native contract and requirements', () => {
  for (const text of [html, read('app.js'), read('index.html.md'), read('getting-started.html'), read('getting-started.html.md'), read('llms.txt')]) {
    assert.match(text, /AppIntentsTesting/);
    assert.match(text, /JSON/);
    assert.match(text, /unshipped|[Dd]evelopment source/);
    assert.match(text, /[Ll]ive (?:runner )?reliability (?:remains |is (?:not )?)?unqualified|live runner reliability is not qualified/);
    assert.match(text, /sign(?:ing|ed|atures)/i);
  }
  assert.match(html, /id="mac-app-intents"/);
  assert.match(html, /Illustrative contract · no action runs in this browser/);
});

test('interactive contract declares its inputs, expected result and evidence limits', () => {
  const app = read('app.js');
  assert.match(app, /function macIntentMarkup\(\)/);
  assert.match(app, /\{"message":"Hello"\}/);
  assert.match(app, /Expected JSON/);
  assert.match(app, /not a recorded invocation or a feature of the published 1\.4\.0 download/);
  assert.match(app, /does not verify Siri/);
  assert.match(app, /\['explore-mac-intents','mac-intent'\]/);
});
