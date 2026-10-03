import test from 'node:test';
import assert from 'node:assert/strict';
import { createViewMotion, copyCurrentResponse } from '../dist/demo-interactions.mjs';

function animationStub() {
  const contexts = [];
  return {
    contexts,
    context(animate) {
      animate();
      const context = {reverted: 0, revert() { this.reverted++; }};
      contexts.push(context);
      return context;
    }
  };
}

test('disabling view motion reverts its active animation once', () => {
  const motion = createViewMotion();
  const gsap = animationStub();
  motion.clear();
  motion.start(gsap, () => {});
  motion.clear();
  motion.clear();
  assert.equal(gsap.contexts[0].reverted, 1);
});

test('a new view restores the previous animation before starting its own', () => {
  const motion = createViewMotion();
  const gsap = animationStub();
  motion.start(gsap, () => {});
  motion.start(gsap, () => assert.equal(gsap.contexts[0].reverted, 1));
  assert.equal(gsap.contexts[1].reverted, 0);
  motion.clear();
  assert.equal(gsap.contexts[1].reverted, 1);
});

test('copy confirms the original text only after the clipboard succeeds', async () => {
  const result = [];
  let finish;
  const pending = copyCurrentResponse({
    text: 'Recorded response',
    writeText(text) {
      assert.equal(text, 'Recorded response');
      return new Promise(resolve => { finish = resolve; });
    },
    isCurrent: () => true,
    onResult: copied => result.push(copied)
  });
  assert.deepEqual(result, []);
  finish();
  await pending;
  assert.deepEqual(result, [true]);
});

test('a current copy failure reports the fallback', async () => {
  const result = [];
  await copyCurrentResponse({
    text: 'Recorded response',
    writeText: async () => { throw new Error('Permission denied'); },
    isCurrent: () => true,
    onResult: copied => result.push(copied)
  });
  assert.deepEqual(result, [false]);
});

for (const succeeds of [true, false]) {
  test(`replacing a response ignores a pending copy ${succeeds ? 'success' : 'failure'}`, async () => {
    let current = true;
    let finish;
    const result = [];
    const pending = copyCurrentResponse({
      text: 'Original response',
      writeText: () => new Promise((resolve, reject) => {
        finish = () => succeeds ? resolve() : reject(new Error('Permission denied'));
      }),
      isCurrent: () => current,
      onResult: copied => result.push(copied)
    });
    current = false;
    finish();
    await pending;
    assert.deepEqual(result, []);
  });
}

test('an unavailable clipboard reports the fallback without rejecting', async () => {
  const result = [];
  await copyCurrentResponse({
    text: 'Recorded response',
    writeText: () => { throw new TypeError('Clipboard unavailable'); },
    isCurrent: () => true,
    onResult: copied => result.push(copied)
  });
  assert.deepEqual(result, [false]);
});
