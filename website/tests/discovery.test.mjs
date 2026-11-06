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
      assert.ok(existsSync(new URL(`../dist/${!path ? 'index.html' : /\.[^/]+$/.test(path) ? path : `${path}.html`}`, import.meta.url)), path);
    }
  }
});

test('Mac App Intent content explains the native contract and signing requirements', () => {
  for (const text of [html, read('app.js'), read('index.html.md'), read('getting-started.html'), read('getting-started.html.md'), read('llms.txt')]) {
    assert.match(text, /AppIntentsTesting/);
    assert.match(text, /JSON/);
    assert.match(text, /sign(?:ing|ed|atures)/i);
    assert.doesNotMatch(text, /unshipped (?:source|Mac App Intent)|source-only Mac App Intent/i);
  }
  assert.match(html, /id="mac-app-intents"/);
  assert.match(html, /Illustrative contract · no action runs in this browser/);
});

test('interactive contract discloses its execution limits', () => {
  const app = read('app.js');
  assert.match(app, /Sample JSON contract\. Run the action on your Mac with App Intent Testing in Intents 1\.6\.0/);
  assert.match(app, /does not verify Siri/);
});
