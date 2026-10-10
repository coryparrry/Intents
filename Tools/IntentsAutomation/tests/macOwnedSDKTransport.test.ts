import {test} from 'node:test';
import assert from 'node:assert/strict';
import type {CaptureSnapshotResult} from 'agent-device';
import type {OperationContext} from 'e2e/engine';
import {MacOwnedSDKTransport,type MacOwnedSDKClient} from '../src/macOwnedSDKTransport.js';
import {MacOwnedSession} from '../src/macOwnedSession.js';
import type {Scope,Target} from '../src/protocol.js';

const scope:Scope={protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:1};
const target:Target={id:'host-macos-local',platform:'macos',kind:'nativeMac',bundleId:'example.Target',bundlePath:'/Applications/Selected.app',loginSession:'login-1'};
const instance={bundleId:target.bundleId,canonicalBundlePath:target.bundlePath!,pid:123,processStartIdentity:'100:0'};
const selection={bundleId:instance.bundleId,canonicalBundlePath:instance.canonicalBundlePath};
const context:OperationContext={signal:new AbortController().signal,timeoutMs:1000,runId:'run',attemptId:'attempt',origin:'test'};
const snapshot:CaptureSnapshotResult & {applicationTarget:unknown}={applicationTarget:instance,appBundleId:target.bundleId,
  identifiers:{session:'intents-run-1'},truncated:false,refsGeneration:1,nodes:[{index:1,ref:'@e1',label:'Done',kind:'button',
    identifier:'done',hittable:true,enabled:true,visibleToUser:true,rect:{x:0,y:10,width:100,height:50}}]};
function fixture(){
  const requests:{command:string;options:unknown}[]=[];let cleanup=0;
  let openValue={applicationTarget:instance,appBundleId:target.bundleId,session:'intents-run-1',identifiers:{deviceId:target.id}};
  let captureValue=structuredClone(snapshot),pressValue:unknown={applicationTarget:instance,x:50,y:35,
    disposition:'submittedUnconfirmed',releaseSubmitted:true,action:'press',surface:'frontmost-app',ordinaryMetadata:true};
  const client:MacOwnedSDKClient={apps:{open:async options=>{requests.push({command:'open',options});return openValue;}},
    capture:{snapshot:async options=>{requests.push({command:'snapshot',options});return captureValue;}},
    interactions:{press:async options=>{requests.push({command:'press',options});return pressValue;}}};
  const transport=new MacOwnedSDKTransport(client,target,scope,async(requested,selected)=>{
    cleanup++;assert.deepEqual(requested,scope);assert.deepEqual(selected,instance);
    return {scope,applicationTarget:selected,commandsDrained:true,ownedHelperReaped:true,daemonStopped:true,subjectTerminated:false};
  },'private-owned-mac-source');
  return {transport,requests,client,cleanup:()=>cleanup,setOpen:(v:typeof openValue)=>{openValue=v;},
    setCapture:(v:typeof captureValue)=>{captureValue=v;},setPress:(v:unknown)=>{pressValue=v;}};
}
test('SDK connector pins platform/desktop/exact local ID, session and explicit bundle path',async()=>{
  const f=fixture(),session=await MacOwnedSession.acquire(target,scope,f.transport,async()=>{});
  await session.snapshot(context);await session.perform('@e1~s1',{kind:'tap'},context);
  for(const request of f.requests){const options=request.options as Record<string,unknown>;
    assert.equal(options.platform,'macos');assert.equal(options.target,'desktop');assert.equal(options.udid,target.id);assert.equal(options.session,'intents-run-1');}
  const open=f.requests[0]!.options as Record<string,unknown>;
  assert.equal(open.app,target.bundleId);assert.equal(open.macBundlePath,target.bundlePath);assert.equal(open.surface,'frontmost-app');assert.equal(open.relaunch,false);
  const capture=f.requests[1]!.options as Record<string,unknown>;assert.equal(capture.forceFull,true);assert.equal(capture.raw,true);
  assert.deepEqual(f.requests.at(-1)!.options,{platform:'macos',target:'desktop',udid:target.id,session:'intents-run-1',x:50,y:35,timeoutMs:(f.requests.at(-1)!.options as Record<string,unknown>).timeoutMs});
  assert.equal(session.selectionEvidence.lastInputDisposition,'submittedUnconfirmed');
  assert.equal((await session.release()).released,true);assert.equal(f.cleanup(),1);
  assert.ok(!f.requests.some(request=>request.command==='close'));
});
test('Wrong scope/selection/name cannot submit SDK open; uncertain acquisition is not retried',async()=>{
  const f=fixture();
  for(const call of [()=>f.transport.open(selection,{...scope,leaseGeneration:2},'intents-run-1'),
    ()=>f.transport.open({...selection,bundleId:'example.Other'},scope,'intents-run-1'),
    ()=>f.transport.open(selection,scope,'other')])assert.throws(call);
  assert.equal(f.requests.length,0);
  f.client.apps.open=async()=>{throw new Error('synthetic open failure');};
  await assert.rejects(()=>f.transport.open(selection,scope,'intents-run-1'));
  assert.throws(()=>f.transport.open(selection,scope,'intents-run-1'));
});
test('SDK wrong capture instance and unsupported published result are refused',async()=>{
  const f=fixture();await f.transport.open(selection,scope,'intents-run-1');
  f.setCapture({...snapshot,applicationTarget:{...instance,pid:124}});await assert.rejects(()=>f.transport.capture(instance,context));
  f.setCapture({...snapshot,applicationTarget:undefined});await assert.rejects(()=>f.transport.capture(instance,context));
});
test('SDK input validates expected instance and context before dispatch',async()=>{
  const f=fixture();await f.transport.open(selection,scope,'intents-run-1');
  assert.throws(()=>f.transport.press({...instance,pid:124},{x:50,y:35},context));
  assert.throws(()=>f.transport.press(instance,{x:Infinity,y:35},context));
  const aborted=new AbortController();aborted.abort();
  for(const value of [{...context,signal:aborted.signal},{...context,runId:'other'},{...context,attemptId:'other'},{...context,timeoutMs:0}])
    assert.throws(()=>f.transport.press(instance,{x:50,y:35},value));
  assert.equal(f.requests.filter(r=>r.command==='press').length,0);
});
test('Malformed submitted SDK input remains uncertain and cannot be repeated',async()=>{
  const f=fixture();await f.transport.open(selection,scope,'intents-run-1');f.setPress({applicationTarget:instance,x:50,y:35,releaseSubmitted:false});
  await assert.rejects(()=>f.transport.press(instance,{x:50,y:35},context));
  assert.throws(()=>f.transport.press(instance,{x:50,y:35},context));assert.equal(f.requests.filter(r=>r.command==='press').length,1);
});
test('Cleanup retains observed tuple even if caller never received a valid acquisition envelope',async()=>{
  const f=fixture();await f.transport.open(selection,scope,'intents-run-1');
  const receipt=await f.transport.release(scope,null);assert.deepEqual((receipt as {applicationTarget:unknown}).applicationTarget,instance);
  await f.transport.release(scope,instance);assert.equal(f.cleanup(),1);
  await assert.rejects(()=>f.transport.release({...scope,leaseGeneration:2},instance));
});
test('SDK transport release never certifies in-flight callbacks as drained',async()=>{
  const f=fixture();await f.transport.open(selection,scope,'intents-run-1');
  let resolve!:()=>void,enter!:()=>void;const entered=new Promise<void>(done=>{enter=done;});const wait=new Promise<void>(done=>{resolve=done;});
  f.client.capture.snapshot=async()=>{enter();await wait;return snapshot;};const pending=f.transport.capture(instance,context);await entered;
  await assert.rejects(()=>f.transport.release(scope,instance));assert.equal(f.cleanup(),0);
  resolve();await pending;await f.transport.release(scope,instance);assert.equal(f.cleanup(),1);
});
test('Synchronous cleanup failure remains latched and is not reissued',async()=>{
  const f=fixture();let attempts=0;
  const transport=new MacOwnedSDKTransport(f.client,target,scope,()=>{attempts++;throw new Error('synthetic cleanup failure');},'private-owned-mac-source');
  await transport.open(selection,scope,'intents-run-1');
  await assert.rejects(()=>transport.release(scope,instance),/synthetic cleanup failure/);
  await assert.rejects(()=>transport.release(scope,instance),/synthetic cleanup failure/);assert.equal(attempts,1);
});
type FillRequest=Readonly<{x:number;y:number;value:string}>;
type ScrollRequest=Readonly<{x:number;y:number;direction:'up'|'down'|'left'|'right'}>;
const fillRequest:FillRequest={x:50,y:35,value:'hello'};
const scrollRequest:ScrollRequest={x:50,y:35,direction:'down'};
function nativeFixture(){
  const base=fixture(),calls:{command:'fill'|'scroll';instance:unknown;request:unknown;context:unknown}[]=[];
  let fillValue:unknown={applicationTarget:instance,x:50,y:35,disposition:'replacementVerified'};
  let scrollValue:unknown={applicationTarget:instance,x:50,y:35,direction:'down',disposition:'submittedUnconfirmed'};
  let fillGate:Promise<void>|undefined;
  const transport=new MacOwnedSDKTransport(base.client,target,scope,async(_requested,selected)=>
    ({scope,applicationTarget:selected,commandsDrained:true,ownedHelperReaped:true,daemonStopped:true,subjectTerminated:false}),
  'private-owned-mac-source',
  async(selected,request,operation)=>{calls.push({command:'scroll',instance:selected,request,context:operation});
    if(scrollValue instanceof Error)throw scrollValue;return scrollValue;},
  async(selected,request,operation)=>{calls.push({command:'fill',instance:selected,request,context:operation});
    if(fillGate)await fillGate;if(fillValue instanceof Error)throw fillValue;return fillValue;});
  return {transport,calls,requests:base.requests,setFill:(v:unknown)=>{fillValue=v;},setScroll:(v:unknown)=>{scrollValue=v;},
    setFillGate:(v:Promise<void>|undefined)=>{fillGate=v;}};
}
function assertInputLatched(f:ReturnType<typeof nativeFixture>):void {
  const before=f.calls.length;
  assert.throws(()=>f.transport.press(instance,{x:50,y:35},context),/Earlier Mac SDK input is unresolved/);
  assert.throws(()=>f.transport.ordinaryFill!(instance,fillRequest,context),/Ordinary Mac fill unavailable/);
  assert.throws(()=>f.transport.scroll!(instance,scrollRequest,context),/Invalid or uncertain Mac scroll/);
  assert.equal(f.calls.length,before);assert.equal(f.requests.filter(r=>r.command==='press').length,0);
}
test('Native fill and scroll are only exposed when executors are injected',()=>{
  const plain=fixture().transport,native=nativeFixture().transport;
  assert.equal(plain.ordinaryFill,undefined);assert.equal(plain.scroll,undefined);
  assert.equal(typeof native.ordinaryFill,'function');assert.equal(typeof native.scroll,'function');
});
test('Native fill and scroll forward the exact request and return verified receipts',async()=>{
  const f=nativeFixture();await f.transport.open(selection,scope,'intents-run-1');
  assert.deepEqual(await f.transport.ordinaryFill!(instance,fillRequest,context),
    {applicationTarget:instance,x:50,y:35,disposition:'replacementVerified'});
  assert.deepEqual(await f.transport.scroll!(instance,scrollRequest,context),
    {applicationTarget:instance,x:50,y:35,direction:'down',disposition:'submittedUnconfirmed'});
  assert.deepEqual(f.calls.map(c=>c.command),['fill','scroll']);
  assert.deepEqual(f.calls[0]!.instance,instance);assert.deepEqual(f.calls[0]!.request,fillRequest);assert.equal(f.calls[0]!.context,context);
  assert.deepEqual(f.calls[1]!.instance,instance);assert.deepEqual(f.calls[1]!.request,scrollRequest);assert.equal(f.calls[1]!.context,context);
  await f.transport.press(instance,{x:50,y:35},context);
});
test('Native fill receipt mismatches latch input uncertainty',async()=>{
  for(const receipt of [
    {applicationTarget:instance,x:51,y:35,disposition:'replacementVerified'},
    {applicationTarget:instance,x:50,y:36,disposition:'replacementVerified'},
    {applicationTarget:instance,x:50,y:35,disposition:'submittedUnconfirmed'},
    {applicationTarget:instance,x:50,y:35,disposition:'replacementVerified',extra:true},
    {applicationTarget:{...instance,pid:124},x:50,y:35,disposition:'replacementVerified'},
    {applicationTarget:instance,x:50,y:35},
    new Error('synthetic fill failure')]){
    const f=nativeFixture();await f.transport.open(selection,scope,'intents-run-1');f.setFill(receipt);
    await assert.rejects(()=>f.transport.ordinaryFill!(instance,fillRequest,context));
    assert.equal(f.calls.length,1);assertInputLatched(f);
  }
});
test('Native scroll receipt mismatches latch input uncertainty',async()=>{
  for(const receipt of [
    {applicationTarget:instance,x:51,y:35,direction:'down',disposition:'submittedUnconfirmed'},
    {applicationTarget:instance,x:50,y:36,direction:'down',disposition:'submittedUnconfirmed'},
    {applicationTarget:instance,x:50,y:35,direction:'up',disposition:'submittedUnconfirmed'},
    {applicationTarget:instance,x:50,y:35,direction:'down',disposition:'replacementVerified'},
    {applicationTarget:{...instance,pid:124},x:50,y:35,direction:'down',disposition:'submittedUnconfirmed'},
    new Error('synthetic scroll failure')]){
    const f=nativeFixture();await f.transport.open(selection,scope,'intents-run-1');f.setScroll(receipt);
    await assert.rejects(()=>f.transport.scroll!(instance,scrollRequest,context));
    assert.equal(f.calls.length,1);assertInputLatched(f);
  }
});
test('Native input cancelled while in flight remains uncertain',async()=>{
  const f=nativeFixture();await f.transport.open(selection,scope,'intents-run-1');
  const controller=new AbortController(),live={...context,signal:controller.signal};
  let release!:()=>void;f.setFillGate(new Promise<void>(done=>{release=done;}));
  const pending=f.transport.ordinaryFill!(instance,fillRequest,live);controller.abort();release();
  await assert.rejects(pending,/Invalid or cancelled Mac SDK context/);assertInputLatched(f);
});
test('Native fill and scroll are refused before open',()=>{
  const f=nativeFixture();
  assert.throws(()=>f.transport.ordinaryFill!(instance,fillRequest,context),/Ordinary Mac fill unavailable/);
  assert.throws(()=>f.transport.scroll!(instance,scrollRequest,context),/Invalid or uncertain Mac scroll/);
  assert.equal(f.calls.length,0);
});
test('Native fill and scroll refuse bad context, instance, point, value and direction before dispatch',async()=>{
  const f=nativeFixture();await f.transport.open(selection,scope,'intents-run-1');
  const aborted=new AbortController();aborted.abort();
  for(const value of [{...context,signal:aborted.signal},{...context,timeoutMs:60_001},{...context,timeoutMs:0},
    {...context,timeoutMs:Number.NaN},{...context,runId:'other'},{...context,attemptId:'other'}]){
    assert.throws(()=>f.transport.ordinaryFill!(instance,fillRequest,value),/Invalid or cancelled Mac SDK context/);
    assert.throws(()=>f.transport.scroll!(instance,scrollRequest,value),/Invalid or cancelled Mac SDK context/);
  }
  assert.throws(()=>f.transport.ordinaryFill!({...instance,pid:124},fillRequest,context),/Different Mac application instance/);
  assert.throws(()=>f.transport.scroll!({...instance,pid:124},scrollRequest,context),/Different Mac application instance/);
  for(const point of [{x:1_000_001,y:35},{x:50,y:-1_000_001},{x:Infinity,y:35},{x:50,y:Number.NaN}]){
    assert.throws(()=>f.transport.ordinaryFill!(instance,{...fillRequest,...point},context),/Invalid ordinary Mac point/);
    assert.throws(()=>f.transport.scroll!(instance,{...scrollRequest,...point},context),/Invalid or uncertain Mac scroll/);
  }
  for(const value of ['a\0b','x'.repeat(16_385)])
    assert.throws(()=>f.transport.ordinaryFill!(instance,{...fillRequest,value},context),/Invalid ordinary Mac literal/);
  assert.throws(()=>f.transport.scroll!(instance,{...scrollRequest,direction:'sideways' as 'up'},context),/Invalid or uncertain Mac scroll/);
  assert.equal(f.calls.length,0);
  f.setFill({applicationTarget:instance,x:1_000_000,y:-1_000_000,disposition:'replacementVerified'});
  await f.transport.ordinaryFill!(instance,{...fillRequest,x:1_000_000,y:-1_000_000},context);assert.equal(f.calls.length,1);
});
test('Native fill and scroll refuse overlapping commands and closed transports without latching',async()=>{
  const f=nativeFixture();await f.transport.open(selection,scope,'intents-run-1');
  let release!:()=>void;f.setFillGate(new Promise<void>(done=>{release=done;}));
  const pending=f.transport.ordinaryFill!(instance,fillRequest,context);
  await assert.rejects(()=>f.transport.scroll!(instance,scrollRequest,context),/Mac SDK transport unavailable/);
  await assert.rejects(()=>f.transport.ordinaryFill!(instance,fillRequest,context),/Mac SDK transport unavailable/);
  assert.equal(f.calls.length,1);release();await pending;f.setFillGate(undefined);
  await f.transport.scroll!(instance,scrollRequest,context);assert.equal(f.calls.length,2);
  await f.transport.release(scope,instance);
  await assert.rejects(()=>f.transport.ordinaryFill!(instance,fillRequest,context),/Mac SDK transport unavailable/);
  await assert.rejects(()=>f.transport.scroll!(instance,scrollRequest,context),/Mac SDK transport unavailable/);
  assert.equal(f.calls.length,2);
});
