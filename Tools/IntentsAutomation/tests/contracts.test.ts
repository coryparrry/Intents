import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile,mkdtemp} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {validateValue,FrameReader,requestSchema} from '../src/protocol.js';
import {OperationJournal} from '../src/operationJournal.js';
import {RpcEndpoint} from '../src/rpc.js';
import {segmentSchema} from '../src/segment.js';
import {payloadDigest} from '../src/workerRunner.js';
test('C01 shared golden values preserve exact numbers and omission',async()=>{
 const values:unknown[]=JSON.parse(await readFile(new URL('../../../../Tests/IntentsAutomationCoreTests/Fixtures/values.json',import.meta.url),'utf8'));
 for(const value of values) assert.deepEqual(validateValue(JSON.parse(JSON.stringify(value))),value);
});
test('C01 bounds, unknown tags and keys',()=>{
 assert.throws(()=>validateValue({kind:'integer',value:9007199254740993}));
 assert.throws(()=>validateValue({kind:'text',value:'x',surprise:true}));
 let value:unknown={kind:'null'};for(let i=0;i<20;i++) value={kind:'array',value:[value]};assert.throws(()=>validateValue(value));
});
test('C02 UTF8, sizes and method allowlist',()=>{
 assert.throws(()=>new FrameReader().push(Buffer.from([0xff,10])));
 assert.throws(()=>new FrameReader().push(Buffer.alloc(1024*1024+1,65)));
 assert.throws(()=>requestSchema.parse({jsonrpc:'2.0',id:'1',method:'shell',params:{}}));
 assert.throws(()=>requestSchema.parse({jsonrpc:'2.0',id:'1',method:'hello',params:{},extra:true}));
});
test('C03 reverse callbacks continue while a segment awaits',async()=>{
 const frames:string[]=[];let endpoint:RpcEndpoint;
 endpoint=new RpcEndpoint(frame=>{frames.push(frame)},async()=>endpoint.reverse('controller.decide',{goal:'Navigate'}));
 await endpoint.receive(Buffer.from('{"jsonrpc":"2.0","id":"host-1","method":"ui.runSegment","params":{}}\n'));
 await new Promise(r=>setImmediate(r));const reverse=JSON.parse(frames[0]!);
 await endpoint.receive(Buffer.from(JSON.stringify({jsonrpc:'2.0',id:reverse.id,result:{kind:'finish'}})+'\n'));
 await new Promise(r=>setImmediate(r));assert.equal(JSON.parse(frames[1]!).id,'host-1');endpoint.close();
});
test('C05 duplicate and conflicting operations, crash reopen',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'intents-journal-'));const path=join(dir,'journal.json');let calls=0;
 const journal=new OperationJournal(path);await journal.load();
 const run=()=>journal.dispatch('op','a'.repeat(64),async()=>{calls++;return {ok:true}});
 await run();await run();assert.equal(calls,1);
 await assert.rejects(()=>journal.dispatch('op','b'.repeat(64),async()=>null));
 await assert.rejects(()=>journal.dispatch('crash','c'.repeat(64),async()=>{throw new Error('disconnect')}));
 const reopened=new OperationJournal(path);await reopened.load();await assert.rejects(()=>reopened.dispatch('crash','c'.repeat(64),async()=>{calls++;return null}));assert.equal(calls,1);
});
test('journal handles reserved IDs, multiple owners and transient lock failure',async()=>{
 const {writeFile,unlink}=await import('node:fs/promises');const dir=await mkdtemp(join(tmpdir(),'intents-journal-lock-'));const path=join(dir,'journal.json');
 const first=new OperationJournal(path),second=new OperationJournal(path);await first.load();await second.load();
 for(const id of ['constructor','toString','__proto__'])await first.dispatch(id,'a'.repeat(64),async()=>id);
 assert.equal(await second.dispatch('__proto__','a'.repeat(64),async()=>{throw new Error('duplicate')}),'__proto__');
 await writeFile(path+'.lock','held');await assert.rejects(()=>first.dispatch('locked','b'.repeat(64),async()=>null));await unlink(path+'.lock');
 assert.equal(await first.dispatch('after','b'.repeat(64),async()=>true),true);
});
test('C02 RPC emits explicit null and rejects malformed callback response',async()=>{
 const frames:string[]=[];const endpoint=new RpcEndpoint(f=>frames.push(f),async()=>undefined);
 await endpoint.receive(Buffer.from('{"jsonrpc":"2.0","id":"void","method":"shutdown","params":{}}\n'));
 await new Promise(r=>setImmediate(r));assert.equal(JSON.parse(frames[0]!).result,null);
 await assert.rejects(()=>endpoint.receive(Buffer.from('{"jsonrpc":"2.0","id":"unknown"}\n')));endpoint.close();
});
test('oversized completion cannot poison the persisted journal',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'intents-journal-size-')),path=join(dir,'journal.json');const journal=new OperationJournal(path);await journal.load();
 await assert.rejects(()=>journal.dispatch('large','a'.repeat(64),async()=>({value:'x'.repeat(16*1024*1024)})));
 const reopened=new OperationJournal(path);await reopened.load();await assert.rejects(()=>reopened.dispatch('large','a'.repeat(64),async()=>true));
 assert.equal(await reopened.dispatch('small','b'.repeat(64),async()=>true),true);
});
test('C05 malformed journal files are rejected without dispatch or overwrite',async()=>{
 const {writeFile}=await import('node:fs/promises');const a='a'.repeat(64);
 const cases:[string,RegExp|{name:string}][]=[
  ['[]',/Invalid journal object/],['null',/Invalid journal object/],['"journal"',/Invalid journal object/],['42',/Invalid journal object/],
  [JSON.stringify({'../x':{digest:a,state:'completed'}}),{name:'ZodError'}],
  [JSON.stringify({op:{digest:'not-a-digest',state:'completed'}}),{name:'ZodError'}],
  [JSON.stringify({op:{digest:a,state:'pending'}}),{name:'ZodError'}],
  [JSON.stringify({op:{digest:a,state:'completed',extra:true}}),{name:'ZodError'}],
  [JSON.stringify({op:'completed'}),{name:'ZodError'}],
 ];
 for(const [content,expected] of cases){
  const dir=await mkdtemp(join(tmpdir(),'intents-journal-malformed-')),path=join(dir,'journal.json');await writeFile(path,content);let calls=0;
  const journal=new OperationJournal(path);await assert.rejects(()=>journal.load(),expected,content);
  await assert.rejects(()=>journal.dispatch('fresh','b'.repeat(64),async()=>{calls++;return true}),expected,content);
  assert.equal(calls,0,content);assert.equal(await readFile(path,'utf8'),content,content);
 }
});
test('C05 journal count limit rejects new IDs without dispatch and keeps existing replay',async()=>{
 const {writeFile}=await import('node:fs/promises');const dir=await mkdtemp(join(tmpdir(),'intents-journal-count-')),path=join(dir,'journal.json');
 const seeded:Record<string,unknown>={};for(let i=0;i<9999;i++)seeded[`seed-${i}`]={digest:'a'.repeat(64),state:'completed',response:i};
 await writeFile(path,JSON.stringify(seeded));let calls=0;const journal=new OperationJournal(path);await journal.load();
 assert.equal(await journal.dispatch('edge','b'.repeat(64),async()=>{calls++;return 'edge'}),'edge');assert.equal(calls,1);
 await assert.rejects(()=>journal.dispatch('overflow','c'.repeat(64),async()=>{calls++;return true}),/Operation journal count limit/);assert.equal(calls,1);
 assert.equal(await journal.dispatch('seed-7','a'.repeat(64),async()=>{calls++;return 'redo'}),7);assert.equal(calls,1);
 const persisted=JSON.parse(await readFile(path,'utf8'));assert.equal(Object.keys(persisted).length,10000);assert.equal(persisted.overflow,undefined);
 const reopened=new OperationJournal(path);await reopened.load();
 await assert.rejects(()=>reopened.dispatch('overflow','c'.repeat(64),async()=>{calls++;return true}),/Operation journal count limit/);assert.equal(calls,1);
});
test('C05 completion rejects when another owner changes the entry mid-dispatch',async()=>{
 const {writeFile}=await import('node:fs/promises');const a='a'.repeat(64);
 const rewrites:Record<string,unknown>[]=[{},{op:{digest:'b'.repeat(64),state:'dispatched'}},{op:{digest:a,state:'completed',response:'other owner'}}];
 for(const rewrite of rewrites){
  const dir=await mkdtemp(join(tmpdir(),'intents-journal-completion-')),path=join(dir,'journal.json');let calls=0;
  const journal=new OperationJournal(path);await journal.load();
  await assert.rejects(()=>journal.dispatch('op',a,async()=>{calls++;
   assert.equal(JSON.parse(await readFile(path,'utf8')).op.state,'dispatched');await writeFile(path,JSON.stringify(rewrite));return 'mine';}),/Conflicting completion/);
  assert.equal(calls,1);assert.deepEqual(JSON.parse(await readFile(path,'utf8')),rewrite);
 }
});

test('C01 Unicode limits use the same UTF-16 code units as Swift',()=>{
 assert.equal(validateValue({kind:'text',value:'😀'.repeat(16384)}).kind,'text');
 assert.throws(()=>validateValue({kind:'text',value:'😀'.repeat(16385)}));
 assert.throws(()=>validateValue({kind:'entity',typeId:'Item',value:'😀'.repeat(513)}));
});

test('C01 native UI program golden shares strict schema and canonical payload digest',async()=>{
 const payload=segmentSchema.parse(JSON.parse(await readFile(new URL('../../../../Tests/IntentsAutomationCoreTests/Fixtures/ui-program.json',import.meta.url),'utf8')));
 const {payloadDigest:claimed,...body}=payload;assert.equal(payloadDigest(body),claimed);
});

test('exact button role only qualifies frozen label taps',()=>{
 const body={scope:{protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'setup',leaseGeneration:1},operationId:'attempt:setup',payloadDigest:'a'.repeat(64),phase:'setup',bindings:{},timeoutMs:1000};
 const locator={kind:'label',value:'Wrong record',role:'button'};
 assert.equal(segmentSchema.parse({...body,operations:[{id:'choose',kind:'tap',locator}]}).operations.length,1);
 for(const operation of [{id:'choose',kind:'tap',locator:{...locator,kind:'testId'}},{id:'choose',kind:'observeProperty',locator,property:'text'},
  {id:'choose',kind:'assertEndpoint',locator},{id:'choose',kind:'tap',locator:{...locator,role:'text'}}]){
  assert.throws(()=>segmentSchema.parse({...body,operations:[operation]}));
 }
});

test('goal fill whitelist and required activity must refer to supplied values',()=>{
 const goal={id:'create',instruction:'Create',endpoint:{kind:'testId',value:'done'},maximumCalls:12,maximumActions:30};
 const segment={scope:{protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'setup',leaseGeneration:1},operationId:'run:attempt:setup',payloadDigest:'a'.repeat(64),phase:'setup',operations:[{kind:'navigateGoal',id:'create',goal}],bindings:{},timeoutMs:120000};
 for(const extra of [{allowedFillBindings:['missing']},{minimumBindingUses:{missing:1}}])assert.equal(segmentSchema.safeParse({...segment,operations:[{kind:'navigateGoal',id:'create',goal:{...goal,...extra}}]}).success,false);
 assert.equal(segmentSchema.safeParse({...segment,operations:[{kind:'navigateGoal',id:'create',goal:{...goal,allowedFillBindings:[]}}]}).success,true);
 assert.equal(segmentSchema.safeParse({...segment,bindings:{approved:'input'},operations:[{kind:'navigateGoal',id:'create',goal:{...goal,allowedFillBindings:['approved'],minimumBindingUses:{approved:1}}}]}).success,true);
});

test('C01 explicit v2 and missing-version v1 share numeric-key and escaping goldens',async()=>{
 const {segmentPayloadDigest,nativePayloadDigest}=await import('../src/payloadDigest.js');
 for(const name of ['ui-program-v2','ui-program-v1-numeric']){
  const raw=JSON.parse(await readFile(new URL('../../../../Tests/IntentsAutomationCoreTests/Fixtures/'+name+'.json',import.meta.url),'utf8'));
  const parsed=segmentSchema.parse(raw);const {payloadDigest:claimed,...body}=parsed;
  assert.equal(segmentPayloadDigest(body),claimed);
  assert.equal(Object.hasOwn(parsed,'digestVersion'),name==='ui-program-v2');
  if(name==='ui-program-v2')assert.notEqual(payloadDigest(body),nativePayloadDigest(body));
 }
});
test('C01 digest version cannot use alternate hash or unsupported version spelling',async()=>{
 const {validateMacOwnedProgram}=await import('../src/macOwnedProgram.js');
 const {segmentPayloadDigest}=await import('../src/payloadDigest.js');
 const fixture=JSON.parse(await readFile(new URL('../../../../Tests/IntentsAutomationCoreTests/Fixtures/ui-program-v2.json',import.meta.url),'utf8'));
 assert.equal(validateMacOwnedProgram(fixture,false,true).digestVersion,2);
 const {payloadDigest:_,...body}=fixture;
 assert.throws(()=>validateMacOwnedProgram({...fixture,payloadDigest:payloadDigest(body)},false,true),/digest mismatch/);
 for(const version of [1,3,0,'2',null])assert.throws(()=>segmentSchema.parse({...fixture,digestVersion:version}));
 assert.throws(()=>segmentPayloadDigest({...body,digestVersion:1}),/Unsupported/);
 const {digestVersion:ignored,...legacyBody}=body;
 assert.throws(()=>validateMacOwnedProgram({...legacyBody,payloadDigest:fixture.payloadDigest},false,true),/digest mismatch/);
});

test('C01 prototype-name binding keys are preserved rather than silently removed by schema parsing',async()=>{
 const {segmentPayloadDigest}=await import('../src/payloadDigest.js');
 const raw=JSON.parse(await readFile(new URL('../../../../Tests/IntentsAutomationCoreTests/Fixtures/ui-program-v2.json',import.meta.url),'utf8'));
 const {payloadDigest:_,...base}=raw;
 const body={...base,operations:[{kind:'fillBinding',id:'fill',binding:'__proto__',locator:{kind:'testId',value:'field'}}],bindings:Object.fromEntries([['__proto__','approved public literal']])};
 const parsed=segmentSchema.parse({...body,payloadDigest:segmentPayloadDigest(body)});
 assert.equal(Object.hasOwn(parsed.bindings,'__proto__'),true);assert.equal(parsed.bindings.__proto__,'approved public literal');
 const {payloadDigest:claimed,...checked}=parsed;assert.equal(segmentPayloadDigest(checked),claimed);
 assert.throws(()=>segmentSchema.parse({...body,bindings:Array(1),payloadDigest:claimed}));
 assert.throws(()=>segmentSchema.parse({...body,bindings:Object.fromEntries(Array.from({length:31},(_,i)=>['binding'+i,'literal'])),payloadDigest:claimed}));
});
