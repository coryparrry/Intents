import assert from 'node:assert/strict';
import {test} from 'vitest';
import {createLocalAppleToolProvider, withAppleToolProvider} from '../packages/platform-apple/src/core/tool-provider.ts';
import {runMacOsOwnedApplicationOpen, runMacOsPressAction, runMacOsSnapshotAction} from '../packages/platform-apple/src/os/macos/helper.ts';
import {captureMacOsSurfaceSnapshot} from '../packages/platform-apple/src/os/macos/surface-snapshot.ts';
import {createAgentDeviceClient} from './agent-device-client.ts';
import {buildRuntimeCaptureInput, runtimeExecutionFromContext} from './daemon/snapshot-runtime-capture-input.ts';
import {buildNextOpenSession, buildOpenResult} from './daemon/session-lifecycle/internal/session-open-surface.ts';
import {createAgentDevice, localCommandPolicy} from './runtime.ts';
import {createLocalArtifactAdapter} from './io.ts';
import {serializeSnapshotResult} from './commands/output/result-serialization.ts';
import {RESPONSE_VIEWS} from './daemon/response-views.ts';
import {AppError} from '@agent-device/kernel/errors';
import type {SessionState} from './daemon/session-state.ts';
import type {DeviceInfo} from '@agent-device/kernel/device';
import type {AgentDeviceDaemonTransport} from '@agent-device/contracts/client';
import {prepareLockedRequestScope, type RequestExecutionScope} from './daemon/request-execution-scope.ts';
import {SessionStore} from './daemon/session-store.ts';

const target = Object.freeze({bundleId:'example.Target',canonicalBundlePath:'/Applications/Selected café.app',pid:123,processStartIdentity:'100:0'});
const device: DeviceInfo = {platform:'macos',id:'mac',name:'Mac',kind:'device',target:'desktop'};
const session: SessionState = {name:'owned',device,createdAt:1,surface:'frontmost-app',appBundleId:target.bundleId,applicationTarget:target,actions:[]};
const output = (data: Record<string, unknown>) => ({exitCode:0,stdout:JSON.stringify({ok:true,data}),stderr:''});
const receipt = {applicationTarget:target,x:10,y:20,disposition:'submittedUnconfirmed',releaseSubmitted:true};

test('owned open transports exact selection, signal and captured identity',async()=>{
  const controller = new AbortController(); let calls=0;
  const provider = createLocalAppleToolProvider({macosHelper:{run:async(args,options)=>{
    calls++; assert.deepEqual(args,['app','open','--bundle-id',target.bundleId,'--bundle-path',target.canonicalBundlePath]);
    assert.equal(options?.signal,controller.signal); return output(target);
  }}});
  assert.deepEqual(await withAppleToolProvider(provider,()=>runMacOsOwnedApplicationOpen(target.bundleId,target.canonicalBundlePath,controller.signal)),target);
  assert.equal(calls,1);
});
test('open mismatches and transport failures remain uncertain without retry',async()=>{
  for(const mode of ['mismatch','throw'] as const) {
    let calls=0;
    const provider=createLocalAppleToolProvider({macosHelper:{run:async()=>{calls++;
      if(mode==='throw') throw new Error('transport stopped after dispatch');
      return output({...target,canonicalBundlePath:'/Applications/Other.app'});
    }}});
    await assert.rejects(()=>withAppleToolProvider(provider,()=>runMacOsOwnedApplicationOpen(target.bundleId,target.canonicalBundlePath)),
      (error:unknown)=>error instanceof AppError && error.details?.acquisitionUncertain===true);
    assert.equal(calls,1);
  }
});
test('snapshot captures and projects identity from the helper rather than the ambient frontmost app',async()=>{
  let calls=0;
  const provider=createLocalAppleToolProvider({macosHelper:{run:async(args)=>{calls++;
    assert.ok(args.includes('--target-pid')); assert.equal(args[args.indexOf('--target-pid')+1],'123');
    assert.equal(args[args.indexOf('--target-bundle-path')+1],target.canonicalBundlePath);
    return output({applicationTarget:target,surface:'frontmost-app',nodes:[{index:0,label:'Selected',depth:0}],truncated:false,backend:'macos-helper'});
  }}});
  const result=await withAppleToolProvider(provider,()=>captureMacOsSurfaceSnapshot({surface:'frontmost-app',appBundleId:target.bundleId,applicationTarget:target}));
  assert.deepEqual(result.applicationTarget,target); assert.equal(result.nodes?.[0]?.label,'Selected'); assert.equal(calls,1);
});
test('snapshot rejects missing or changed instance echo',async()=>{
  for(const applicationTarget of [undefined,{...target,pid:124},{...target,processStartIdentity:'101:0'}]) {
    const provider=createLocalAppleToolProvider({macosHelper:{run:async()=>output({applicationTarget,nodes:[],truncated:false,backend:'macos-helper',surface:'frontmost-app'})}});
    await assert.rejects(()=>withAppleToolProvider(provider,()=>runMacOsSnapshotAction('frontmost-app',{bundleId:target.bundleId,applicationTarget:target})));
  }
});
test('press rejects invalid ownership before invoking a provider',async()=>{
  let calls=0;
  const provider=createLocalAppleToolProvider({macosHelper:{run:async()=>{calls++;return output(receipt);}}});
  await withAppleToolProvider(provider,async()=>{
    await assert.rejects(()=>runMacOsPressAction(10,20,{surface:'desktop',bundleId:target.bundleId,applicationTarget:target}));
    await assert.rejects(()=>runMacOsPressAction(10,20,{surface:'frontmost-app',bundleId:'example.Other',applicationTarget:target}));
    await assert.rejects(()=>runMacOsPressAction(10,20,{surface:'frontmost-app',bundleId:target.bundleId,applicationTarget:target,clicks:9}));
  });
  assert.equal(calls,0);
});
test('press submits once and preserves the unconfirmed disposition',async()=>{
  let calls=0;
  const provider=createLocalAppleToolProvider({macosHelper:{run:async(args)=>{calls++;assert.ok(args.includes('--target-process-start'));return output(receipt);}}});
  const result=await withAppleToolProvider(provider,()=>runMacOsPressAction(10,20,{surface:'frontmost-app',bundleId:target.bundleId,applicationTarget:target}));
  assert.deepEqual(result,receipt);assert.equal(calls,1);
});
test('post-dispatch press failures preserve uncertainty and never retry',async()=>{
  for(const mode of ['release','target','throw','malformed'] as const) {
    let calls=0;
    const provider=createLocalAppleToolProvider({macosHelper:{run:async()=>{calls++;
      if(mode==='throw') throw new Error('transport stopped');
      if(mode==='malformed') return {exitCode:0,stdout:'not json',stderr:''};
      return output(mode==='release'?{...receipt,releaseSubmitted:false}:{...receipt,applicationTarget:{...target,pid:124}});
    }}});
    await assert.rejects(()=>withAppleToolProvider(provider,()=>runMacOsPressAction(10,20,{surface:'frontmost-app',bundleId:target.bundleId,applicationTarget:target})),
      (error:unknown)=>error instanceof AppError && error.details?.operationDisposition==='uncertain' && error.details?.mayHaveCommitted===true);
    assert.equal(calls,1);
  }
});
test('open session, runtime capture and touch metadata retain the same target',()=>{
  const next=buildNextOpenSession({existingSession:session,sessionName:'owned',sessionScope:'workspace',device,surface:'frontmost-app',appBundleId:target.bundleId,applicationTarget:target});
  assert.deepEqual(next.applicationTarget,target);
  const input=buildRuntimeCaptureInput({flags:undefined,session:next,snapshotScope:undefined});
  assert.deepEqual(input.options?.applicationTarget,target);assert.deepEqual(input.execution?.applicationTarget,target);
  assert.deepEqual(runtimeExecutionFromContext({applicationTarget:target}).applicationTarget,target);
  const result=buildOpenResult({sessionName:'owned',sessionStateDir:'/tmp/state',runnerLogPath:'/tmp/runner',requestLogPath:'/tmp/request',eventLogPath:'/tmp/event',surface:'frontmost-app',sessionReused:true,runtimeHintCount:()=>0,applicationTarget:target});
  assert.deepEqual(result.applicationTarget,target);
});
test('runtime snapshot, serializer and digest preserve the fresh captured target',async()=>{
  const runtime=createAgentDevice({backend:{platform:'macos',captureSnapshot:async()=>({applicationTarget:target,
    snapshot:{nodes:[],backend:'macos-helper',createdAt:1},appBundleId:target.bundleId})},artifacts:createLocalArtifactAdapter(),
    sessions:{get:()=>undefined,set:()=>{}},policy:localCommandPolicy()});
  const result=await runtime.capture.snapshot({session:'owned'});
  assert.deepEqual(result.applicationTarget,target);
  const serialized=serializeSnapshotResult({...result,identifiers:{session:'owned'}});
  assert.deepEqual(serialized.applicationTarget,target);
  assert.deepEqual(RESPONSE_VIEWS.snapshot(serialized,'digest').applicationTarget,target);
});
test('public client forwards explicit selection and validates open and snapshot target responses',async()=>{
  const requests: Parameters<AgentDeviceDaemonTransport>[0][]=[];
  let bad=false;
  const client=createAgentDeviceClient({session:'owned'},{transport:async(req)=>{
    requests.push(req); return {ok:true,data:{applicationTarget:bad?{...target,pid:0}:target,nodes:[],appBundleId:target.bundleId}};
  }});
  const opened=await client.apps.open({app:target.bundleId,macBundlePath:target.canonicalBundlePath,platform:'macos',surface:'frontmost-app'});
  assert.equal(requests[0]?.flags?.macBundlePath,target.canonicalBundlePath);assert.deepEqual(opened.applicationTarget,target);
  assert.deepEqual((await client.capture.snapshot()).applicationTarget,target);
  bad=true;await assert.rejects(()=>client.capture.snapshot());await assert.rejects(()=>client.apps.open({app:target.bundleId,macBundlePath:target.canonicalBundlePath}));
});
test('daemon refuses unsupported owned Mac commands before a runtime can be bound',async()=>{
  const store=new SessionStore('/private/tmp/intents-owned-mac-no-files');
  store.set('owned',session);
  let binds=0;
  for(const command of ['fill','scroll','close','screenshot','appstate','gesture','keyboard','click','longpress']) {
    const scope={req:{command,session:'owned'},command,sessionName:'owned',runnerLogPath:'/private/tmp/unused',
      throwIfCanceled:()=>{},bindDevice:async()=>{binds++;throw new Error('Unexpected bind');}} as unknown as RequestExecutionScope;
    const result=await prepareLockedRequestScope({scope,sessionStore:store,trackDownloadableArtifact:()=>{throw new Error('Unexpected artifact');}});
    assert.equal(result.type,'response',command);
    if(result.type==='response') {assert.equal(result.response.ok,false);
      if(!result.response.ok) assert.equal(result.response.error.code,'UNSUPPORTED_OPERATION');}
  }
  assert.equal(binds,0);
});
