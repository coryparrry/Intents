import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer,type IncomingMessage,type ServerResponse} from 'node:http';
import {mkdtemp,mkdir,realpath,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import type {AddressInfo} from 'node:net';
import {MacOwnedDaemon,type PrivateMacDaemonSDK} from '../src/macOwnedDaemon.js';
import type {MacOwnedSDKClient} from '../src/macOwnedSDKTransport.js';
import type {Scope,Target} from '../src/protocol.js';
import type {OperationContext} from 'e2e/engine';

// Deterministic in-process coverage: no SDK, Node fixture runtime, helper or GUI.
const scope:Scope={protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:1};
const session='intents-run-1';

type Options={httpPort?:number;drain?:boolean;shutdownFails?:boolean;respond?:(id:string,response:ServerResponse)=>void;
  stop?:(input:any)=>Promise<unknown>;open?:()=>Promise<void>;snapshot?:()=>Promise<void>};

async function harness(options:Options={}){
  const root=await realpath(await mkdtemp(join(tmpdir(),'intents-daemon-unit-')));
  const app=join(root,'Fixture.app');await mkdir(app);
  const directory=join(root,'state');
  const target:Target={id:'fixture-mac',platform:'macos',kind:'nativeMac',bundleId:'example.Fixture',bundlePath:app,loginSession:'synthetic'};
  const instance={bundleId:target.bundleId,canonicalBundlePath:app,pid:123,processStartIdentity:'100:0'};
  const server=createServer((request:IncomingMessage,response:ServerResponse)=>{
    let body='';request.on('data',chunk=>{body+=chunk;});
    request.on('end',()=>{const id=JSON.parse(body).id as string;
      if(options.respond)return options.respond(id,response);
      response.setHeader('content-type','application/json');response.end(JSON.stringify({jsonrpc:'2.0',id,result:{ok:true}}));});
  });
  await new Promise<void>(resolve=>server.listen(0,'127.0.0.1',resolve));
  const port=(server.address() as AddressInfo).port;
  const calls={shutdown:0,stop:0,drain:0};
  let admit:((request:unknown)=>boolean)|undefined,transport:((request:Record<string,unknown>)=>Promise<any>)|undefined;
  const client:MacOwnedSDKClient={
    apps:{open:async()=>{await options.open?.();return {session,appBundleId:target.bundleId,identifiers:{deviceId:target.id},applicationTarget:{...instance}};}},
    capture:{snapshot:async()=>{await options.snapshot?.();throw new Error('Synthetic snapshot unavailable');}},
    interactions:{press:async()=>{throw new Error('Synthetic press unavailable');}}};
  const api:PrivateMacDaemonSDK={
    startDaemonRuntime:async runtime=>{admit=runtime.intentsOwnedMac.admitRequest;
      return {httpPort:options.httpPort??port,token:'c'.repeat(48),
        drainOwnedRequests:async()=>{calls.drain++;return options.drain??true;},
        shutdown:async()=>{calls.shutdown++;server.close();if(options.shutdownFails)throw new Error('Synthetic shutdown failure');}};},
    createLocalAppleToolProvider:()=>({}),
    createAgentDeviceClient:(_config,dependencies)=>{transport=dependencies.transport;return client;}};
  const channel={reverse:async(method:string,input:any)=>{
    assert.equal(method,'mac.helper.stop');calls.stop++;
    return options.stop?await options.stop(input):{scope,applicationTarget:input.applicationTarget,commandsDrained:true,ownedHelperReaped:true};
  }} as unknown as Parameters<typeof MacOwnedDaemon.start>[6];
  const previous=process.env.AGENT_DEVICE_CLAIMS_DIR;
  process.env.AGENT_DEVICE_CLAIMS_DIR=join(directory,'claims');
  const start=()=>MacOwnedDaemon.start(api,directory,target,scope,'a'.repeat(64),'b'.repeat(64),channel);
  const dispose=async()=>{
    if(previous===undefined)delete process.env.AGENT_DEVICE_CLAIMS_DIR;else process.env.AGENT_DEVICE_CLAIMS_DIR=previous;
    server.close();await rm(root,{recursive:true,force:true});
  };
  const press=(extra:Record<string,unknown>={},positionals=['10','20'])=>({session,command:'press',positionals,
    flags:{stateDir:directory,session,platform:'macos',target:'desktop',udid:target.id,...extra},meta:{cwd:directory,sessionExplicit:true}});
  return {root,directory,target,instance,calls,start,dispose,press,admit:(value:unknown)=>admit!(value),send:(value:Record<string,unknown>)=>transport!(value)};
}
const context=(signal:AbortSignal):OperationContext=>({origin:'agent',runId:scope.runId,attemptId:scope.attemptId,timeoutMs:1000,signal});

test('admission accepts only exact scoped requests with canonical points and bounded timeouts',async()=>{
  const h=await harness();
  try{
    await h.start();
    assert.equal(h.admit(h.press()),true);
    assert.equal(h.admit(h.press({timeoutMs:60_000})),true);
    assert.equal(h.admit({...h.press(),session:'intents-other-1'}),false);
    assert.equal(h.admit({...h.press(),meta:{cwd:h.root,sessionExplicit:true}}),false);
    assert.equal(h.admit(h.press({udid:'other-mac'})),false);
    assert.equal(h.admit(h.press({stateDir:h.root})),false);
    assert.equal(h.admit(h.press({platform:'ios'})),false);
    assert.equal(h.admit(h.press({snapshotRaw:true})),false);
    assert.equal(h.admit(h.press({},['1.0','20'])),false);
    assert.equal(h.admit(h.press({},['10'])),false);
    assert.equal(h.admit(h.press({},['2000000','20'])),false);
    assert.equal(h.admit(h.press({timeoutMs:60_001})),false);
    assert.equal(h.admit(h.press({timeoutMs:0})),false);
    assert.equal(h.admit({...h.press(),input:'secret'}),false);
    assert.equal(h.admit({...h.press(),runtime:{extra:true}}),false);
  }finally{await h.dispose();}
});

test('send returns matching results and rejects unadmitted, oversized or mismatched responses',async()=>{
  let mode='valid';
  const h=await harness({respond:(id,response)=>{
    response.setHeader('content-type','application/json');
    if(mode==='oversized')return response.end(JSON.stringify({jsonrpc:'2.0',id,result:{padding:'x'.repeat(1_100_000)}}));
    if(mode==='mismatched')return response.end(JSON.stringify({jsonrpc:'2.0',id:'other',result:{ok:true}}));
    if(mode==='error')return response.end(JSON.stringify({jsonrpc:'2.0',id,error:{message:'Synthetic daemon refusal'}}));
    response.end(JSON.stringify({jsonrpc:'2.0',id,result:{ok:true}}));
  }});
  try{
    await h.start();
    assert.deepEqual(await h.send(h.press()),{ok:true});
    await assert.rejects(h.send(h.press({udid:'other-mac'})),/Unsupported or unscoped/);
    mode='oversized';await assert.rejects(h.send(h.press()),/exceeds bound/);
    mode='mismatched';await assert.rejects(h.send(h.press()));
    mode='error';await assert.rejects(h.send(h.press()),/Synthetic daemon refusal/);
  }finally{await h.dispose();}
});

test('operations are serialized and abort stops the native helper exactly once',async()=>{
  let releaseOpen!:()=>void,releaseSnapshot!:()=>void,snapshotStarted!:()=>void;
  const openGate=new Promise<void>(resolve=>{releaseOpen=resolve;}),snapshotGate=new Promise<void>(resolve=>{releaseSnapshot=resolve;});
  const started=new Promise<void>(resolve=>{snapshotStarted=resolve;});
  const h=await harness({open:()=>openGate,snapshot:()=>{snapshotStarted();return snapshotGate;}});
  try{
    const daemon=await h.start();
    const selection={bundleId:h.target.bundleId,canonicalBundlePath:h.target.bundlePath!};
    const first=daemon.transport.open(selection,scope,session);
    await assert.rejects(daemon.transport.open(selection,scope,session),/Private Mac operation unavailable/);
    releaseOpen();
    assert.deepEqual((await first).applicationTarget,h.instance);
    const controller=new AbortController();
    void daemon.transport.capture(h.instance,context(controller.signal)).catch(()=>{});
    await started;
    controller.abort();controller.abort();
    await assert.rejects(daemon.transport.capture(h.instance,context(new AbortController().signal)),/Private Mac operation unavailable/);
    await new Promise(resolve=>setImmediate(resolve));
    assert.equal(h.calls.stop,1);
    releaseSnapshot();
    await daemon.cleanup(scope,null);
    assert.equal(h.calls.stop,1);
  }finally{await h.dispose();}
});

test('cleanup reports no proof for malformed or foreign-scope native replies but still stops the drained daemon',async()=>{
  for(const reply of [{},{scope:{...scope,runId:'other'},applicationTarget:null,commandsDrained:true,ownedHelperReaped:true}]){
    const h=await harness({stop:async()=>reply});
    try{
      const daemon=await h.start();
      await assert.rejects(daemon.cleanup({...scope,runId:'other'},null),/Different cleanup scope/);
      const first=daemon.cleanup(scope,null);
      assert.equal(daemon.cleanup(scope,null),first);
      const result=await first as Record<string,unknown>;
      assert.equal(result.commandsDrained,false);assert.equal(result.ownedHelperReaped,false);
      assert.equal(result.daemonStopped,true);assert.equal(result.subjectTerminated,false);
      assert.equal(h.calls.shutdown,1);assert.equal(h.calls.stop,1);
    }finally{await h.dispose();}
  }
});

test('cleanup keeps the daemon running and reports no drain when local requests fail to drain',async()=>{
  const h=await harness({drain:false});
  try{
    const daemon=await h.start();
    const result=await daemon.cleanup(scope,null) as Record<string,unknown>;
    assert.equal(result.commandsDrained,false);assert.equal(result.ownedHelperReaped,true);assert.equal(result.daemonStopped,false);
    assert.equal(h.calls.drain,1);assert.equal(h.calls.shutdown,0);
  }finally{await h.dispose();}
});

test('complete native and local proof reports a fully drained cleanup',async()=>{
  const h=await harness();
  try{
    const daemon=await h.start();
    assert.deepEqual(await daemon.cleanup(scope,null),{scope,applicationTarget:null,commandsDrained:true,ownedHelperReaped:true,daemonStopped:true,subjectTerminated:false});
    await assert.rejects(daemon.transport.open({bundleId:h.target.bundleId,canonicalBundlePath:h.target.bundlePath!},scope,session),/Private Mac operation unavailable/);
  }finally{await h.dispose();}
});

test('startup failure closes the started listener and aggregates a shutdown failure',async()=>{
  const invalid=await harness({httpPort:0});
  try{
    await assert.rejects(invalid.start(),/Private daemon did not start/);
    assert.equal(invalid.calls.shutdown,1);
  }finally{await invalid.dispose();}
  const failing=await harness({httpPort:0,shutdownFails:true});
  try{
    await assert.rejects(failing.start(),(error:unknown)=>error instanceof AggregateError &&
      error.errors.length===2 && /did not start/.test(error.errors[0].message) && /shutdown failure/.test(error.errors[1].message));
    assert.equal(failing.calls.shutdown,1);
  }finally{await failing.dispose();}
});

test('startup requires state-local claims and fresh canonical state',async()=>{
  const h=await harness();
  try{
    process.env.AGENT_DEVICE_CLAIMS_DIR=join(h.root,'claims');
    await assert.rejects(h.start(),/state-local private claim/);
    process.env.AGENT_DEVICE_CLAIMS_DIR=join(h.directory,'claims');
    await mkdir(h.directory);await writeFile(join(h.directory,'stale'),'');
    await assert.rejects(h.start());
    assert.equal(h.calls.shutdown,0);
  }finally{await h.dispose();}
});
