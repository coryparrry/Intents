import test from 'node:test';import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';import {join} from 'node:path';import {tmpdir} from 'node:os';
import {MacOwnedSession,type MacOwnedTransport} from '../src/macOwnedSession.js';
import {runMacOwnedProgram,validateMacOwnedProgram,validateMacOwnedReceipt} from '../src/macOwnedProgram.js';
import {payloadDigest} from '../src/workerRunner.js';import type {Segment} from '../src/segment.js';
import type {Target,Scope} from '../src/protocol.js';

const target:Target={id:'host-macos-local',platform:'macos',kind:'nativeMac',bundleId:'example.Fixture',bundlePath:'/Applications/Fixture.app',loginSession:'fixture-login'};
const scope:Scope={protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:1};
const instance={bundleId:target.bundleId,canonicalBundlePath:target.bundlePath!,pid:123,processStartIdentity:'100:0'};
function segment(operations:Segment['operations'],bindings:Record<string,string>={}):Segment {
 const body={scope,operationId:'owned-program',phase:'subject' as const,operations,bindings,timeoutMs:15000};
 return {...body,payloadDigest:payloadDigest(body)};
}
test('real pinned worker maps capability-gated Mac viewport scroll through policy and fresh area',async()=>{
 const root=await mkdtemp(join(tmpdir(),'intents-mac-scroll-worker-'));let calls=0,captures=0,policies=0,worker=0;
 const transport:MacOwnedTransport={open:async()=>({applicationTarget:instance,deviceId:target.id,sessionName:'intents-run-1',appBundleId:target.bundleId}),
  capture:async()=>({applicationTarget:instance,nodes:[{index:1,ref:'@e1',role:'AXScrollArea',kind:'ScrollArea',label:'Content',
    enabled:true,hittable:true,visibleToUser:true,rect:{x:0,y:0,width:100,height:50}}],refsGeneration:++captures,
    truncated:false,identifiers:{session:'intents-run-1'},appBundleId:target.bundleId}),
  press:async()=>{throw new Error('not a tap');},scroll:async(selected,request)=>{assert.deepEqual(selected,instance);calls++;
    return {applicationTarget:instance,...request,disposition:'submittedUnconfirmed'};},
  release:async()=>({scope,applicationTarget:instance,commandsDrained:true,ownedHelperReaped:true,daemonStopped:true,subjectTerminated:false})};
 const session=await MacOwnedSession.acquire(target,scope,transport,async(_scope,action)=>{policies++;assert.equal(action.kind,'swipe');});
 try {
  const result=await runMacOwnedProgram(session,segment([{id:'scroll',kind:'scroll',direction:'down'}]),root,new AbortController().signal,async pid=>{worker=pid;});
  assert.equal(result.complete,true);assert.equal(Object.keys(result.outputs).length,0);assert.equal(calls,1);assert.equal(policies,1);
  assert.throws(()=>process.kill(worker,0),{code:'ESRCH'});
 }finally{await session.release();await rm(root,{recursive:true,force:true});}
});
async function fixture(mode='valid'){
 const root=await mkdtemp(join(tmpdir(),'intents-mac-owned-program-'));let captures=0,presses=0,policies=0,releases=0;
 const transport:MacOwnedTransport={open:async()=>({applicationTarget:instance,deviceId:target.id,sessionName:'intents-run-1',appBundleId:target.bundleId}),
  capture:async(_instance,context)=>{assert.equal(context?.runId,scope.runId);assert.equal(context?.attemptId,scope.attemptId);captures++;return {applicationTarget:mode==='changed-instance'?{...instance,pid:124}:instance,
   nodes:[{index:1,ref:'@e1',identifier:presses?'done':'open',label:presses?'Done':'Open',role:'button',hittable:true,enabled:true,visibleToUser:true,rect:{x:0,y:0,width:100,height:50}}],
   refsGeneration:captures,truncated:false,identifiers:{session:'intents-run-1'},appBundleId:target.bundleId};},
  press:async(_instance,point,context)=>{assert.equal(context.runId,scope.runId);assert.equal(context.attemptId,scope.attemptId);presses++;assert.deepEqual(point,{x:50,y:25});return {applicationTarget:instance,...point,disposition:'submittedUnconfirmed',releaseSubmitted:mode!=='uncertain'};},
  release:async()=>{releases++;return {scope,applicationTarget:instance,commandsDrained:true,ownedHelperReaped:true,daemonStopped:true,subjectTerminated:false};}};
 const session=await MacOwnedSession.acquire(target,scope,transport,async(_scope,action)=>{assert.equal(action.kind,'tap');policies++;});
 return {root,session,counts:()=>({captures,presses,policies,releases}),remove:async()=>{await session.release();await rm(root,{recursive:true,force:true});}};
}
test('real pinned gated e2e worker maps exact Mac tap and independent readback through the existing engine',async()=>{
 const f=await fixture();let worker=0;
 try{
  const result=await runMacOwnedProgram(f.session,segment([
   {id:'tap',kind:'tap',locator:{kind:'testId',value:'open'}},
   {id:'read',kind:'observeProperty',locator:{kind:'testId',value:'done'},property:'text'}]),f.root,new AbortController().signal,async pid=>{
    worker=pid;assert.equal(f.counts().captures,0);assert.doesNotThrow(()=>process.kill(pid,0));
   });
  const proof=result.outputs.read;assert.ok(proof && typeof proof==='object');
  assert.equal(result.complete,true);assert.equal(proof.appBundleId,target.bundleId);
  assert.equal(proof.targetId,target.id);assert.equal(proof.nodes[0]!.label,'Done');
  assert.equal(f.counts().presses,1);assert.equal(f.counts().policies,1);assert.throws(()=>process.kill(worker,0),{code:'ESRCH'});
 }finally{await f.remove();}
});
test('native admission denial cannot dispatch a Mac program capture or input',async()=>{
 const f=await fixture();
 try{
  await assert.rejects(runMacOwnedProgram(f.session,segment([{id:'locate',kind:'locate',locator:{kind:'testId',value:'open'}}]),f.root,new AbortController().signal,async()=>{throw new Error('Lease revoked');}));
  assert.equal(f.counts().captures,0);assert.equal(f.counts().presses,0);
 }finally{await f.remove();}
});
test('changed Mac application instance never submits a program input',async()=>{
 const f=await fixture('changed-instance');
 try{
  await assert.rejects(runMacOwnedProgram(f.session,segment([{id:'tap',kind:'tap',locator:{kind:'testId',value:'open'}}]),f.root,new AbortController().signal,async()=>{}));
  assert.equal(f.counts().presses,0);
 }finally{await f.remove();}
});
test('unsupported fill or scroll is rejected before worker admission and before an earlier tap',async()=>{
 const f=await fixture();let admissions=0;
 try{
  for(const operation of [{id:'fill',kind:'fillBinding' as const,locator:{kind:'testId' as const,value:'field'},binding:'text'},
    {id:'scroll',kind:'scroll' as const,direction:'down' as const}]){
   await assert.rejects(runMacOwnedProgram(f.session,segment([{id:'tap',kind:'tap',locator:{kind:'testId',value:'open'}},operation],{text:'approved'}),f.root,new AbortController().signal,async()=>{admissions++;}),{code:'UNSUPPORTED_CAPABILITY'});
  }
  assert.equal(admissions,0);assert.equal(f.counts().captures,0);assert.equal(f.counts().presses,0);
 }finally{await f.remove();}
});
test('uncertain Mac program input cannot retry or produce a completed receipt',async()=>{
 const f=await fixture('uncertain');
 try{
  await assert.rejects(runMacOwnedProgram(f.session,segment([{id:'tap',kind:'tap',locator:{kind:'testId',value:'open'}}]),f.root,new AbortController().signal,async()=>{}));
  assert.equal(f.counts().presses,1);
 }finally{await f.remove();}
});
test('goal requiring unsupported fill and a tampered payload fail capability or digest preflight',()=>{
 assert.throws(()=>validateMacOwnedProgram(segment([{id:'goal',kind:'navigateGoal',goal:{id:'goal',instruction:'Fill a field',endpoint:{kind:'testId',value:'done'},maximumCalls:2,maximumActions:3,allowedFillBindings:['text']}}],{text:'approved'})),{code:'UNSUPPORTED_CAPABILITY'});
 const changed=segment([{id:'locate',kind:'locate',locator:{kind:'testId',value:'open'}}]);changed.timeoutMs++;
 assert.throws(()=>validateMacOwnedProgram(changed),/digest mismatch/);
});
test('a full two-minute Mac program preserves a supported per-action capture budget',async()=>{
 const f=await fixture();
 try{
  const selected=segment([{id:'locate',kind:'locate',locator:{kind:'testId',value:'open'}}]);
  selected.timeoutMs=120000;const {payloadDigest:_,...body}=selected;selected.payloadDigest=payloadDigest(body);
  const result=await runMacOwnedProgram(f.session,selected,f.root,new AbortController().signal,async()=>{});
  assert.equal(result.outputs.locate,1);assert.equal(f.counts().presses,0);
 }finally{await f.remove();}
});
test('malformed typed outputs or extra receipt fields cannot become Mac program evidence',()=>{
 const selected=segment([{id:'locate',kind:'locate',locator:{kind:'testId',value:'open'}}]);
 const valid={schemaVersion:1,scope,operationId:selected.operationId,complete:true,outputs:{locate:1}};
 assert.equal(validateMacOwnedReceipt(valid,selected,target).outputs.locate,1);
 for(const bad of [{...valid,outputs:{locate:'1'}},{...valid,outputs:{locate:-1}},{...valid,outputs:{locate:1,extra:1}},
   {...valid,extra:true},{...valid,scope:{...scope,leaseGeneration:2}}])assert.throws(()=>validateMacOwnedReceipt(bad,selected,target));
 const observed=segment([{id:'read',kind:'observeProperty',locator:{kind:'testId',value:'open'},property:'text'}]);
 assert.throws(()=>validateMacOwnedReceipt({...valid,outputs:{read:'unbound scalar'}},observed,target));
 const proof={schemaVersion:1,appBundleId:target.bundleId,targetId:target.id,complete:true,
  nodes:[{index:1,identifier:'open',label:'Open',blocked:false,hidden:false,visible:true,disabled:false,secure:false}]};
 assert.deepEqual(validateMacOwnedReceipt({...valid,outputs:{read:proof}},observed,target).outputs.read,proof);
 for(const changed of [{...proof,appBundleId:'foreign.App'},{...proof,targetId:'foreign-target'},
  {...proof,nodes:[{...proof.nodes[0],visible:false}]},{...proof,nodes:[...proof.nodes,...proof.nodes]}])
  assert.throws(()=>validateMacOwnedReceipt({...valid,outputs:{read:changed}},observed,target));
});

test('real pinned worker replaces an approved public binding and observes a separate status',async()=>{
 const root=await mkdtemp(join(tmpdir(),'intents-mac-fill-worker-'));let fills=0,captures=0,policies=0,worker=0;
 const literal='public-e\u0301🙂';
 const transport:MacOwnedTransport={open:async()=>({applicationTarget:instance,deviceId:target.id,sessionName:'intents-run-1',appBundleId:target.bundleId}),
  capture:async()=>({applicationTarget:instance,nodes:[
   {index:1,ref:'@e1',role:'AXTextField',editable:true,enabled:true,hittable:true,visibleToUser:true,rect:{x:0,y:0,width:100,height:50}},
   {index:2,ref:'@e2',role:'AXStaticText',identifier:'status',label:fills?'Updated':'Ready',enabled:true,hittable:true,visibleToUser:true,rect:{x:0,y:60,width:100,height:20}}],
   refsGeneration:++captures,truncated:false,identifiers:{session:'intents-run-1'},appBundleId:target.bundleId}),
  press:async()=>{throw new Error('not a tap');},ordinaryFill:async(selected,request)=>{assert.deepEqual(selected,instance);assert.equal(request.value,literal);fills++;
   return {applicationTarget:instance,x:request.x,y:request.y,disposition:'replacementVerified'};},
  release:async()=>({scope,applicationTarget:instance,commandsDrained:true,ownedHelperReaped:true,daemonStopped:true,subjectTerminated:false})};
 const session=await MacOwnedSession.acquire(target,scope,transport,async(_scope,action)=>{policies++;assert.equal(action.kind,'fill');});
 try {
  const result=await runMacOwnedProgram(session,segment([
   {id:'fill',kind:'fillBinding',locator:{kind:'role',value:'textbox'},binding:'query'},
   {id:'observe',kind:'observeProperty',locator:{kind:'testId',value:'status'},property:'text'}],{query:literal}),root,new AbortController().signal,async pid=>{worker=pid;});
  assert.equal(result.complete,true);const proof=result.outputs.observe;assert.ok(proof && typeof proof==='object');assert.equal(proof.nodes.find(node=>node.identifier==='status')?.label,'Updated');
  assert.equal(fills,1);assert.equal(policies,1);assert.throws(()=>process.kill(worker,0),{code:'ESRCH'});
 }finally{await session.release();await rm(root,{recursive:true,force:true});}
});
test('public fill limits preflight before worker admission or an earlier tap',()=>{
 const payload=segment([{id:'tap',kind:'tap',locator:{kind:'testId',value:'open'}},
  {id:'fill',kind:'fillBinding',locator:{kind:'role',value:'textbox'},binding:'query'}],{query:'x'.repeat(16385)});
 assert.throws(()=>validateMacOwnedProgram(payload,false,true),/Invalid ordinary Mac literal/);
 const valid=segment([{id:'fill',kind:'fillBinding',locator:{kind:'role',value:'textbox'},binding:'query'}],{query:''});
 assert.doesNotThrow(()=>validateMacOwnedProgram(valid,false,true));assert.throws(()=>validateMacOwnedProgram(valid));
});

test('role locators cannot authorize taps, readbacks or unsupported roles',()=>{
 const operations:Segment['operations']=[{id:'role',kind:'tap',locator:{kind:'role',value:'textbox'}},
  {id:'role',kind:'locate',locator:{kind:'role',value:'textbox'}},
  {id:'role',kind:'observeProperty',locator:{kind:'role',value:'textbox'},property:'text'}];
 for(const operation of operations)assert.throws(()=>validateMacOwnedProgram(segment([operation]),false,true));
 assert.throws(()=>validateMacOwnedProgram(segment([{id:'fill',kind:'fillBinding',locator:{kind:'role',value:'AXSecureTextField'},binding:'query'}],{query:'public'}),false,true));
});

test('unexpected prototype-name output is included in the exact-key rejection',()=>{
 const selected=segment([{id:'locate',kind:'locate',locator:{kind:'testId',value:'open'}}]);
 const raw={schemaVersion:1,scope,operationId:selected.operationId,complete:true,outputs:Object.fromEntries([['locate',1],['__proto__',1]])};
 assert.throws(()=>validateMacOwnedReceipt(raw,selected,target),/outputs differ/);
});
