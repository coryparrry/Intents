import test from 'node:test';import assert from 'node:assert/strict';
import {mkdtemp,rm,readFile,writeFile} from 'node:fs/promises';import {join} from 'node:path';import {tmpdir} from 'node:os';
import {MacOwnedProgramController} from '../src/macOwnedProgramController.js';
import {MacOwnedSession} from '../src/macOwnedSession.js';import {OperationJournal} from '../src/operationJournal.js';
import {OwnedUIWorkerError} from '../src/ownedUIWorker.js';import {payloadDigest} from '../src/workerRunner.js';
import type {Segment} from '../src/segment.js';import type {Scope,Target} from '../src/protocol.js';
import type {runMacOwnedProgram,MacOwnedProgramReceipt} from '../src/macOwnedProgram.js';

async function fixture(execute:typeof runMacOwnedProgram,capabilities=false){
 const root=await mkdtemp(join(tmpdir(),'intents-mac-program-controller-'));
 const target:Target={id:'host-macos-local',platform:'macos',kind:'nativeMac',bundleId:'example.Fixture',bundlePath:'/Applications/Fixture.app',loginSession:'synthetic'};
 const scope:Scope={protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:1};
 const instance={bundleId:target.bundleId,canonicalBundlePath:target.bundlePath!,pid:123,processStartIdentity:'100:0'};
 const session=await MacOwnedSession.acquire(target,scope,{open:async()=>({applicationTarget:instance,deviceId:target.id,sessionName:'intents-run-1',appBundleId:target.bundleId}),
  capture:async()=>{throw new Error('No real capture in controller fixture');},press:async()=>{throw new Error('No real input in controller fixture');},
  ...(capabilities?{ordinaryFill:async()=>{throw new Error('No real fill in controller fixture');},scroll:async()=>{throw new Error('No real scroll in controller fixture');}}:{}),
  release:async()=>({scope,applicationTarget:instance,commandsDrained:true,ownedHelperReaped:true,daemonStopped:true,subjectTerminated:false})},async()=>{});
 const body={scope,operationId:'operation',phase:'subject' as const,operations:[{id:'locate',kind:'locate' as const,locator:{kind:'testId' as const,value:'open'}}],bindings:{},timeoutMs:1000};
 const segment:Segment={...body,payloadDigest:payloadDigest(body)};
 const journalPath=join(root,'operations.json');
 const controller=new MacOwnedProgramController(session,root,new OperationJournal(journalPath),async()=>{},undefined,execute);
 return {root,scope,segment,controller,journalPath,remove:async()=>{await controller.stop();await session.release();await rm(root,{recursive:true,force:true});}};
}
function receipt(input:unknown):MacOwnedProgramReceipt {
 const segment=input as Segment;return {schemaVersion:1,scope:segment.scope,operationId:segment.operationId,complete:true,outputs:{locate:1}};
}
test('completed private program is cached once and conflicting payload cannot redispatch',async()=>{
 let executions=0;const f=await fixture(async(_session,input,root)=>{executions++;assert.equal(root.split('/').at(-1),(input as Segment).payloadDigest);return receipt(input);});
 try{
  assert.deepEqual(await f.controller.run(f.segment),await f.controller.run(f.segment));assert.equal(executions,1);
  const changed={...f.segment,timeoutMs:1001};const {payloadDigest:_,...body}=changed;changed.payloadDigest=payloadDigest(body);
  await assert.rejects(f.controller.run(changed),/Conflicting operation payload/);assert.equal(executions,1);
 }finally{await f.remove();}
});
test('failed private mutation remains dispatched and cannot retry',async()=>{
 let executions=0;const f=await fixture(async()=>{executions++;throw new OwnedUIWorkerError('Uncertain input',true);});
 try{
  await assert.rejects(f.controller.run(f.segment),/Uncertain input/);
  await assert.rejects(f.controller.run(f.segment),/ACTION_MAY_HAVE_COMMITTED/);assert.equal(executions,1);
  assert.equal(await f.controller.stop(),true);
 }finally{await f.remove();}
});
test('concurrent program close shares cancellation and waits for pending completion',async()=>{
 let entered!:()=>void;const entering=new Promise<void>(resolve=>{entered=resolve;});
 const f=await fixture(async(_session,_input,_root,signal)=>await new Promise((_,reject)=>{
  signal.addEventListener('abort',()=>reject(new OwnedUIWorkerError('Cancelled owned child',true)),{once:true});entered();
 }));
 try{
  const running=f.controller.run(f.segment);const rejected=assert.rejects(running,/Cancelled owned child/);
  await entering;const first=f.controller.stop(),second=f.controller.stop();assert.equal(first,second);assert.equal(await first,true);await rejected;
  await assert.rejects(f.controller.run(f.segment),/unavailable/);
 }finally{await f.remove();}
});
test('unknown child drain remains negative even after operation rejection settles',async()=>{
 let entered!:()=>void,rejectChild!:(error:Error)=>void;
 const entering=new Promise<void>(resolve=>{entered=resolve;});
 const f=await fixture(async()=>await new Promise((_,reject)=>{rejectChild=reject;entered();}));
 try{
  const running=f.controller.run(f.segment);const rejected=assert.rejects(running,/Unknown child/);await entering;
  const stop=f.controller.stop();rejectChild(new OwnedUIWorkerError('Unknown child',false));await rejected;
  assert.equal(await stop,false);assert.equal(await f.controller.stop(),false);
 }finally{await f.remove();}
});
test('wrong program scope is refused before durable dispatch or executor work',async()=>{
 let executions=0;const f=await fixture(async(_session,input)=>{executions++;return receipt(input);});
 try{
  const changed={...f.segment,scope:{...f.scope,leaseGeneration:2}};const {payloadDigest:_,...body}=changed;changed.payloadDigest=payloadDigest(body);
  await assert.rejects(f.controller.run(changed),/scope differs/);assert.equal(executions,0);
  await assert.rejects(readFile(f.journalPath),{code:'ENOENT'});
 }finally{await f.remove();}
});
test('unproved child drain fences a different subsequent program as well as retry',async()=>{
 let executions=0;const f=await fixture(async()=>{executions++;throw new OwnedUIWorkerError('Unknown prior child',false);});
 try{
  await assert.rejects(f.controller.run(f.segment),/Unknown prior child/);
  const changed={...f.segment,operationId:'next-operation'};const {payloadDigest:_,...body}=changed;changed.payloadDigest=payloadDigest(body);
  await assert.rejects(f.controller.run(changed),/unavailable/);assert.equal(executions,1);assert.equal(await f.controller.stop(),false);
 }finally{await f.remove();}
});
test('cached completed journal evidence still passes the typed selected-target boundary',async()=>{
 let executions=0;const f=await fixture(async(_session,input)=>{executions++;return receipt(input);});
 try{
  for(const response of [undefined,{...receipt(f.segment),outputs:{locate:'1'}}]){
   await writeFile(f.journalPath,JSON.stringify({'run:operation':{digest:f.segment.payloadDigest,state:'completed',...(response?{response}:{})}}));
   await assert.rejects(f.controller.run(f.segment));
  }
  const selected={...f.segment,operations:[{id:'read',kind:'observeProperty' as const,locator:{kind:'testId' as const,value:'open'},property:'text' as const}]};
  const {payloadDigest:_,...body}=selected;selected.payloadDigest=payloadDigest(body);
  const proof={schemaVersion:1,appBundleId:'example.Fixture',targetId:'foreign-target',complete:true,
   nodes:[{index:1,identifier:'open',label:'Open',blocked:false,hidden:false,visible:true,disabled:false,secure:false}]};
  await writeFile(f.journalPath,JSON.stringify({'run:operation':{digest:selected.payloadDigest,state:'completed',response:{...receipt(selected),outputs:{read:proof}}}}));
  await assert.rejects(f.controller.run(selected),/readback identity differs/);assert.equal(executions,0);
 }finally{await f.remove();}
});

test('controller preflight uses the leased fill and scroll capabilities before durable dispatch',async()=>{
 for(const capabilities of [false,true]){
  let executions=0;
  const f=await fixture(async(_session,input)=>{executions++;const selected=input as Segment;return {schemaVersion:1,scope:selected.scope,operationId:selected.operationId,complete:true,outputs:{}};},capabilities);
  try{
   const body={...f.segment,operations:[{id:'fill',kind:'fillBinding' as const,locator:{kind:'role' as const,value:'textbox'},binding:'public'},
    {id:'scroll',kind:'scroll' as const,direction:'down' as const}],bindings:{public:'Approved public literal'}};
   const {payloadDigest:_,...unsigned}=body;const selected={...unsigned,payloadDigest:payloadDigest(unsigned)};
   if(capabilities){assert.equal((await f.controller.run(selected)).complete,true);assert.equal(executions,1);}
   else{await assert.rejects(f.controller.run(selected),{code:'UNSUPPORTED_CAPABILITY'});assert.equal(executions,0);await assert.rejects(readFile(f.journalPath),{code:'ENOENT'});}
  }finally{await f.remove();}
 }
});

test('digest version changes conflict under the same operation and reopened v1 replay stays cached',async()=>{
 const {segmentPayloadDigest}=await import('../src/payloadDigest.js');let executions=0;
 const f=await fixture(async(_session,input)=>{executions++;return receipt(input);});
 try{
  const saved=await f.controller.run(f.segment);
  const {payloadDigest:_,...body}=f.segment;const upgraded={...body,digestVersion:2 as const};
  await assert.rejects(f.controller.run({...upgraded,payloadDigest:segmentPayloadDigest(upgraded)}),/Conflicting operation payload/);
  const reopened=new OperationJournal(f.journalPath);await reopened.load();
  assert.deepEqual(await reopened.dispatch('run:operation',f.segment.payloadDigest,async()=>{executions++;return null;}),JSON.parse(JSON.stringify(saved)));
  assert.equal(executions,1);
 }finally{await f.remove();}
});

test('reserved ordinary output IDs survive Mac normalization and completed cache replay',async()=>{
 const {validateMacOwnedReceipt}=await import('../src/macOwnedProgram.js');
 const {segmentPayloadDigest}=await import('../src/payloadDigest.js');let executions=0;
 const f=await fixture(async(session,input)=>{
  executions++;const selected=input as Segment;
  const outputs=Object.fromEntries(selected.operations.map(operation=>[operation.id,1]));
  return validateMacOwnedReceipt({schemaVersion:1,scope:selected.scope,operationId:selected.operationId,complete:true,outputs},selected,session.target);
 });
 try{
  const {payloadDigest:_,...base}=f.segment;
  const body={...base,digestVersion:2 as const,operations:['__proto__','constructor','2','10'].map(id=>({id,kind:'locate' as const,locator:{kind:'testId' as const,value:'open'}}))};
  const selected:Segment={...body,payloadDigest:segmentPayloadDigest(body)};
  const first=await f.controller.run(selected),cached=await f.controller.run(selected);
  assert.deepEqual(JSON.parse(JSON.stringify(first)),JSON.parse(JSON.stringify(cached)));
  for(const id of ['__proto__','constructor','2','10']){assert.equal(Object.hasOwn(first.outputs,id),true);assert.equal(first.outputs[id],1);}
  const durable=JSON.parse(await readFile(f.journalPath,'utf8'));
  assert.equal(Object.hasOwn(durable['run:operation'].response.outputs,'__proto__'),true);
  assert.equal(executions,1);
 }finally{await f.remove();}
});
