import test from 'node:test';import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';import {mkdtemp,mkdir,rm,readFile,readdir,writeFile} from 'node:fs/promises';
import {join} from 'node:path';import {pathToFileURL} from 'node:url';
import {segmentPayloadDigest} from '../src/payloadDigest.js';
import {privateFillHelperSHA256} from '../src/macOwnedHelperProvider.js';

const v2Unit=process.env.INTENTS_PRIVATE_V2_DAEMON_UNIT;
const fillUnit=v2Unit??process.env.INTENTS_PRIVATE_FILL_DAEMON_UNIT;
const unit=fillUnit??process.env.INTENTS_PRIVATE_PROGRAM_DAEMON_UNIT;
const helperSHA256=fillUnit?privateFillHelperSHA256:'91dc95a1bf0715746dfc6cf4790a9714f60565aab8e025ce0acc9edafb2ce4a4';
const helperABI=fillUnit?'startup-gate-v2-private-input':'startup-gate-v1';
const publicLiteral='public-e\u0301🙂';
const modes=fillUnit?['fill-valid','fill-denied','fill-uncertain','scroll-denied','invalid-literal','tap-valid','helper-downgrade']:['valid','worker-denied','tap-denied','uncertain','unsupported','eof-worker'];
for(const mode of modes)test(`sealed private program entry with real SDK/e2e and synthetic native channel: ${mode}`,{skip:!unit,timeout:30000},async()=>{
 const root=await mkdtemp('/private/tmp/intents-daemon-program-entry-'),state=join(root,'state'),app=join(root,'Fixture.app');await mkdir(state);await mkdir(app);
 const filling=!!fillUnit && mode!=='tap-valid';
 const scope={protocolVersion:1,runId:'entry-run',attemptId:'entry-attempt',segmentId:'entry-segment',leaseGeneration:1};
 const target={id:'host-macos-local',platform:'macos',kind:'nativeMac',bundleId:'example.Fixture',bundlePath:app,loginSession:'synthetic'};
 const instance={bundleId:target.bundleId,canonicalBundlePath:app,pid:123,processStartIdentity:'100:0'},authentication='b'.repeat(64);
 const pending=new Map<string,{resolve:(value:unknown)=>void;reject:(error:Error)=>void}>();
 const child=spawn(join(unit!,'node'),['--import',pathToFileURL(new URL('./fixtures/macDaemonEntryGuard.js',import.meta.url).pathname).href,
  join(unit!,'sidecar/src/macOwnedDaemonMain.js'),'--state-dir',state],
  {env:{PATH:'/usr/bin:/bin',AGENT_DEVICE_CLAIMS_DIR:join(state,'owned-mac/claims'),INTENTS_SYNTHETIC_PROGRAM_WORKER:'1'},stdio:['pipe','pipe','pipe']});
 let frame='',stderr='',ordinal=0,error:unknown,presses=0,taps=0,activations=0,captures=0,fills=0,scrolls=0,fillPolicies=0,scrollPolicies=0;const workers:number[]=[];
 const send=(value:unknown)=>{if(!child.stdin.writableEnded)child.stdin.write(JSON.stringify(value)+'\n');};
 const request=(method:string,params:unknown)=>new Promise<unknown>((resolve,reject)=>{
  const id='parent-'+(++ordinal);pending.set(id,{resolve,reject});send({jsonrpc:'2.0',id,method,params});
 });
 child.stderr.on('data',bytes=>{stderr=(stderr+bytes).slice(-65536);});
 child.stdout.on('data',bytes=>{
  try{
   frame+=bytes.toString('utf8');assert.ok(Buffer.byteLength(frame)<=1048576);
   while(frame.includes('\n')){
    const index=frame.indexOf('\n'),message=JSON.parse(frame.slice(0,index));frame=frame.slice(index+1);
    if(!message.method){const call=pending.get(message.id);assert.ok(call);pending.delete(message.id);message.error?call.reject(new Error(message.error.message)):call.resolve(message.result);continue;}
    const input=message.params;let result:unknown;
    if(message.method==='policy.reviewAction'){
     const {action,effect,target:activationTarget,controllerNode,...selected}=input;assert.deepEqual(selected,scope);
     if(effect==='activate'){assert.deepEqual(activationTarget,target);activations++;result={allowed:true};}
     else if(action.kind==='fill'){assert.deepEqual(action,{kind:'fill',value:publicLiteral,sensitive:false});fillPolicies++;result={allowed:mode!=='fill-denied'};}
     else if(action.kind==='swipe'){assert.deepEqual(action,{kind:'swipe',direction:'down'});scrollPolicies++;result={allowed:mode!=='scroll-denied'};}
     else{assert.deepEqual(action,{kind:'tap'});if(controllerNode)assert.match(controllerNode,/^node-/);taps++;result={allowed:mode!=='tap-denied'};}
    }else if(message.method==='ui.workerStarted'){
     const {pid,...selected}=input;assert.deepEqual(selected,scope);assert.ok(Number.isInteger(pid)&&pid>0);assert.doesNotThrow(()=>process.kill(pid,0));workers.push(pid);
     if(mode==='eof-worker'){child.stdin.end();continue;}result={allowed:mode!=='worker-denied'};
    }else if(message.method==='mac.helper.stop'){
     assert.equal(input.authentication,authentication);assert.deepEqual(input.scope,scope);
     result={scope,applicationTarget:input.applicationTarget,commandsDrained:true,ownedHelperReaped:true};
    }else{
     assert.equal(message.method,'mac.helper.run');assert.equal(input.authentication,authentication);const native=input.request;
     assert.deepEqual(native.scope,scope);assert.deepEqual(native.selection,{bundleId:target.bundleId,canonicalBundlePath:app});
     let data:unknown=instance;
     if(native.action.kind==='snapshot'){
      captures++;data={applicationTarget:instance,surface:'frontmost-app',backend:'macos-helper',truncated:false,
       nodes:filling?[
        {index:0,ref:'@e1',identifier:'field',role:'AXTextField',depth:0,enabled:true,editable:true,secure:false,hittable:true,visibleToUser:true,rect:{x:0,y:0,width:100,height:50}},
        {index:1,ref:'@e2',role:'AXScrollArea',depth:0,enabled:true,secure:false,hittable:true,visibleToUser:true,rect:{x:100,y:100,width:200,height:200}},
        {index:2,ref:'@e3',identifier:'status',label:fills&&scrolls?'Done':'Ready',role:'AXStaticText',depth:0,enabled:true,secure:false,hittable:true,visibleToUser:true,rect:{x:0,y:300,width:100,height:50}}
       ]:[{index:0,ref:'@e1',identifier:presses?'done':'open',label:presses?'Done':'Open',role:'button',depth:0,enabled:true,hittable:true,visibleToUser:true,rect:{x:0,y:0,width:100,height:50}}]};
     }
     if(native.action.kind==='press'){
      presses++;assert.equal(native.action.x,50);assert.equal(native.action.y,25);
      data={applicationTarget:instance,x:50,y:25,disposition:'submittedUnconfirmed',releaseSubmitted:mode!=='uncertain'};
     }
     if(native.action.kind==='ordinaryFill'){
      fills++;assert.equal(native.action.value,publicLiteral);assert.equal(native.action.x,50);assert.equal(native.action.y,25);
      data={applicationTarget:instance,x:50,y:25,disposition:mode==='fill-uncertain'?'submittedUnconfirmed':'replacementVerified'};
     }
     if(native.action.kind==='scroll'){
      scrolls++;assert.equal(native.action.direction,'down');assert.equal(native.action.x,200);assert.equal(native.action.y,200);
      data={applicationTarget:instance,x:200,y:200,direction:'down',disposition:'submittedUnconfirmed'};
     }
     result={requestId:native.requestId,scope,helperABI,helperSHA256,ownedIdentity:{pid:456,startIdentity:'200:0'},
      startupAcknowledged:true,directChildReaped:true,pipesDrained:true,callbacksDrained:true,logsTruncated:false,exitCode:0,stderr:'',stdout:JSON.stringify({ok:true,data})};
    }
    send({jsonrpc:'2.0',id:message.id,result});
   }
  }catch(failure){error=failure;for(const call of pending.values())call.reject(failure as Error);pending.clear();child.kill();}
 });
 const completion=new Promise<number|null>((resolve,reject)=>{child.once('error',reject);child.once('close',code=>{
  for(const call of pending.values())call.reject(new Error('Private program child closed'));pending.clear();resolve(code);
 });});
 const deadline=setTimeout(()=>child.kill('SIGKILL'),25000);
 let passed=false;
 try{
  if(mode==='helper-downgrade'){
   await assert.rejects(request('hello',{scope,target,authentication,helperSHA256:'91dc95a1bf0715746dfc6cf4790a9714f60565aab8e025ce0acc9edafb2ce4a4'}));
   assert.equal((await request('shutdown',{protocolVersion:1}) as {resourcesReleased:boolean}).resourcesReleased,true);child.stdin.end();
   assert.equal(await completion,0,stderr);assert.equal(error,undefined);assert.equal(frame,'');assert.equal(activations,0);assert.equal(captures,0);assert.deepEqual(workers,[]);
   const line=stderr.split('\n').find(value=>value.startsWith('SYNTHETIC_HOST_GUARD '));assert.ok(line,stderr);
   assert.deepEqual(JSON.parse(line.slice('SYNTHETIC_HOST_GUARD '.length)),{hostCalls:[],metadataCalls:[],ownedWorkerCalls:[]});passed=true;return;
  }
  await request('hello',{scope,target,authentication,helperSHA256});
  const acquired=await request('ui.acquire',{scope,programMode:true}) as {applicationTarget:unknown};assert.deepEqual(acquired.applicationTarget,instance);
  const bindingID=v2Unit?'10':'text',outputID=v2Unit?'__proto__':'read';
  const bindings=filling?Object.fromEntries([[bindingID,mode==='invalid-literal'?'invalid\0':publicLiteral],...(v2Unit?[['2','unused public binding']]:[])]):{};
  const body={scope,operationId:'program-operation',...(v2Unit?{digestVersion:2}:{}),phase:'subject',bindings,timeoutMs:15000,
   operations:filling?[{id:'fill',kind:'fillBinding',locator:{kind:'role',value:'textbox'},binding:bindingID},
    {id:'scroll',kind:'scroll',direction:'down'}, {id:outputID,kind:'observeProperty',locator:{kind:'testId',value:'status'},property:'text'}]:mode==='unsupported'?[{id:'tap',kind:'tap',locator:{kind:'testId',value:'open'}},{id:'scroll',kind:'scroll',direction:'down'}]:
    [{id:'tap',kind:'tap',locator:{kind:'testId',value:'open'}},{id:outputID,kind:'observeProperty',locator:{kind:'testId',value:'done'},property:'text'}]};
  const payload={...body,payloadDigest:segmentPayloadDigest(body)};
  if(['valid','tap-valid','fill-valid'].includes(mode)){
   const result=await request('ui.runSegment',payload) as {applicationTarget:unknown;receipt:{complete:boolean;outputs:Record<string,unknown>}};
   assert.deepEqual(result.applicationTarget,instance);assert.equal(result.receipt.complete,true);assert.ok(result.receipt.outputs[outputID]);assert.equal(Object.hasOwn(result.receipt.outputs,outputID),true);
   assert.equal(JSON.stringify(result).includes(publicLiteral),false);
   if(mode==='fill-valid'){
    const proof=result.receipt.outputs[outputID] as {nodes:{identifier?:string;label?:string}[]};
    assert.equal(proof.nodes.find(node=>node.identifier==='status')?.label,'Done');
    assert.deepEqual(await request('ui.runSegment',payload),result);
   }
  }else await assert.rejects(request('ui.runSegment',payload));
  if(mode!=='eof-worker'){
   const released=await request('shutdown',{protocolVersion:1}) as {resourcesReleased:boolean};assert.equal(released.resourcesReleased,true);child.stdin.end();
  }
  assert.equal(await completion,mode==='eof-worker'?1:0,stderr);assert.equal(error,undefined);assert.equal(frame,'');
  assert.equal(activations,1);assert.equal(presses,['valid','tap-valid','uncertain'].includes(mode)?1:0);
  assert.equal(taps,['valid','tap-valid','uncertain','tap-denied'].includes(mode)?1:0);
  assert.equal(fills,['fill-valid','fill-uncertain','scroll-denied'].includes(mode)?1:0);
  assert.equal(scrolls,mode==='fill-valid'?1:0);assert.equal(fillPolicies,['fill-valid','fill-denied','fill-uncertain','scroll-denied'].includes(mode)?1:0);
  assert.equal(scrollPolicies,['fill-valid','scroll-denied'].includes(mode)?1:0);
  assert.equal(workers.length,['unsupported','invalid-literal'].includes(mode)?0:1);if(['worker-denied','unsupported','invalid-literal','eof-worker'].includes(mode))assert.equal(captures,0);
  for(const pid of workers)assert.throws(()=>process.kill(pid,0),{code:'ESRCH'});
  const guardLine=stderr.split('\n').find(line=>line.startsWith('SYNTHETIC_HOST_GUARD '));assert.ok(guardLine,stderr);
  const guard=JSON.parse(guardLine.slice('SYNTHETIC_HOST_GUARD '.length));assert.deepEqual(guard.hostCalls,[]);assert.deepEqual(guard.ownedWorkerCalls,workers);
  passed=true;
 }catch(failure){
  let log='';
  for(const name of await readdir(join(state,'mac-programs/runs')).catch(()=>[]))if(/^[a-f0-9]{64}$/.test(name))
   log+=await readFile(join(state,'mac-programs/runs',name,'worker.log'),'utf8').catch(()=> 'Worker log unavailable');
  await writeFile(join(root,'test-diagnostics.json'),JSON.stringify({mode,activations,taps,captures,presses,fills,scrolls,fillPolicies,scrollPolicies,workers,stderr,workerLog:log},null,2));
  process.stderr.write(`SYNTHETIC_PROGRAM_FAILURE ${mode} preserved ${root}\n${log.slice(-12000)}\n`);
  throw failure;
 }finally{clearTimeout(deadline);if(child.exitCode===null && child.signalCode===null)child.kill();await completion.catch(()=>{});if(passed)await rm(root,{recursive:true,force:true});}
});
