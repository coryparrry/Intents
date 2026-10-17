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
