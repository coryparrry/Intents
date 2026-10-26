import test from 'node:test';
import assert from 'node:assert/strict';
import { createDraftAutosave } from '../ui/autosave.js';
import { caseTitle,resultTitle } from '../ui/presentation.js';
import { nativeScore } from '../ui/native-results.js';
import { nativeRewritePrompt,promptRewriteRequest,watchPromptPreview } from '../ui/workflows.js';
import { newAppSuite } from '../ui/native-suite.js';

/** Opens the real writing workflow around a delayed model response and records its visible actions and draft effects. */
async function rewriteFixture(t) {
 const original = { id: 'case', prompt: 'Only JSON' }, owner = { id: 'suite', cases: [original] };
 const state = { draft: owner }, buttons = new Map(), calls = [];
 let complete, body, changes = 0, renders = 0;
 const response = new Promise(resolve => { complete = resolve; });
 /** Supplies DOM-style content and close events without mounting the unrelated workspace shell. */
 function element(tag, text = '') {
  const node = new EventTarget();
  Object.assign(node, { tag, textContent: text, children: [], value: '', append(...children) { this.children.push(...children); }, setAttribute() {}, close() { this.closed = true; this.dispatchEvent(new Event('close')); } });
  return node;
 }
 const ctx = { state, node: element, newSuite: newAppSuite, active: () => false,
  dialog(_title, render) { body = element('dialog'); render(body); },
  button(text, action, _style, disabled) { const node = element('button', text); Object.assign(node, { action, disabled }); buttons.set(text, node); return node; },
  call(name, args) { calls.push({ name, args }); return name === 'eval_preview_response' ? response : Promise.resolve({}); },
  changed() { changes++; }, renderMain() { renders++; },
 };
 await nativeRewritePrompt(ctx, original, 'grammar');
 const pending = buttons.get('Preview').action();
 t.after(async () => { complete({ response: 'Revised JSON' }); await pending; body.close(); });
 return { state, owner, original, buttons, body, calls, effects: () => ({ changes, renders }),
  async finish() { complete({ response: '  Revised JSON  ' }); await pending; },
 };
}
test('autosave serializes snapshots and retains typing during an in-flight save',async()=>{
 const draft={id:'suite',name:'first'},saved=[],resolvers=[],states=[];
 const queue=createDraftAutosave({read:()=>draft,save:snapshot=>{saved.push(snapshot);return new Promise(resolve=>resolvers.push(resolve));},applied:(current,response)=>{current.revision=response.revision;},status:status=>states.push(status),error:error=>{throw error;},delay:10000});
 queue.changed();const flushed=queue.flush();draft.name='second';queue.changed();assert.equal(saved[0].name,'first');resolvers.shift()({revision:'one'});await new Promise(resolve=>setImmediate(resolve));assert.equal(saved[1].name,'second');assert.equal(saved[1].revision,'one');resolvers.shift()({revision:'two'});await flushed;assert.equal(draft.name,'second');assert.equal(draft.revision,'two');assert.equal(states.at(-1),'saved');queue.dispose();
});
test('a failed autosave preserves pending edits and a retry saves them',async()=>{
 const draft={name:'edited'},states=[];let attempts=0;
 const queue=createDraftAutosave({read:()=>draft,save:async value=>{if(++attempts===1)throw Error('Revision conflict');return value;},applied:()=>{},status:status=>states.push(status),error:()=>{},delay:10000});queue.changed();await assert.rejects(queue.flush(),/Revision conflict/);assert.equal(draft.name,'edited');assert.equal(states.at(-1),'error');await queue.flush();assert.equal(states.at(-1),'saved');queue.dispose();
});
test('display retains named cases despite native uppercase UUIDs and app scoring scale',()=>{
 const id='6AA53269-2571-4005-B40D-25BC14D518FD',run={suite:{cases:[{id:id.toLowerCase(),name:'Keep preference'}]}};
 assert.equal(caseTitle({id,name:'Latest preference wins'}),'Latest preference wins');assert.equal(resultTitle(run,{caseId:id}),'Keep preference');assert.equal(resultTitle(run,{caseId:id,appSample:{caseName:'Original case name'}}),'Original case name');assert.equal(nativeScore({score:3,scoreScale:'appRubric'}),'3/4');assert.equal(nativeScore({score:1}),'1');
});
test('writing tools preserve app instructions and keep a revision on its original case',async t=>{
 assert.match(promptRewriteRequest('Only JSON','grammar'),/without changing its requirements or meaning/);assert.match(promptRewriteRequest('Only JSON','prompt','Keep the keys'),/Keep the keys\n\nOriginal evaluation prompt:\nOnly JSON$/);
 const f = await rewriteFixture(t);
 assert.equal(f.buttons.get('Keep').disabled, true);
 await f.finish();
 assert.equal(f.buttons.get('Keep').disabled, false);
 f.buttons.get('Keep').action();
 assert.equal(f.original.prompt, 'Revised JSON');
 assert.deepEqual(f.effects(), { changes: 1, renders: 1 });
 assert.equal(f.body.closed, true);
 assert.equal(f.calls[0].args.suite.features.streamResponse, true);
});

for (const change of ['suite object', 'case object', 'suite identity', 'prompt text', 'prompt type']) {
 test(`writing revision rejects changed ${change} while the model response is pending`, async t => {
  const f = await rewriteFixture(t);
  if (change === 'suite object') f.state.draft = { ...f.owner };
  else if (change === 'case object') f.owner.cases = [{ ...f.original }];
  else if (change === 'suite identity') f.owner.id = 'another-suite';
  else if (change === 'prompt text') f.original.prompt = 'New user edit';
  else f.original.prompt = new String(f.original.prompt);
  const prompt = f.original.prompt;
  await f.finish();
  assert.throws(() => f.buttons.get('Keep').action(), /prompt changed/);
  assert.equal(f.original.prompt, prompt);
  assert.deepEqual(f.effects(), { changes: 0, renders: 0 });
  assert.equal(f.body.closed, undefined);
 });
}
test('native app sample envelope and full Apple transcript document retain readable evidence',async()=>{
 const {transcriptEntries}=await import('../ui/presentation.js');
 const result={caseId:'case',score:4,trace:{appSample:{caseName:'Native case'},transcript:[{type:'FoundationModels.Transcript',transcript:{entries:[{role:'user',contents:[{text:'Only apple'}]},{role:'response',contents:[{text:'apple'}]}]}}]}};
 assert.equal(resultTitle({},result),'Native case');assert.equal(nativeScore(result),'4/4');assert.deepEqual(transcriptEntries(result).map(entry=>[entry.role,entry.text]),[['User','Only apple'],['Model','apple']]);
});
test('base64 Apple Codable Data is displayed as decoded JSON rather than an opaque string',async()=>{
 const {transcriptJSONText}=await import('../ui/presentation.js');const document={transcript:{entries:[{role:'user',contents:[{text:'café'}]}]}};
 const raw=Buffer.from(JSON.stringify(document)).toString('base64');assert.deepEqual(JSON.parse(transcriptJSONText({trace:{appSample:{featureTrace:{transcript:{transcriptJSON:raw}}}}})),document);
});

test('prompt preview shows only its own streamed evidence and closing cancels its request',async()=>{
 let update=[],cancelled=[],cleared=0,status={preview:{id:'other',liveResponse:'unrelated'}};
 const watcher=watchPromptPreview({previewId:'mine',readStatus:async()=>status,cancel:async id=>cancelled.push(id),onResponse:text=>update.push(text),schedule:()=>1,unschedule:()=>cleared++});
 await watcher.poll();assert.deepEqual(update,[]);status={preview:{id:'mine',liveResponse:{text:'actual stream',phase:'responding'}}};await watcher.poll();assert.deepEqual(update,['actual stream']);await watcher.close();await watcher.poll();assert.deepEqual(cancelled,['mine']);assert.equal(cleared,1);
});
test('completed or closed preview ignores a delayed stream and does not cancel a later preview',async()=>{
 let resolve,updates=0,cancelled=0;
 const watcher=watchPromptPreview({previewId:'mine',readStatus:()=>new Promise(done=>resolve=done),cancel:async()=>cancelled++,onResponse:()=>updates++,schedule:()=>1,unschedule:()=>{}});
 const pending=watcher.poll();watcher.finish();resolve({preview:{id:'mine',liveResponse:'late'}});await pending;await watcher.close();assert.equal(updates,0);assert.equal(cancelled,0);
});

test('file preview re-export preserves the raw app trace and its assessment evidence',async()=>{
 const {traceExportPayload}=await import('../ui/presentation.js');const raw={id:'app-id',samples:[{id:'sample-id',score:4}],assessments:[{id:'judge-id'}]};const normalized={id:'plugin-id',results:[],appRun:raw};assert.deepEqual(traceExportPayload(normalized),raw);assert.equal(traceExportPayload({id:'legacy'}).run.id,'legacy');
});
