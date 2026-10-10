import test from 'node:test';
import assert from 'node:assert/strict';
import {MacOwnedHelperProvider,privateScrollHelperSHA256,type MacNativeHelperRequest} from '../src/macOwnedHelperProvider.js';
import type {Scope,Target} from '../src/protocol.js';

const scope:Scope={protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:3};
const target:Target={id:'desktop',platform:'macos',kind:'nativeMac',bundleId:'example.Fixture',
  bundlePath:'/private/tmp/Fixture.app',loginSession:'synthetic-session'};
const instance={bundleId:target.bundleId,canonicalBundlePath:target.bundlePath!,pid:42,processStartIdentity:'100:0'};
const helperSHA256='a'.repeat(64);
const open=['app','open','--bundle-id',target.bundleId,'--bundle-path',target.bundlePath!];
const context=['--target-bundle-path',instance.canonicalBundlePath,'--target-pid','42','--target-process-start','100:0',
  '--bundle-id',instance.bundleId,'--surface','frontmost-app'];
const snapshot=['snapshot',...context];
const press=['press','--x','1','--y','-2',...context];
function reply(request:MacNativeHelperRequest){
  return {requestId:request.requestId,scope:request.scope,helperABI:'startup-gate-v1',helperSHA256,
    ownedIdentity:{pid:99,startIdentity:'200:0'},startupAcknowledged:true,directChildReaped:true,pipesDrained:true,
    callbacksDrained:true,logsTruncated:false,exitCode:0,stderr:'',
    stdout:JSON.stringify({ok:true,data:request.action.kind==='acquire'?instance:
      request.action.kind==='press'?{applicationTarget:instance,x:request.action.x,y:request.action.y,
        disposition:'submittedUnconfirmed',releaseSubmitted:true}:{applicationTarget:instance}})};
}

test('native provider translates only exact owned actions and accepts request-bound drain proof',async()=>{
  const requests:MacNativeHelperRequest[]=[];
  const provider=new MacOwnedHelperProvider(target,scope,helperSHA256,async request=>{requests.push(request);return reply(request);});
  await provider.run(open,{allowFailure:true,timeoutMs:30_000,kill:{signal:'SIGTERM',graceMs:1000}});
  await provider.overrides().macosHelper.run(snapshot);
  await provider.run(press);
  assert.deepEqual(requests.map(request=>request.action.kind),['acquire','snapshot','press']);
  assert.equal(new Set(requests.map(request=>request.requestId)).size,3);
  assert.equal(Object.isFrozen(requests[0]),true);
  assert.equal(Object.isFrozen(requests[0]!.scope),true);
  assert.deepEqual(requests[2]!.action,{kind:'press',instance,x:1,y:-2});
  assert.equal(provider.inFlight,false);
});
test('scroll is denied for old helper and enabled only for the exact separately compiled candidate',async()=>{
  let oldCalls=0;
  const old=new MacOwnedHelperProvider(target,scope,helperSHA256,async request=>{oldCalls++;return reply(request);});
  await old.run(open);assert.equal(old.supportsScroll,false);
  await assert.rejects(old.scroll(instance,{x:1,y:2,direction:'down'},{timeoutMs:1000,signal:new AbortController().signal}));assert.equal(oldCalls,1);
  const actions:MacNativeHelperRequest['action'][]=[];
  const candidate=new MacOwnedHelperProvider(target,scope,privateScrollHelperSHA256,async request=>{
    actions.push(request.action);
    return {...reply(request),helperSHA256:privateScrollHelperSHA256,stdout:JSON.stringify({ok:true,data:request.action.kind==='acquire'?instance:
      request.action.kind==='scroll'?{applicationTarget:instance,x:request.action.x,y:request.action.y,direction:request.action.direction,
        disposition:'submittedUnconfirmed'}:{applicationTarget:instance}})};
  });
  await candidate.run(open);assert.equal(candidate.supportsScroll,true);
  const receipt=await candidate.scroll(instance,{x:1,y:2,direction:'down'},{timeoutMs:1000,signal:new AbortController().signal});
  assert.deepEqual(receipt,{applicationTarget:instance,x:1,y:2,direction:'down',disposition:'submittedUnconfirmed'});
  assert.deepEqual(actions.map(action=>action.kind),['acquire','scroll']);
});
test('scroll receipt disagreement disables the provider and prevents retries',async()=>{
  let calls=0;
  const provider=new MacOwnedHelperProvider(target,scope,privateScrollHelperSHA256,async request=>{
    calls++;return {...reply(request),helperSHA256:privateScrollHelperSHA256,stdout:JSON.stringify({ok:true,data:request.action.kind==='acquire'?instance:
      {applicationTarget:instance,x:1,y:2,direction:'up',disposition:'submittedUnconfirmed'}})};
  });
  await provider.run(open);
  const request={x:1,y:2,direction:'down' as const},ctx={timeoutMs:1000,signal:new AbortController().signal};
  await assert.rejects(provider.scroll(instance,request,ctx));await assert.rejects(provider.scroll(instance,request,ctx));assert.equal(calls,2);
});

test('generic commands and every Mac host fallback are denied without native execution',async()=>{
  let calls=0;
  const provider=new MacOwnedHelperProvider(target,scope,helperSHA256,async request=>{calls++;return reply(request);});
  const overrides=provider.overrides();
  await assert.rejects(overrides.runCommand('open',['-b',target.bundleId]));
  for(const method of Object.values(overrides.macosHost))await assert.rejects(method());
  assert.equal(calls,0);
});

test('legacy commands, aliases, duplicate flags and process options fail before acquisition',async()=>{
  let calls=0;
  const provider=new MacOwnedHelperProvider(target,scope,helperSHA256,async request=>{calls++;return reply(request);});
  for(const args of [['app','quit'],['permission'],['audio-probe'],snapshot,
    [...open,'--bundle-id',target.bundleId],open.map(value=>value===target.bundlePath?'/private/tmp/Other.app':value)])
    await assert.rejects(provider.run(args));
  for(const options of [{cwd:'/tmp'},{env:{SECRET:'x'}},{stdin:'x'},{detached:true},
    {timeoutMs:0},{timeoutMs:60_001},{kill:{signal:'SIGKILL',graceMs:0}}])
    await assert.rejects(provider.run(open,options as never));
  assert.equal(calls,0);
  await provider.run(open);
  await assert.rejects(provider.run(open));
  assert.equal(calls,1);
});

test('owned action rejects changed PID, path, surface, numeric spellings and unsupported input schedules',async()=>{
  let calls=0;
  const provider=new MacOwnedHelperProvider(target,scope,helperSHA256,async request=>{calls++;return reply(request);});
  await provider.run(open);
  for(const args of [snapshot.map(value=>value==='42'?'43':value),snapshot.map(value=>value==='42'?'042':value),
    snapshot.map(value=>value===instance.canonicalBundlePath?'/private/tmp/Other.app':value),
    snapshot.map(value=>value==='frontmost-app'?'desktop':value),[...press,'--hold-ms','60'],
    press.map((value,index)=>index===2?'1.0':value),press.map((value,index)=>index===2?'NaN':value)])
    await assert.rejects(provider.run(args));
  assert.equal(calls,1);
  await provider.run(snapshot);
  assert.equal(calls,2);
});

test('foreign scope, old helper ABI, replayed IDs and every missing cleanup fact disable the provider',async()=>{
  const mutations=[(value:ReturnType<typeof reply>)=>{value.scope={...scope,leaseGeneration:4};},
    (value:ReturnType<typeof reply>)=>{value.helperABI='legacy';},
    (value:ReturnType<typeof reply>)=>{value.helperSHA256='b'.repeat(64);},
    (value:ReturnType<typeof reply>)=>{value.requestId='aaaaaaaa-1234-1234-1234-123456789abc';},
    ...['startupAcknowledged','directChildReaped','pipesDrained','callbacksDrained'].map(key=>(value:ReturnType<typeof reply>)=>{(value as unknown as Record<string,unknown>)[key]=false;}),
    (value:ReturnType<typeof reply>)=>{value.logsTruncated=true;},
    (value:ReturnType<typeof reply>)=>{value.ownedIdentity.startIdentity='0:0';}];
  for(const mutate of mutations){
    let calls=0;
    const provider=new MacOwnedHelperProvider(target,scope,helperSHA256,async request=>{
      calls++;const value=reply(request);if(calls===2)mutate(value);return value;
    });
    await provider.run(open);
    await assert.rejects(provider.run(snapshot));
    await assert.rejects(provider.run(snapshot));
    assert.equal(calls,2);
  }
});

test('transport failure after acquisition permanently blocks otherwise valid commands',async()=>{
    let calls=0;
    const provider=new MacOwnedHelperProvider(target,scope,helperSHA256,async request=>{
      calls++;
      if(calls===2)throw new Error('Outcome unknown');
      return reply(request);
    });
    await provider.run(open);
    await assert.rejects(provider.run(snapshot));
    await assert.rejects(provider.run(snapshot));
    assert.equal(calls,2);
});

test('a different acquired application path cannot become the owned instance',async()=>{
  let calls=0;
  const provider=new MacOwnedHelperProvider(target,scope,helperSHA256,async request=>{
    calls++;const value=reply(request);
    value.stdout=JSON.stringify({ok:true,data:{...instance,pid:43,canonicalBundlePath:'/private/tmp/Other.app'}});
    return value;
  });
  await assert.rejects(provider.run(open));
  await assert.rejects(provider.run(snapshot));
  assert.equal(calls,1);
});

test('uncertain or mismatched press receipts cannot submit another input',async()=>{
  for(const mode of ['exit','json','ok','missing','release','disposition','identity','point']){
    let calls=0;
    const provider=new MacOwnedHelperProvider(target,scope,helperSHA256,async request=>{
      calls++;const value=reply(request);
      if(calls!==2)return value;
      if(mode==='exit')value.exitCode=1;
      if(mode==='json')value.stdout='malformed';
      else{
        const envelope=JSON.parse(value.stdout);
        if(mode==='ok')envelope.ok=false;
        if(mode==='missing')delete envelope.data.releaseSubmitted;
        if(mode==='release')envelope.data.releaseSubmitted=false;
        if(mode==='disposition')envelope.data.disposition='confirmed';
        if(mode==='identity')envelope.data.applicationTarget={...instance,pid:43};
        if(mode==='point')envelope.data.x=2;
        value.stdout=JSON.stringify(envelope);
      }
      return value;
    });
    await provider.run(open);
    await assert.rejects(provider.run(press));
    await assert.rejects(provider.run(press));
    assert.equal(calls,2);
  }
});

test('abort and release retain an active command until its native promise settles',async()=>{
  for(const mode of ['abort','disable','both']){
  let finish!:(value:unknown)=>void,request!:MacNativeHelperRequest;
  const controller=new AbortController();
  const provider=new MacOwnedHelperProvider(target,scope,helperSHA256,async value=>{request=value;return new Promise(resolve=>{finish=resolve;});});
  const pending=provider.run(open,{signal:controller.signal});
  assert.equal(provider.inFlight,true);
  if(mode!=='disable')controller.abort();
  if(mode!=='abort')provider.disable();
  await assert.rejects(provider.run(open));assert.equal(provider.inFlight,true);
  finish(reply(request));await assert.rejects(pending);
  assert.equal(provider.inFlight,false);await assert.rejects(provider.run(snapshot));
  }
});

test('expired reply after acquisition disables later commands',async()=>{
    let calls=0;
    const provider=new MacOwnedHelperProvider(target,scope,helperSHA256,async request=>{
      calls++;
      const value=reply(request);
      if(calls===2)await new Promise(resolve=>setTimeout(resolve,25));
      return value;
    });
    await provider.run(open);
    await assert.rejects(provider.run(snapshot,{timeoutMs:10}));
    await assert.rejects(provider.run(snapshot));
    assert.equal(calls,2);
});

test('valid JSON at the output bound passes and one extra byte disables further commands',async()=>{
  let calls=0;
  const output=(length:number)=>{
    const base=JSON.stringify({ok:true,data:{applicationTarget:instance},padding:''});
    const value=JSON.stringify({ok:true,data:{applicationTarget:instance},padding:'x'.repeat(length-Buffer.byteLength(base))});
    assert.equal(Buffer.byteLength(value),length);
    JSON.parse(value);
    return value;
  };
  const provider=new MacOwnedHelperProvider(target,scope,helperSHA256,async request=>{
    calls++;const value=reply(request);
    if(calls>1)value.stdout=output(calls===2?1_048_576:1_048_577);
    return value;
  });
  await provider.run(open);
  assert.equal(Buffer.byteLength((await provider.run(snapshot)).stdout),1_048_576);
  await assert.rejects(provider.run(snapshot));
  await assert.rejects(provider.run(snapshot));
  assert.equal(calls,3);
});

test('ordinary fill requires the pinned v2 helper and returns value-free exact replacement proof',async()=>{
 const {privateFillHelperSHA256}=await import('../src/macOwnedHelperProvider.js');let calls=0;
 const old=new MacOwnedHelperProvider(target,scope,helperSHA256,async request=>{calls++;return reply(request);});
 await old.run(open);assert.equal(old.supportsOrdinaryFill,false);
 await assert.rejects(old.ordinaryFill(instance,{x:1,y:2,value:'public'},{timeoutMs:1000,signal:new AbortController().signal}));assert.equal(calls,1);
 const actions:MacNativeHelperRequest['action'][]=[];
 const provider=new MacOwnedHelperProvider(target,scope,privateFillHelperSHA256,async request=>{
  actions.push(request.action);return {...reply(request),helperABI:'startup-gate-v2-private-input',helperSHA256:privateFillHelperSHA256,
   stdout:JSON.stringify({ok:true,data:request.action.kind==='acquire'?instance:request.action.kind==='ordinaryFill'?
    {applicationTarget:instance,x:request.action.x,y:request.action.y,disposition:'replacementVerified'}:{applicationTarget:instance}})};
 });
 await provider.run(open);assert.equal(provider.supportsOrdinaryFill,true);assert.equal(provider.supportsScroll,true);
 const receipt=await provider.ordinaryFill(instance,{x:1,y:2,value:'public-e\u0301'},{timeoutMs:1000,signal:new AbortController().signal});
 assert.deepEqual(actions[1],{kind:'ordinaryFill',instance,x:1,y:2,value:'public-e\u0301'});
 assert.deepEqual(receipt,{applicationTarget:instance,x:1,y:2,disposition:'replacementVerified'});
 assert.equal(JSON.stringify(receipt).includes('public-e'),false);
});
test('ordinary fill invalid literal and point are rejected before dispatch and wrong receipt never retries',async()=>{
 const {privateFillHelperSHA256}=await import('../src/macOwnedHelperProvider.js');let calls=0;
 const provider=new MacOwnedHelperProvider(target,scope,privateFillHelperSHA256,async request=>{
  calls++;return {...reply(request),helperABI:'startup-gate-v2-private-input',helperSHA256:privateFillHelperSHA256,
   stdout:JSON.stringify({ok:true,data:request.action.kind==='acquire'?instance:{applicationTarget:instance,x:999,y:2,disposition:'replacementVerified'}})};
 });
 await provider.run(open);const ctx={timeoutMs:1000,signal:new AbortController().signal};
 for(const value of ['x\0','\ud800',String('x').repeat(16385)])await assert.rejects(provider.ordinaryFill(instance,{x:1,y:2,value},ctx));
 await assert.rejects(provider.ordinaryFill(instance,{x:Infinity,y:2,value:'public'},ctx));assert.equal(calls,1);
 await assert.rejects(provider.ordinaryFill(instance,{x:1,y:2,value:'public'},ctx));
 await assert.rejects(provider.ordinaryFill(instance,{x:1,y:2,value:'public'},ctx));assert.equal(calls,2);
});
test('fill helper ABI cannot be downgraded to the tap startup contract',async()=>{
 const {privateFillHelperSHA256}=await import('../src/macOwnedHelperProvider.js');
 const provider=new MacOwnedHelperProvider(target,scope,privateFillHelperSHA256,async request=>({...reply(request),helperSHA256:privateFillHelperSHA256}));
 await assert.rejects(provider.run(open));
});
