// Dedicated synthetic composition; it submits no GUI input.
import assert from 'node:assert/strict';
import {join} from 'node:path';import {mkdir} from 'node:fs/promises';
import {MacOwnedDaemon,type PrivateMacDaemonSDK} from '../../src/macOwnedDaemon.js';
import {MacOwnedSession} from '../../src/macOwnedSession.js';
import {privateFillHelperSHA256,type MacNativeHelperRequest,MacOwnedHelperProvider} from '../../src/macOwnedHelperProvider.js';
import type {Scope,Target} from '../../src/protocol.js';import type {OperationContext} from 'e2e/engine';
const config=JSON.parse(Buffer.from(process.argv[2]!,'base64').toString('utf8')) as {root:string;mode:string};
const directory=join(config.root,'state'),app=join(config.root,'Fixture.app');await mkdir(app);
assert.equal(process.env.AGENT_DEVICE_CLAIMS_DIR,join(directory,'claims'));
const scope:Scope={protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:1};
const target:Target={id:'host-macos-local',kind:'nativeMac',platform:'macos',bundleId:'example.Fixture',bundlePath:app,loginSession:'synthetic'};
const instance={bundleId:target.bundleId,canonicalBundlePath:app,pid:123,processStartIdentity:'100:0'};
const helperSHA256=config.mode==='old-helper'?'a'.repeat(64):privateFillHelperSHA256;
let overrides:ReturnType<MacOwnedHelperProvider['overrides']>,capture=0,fills=0,policies=0,shutdown=0;
const args=['--bundle-id',target.bundleId,'--target-bundle-path',app,'--target-pid','123','--target-process-start','100:0','--surface','frontmost-app'];
const api:PrivateMacDaemonSDK={startDaemonRuntime:async options=>{
 overrides=options.appleToolProvider({device:{id:target.id}}) as typeof overrides;
 return {httpPort:12345,token:'a'.repeat(48),drainOwnedRequests:async()=>true,shutdown:async()=>{shutdown++;}};
},createLocalAppleToolProvider:value=>value,createAgentDeviceClient:()=>({
 apps:{open:async()=>{const r=await overrides.macosHelper.run(['app','open','--bundle-id',target.bundleId,'--bundle-path',app]);
  return {session:'intents-run-1',identifiers:{deviceId:target.id},appBundleId:target.bundleId,applicationTarget:JSON.parse(r.stdout).data};}},
 capture:{snapshot:async()=>{const r=await overrides.macosHelper.run(['snapshot',...args]);capture++;
  return {...JSON.parse(r.stdout).data,appBundleId:target.bundleId,identifiers:{session:'intents-run-1'},refsGeneration:capture};}},
 interactions:{press:async()=>{throw new Error('Unexpected tap');}}})};
const channel={reverse:async(method:string,input:any)=>{
 if(method==='mac.helper.stop')return {scope,applicationTarget:input.applicationTarget,commandsDrained:true,ownedHelperReaped:true};
 assert.equal(method,'mac.helper.run');const request=input.request as MacNativeHelperRequest;assert.deepEqual(request.scope,scope);
 let data:unknown=instance;
 if(request.action.kind==='snapshot')data={applicationTarget:instance,truncated:false,nodes:[{index:1,ref:'@e1',role:'AXTextField',editable:true,
  enabled:true,hittable:true,visibleToUser:true,rect:{x:0,y:0,width:100,height:50}}]};
 if(request.action.kind==='ordinaryFill'){fills++;assert.equal(request.action.value,'public-e\u0301');
  data={applicationTarget:instance,x:config.mode==='uncertain'?999:request.action.x,y:request.action.y,disposition:'replacementVerified'};}
 return {requestId:request.requestId,scope,helperABI:config.mode==='old-helper'?'startup-gate-v1':'startup-gate-v2-private-input',helperSHA256,
  ownedIdentity:{pid:42,startIdentity:'200:0'},startupAcknowledged:true,directChildReaped:true,pipesDrained:true,callbacksDrained:true,
  logsTruncated:false,exitCode:0,stderr:'',stdout:JSON.stringify({ok:true,data})};
}};
const daemon=await MacOwnedDaemon.start(api,directory,target,scope,helperSHA256,'b'.repeat(64),channel);
const session=await MacOwnedSession.acquire(target,scope,daemon.transport,async(_scope,action)=>{assert.equal(action.kind,'fill');policies++;});
const context:OperationContext={runId:'run',attemptId:'attempt',origin:'test',signal:new AbortController().signal,timeoutMs:5000};
await session.snapshot(context);const action={kind:'fill' as const,value:'public-e\u0301',sensitive:false};
if(config.mode==='old-helper'){
 assert.equal(session.supportsOrdinaryFill,false);await assert.rejects(session.perform('@e1~s1',action,context));assert.equal(fills,0);
}else if(config.mode==='uncertain'){
 assert.equal(session.supportsOrdinaryFill,true);await assert.rejects(session.perform('@e1~s1',action,context));
 await assert.rejects(session.perform('@e1~s1',action,context));assert.equal(fills,1);
}else{
 assert.equal(session.supportsOrdinaryFill,true);await session.perform('@e1~s1',action,context);assert.equal(fills,1);assert.equal(policies,1);
}
const released=await session.release();assert.equal(released.released,true);assert.equal(shutdown,1);
process.stdout.write(JSON.stringify({fills,policies,released:released.released,shutdown}));
