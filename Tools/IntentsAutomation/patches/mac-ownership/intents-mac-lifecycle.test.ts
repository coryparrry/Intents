import {listSessionSelectorConflicts} from './daemon/session-selector.ts';
import {resolveOpenSurfaceResponse,prepareOpenCommandDetails} from './daemon/session-lifecycle/internal/session-open-prepare.ts';
import assert from 'node:assert/strict';
import {test} from 'vitest';
import {bindAppleApplicationLifecycle} from '../packages/platform-apple/src/lifecycle.ts';
import {openInput} from '../packages/platform-apple/src/lifecycle.fixtures.ts';
import {platformRuntimeHostFixture} from '../packages/platform-apple/src/runtime.fixtures.ts';
import {createLocalAppleToolProvider,withAppleToolProvider} from '../packages/platform-apple/src/core/tool-provider.ts';
import type {DeviceInfo} from '@agent-device/kernel/device';
import {validateResolvedOpenRequest} from './daemon/session-lifecycle/internal/session-open-prepare.ts';

const target={bundleId:'example.Target',canonicalBundlePath:'/Applications/Selected.app',pid:123,processStartIdentity:'100:0'};
const mac:DeviceInfo={platform:'apple',appleOs:'macos',id:'mac',name:'Mac',kind:'device',target:'desktop'};
const input=()=>({...openInput(),target:target.bundleId,positionals:[target.bundleId],appBundleId:target.bundleId,
  macBundlePath:target.canonicalBundlePath,surface:'frontmost-app' as const,relaunch:false});

test('request validation admits a normalized Mac and rejects other Apple OSes',async()=>{
  const request={macBundlePath:target.canonicalBundlePath,shouldRelaunch:false,openTarget:target.bundleId,
    surface:'frontmost-app' as const,device:mac};
  assert.equal(await validateResolvedOpenRequest(request),null);
  for(const appleOs of ['ios','ipados','tvos','visionos','watchos',undefined] as const){
    const response=await validateResolvedOpenRequest({...request,device:{...mac,appleOs}});
    assert.equal(response?.ok,false);
    if(response && !response.ok)assert.equal(response.error.code,'INVALID_ARGS');
  }
});

test('Mac lifecycle reaches owned provider with exact selection and bound cancellation',async()=>{
  const controller=new AbortController();let calls=0;
  const provider=createLocalAppleToolProvider({macosHelper:{run:async(args,options)=>{
    calls++;assert.deepEqual(args,['app','open','--bundle-id',target.bundleId,'--bundle-path',target.canonicalBundlePath]);
    assert.equal(options?.signal,controller.signal);
    return {stdout:JSON.stringify({ok:true,data:target}),stderr:'',exitCode:0};
  }}});
  const lifecycle=bindAppleApplicationLifecycle({host:platformRuntimeHostFixture(),device:mac,signal:controller.signal});
  const result=await withAppleToolProvider(provider,()=>lifecycle.openApplication(input()));
  assert.deepEqual(result.applicationTarget,target);assert.equal(result.appBundleId,target.bundleId);assert.equal(calls,1);
});

test('exact-path Mac acquisition rejects other Apple OSes before helper dispatch',async()=>{
  let calls=0;
  const provider=createLocalAppleToolProvider({macosHelper:{run:async()=>{calls++;throw new Error('must not dispatch');}}});
  for(const appleOs of ['ios','ipados','tvos','visionos','watchos',undefined] as const){
    const lifecycle=bindAppleApplicationLifecycle({host:platformRuntimeHostFixture(),device:{...mac,appleOs},signal:new AbortController().signal});
    await assert.rejects(()=>withAppleToolProvider(provider,()=>lifecycle.openApplication(input())),/Owned Mac open requires/);
  }
  assert.equal(calls,0);
});

test('Mac lifecycle does not lose cancellation or accept ambiguous open options',async()=>{
  const controller=new AbortController();controller.abort();let calls=0;
  const provider=createLocalAppleToolProvider({macosHelper:{run:async(_args,options)=>{
    calls++;assert.equal(options?.signal,controller.signal);options!.signal!.throwIfAborted();
    throw new Error('cancelled helper must not return success');
  }}});
  const lifecycle=bindAppleApplicationLifecycle({host:platformRuntimeHostFixture(),device:mac,signal:controller.signal});
  await assert.rejects(()=>withAppleToolProvider(provider,()=>lifecycle.openApplication(input())),/verified identity/);
  assert.equal(calls,1);
  for(const options of [{relaunch:true},{surface:'desktop' as const},{runtimeHints:{metroHost:'localhost'}},
    {positionals:[target.bundleId,'extra']},{execution:{launchArgs:['unsafe']}}]){
    await assert.rejects(()=>withAppleToolProvider(provider,()=>lifecycle.openApplication({...input(),...options})),/Owned Mac open requires/);
  }
  assert.equal(calls,1);
});


test('surface admission accepts only validated exact Mac frontmost selection',()=>{
  assert.equal(resolveOpenSurfaceResponse(mac,'frontmost-app',target.bundleId,undefined,target.canonicalBundlePath),'frontmost-app');
  for(const params of [[mac,'frontmost-app',target.bundleId,undefined,undefined],
    [mac,'desktop',target.bundleId,undefined,target.canonicalBundlePath],
    [{...mac,appleOs:'ios'},'frontmost-app',target.bundleId,undefined,target.canonicalBundlePath],
    [mac,'frontmost-app','https://example.com',undefined,target.canonicalBundlePath],
    [mac,'frontmost-app',target.bundleId,undefined,'/private/tmp/../Other.app']] as const){
    assert.notEqual(resolveOpenSurfaceResponse(params[0],params[1],params[2],params[3],params[4]),'frontmost-app');
  }
});


test('exact Mac preparation never asks an ambient runtime for target identity or preparation',async()=>{
  let calls=0;
  const runtime={operations:new Proxy({}, {get(){calls++;throw new Error('Ambient runtime must not be consulted');}})};
  const result=await prepareOpenCommandDetails({req:{token:'fixture',session:'owned',command:'open',positionals:[target.bundleId],flags:{macBundlePath:target.canonicalBundlePath}},
    logPath:'/private/tmp/fixture.log',surface:'frontmost-app',openTarget:target.bundleId,foreground:true,
    runtime:runtime as unknown as Parameters<typeof prepareOpenCommandDetails>[0]['runtime'],
    runtimeHintPlan:{runtime:undefined,previousRuntime:undefined,replacedStoredRuntime:false,applyRuntimeHints:false,clearRemovedRuntimeHints:false}});
  assert.equal(result.type,'details');if(result.type==='details'){assert.equal(result.details.appBundleId,target.bundleId);assert.equal(result.details.appName,undefined);}
  assert.equal(calls,0);
});


test('Mac exact session retains its device selector without allowing ambient Mac identity',()=>{
  const session={name:'owned',device:mac,createdAt:1,surface:'frontmost-app' as const,appBundleId:target.bundleId,applicationTarget:target,actions:[]};
  assert.deepEqual(listSessionSelectorConflicts(session,{udid:mac.id,platform:'macos',target:'desktop'}),[]);
  assert.deepEqual(listSessionSelectorConflicts(session,{udid:'other'}),[{key:'udid',value:'other'}]);
  assert.deepEqual(listSessionSelectorConflicts({...session,applicationTarget:undefined},{udid:mac.id}),[{key:'udid',value:mac.id}]);
});
