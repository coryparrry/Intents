import {requireMacOwnedInstance} from '../../src/macOwnedSession.js';
import assert from 'node:assert/strict';
import {guardSyntheticDaemonHost} from './macDaemonHostGuard.js';
import {pathToFileURL} from 'node:url';
import {join} from 'node:path';
import {MacOwnedDaemon,type PrivateMacDaemonSDK} from '../../src/macOwnedDaemon.js';
import type {Scope,Target} from '../../src/protocol.js';
import type {MacNativeHelperRequest} from '../../src/macOwnedHelperProvider.js';
import type {OperationContext} from 'e2e/engine';

// Runs only in a dedicated synthetic fixture child, never the product sidecar.
const config=JSON.parse(Buffer.from(process.argv[2]!,'base64').toString('utf8')) as {
  directory:string;sdk:string;target:Target;scope:Scope;mode:string;
};
assert.equal(process.env.AGENT_DEVICE_CLAIMS_DIR,join(config.directory,'claims'));
const {hostCalls,metadataCalls}=guardSyntheticDaemonHost();
const imported=await import(pathToFileURL(config.sdk).href) as PrivateMacDaemonSDK;
const server:{controller:Awaited<ReturnType<PrivateMacDaemonSDK['startDaemonRuntime']>>}={controller:null};
let daemonLog='';
const api:PrivateMacDaemonSDK={...imported,createAgentDeviceClient:(settings,deps)=>{if(config.mode==='startup-fail')throw new Error('synthetic-client-construction');return imported.createAgentDeviceClient(settings,{transport:async request=>{try{return await deps.transport(request);}catch(error){process.stderr.write(JSON.stringify(request).replace(/[a-f0-9]{48,64}/g,'[redacted]')+'\n');throw error;}}});},startDaemonRuntime:async options=>{
  server.controller=await imported.startDaemonRuntime({...options,stdout:{write:text=>{daemonLog=(daemonLog+text).slice(-8192);options.stdout.write(text);}},stderr:{write:text=>{daemonLog=(daemonLog+text).slice(-8192);options.stderr.write(text);}}});return config.mode==='invalid-port' && server.controller?{...server.controller,httpPort:0}:server.controller;
}};
const helperSHA256='a'.repeat(64),authentication='b'.repeat(64),requests:MacNativeHelperRequest[]=[];
const instance={bundleId:config.target.bundleId,canonicalBundlePath:config.target.bundlePath!,pid:123,processStartIdentity:'100:0'};
let resolvePress:(()=>void)|undefined,pressStarted:(()=>void)|undefined;
const started=new Promise<void>(resolve=>{pressStarted=resolve;});
const stopped=new Promise<void>(resolve=>{resolvePress=resolve;});
const channel={reverse:async(method:string,input:any)=>{
  assert.equal(input.authentication,authentication);
  if(method==='mac.helper.stop'){
    if(config.mode==='cleanup-fail')throw new Error('Synthetic native cleanup unavailable');
    resolvePress?.();return {scope:config.scope,applicationTarget:input.applicationTarget,commandsDrained:true,ownedHelperReaped:true};
  }
  assert.equal(method,'mac.helper.run');const request=input.request as MacNativeHelperRequest;
  assert.deepEqual(request.scope,config.scope);requests.push(request);
  let data:unknown=instance;
  if(request.action.kind==='snapshot')data={applicationTarget:instance,surface:'frontmost-app',nodes:[{index:0,label:'Selected',depth:0}],truncated:false,backend:'macos-helper'};
  if(request.action.kind==='press'){
    pressStarted?.();if(config.mode==='cancel'){await stopped;throw new Error('Synthetic native press cancelled');}
    data={applicationTarget:instance,x:request.action.x,y:request.action.y,disposition:'submittedUnconfirmed',releaseSubmitted:config.mode!=='uncertain'};
  }
  return {requestId:request.requestId,scope:request.scope,helperABI:'startup-gate-v1',helperSHA256,
    ownedIdentity:{pid:456,startIdentity:'200:0'},startupAcknowledged:true,directChildReaped:true,pipesDrained:true,
    callbacksDrained:true,logsTruncated:false,exitCode:0,stderr:'',stdout:JSON.stringify({ok:true,data})};
}};
let daemon:MacOwnedDaemon|undefined;
try {
  daemon=await MacOwnedDaemon.start(api,config.directory,config.target,config.scope,helperSHA256,authentication,channel);
  assert.ok(server.controller?.httpPort);
  const rpc=async(params:unknown,token=server.controller!.token)=>{
    const response=await fetch(`http://127.0.0.1:${server.controller!.httpPort}/rpc`,{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${token}`},
      body:JSON.stringify({jsonrpc:'2.0',id:'probe',method:'agent_device.command',params})});
    return await response.json() as any;
  };
  const session=`intents-${config.scope.runId}-${config.scope.leaseGeneration}`;
  const open={session,meta:{cwd:config.directory,sessionExplicit:true},command:'open',positionals:[config.target.bundleId],flags:{stateDir:config.directory,session,platform:'macos',target:'desktop',udid:config.target.id,
    macBundlePath:config.target.bundlePath,surface:'frontmost-app',relaunch:false}};
  const before=requests.length;
  const denied=[];
  for(const params of [{...open,session:'other'},{...open,runtime:null},{...open,runtime:[]},{...open,runtime:{anything:true}},
    {...open,command:'audio',positionals:['record']},{...open,command:'close'},
    {...open,flags:{...open.flags,platform:'ios'}},{...open,flags:{...open.flags,udid:'ambient'}},
    {...open,flags:{...open.flags,macBundlePath:'/private/tmp/Other.app'}}]){
    const value=await rpc(params);assert.ok(value.error || value.result?.ok===false);denied.push(params.command);
  }
  const auth=await rpc(open,'0'.repeat(48));assert.ok(auth.error || auth.result?.ok===false);
  for(const path of ['/health','/upload','/human-control','/diagnostics','/rpc?extra=1']){
    const response:Response=await fetch(`http://127.0.0.1:${server.controller!.httpPort}${path}`);assert.equal(response.status,403);
  }
  assert.equal(requests.length,before);
  const transport=daemon.transport;
  const selected=await transport.open({bundleId:config.target.bundleId,canonicalBundlePath:config.target.bundlePath!},config.scope,session);
  assert.deepEqual(requireMacOwnedInstance(selected.applicationTarget),instance);
  const abort=new AbortController();const context:OperationContext={origin:'test',runId:config.scope.runId,attemptId:config.scope.attemptId,timeoutMs:5000,signal:abort.signal};
  await transport.capture(instance,context);
  if(config.mode==='valid' || config.mode==='cleanup-fail')await transport.press(instance,{x:10,y:20},context);
  else if(config.mode==='uncertain'){
    await assert.rejects(()=>transport.press(instance,{x:10,y:20},context));
    await assert.rejects(()=>transport.press(instance,{x:10,y:20},context));
  }else{
    const pressing=transport.press(instance,{x:10,y:20},context);await started;abort.abort();
    await assert.rejects(()=>pressing);await assert.rejects(()=>transport.press(instance,{x:10,y:20},context));
  }
  await assert.rejects(()=>daemon!.cleanup({...config.scope,leaseGeneration:config.scope.leaseGeneration+1},instance));
  const cleanup=await transport.release(config.scope,instance) as any;
  assert.equal(cleanup.commandsDrained,config.mode!=='cleanup-fail');assert.equal(cleanup.ownedHelperReaped,config.mode!=='cleanup-fail');assert.equal(cleanup.daemonStopped,true);assert.equal(cleanup.subjectTerminated,false);
  await assert.rejects(()=>fetch(`http://127.0.0.1:${server.controller!.httpPort}/rpc`));
  assert.deepEqual(requests.map(r=>r.action.kind),['acquire','snapshot','press']);
  assert.deepEqual(hostCalls,[]);
  process.stdout.write(JSON.stringify({mode:config.mode,requests:requests.map(r=>r.action.kind),denied:denied.length+6,cleanup,hostCalls,metadataCalls})+'\n');
}catch(error){
  if(config.mode==='startup-fail' || config.mode==='invalid-port'){
    assert.equal(error instanceof Error?error.message:'',config.mode==='startup-fail'?'synthetic-client-construction':'Private daemon did not start');
    assert.ok(server.controller?.httpPort);
    // Check before fixture cleanup: startup itself must have closed the created server.
    await assert.rejects(()=>fetch(`http://127.0.0.1:${server.controller!.httpPort}/rpc`));
    assert.deepEqual(hostCalls,[]);assert.equal(requests.length,0);
    process.stdout.write(JSON.stringify({mode:config.mode,requests:[],cleanup:{daemonStopped:true},hostCalls,metadataCalls})+'\n');
  }else{
  process.stderr.write(daemonLog.replace(/[a-f0-9]{48,64}/g,'[redacted]'));
  if(daemon)await daemon.cleanup(config.scope,null);
  else if(server.controller)await server.controller.shutdown();
  throw error;
  }
}
