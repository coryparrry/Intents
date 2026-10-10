import {test} from 'node:test';
import assert from 'node:assert/strict';
import type {CaptureSnapshotResult} from 'agent-device';
import {EngineError,type OperationContext} from 'e2e/engine';
import {MacOwnedSession,requireMacOwnedInstance,type MacOwnedTransport} from '../src/macOwnedSession.js';
import {DeviceAcquisitionError,DeviceSession} from '../src/deviceSession.js';
import {intentsUIEngine} from '../src/e2e/engine.js';
import type {Scope,Target} from '../src/protocol.js';

const scope:Scope={protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:1};
const target:Target={id:'mac-exact',platform:'macos',kind:'nativeMac',bundleId:'example.Target',bundlePath:'/Applications/Selected.app',loginSession:'login-1'};
const instance={bundleId:target.bundleId,canonicalBundlePath:target.bundlePath!,pid:123,processStartIdentity:'100:0'};
const context:OperationContext={signal:new AbortController().signal,timeoutMs:1000,runId:'run',attemptId:'attempt',origin:'test'};
const data:CaptureSnapshotResult & {applicationTarget:unknown}={applicationTarget:instance,appBundleId:target.bundleId,
  identifiers:{session:'intents-run-1',udid:target.id},truncated:false,refsGeneration:1,nodes:[
    {index:1,ref:'@e1',kind:'button',identifier:'done',label:'Done',hittable:true,enabled:true,visibleToUser:true,
      bundleId:target.bundleId,rect:{x:0,y:10,width:100,height:50}},
  ]};
function fixture(){
  let capture=structuredClone(data),presses=0,opens=0,cleanup=0,policies=0;let cleanupInstance:unknown;
  let openValue={applicationTarget:instance,deviceId:target.id,appBundleId:target.bundleId,sessionName:'intents-run-1'};
  let releaseValue:unknown={scope,applicationTarget:instance,commandsDrained:true,ownedHelperReaped:true,daemonStopped:true,subjectTerminated:false};
  let pressValue:unknown={applicationTarget:instance,x:50,y:35,disposition:'submittedUnconfirmed',releaseSubmitted:true};
  const transport:MacOwnedTransport={
    open:async(selection,requested,name)=>{opens++;assert.equal(selection.canonicalBundlePath,target.bundlePath);
      assert.deepEqual(requested,scope);assert.equal(name,'intents-run-1');return openValue;},
    capture:async selected=>{assert.deepEqual(selected,instance);return capture;},
    press:async(selected,point)=>{presses++;assert.deepEqual(selected,instance);assert.deepEqual(point,{x:50,y:35});return pressValue;},
    release:async(requested,selected)=>{cleanup++;assert.deepEqual(requested,scope);cleanupInstance=selected;return releaseValue;},
  };
  const acquire=()=>MacOwnedSession.acquire(target,scope,transport,async()=>{policies++;});
  return {transport,acquire,setCapture:(value:typeof capture)=>{capture=value;},setOpen:(value:typeof openValue)=>{openValue=value;},
    setPress:(value:unknown)=>{pressValue=value;},setRelease:(value:unknown)=>{releaseValue=value;},
    counts:()=>({opens,presses,cleanup,policies}),cleanupInstance:()=>cleanupInstance};
}
test('Mac injected adapter freezes exact identity, observes and submits unconfirmed tap',async()=>{
  const f=fixture(),session=await f.acquire();assert.ok(Object.isFrozen(session.instance));
  await session.snapshot(context);await session.perform('@e1~s1',{kind:'tap'},context,'node');
  assert.equal(f.counts().presses,1);assert.equal(session.selectionEvidence.lastInputDisposition,'submittedUnconfirmed');
  assert.equal(session.selectionEvidence.hardwareQualified,false);assert.equal((await session.release()).released,true);
});
test('implemented viewport scroll resolves a uniquely observed fresh owned scroll area and calls policy',async()=>{
  const f=fixture();let scrolls=0;
  const scrollCapture={...structuredClone(data),nodes:[{...data.nodes[0]!,role:'AXScrollArea',kind:'ScrollArea',label:'Content'}]};
  f.setCapture(scrollCapture);
  f.transport.scroll=async(selected,request)=>{scrolls++;assert.deepEqual(selected,instance);assert.deepEqual(request,{x:50,y:35,direction:'down'});
    return {applicationTarget:instance,...request,disposition:'submittedUnconfirmed'};};
  const session=await f.acquire();assert.equal(session.supportsScroll,true);
  await session.snapshot(context);await session.perform('root',{kind:'swipe',direction:'down'},context,'root');
  assert.equal(scrolls,1);assert.equal(f.counts().policies,1);assert.equal(session.selectionEvidence.hardwareQualified,false);
  await session.release();
});
test('scroll denies missing capability, unseen ambiguous changed or partial scroll areas before input',async()=>{
  const unsupported=fixture(),tapOnly=await unsupported.acquire();assert.equal(tapOnly.supportsScroll,false);
  unsupported.transport.scroll=async()=>{throw new Error('A late-added capability must never dispatch');};
  await assert.rejects(tapOnly.perform('root',{kind:'swipe',direction:'down'},context));await tapOnly.release();
  for(const mode of ['unseen','ambiguous','changed','partial','secure']){
    const f=fixture();let calls=0;
    const area={...data.nodes[0]!,role:'AXScrollArea',kind:'ScrollArea',label:'Content'};
    f.setCapture({...structuredClone(data),nodes:[area]});
    f.transport.scroll=async()=>{calls++;throw new Error('must not submit');};const session=await f.acquire();
    if(mode!=='unseen')await session.snapshot(context);
    if(mode==='ambiguous')f.setCapture({...structuredClone(data),nodes:[area,{...area,index:2,ref:'@e2'}]});
    if(mode==='changed')f.setCapture({...structuredClone(data),nodes:[{...area,label:'Other'}]});
    if(mode==='partial')f.setCapture({...structuredClone(data),nodes:[area],truncated:true});
    if(mode==='secure')f.setCapture({...structuredClone(data),nodes:[{...area,password:true}]});
    await assert.rejects(session.perform('root',{kind:'swipe',direction:'down'},context));assert.equal(calls,0);await session.release();
  }
});
test('scroll receipt ambiguity latches uncertainty and prevents any second input',async()=>{
  for(const wrong of ['direction','instance','point','transport']){
    const f=fixture();let calls=0;f.setCapture({...structuredClone(data),nodes:[{...data.nodes[0]!,role:'AXScrollArea',kind:'ScrollArea'}]});
    f.transport.scroll=async(_selected,request)=>{calls++;if(wrong==='transport')throw new Error('lost reply');
      return {applicationTarget:wrong==='instance'?{...instance,pid:124}:instance,...request,
        ...(wrong==='point'?{x:51}:{}),direction:wrong==='direction'?'up':request.direction,disposition:'submittedUnconfirmed'};};
    const session=await f.acquire();await session.snapshot(context);
    await assert.rejects(session.perform('root',{kind:'swipe',direction:'down'},context));
    await assert.rejects(session.perform('root',{kind:'swipe',direction:'down'},context));assert.equal(calls,1);await session.release();
  }
});
test('Mac instance rejects malformed, unknown and changed identity fields',()=>{
  assert.deepEqual(requireMacOwnedInstance(instance),instance);
  for(const change of [{pid:0},{pid:2147483648},{processStartIdentity:'0:0'},{processStartIdentity:'100:1000000'},
    {processStartIdentity:'18446744073709551616:0'},{canonicalBundlePath:'/Applications/../Other.app'},{foreign:true}])
    assert.throws(()=>requireMacOwnedInstance({...instance,...change}));
  for(const change of [{pid:124},{processStartIdentity:'101:0'},{bundleId:'example.Other'},{canonicalBundlePath:'/Applications/Other.app'}])
    assert.throws(()=>requireMacOwnedInstance({...instance,...change},instance));
  assert.throws(()=>requireMacOwnedInstance(Object.assign(Object.create({foreign:true}),instance)));
});
test('Wrong app/device/session acquisition never becomes an owned session',async()=>{
  for(const change of [{deviceId:'other'},{sessionName:'other'},{appBundleId:'example.Other'},
    {applicationTarget:{...instance,canonicalBundlePath:'/Applications/Other.app'}}]){
    const f=fixture();f.setOpen({applicationTarget:instance,deviceId:target.id,appBundleId:target.bundleId,sessionName:'intents-run-1',...change});
    const observed=change.applicationTarget??instance;
    f.setRelease({scope,applicationTarget:observed,commandsDrained:true,ownedHelperReaped:true,daemonStopped:true,subjectTerminated:false});
    await assert.rejects(f.acquire,error=>error instanceof DeviceAcquisitionError && error.released);
    assert.equal(f.counts().presses,0);assert.equal(f.counts().cleanup,1);
    assert.deepEqual(f.cleanupInstance(),observed);
  }
});
test('Known acquisition instance cannot be discarded for a null cleanup receipt',async()=>{
  const f=fixture();f.setOpen({applicationTarget:instance,deviceId:'other',appBundleId:target.bundleId,sessionName:'intents-run-1'});
  f.setRelease({scope,applicationTarget:null,commandsDrained:true,ownedHelperReaped:true,daemonStopped:true,subjectTerminated:false});
  await assert.rejects(f.acquire,error=>error instanceof DeviceAcquisitionError && !error.released);
  assert.deepEqual(f.cleanupInstance(),instance);assert.equal(f.counts().cleanup,1);
});
test('Invalid selection fails before opening or cleaning an untouched transport',async()=>{
  const f=fixture();await assert.rejects(()=>MacOwnedSession.acquire({...target,bundlePath:'/Applications/../Other.app'},scope,f.transport,async()=>{}));
  assert.deepEqual(f.counts(),{opens:0,presses:0,cleanup:0,policies:0});
});
test('Mac captures reject wrong process instance, bundle or session',async()=>{
  for(const change of [{applicationTarget:{...instance,pid:124}},{applicationTarget:{...instance,processStartIdentity:'101:0'}},
    {appBundleId:'example.Other'},{identifiers:{session:'other'}}]){
    const f=fixture(),session=await f.acquire();f.setCapture({...data,...change});await assert.rejects(()=>session.snapshot(context));
    assert.equal(f.counts().presses,0);
  }
});
test('Fresh changed/ambiguous/hidden/foreign/partial nodes cannot dispatch',async()=>{
  for(const next of [
    {...data,nodes:[{...data.nodes[0]!,label:'Other'}]}, {...data,nodes:[data.nodes[0]!,{...data.nodes[0]!,index:2}]},
    {...data,nodes:[{...data.nodes[0]!,hittable:false}]}, {...data,nodes:[{...data.nodes[0]!,bundleId:'example.Other'}]},
    {...data,truncated:true}, {...data,visibility:{partial:true,visibleNodeCount:1,totalNodeCount:2,reasons:['scroll-hidden-below' as const]}},
    {...data,nodes:[{...data.nodes[0]!,rect:{x:NaN,y:10,width:100,height:50}}]},
  ]){
    const f=fixture(),session=await f.acquire();await session.snapshot(context);f.setCapture(next);
    await assert.rejects(()=>session.perform('@e1~s1',{kind:'tap'},context));assert.equal(f.counts().presses,0);
  }
});
test('Secret ancestors redact capture values and forbid taps',async()=>{
  const f=fixture(),session=await f.acquire();f.setCapture({...data,nodes:[
    {index:0,ref:'@parent',password:true,value:'secret'}, {...data.nodes[0]!,parentIndex:0,value:'secret child'},
  ]});
  const capture=await session.snapshot(context);assert.ok(capture.nodes.every(node=>node.value===undefined));
  await assert.rejects(()=>session.perform('@e1~s1',{kind:'tap'},context));assert.equal(f.counts().presses,0);
});
test('Only prior unique tap observation is supported; fill/swipe bypass neither policy nor transport',async()=>{
  const f=fixture(),session=await f.acquire();await assert.rejects(()=>session.perform('@e1~s1',{kind:'tap'},context));
  await session.snapshot(context);
  for(const action of [{kind:'fill' as const,value:'text',sensitive:false},{kind:'swipe' as const,direction:'down' as const}])
    await assert.rejects(()=>session.perform('@e1~s1',action,context));
  assert.equal(f.counts().presses,0);assert.equal(f.counts().policies,0);
});
test('Cancelled and invalid budgets cannot call policy or input',async()=>{
  const f=fixture(),session=await f.acquire();await session.snapshot(context);const cancelled=new AbortController();cancelled.abort();
  for(const ctx of [{...context,signal:cancelled.signal},...[-1,0,NaN,Infinity,60_001].map(timeoutMs=>({...context,timeoutMs}))])
    await assert.rejects(()=>session.perform('@e1~s1',{kind:'tap'},ctx));
  assert.equal(f.counts().presses,0);assert.equal(f.counts().policies,0);
});
test('Incomplete/foreign input echoes latch uncertainty and never repeat submission',async()=>{
  for(const change of [{releaseSubmitted:false},{disposition:'completed'},{x:51},{applicationTarget:{...instance,pid:124}}]){
    const f=fixture(),session=await f.acquire();await session.snapshot(context);
    f.setPress({applicationTarget:instance,x:50,y:35,disposition:'submittedUnconfirmed',releaseSubmitted:true,...change});
    await assert.rejects(()=>session.perform('@e1~s1',{kind:'tap'},context),error=>error instanceof EngineError && error.code==='ACTION_MAY_HAVE_COMMITTED' && !error.retryable);
    await session.snapshot(context);await assert.rejects(()=>session.perform('@e1~s1',{kind:'tap'},context));assert.equal(f.counts().presses,1);
  }
});
test('Release evidence requires same scope/process and all resource gates; cached cleanup is not retried',async()=>{
  for(const change of [{scope:{...scope,leaseGeneration:2}},{applicationTarget:{...instance,pid:124}},
    {commandsDrained:false},{ownedHelperReaped:false},{daemonStopped:false},{subjectTerminated:true},{foreign:true}]){
    const f=fixture(),session=await f.acquire();f.setRelease({scope,applicationTarget:instance,commandsDrained:true,ownedHelperReaped:true,daemonStopped:true,subjectTerminated:false,...change});
    assert.equal((await session.release()).released,false);assert.equal((await session.release()).released,false);
    assert.equal(f.counts().cleanup,1);await assert.rejects(()=>session.snapshot(context));
  }
});
test('Release during capture prevents pending input and waits for commands to drain',async()=>{
  const f=fixture(),session=await f.acquire();await session.snapshot(context);
  let unblock!:()=>void,started!:()=>void;const entered=new Promise<void>(resolve=>{started=resolve;});
  const blocked=new Promise<void>(resolve=>{unblock=resolve;});f.transport.capture=async()=>{started();await blocked;return data;};
  const action=session.perform('@e1~s1',{kind:'tap'},context);await entered;
  assert.equal((await session.release()).released,false);assert.equal(f.counts().cleanup,0);
  unblock();await assert.rejects(()=>action);assert.equal(f.counts().presses,0);assert.equal((await session.release()).released,true);
});
test('e2e integration uses fresh Mac captures and exact point submission',async()=>{
  const f=fixture(),session=await f.acquire();const engine=intentsUIEngine(session,'macos',target.bundleId);
  const observation=await engine.observe!(context);await engine.perform!(observation.root.children![0]!.ref,{kind:'tap'},context);
  assert.equal(f.counts().presses,1);
});
test('Customer DeviceSession Mac fence remains before state allocation and SDK activation',async()=>{
  await assert.rejects(()=>DeviceSession.create('/private/tmp/uncreated-mac-owned-customer',target,scope,async()=>{}),
    error=>error instanceof DeviceAcquisitionError && error.released && /not qualified/.test(error.message));
});

function ordinaryField(){return {index:1,ref:'@e1',role:'AXTextField',editable:true,enabled:true,hittable:true,visibleToUser:true,
 bundleId:target.bundleId,rect:{x:0,y:10,width:100,height:50}};}
test('ordinary fill uses frozen capability, approved literal, fresh nonsecure field and value-free receipt',async()=>{
 const f=fixture();let fills=0;
 f.setCapture({...data,nodes:[ordinaryField()]});
 f.transport.ordinaryFill=async(selected,request)=>{fills++;assert.deepEqual(selected,instance);assert.equal(request.value,'public-e\u0301');
  return {applicationTarget:instance,x:request.x,y:request.y,disposition:'replacementVerified'};};
 const session=await f.acquire();assert.equal(session.supportsOrdinaryFill,true);await session.snapshot(context);
 await session.perform('@e1~s1',{kind:'fill',sensitive:false,value:'public-e\u0301'},context,'node');
 assert.equal(fills,1);assert.equal(f.counts().policies,1);assert.equal(session.selectionEvidence.lastInputDisposition,'replacementVerified');
 const late=fixture(),unqualified=await late.acquire();late.transport.ordinaryFill=f.transport.ordinaryFill;
 assert.equal(unqualified.supportsOrdinaryFill,false);await unqualified.snapshot(context);
 await assert.rejects(unqualified.perform('@e1~s1',{kind:'fill',sensitive:false,value:'public'},context));assert.equal(fills,1);
});
test('secure ancestry, missing capability, ambiguity and stale field cannot receive ordinary fill',async()=>{
 for(const nodes of [[{...ordinaryField(),subrole:'AXSecureTextField'}],[{...ordinaryField(),editable:false}],
  [ordinaryField(),{...ordinaryField(),index:2}], [{...ordinaryField(),rect:{x:20,y:10,width:100,height:50}}],
  [{...ordinaryField(),parentIndex:2},{index:2,ref:'@e2',role:'AXSecureTextField'}]]){
  const f=fixture();let fills=0;f.transport.ordinaryFill=async()=>{fills++;throw new Error('must not submit');};
  f.setCapture({...data,nodes:[ordinaryField()]});const session=await f.acquire();await session.snapshot(context);
  f.setCapture({...data,nodes});await assert.rejects(session.perform('@e1~s1',{kind:'fill',sensitive:false,value:'public'},context));assert.equal(fills,0);
 }
});
test('ordinary fill sensitivity and invalid literals reject before policy or native submission',async()=>{
 const f=fixture();let fills=0;f.transport.ordinaryFill=async()=>{fills++;return {};};f.setCapture({...data,nodes:[ordinaryField()]});
 const session=await f.acquire();await session.snapshot(context);
 for(const action of [{kind:'fill' as const,sensitive:true,value:'public'},{kind:'fill' as const,sensitive:false,value:'x\0'},
  {kind:'fill' as const,sensitive:false,value:'\ud800'},{kind:'fill' as const,sensitive:false,value:'x'.repeat(16385)}])await assert.rejects(session.perform('@e1~s1',action,context));
 assert.equal(fills,0);assert.equal(f.counts().policies,0);
});
test('wrong ordinary replacement receipt latches uncertainty and prevents subsequent input',async()=>{
 const f=fixture();let fills=0;f.transport.ordinaryFill=async()=>{fills++;return {applicationTarget:instance,x:999,y:35,disposition:'replacementVerified'};};
 f.setCapture({...data,nodes:[ordinaryField()]});const session=await f.acquire();await session.snapshot(context);
 await assert.rejects(session.perform('@e1~s1',{kind:'fill',sensitive:false,value:'public'},context));
 await assert.rejects(session.perform('@e1~s1',{kind:'fill',sensitive:false,value:'public'},context));
 await assert.rejects(session.perform('@e1~s1',{kind:'tap'},context));assert.equal(fills,1);assert.equal(f.counts().presses,0);
});
