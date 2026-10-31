import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { tabDestination, duplicateSuiteDraft, comparisonSelection } from '../ui/workspace-controls.js';
import { EvaluationApp } from '../server/app.mjs';
import { newAppSuite } from '../ui/native-suite.js';

test('tab keyboard movement wraps and supports Home/End without handling editing keys', () => {
  assert.equal(tabDestination('ArrowRight', 3, 4), 0);
  assert.equal(tabDestination('ArrowLeft', 0, 4), 3);
  assert.equal(tabDestination('Home', 2, 4), 0);
  assert.equal(tabDestination('End', 0, 4), 3);
  assert.equal(tabDestination('Enter', 1, 4), null);
  assert.equal(tabDestination('ArrowRight', 0, 0), null);
});

test('suite duplication drops storage identity while preserving independent case/settings/reference data', () => {
  const source = {...newAppSuite(randomUUID()), revision:'old',createdAt:'old',updatedAt:'old'};
  source.attachments = [{id:randomUUID(), name:'Reference',extractedText:'apple'}];
  const copy = duplicateSuiteDraft(source);
  assert.equal(copy.name, `${source.name} copy`);
  for (const key of ['id','revision','projectId','createdAt','updatedAt']) assert.equal(key in copy,false,key);
  for (const key of ['cases','features','modelConfiguration','attachments']) assert.deepEqual(copy[key],source[key]);
  copy.cases[0].prompt = 'changed';
  copy.modelConfiguration.temperature = .2;
  assert.notEqual(source.cases[0].prompt,'changed');
  assert.equal(source.modelConfiguration.temperature,.7);
  assert.equal(duplicateSuiteDraft({...source,name:'a'.repeat(160)}).name.length,160);
});

test('2–4 run selection preserves ordering, removes missing/duplicate runs and fills new slots', () => {
  const runs=['a','b','c','d'].map(id=>({id}));
  assert.deepEqual(comparisonSelection(runs,['c','a'],4),['c','a','b','d']);
  assert.deepEqual(comparisonSelection(runs,['missing','b','b'],3),['b','a','c']);
  assert.deepEqual(comparisonSelection(runs,['c','a','b','d'],2),['c','a']);
  assert.deepEqual(comparisonSelection([],['a'],4),[]);
});

test('duplicated suite saves with a new identity, keeps original intact, and survives deleting the copy', async t => {
  const directory=await mkdtemp(join(tmpdir(),'foundation-evals-duplicate-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  const app=new EvaluationApp({dataDir:directory});
  await app.init();t.after(()=>app.shutdown());
  const original=(await app.call('eval_save_suite',{suite:newAppSuite((await app.call('eval_list_projects')).projects[0].id)})).suite;
  const copy=(await app.call('eval_save_suite',{projectId:original.projectId,suite:duplicateSuiteDraft(original)})).suite;
  assert.notEqual(copy.id,original.id);
  assert.equal(copy.projectId,original.projectId);
  assert.deepEqual(copy.cases,original.cases);
  assert.deepEqual(copy.features,original.features);
  await app.call('eval_delete_suite',{suiteId:copy.id});
  const suites=(await app.call('eval_list_suites')).suites;
  assert.ok(suites.some(suite=>suite.id===original.id));
  assert.ok(!suites.some(suite=>suite.id===copy.id));
});
