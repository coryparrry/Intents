import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { EvaluationApp } from '../server/app.mjs';
import { suite as strictSuite } from '../server/validation.mjs';

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'model-bounds-'));
  const app = new EvaluationApp({ dataDir: root, invoke: async () => { throw new Error('Unexpected inference'); } });
  await app.init(); t.after(async () => { await app.shutdown(); await rm(root, { recursive: true, force: true }); });
  return app;
}
function definition(modelConfiguration = {}, profile = {}) {
  return { id: randomUUID(), name: 'native bounds', version: 'v1', cases: [{ id: randomUUID(), name: 'one', prompt: 'fruit', expected: '' }], modelConfiguration: { temperatureEnabled: true, samplingMode: 'probability', ...modelConfiguration }, features: { tools: [{ name: 'fixture', fixtureResponse: 'apple' }], profile: { enabled: true, name: 'profile', afterToolTemperatureEnabled: true, afterToolSamplingMode: 'probability', ...profile } } };
}
const bounds = {
  maximumResponseTokens: [128, 4096, 127, 4097], maximumInputTokens: [512, 32768, 511, 32769],
  temperature: [0, 1, -0.01, 1.01], probabilityThreshold: [0.01, 1, 0, 1.01],
  topK: [1, 1000, 0, 1001], maximumToolCalls: [1, 4, 0, 5],
};
const profileBounds = {
  afterToolMaximumResponseTokens: [128, 4096, 127, 4097], afterToolTemperature: [0, 1, -0.01, 1.01],
  afterToolProbabilityThreshold: [0.01, 1, 0, 1.01], afterToolTopK: [1, 1000, 0, 1001],
};
test('saved and strict app models enforce every native model/profile bound', async (t) => {
  const app = await fixture(t);
  for (const [profile, fields] of [[false, bounds], [true, profileBounds]]) {
    for (const [key, [minimum, maximum, below, above]] of Object.entries(fields)) {
      for (const value of [minimum, maximum]) {
        const source = definition(profile ? {} : { [key]: value }, profile ? { [key]: value } : {});
        const { suite } = await app.call('eval_save_suite', { suite: source });
        const strict = strictSuite(suite, randomUUID);
        assert.equal(profile ? strict.features.profile[key] : strict.modelConfiguration[key], value, `${key} accepts native boundary ${value}`);
      }
      for (const value of [below, above]) {
        const source = definition(profile ? {} : { [key]: value }, profile ? { [key]: value } : {});
        await assert.rejects(app.call('eval_save_suite', { suite: source }), new RegExp(key));
        await assert.rejects(app.store.read('suites', source.id), /not found/);
        assert.throws(() => strictSuite(source, randomUUID), new RegExp(key));
      }
    }
  }
});
test('optional profile response limit stays optional and legacy per-case limits stay compatible', async (t) => {
  const app = await fixture(t);
  const { suite: appSuite } = await app.call('eval_save_suite', { suite: definition({ maximumInputTokens: null }, { afterToolMaximumResponseTokens: null }) });
  assert.equal(appSuite.modelConfiguration.maximumInputTokens, undefined);
  assert.equal(appSuite.features.profile.afterToolMaximumResponseTokens, undefined);
  const legacy = { name: 'legacy', temperature: 1.5, maxTokens: 64, cases: [{ id: 'named-case', prompt: 'fruit', expected: 'apple', scoring: 'contains' }] };
  const { suite } = await app.call('eval_save_suite', { suite: legacy });
  assert.equal(suite.temperature, 1.5); assert.equal(suite.maxTokens, 64);
  assert.equal(suite.modelConfiguration, undefined); assert.equal(suite.cases[0].scoring, 'contains');
  assert.equal(strictSuite(suite, randomUUID).cases[0].id, 'named-case');
});

test('tool call bounds apply to every configured tool source and preserve inactive settings', async (t) => {
  const app = await fixture(t);
  const inactive = definition({ maximumToolCalls: 0 }); inactive.features.tools = [];
  const { suite } = await app.call('eval_save_suite', { suite: inactive });
  assert.equal(strictSuite(suite, randomUUID).modelConfiguration.maximumToolCalls, 0);
  for (const configure of [
    (source) => { source.modelConfiguration.referenceMode = 'lookupTool'; },
    (source) => { source.features.spotlightSearch = { enabled: true }; },
    (source) => { source.modelConfiguration.customization = { visionTools: { ocrEnabled: true } }; },
    (source) => { source.modelConfiguration.customization = { visionTools: { barcodeEnabled: true } }; },
  ]) {
    for (const maximumToolCalls of [0, 5]) {
      const source = definition({ maximumToolCalls }); source.features.tools = []; configure(source);
      await assert.rejects(app.call('eval_save_suite', { suite: source }), /maximumToolCalls/);
      assert.throws(() => strictSuite(source, randomUUID), /maximumToolCalls/);
    }
  }
});

test('native-compatible inactive saved settings round-trip and fail only when activated', async (t) => {
  const app = await fixture(t);
  for (const [inactive, activate, field] of [
    [definition({ temperatureEnabled: false, temperature: 1.5 }), (source) => { source.modelConfiguration.temperatureEnabled = true; }, 'temperature'],
    [definition({ samplingMode: 'automatic', probabilityThreshold: 0 }), (source) => { source.modelConfiguration.samplingMode = 'probability'; }, 'probabilityThreshold'],
    [definition({}, { enabled: false, afterToolTemperature: 1.5 }), (source) => { source.features.profile.enabled = true; }, 'afterToolTemperature'],
    [definition({}, { enabled: false, afterToolProbabilityThreshold: 0 }), (source) => { source.features.profile.enabled = true; }, 'afterToolProbabilityThreshold'],
    [definition({}, { enabled: false, afterToolMaximumResponseTokens: 64 }), (source) => { source.features.profile.enabled = true; }, 'afterToolMaximumResponseTokens'],
    [definition({}, { afterToolTemperatureEnabled: false, afterToolTemperature: 1.5 }), (source) => { source.features.profile.afterToolTemperatureEnabled = true; }, 'afterToolTemperature'],
    [definition({}, { afterToolSamplingMode: 'automatic', afterToolProbabilityThreshold: 0 }), (source) => { source.features.profile.afterToolSamplingMode = 'probability'; }, 'afterToolProbabilityThreshold'],
  ]) {
    const { suite } = await app.call('eval_save_suite', { suite: inactive });
    const strict = strictSuite(suite, randomUUID);
    assert.equal(field.startsWith('after') ? strict.features.profile[field] : strict.modelConfiguration[field], field.startsWith('after') ? inactive.features.profile[field] : inactive.modelConfiguration[field]);
    const activated = structuredClone(suite); activate(activated);
    await assert.rejects(app.call('eval_save_suite', { suite: activated, expectedRevision: suite.revision }), new RegExp(field));
    assert.throws(() => strictSuite(activated, randomUUID), new RegExp(field));
    assert.deepEqual(await app.store.read('suites', suite.id), suite);
  }
});


test('app suite repetitions match native bounds before save while legacy limits stay compatible', async (t) => {
  const app = await fixture(t);
  for (const repetitions of [1, 5]) {
    const source = { ...definition(), repetitions };
    const { suite } = await app.call('eval_save_suite', { suite: source });
    assert.equal(strictSuite(suite, randomUUID).repetitions, repetitions);
  }
  for (const repetitions of [0, 6, 10]) {
    const source = { ...definition(), repetitions };
    assert.throws(() => strictSuite(source, randomUUID), /repetitions/);
    await assert.rejects(app.call('eval_save_suite', { suite: source }), /repetitions/);
    await assert.rejects(app.store.read('suites', source.id), /not found/);
  }
  const legacy = { name: 'legacy repetitions', repetitions: 10, maxTokens: 64, cases: [{ id: 'one', prompt: 'fruit', scoring: 'none' }] };
  assert.equal(strictSuite(legacy, randomUUID).repetitions, 10);
  assert.equal((await app.call('eval_save_suite', { suite: legacy })).suite.repetitions, 10);
});
