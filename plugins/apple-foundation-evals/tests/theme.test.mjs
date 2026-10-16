import test from 'node:test';
import assert from 'node:assert/strict';
import { applyHostContext } from '../ui/theme.js';
function documentStub() {
  const elements = [];
  const variables = new Map();
  return { variables, elements, documentElement: { dataset: {}, style: { setProperty: (name, value) => variables.set(name, value) } },
    getElementById: id => elements.find(element => element.id === id),
    createElement: tag => ({ tagName: tag }), head: { append: element => elements.push(element) } };
}
test('initial host theme and font/color variables are applied before rendering', () => {
  const document = documentStub();
  applyHostContext({ theme: 'dark', styles: { variables: { '--color-background-primary': '#212121', '--font-sans': 'Host Sans', invalid: 'ignored', '--bad-value': 42 } } }, document);
  assert.equal(document.documentElement.dataset.theme, 'dark');
  assert.equal(document.documentElement.style.colorScheme, 'dark');
  assert.equal(document.variables.get('--color-background-primary'), '#212121');
  assert.equal(document.variables.get('--font-sans'), 'Host Sans');
  assert.equal(document.variables.size, 2);
});
test('live updates change theme colors while partial context retains existing host values', () => {
  const document = documentStub();
  applyHostContext({ theme: 'dark', styles: { variables: { '--font-sans': 'Host Sans', '--color-background-primary': '#212121' } } }, document);
  applyHostContext({ theme: 'light', styles: { variables: { '--color-background-primary': '#fff' } } }, document);
  applyHostContext({ displayMode: 'fullscreen' }, document);
  assert.equal(document.documentElement.style.colorScheme, 'light');
  assert.equal(document.variables.get('--color-background-primary'), '#fff');
  assert.equal(document.variables.get('--font-sans'), 'Host Sans');
});
test('host font CSS is installed once and updated when fonts change', () => {
  const document = documentStub();
  applyHostContext({ styles: { css: { fonts: '@font-face { font-family: Host; }' } } }, document);
  applyHostContext({ styles: { css: { fonts: '@font-face { font-family: Updated; }' } } }, document);
  assert.equal(document.elements.length, 1);
  assert.equal(document.elements[0].textContent, '@font-face { font-family: Updated; }');
});
test('absent or invalid host themes leave system appearance intact', () => {
  const document = documentStub();
  for (const context of [undefined, null, 'dark', {}, { theme: 'unknown' }]) applyHostContext(context, document);
  assert.equal(document.documentElement.style.colorScheme, undefined);
  assert.equal(document.elements.length, 0);
});
