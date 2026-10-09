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
