import {test} from 'node:test';import assert from 'node:assert/strict';import {mkdtemp,mkdir,readFile,rm} from 'node:fs/promises';import {join} from 'node:path';import {tmpdir} from 'node:os';
import {runWorker,payloadDigest} from '../src/workerRunner.js';import type {UIBackend} from '../src/deviceSession.js';import type {Segment} from '../src/segment.js';
import {EngineError} from 'e2e/engine';
test('real pinned e2e StepExecutor invokes scoped controller and grammar actions without a model account',async()=>{
 let actions=0,calls=0;const backend:UIBackend={snapshot:async()=>({truncated:false,nodes:[{index:1,ref:'@e1',identifier:actions?'done':'open',role:'button',label:actions?'Done':'Open',hittable:true,enabled:true,visibleToUser:true,rect:{x:0,y:0,width:100,height:50}}],refsGeneration:7,identifiers:{udid:'exact'},appBundleId:'com.example.App'}),
  perform:async(ref,_action,_context,nodeId)=>{assert.equal(ref,'@e1~s7');assert.ok(nodeId?.startsWith('node-'));actions++;},release:async()=>({released:false,reason:'SDK contract fixture; no hardware claim'})};
 const segment:Segment={scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'goal',leaseGeneration:1},operationId:'goal-op',payloadDigest:'a'.repeat(64),phase:'setup',bindings:{},timeoutMs:50000,
  operations:[{id:'goal',kind:'navigateGoal',goal:{id:'goal',instruction:'Open the test endpoint',endpoint:{kind:'testId',value:'done'},maximumCalls:12,maximumActions:30}}]};
 const {payloadDigest:ignored,...body}=segment;segment.payloadDigest=payloadDigest(body);
 await runWorker(backend,{id:'exact',platform:'ios',kind:'simulator',bundleId:'com.example.App',bundlePath:null,loginSession:null},segment,
  await mkdtemp(join(tmpdir(),'intents-controller-contract-')),new AbortController().signal,async request=>{
   calls++;assert.equal(request.goalId,'goal');assert.ok(request.verbs.includes('tap'));
   return actions?{kind:'finish'}:{kind:'tap',node:request.nodes.find(n=>n.name==='Open')!.id};
  });
 assert.equal(actions,1);assert.equal(calls,2);
});
test('real pinned e2e CLI routes actions through adapter and broker',async()=>{
 let calls=0,actionBudget=0;const backend:UIBackend={snapshot:async()=>({truncated:false,nodes:[{index:1,ref:'@e1',identifier:'done',role:'button',label:'Done',rect:{x:0,y:0,width:100,height:50}}],
  refsGeneration:7,identifiers:{udid:'exact'},appBundleId:'com.example.App'}),perform:async(ref,_action,context)=>{assert.equal(ref,'@e1~s7');calls++;actionBudget=context.timeoutMs;},release:async()=>({released:false,reason:'not hardware'})};
 const segment:Segment={scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'s',leaseGeneration:1},operationId:'op',payloadDigest:'a'.repeat(64),
  phase:'setup',bindings:{},timeoutMs:50000,operations:[{id:'tap',kind:'tap',locator:{kind:'testId',value:'done'}},{id:'endpoint',kind:'assertEndpoint',locator:{kind:'testId',value:'done'}}]};
 const {payloadDigest:ignored,...body}=segment;segment.payloadDigest=payloadDigest(body);
 await runWorker(backend,{id:'exact',platform:'ios',kind:'simulator',bundleId:'com.example.App',bundlePath:null,loginSession:null},segment,
  await mkdtemp(join(tmpdir(),'intents-runner-contract-')),new AbortController().signal);assert.equal(calls,1);assert.ok(actionBudget>49000 && actionBudget<=50000);
});

test('broker preserves the remaining action budget instead of silently clipping it to 15 seconds',async()=>{
 const {createBroker,BrokerClient}=await import('../src/segmentBroker.js');
 let received=0;const backend:UIBackend={snapshot:async()=>({nodes:[],identifiers:{udid:"exact"}}),perform:async(_ref,_action,context)=>{received=context.timeoutMs;},release:async()=>({released:false,reason:'not hardware'})};
 const broker=await createBroker(backend);
 try{await new BrokerClient(broker.socket,broker.token).perform('@e1~s1',{kind:'tap'},
  {runId:'r',attemptId:'a',origin:'test',signal:new AbortController().signal,timeoutMs:50000});
  assert.ok(received>49000 && received<=50000);
 }finally{await broker.close();}
});

test('broker refuses already-aborted actions and removes queued actions on cancellation',async()=>{
 const {createBroker,BrokerClient}=await import('../src/segmentBroker.js');
 let started!:()=>void,unblock!:()=>void;const begun=new Promise<void>(r=>{started=r});const blocked=new Promise<void>(r=>{unblock=r});let actions=0;
 const backend:UIBackend={snapshot:async()=>{started();await blocked;return {nodes:[],identifiers:{udid:'exact'}};},
  perform:async()=>{actions++;},release:async()=>({released:false,reason:'not hardware'})};
 const broker=await createBroker(backend);const client=new BrokerClient(broker.socket,broker.token);
 const context=(signal:AbortSignal)=>({runId:'r',attemptId:'a',origin:'test' as const,signal,timeoutMs:50000});
 try{
  const aborted=new AbortController();aborted.abort();await assert.rejects(client.perform('@e1~s1',{kind:'tap'},context(aborted.signal)),/cancelled/);
  const first=client.snapshot(context(new AbortController().signal));await begun;
  const queued=new AbortController();const action=client.perform('@e1~s1',{kind:'tap'},context(queued.signal));
  // Allow the real socket to enqueue behind the blocked snapshot before aborting.
  await new Promise(r=>setTimeout(r,30));queued.abort();await assert.rejects(action,/cancelled/);
  await new Promise(r=>setTimeout(r,30));unblock();await first;
 }finally{unblock();await broker.close();}
 assert.equal(actions,0);
});

test('public SDK viewport scroll is normalized without losing its action policy',async()=>{
 let actions=0;
 const backend:UIBackend={snapshot:async()=>({truncated:false,nodes:[{index:1,ref:'@e1',identifier:actions?'done':'open',role:'button',label:actions?'Done':'Open',hittable:true,enabled:true,visibleToUser:true,rect:{x:0,y:0,width:100,height:50}}],refsGeneration:7,identifiers:{udid:'exact'},appBundleId:'com.example.App'}),
  perform:async(ref,action,_context,nodeId)=>{assert.equal(ref,'root');assert.equal(nodeId,'root');assert.deepEqual(action,{kind:'swipe',direction:'down'});actions++;},release:async()=>({released:false,reason:'SDK contract fixture; no hardware claim'})};
 const segment:Segment={scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'goal',leaseGeneration:1},operationId:'scroll-op',payloadDigest:'a'.repeat(64),phase:'setup',bindings:{},timeoutMs:50000,
  operations:[{id:'goal',kind:'navigateGoal',goal:{id:'goal',instruction:'Scroll to the test endpoint',endpoint:{kind:'testId',value:'done'},maximumCalls:12,maximumActions:30}}]};
 const {payloadDigest:ignored,...body}=segment;segment.payloadDigest=payloadDigest(body);
 await runWorker(backend,{id:'exact',platform:'ios',kind:'simulator',bundleId:'com.example.App',bundlePath:null,loginSession:null},segment,
  await mkdtemp(join(tmpdir(),'intents-scroll-contract-')),new AbortController().signal,async()=>actions?{kind:'finish'}:{kind:'scroll',direction:'down'});
 assert.equal(actions,1);
});
test('a pre-spawn setup failure closes the broker and lets its process exit',async()=>{
 const {spawnSync}=await import('node:child_process');
 const root=await mkdtemp(join(tmpdir(),'intents-worker-setup-failure-'));await mkdir(join(root,'case'));await mkdir(join(root,'case','e2e.config.mjs'));
 const runnerURL=new URL('../src/workerRunner.js',import.meta.url).href;
 const script=`import {runWorker,payloadDigest} from ${JSON.stringify(runnerURL)};
 import {readdir} from 'node:fs/promises';import assert from 'node:assert/strict';
 const body={scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'s',leaseGeneration:1},operationId:'op',phase:'setup',bindings:{},timeoutMs:50000,operations:[]};
 await assert.rejects(runWorker({}, {}, {...body,payloadDigest:payloadDigest(body)},process.env.TEST_ROOT+'/case',new AbortController().signal));
 assert.equal((await readdir(process.env.TEST_ROOT)).some(n=>n.startsWith('ia-')),false);`;
 const child=spawnSync(process.execPath,['--input-type=module','-e',script],{env:{...process.env,TMPDIR:root,TEST_ROOT:root},timeout:10000,encoding:'utf8'});
 assert.ifError(child.error);assert.equal(child.status,0,child.stderr);
});

test('real pinned runner obtains fresh app-bound property readback without invoking a model',async()=>{
 let snapshots=0;const deadlines:number[]=[];const backend:UIBackend={snapshot:async context=>{deadlines.push(context!.timeoutMs);snapshots++;return {truncated:false,nodes:[{index:1,ref:'@e1',identifier:'result',label:'Result',value:'actual saved text',checked:false,hittable:true,enabled:true,visibleToUser:true}],refsGeneration:snapshots,identifiers:{udid:'exact'},appBundleId:'com.example.App'};},
  perform:async()=>{throw new Error('Readback must not mutate')},release:async()=>({released:false,reason:'SDK contract fixture; no hardware claim'})};
 const segment:Segment={scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'observe',leaseGeneration:1},operationId:'readback-op',payloadDigest:'a'.repeat(64),phase:'observe',bindings:{},timeoutMs:50000,
  operations:[{id:'actual',kind:'observeProperty',locator:{kind:'testId',value:'result'},property:'value'},{id:'checked',kind:'observeProperty',locator:{kind:'testId',value:'result'},property:'checked'}]};
 const {payloadDigest:ignored,...body}=segment;segment.payloadDigest=payloadDigest(body);
 const receipt=await runWorker(backend,{id:'exact',platform:'ios',kind:'simulator',bundleId:'com.example.App',bundlePath:null,loginSession:null},segment,
  await mkdtemp(join(tmpdir(),'intents-readback-contract-')),new AbortController().signal) as {outputs:Record<string,{complete:boolean;nodes:{value:string;checked:boolean}[]}>};
 assert.ok(deadlines.every(value=>value>15000 && value<=50000));assert.ok(snapshots>=2);assert.equal(receipt.outputs.actual!.complete,true);assert.equal(receipt.outputs.actual!.nodes[0]!.value,'actual saved text');assert.equal(receipt.outputs.checked!.nodes[0]!.checked,false);
});

 test('controller retains exact unique identified control across index and geometry churn',async()=>{
 let changed=false,actions=0,approved:string|undefined,calls=0;
 const backend:UIBackend={snapshot:async()=>({truncated:false,refsGeneration:7,identifiers:{udid:'exact'},appBundleId:'com.example.App',nodes:[
  {index:changed?4:1,ref:'@e1',identifier:'task.title',kind:'text-field',type:'TextField',hittable:true,enabled:true,visibleToUser:true,rect:{x:changed?20:0,y:0,width:100,height:50}},
  {index:5,ref:'@e5',identifier:'done',role:'button',label:'Done',hittable:true,enabled:true,visibleToUser:true}]}),
  perform:async(ref,action,_context,nodeId)=>{assert.equal(nodeId,approved);assert.equal(ref,'@e1~s7');assert.deepEqual(action,{kind:'fill',value:'fresh input',sensitive:false});actions++;},
  release:async()=>({released:false,reason:'contract fixture'})};
 const segment:Segment={scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'goal',leaseGeneration:1},operationId:'exact-fill-op',payloadDigest:'a'.repeat(64),phase:'setup',bindings:{approved:'fresh input'},timeoutMs:50000,
  operations:[{id:'goal',kind:'navigateGoal',goal:{id:'goal',instruction:'Fill the approved title field',endpoint:{kind:'testId',value:'done'},maximumCalls:12,maximumActions:30,minimumBindingUses:{approved:1}}}]};
 const {payloadDigest:ignored,...body}=segment;segment.payloadDigest=payloadDigest(body);
 await runWorker(backend,{id:'exact',platform:'ios',kind:'simulator',bundleId:'com.example.App',bundlePath:null,loginSession:null},segment,
  await mkdtemp(join(tmpdir(),'intents-exact-fill-contract-')),new AbortController().signal,async request=>{
   calls++;if(actions)return {kind:'finish'};approved=request.nodes.find(n=>n.testId==='task.title')!.id;changed=true;
   return {kind:'fill',node:approved,textBinding:'approved'};
  });
 assert.equal(actions,1);assert.equal(calls,2);
});
 test('controller rejects generic relocation to a different anonymous same-role node',async()=>{
 let changed=false,actions=0;
 const backend:UIBackend={snapshot:async()=>({truncated:false,refsGeneration:7,identifiers:{udid:'exact'},appBundleId:'com.example.App',nodes:[
  {index:changed?4:1,ref:changed?'@e4':'@e1',kind:'text-field',type:'TextField',hittable:true,enabled:true,visibleToUser:true,rect:{x:changed?20:0,y:0,width:100,height:50}}]}),
  perform:async()=>{actions++;throw new Error('Replacement must not reach policy or device');},release:async()=>({released:false,reason:'contract fixture'})};
 const segment:Segment={scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'goal',leaseGeneration:1},operationId:'anonymous-fill-op',payloadDigest:'a'.repeat(64),phase:'setup',bindings:{approved:'fresh input'},timeoutMs:50000,
  operations:[{id:'goal',kind:'navigateGoal',goal:{id:'goal',instruction:'Fill this approved field',endpoint:{kind:'testId',value:'done'},maximumCalls:12,maximumActions:30,minimumBindingUses:{approved:1}}}]};
 const {payloadDigest:ignored,...body}=segment;segment.payloadDigest=payloadDigest(body);
 await assert.rejects(runWorker(backend,{id:'exact',platform:'ios',kind:'simulator',bundleId:'com.example.App',bundlePath:null,loginSession:null},segment,
  await mkdtemp(join(tmpdir(),'intents-anonymous-fill-contract-')),new AbortController().signal,async request=>{
   changed=true;return {kind:'fill',node:request.nodes.find(n=>n.role==='text-field')!.id,textBinding:'approved'};
  }));
 assert.equal(actions,0);
});

 test('pinned private targeted action patch respects action and remaining step deadlines',async()=>{
 const {StepAccounting}=await import(new URL('./agent/step-accounting.js',import.meta.resolve('e2e')).href);
 for(const [configured,remaining,expected] of [[120000,50000,50000],[10000,50000,10000],[120000,8000,8000],[200000,200000,120000]]){
  const signal=new AbortController().signal;const runtime={config:{actionTimeout:configured},engine:{signal,deadline:()=>({remaining:()=>remaining}),
   operation:(timeoutMs:number)=>({signal,timeoutMs,runId:'r',attemptId:'a',origin:'test'})}};
  const accounting=new StepAccounting(runtime,{api:'agent.act',timeoutMs:remaining,maxActions:30,maxModelCalls:12,contextBytes:0});
  assert.equal(accounting.actionOperation().timeoutMs,expected);
 }
});
 test('broker retains mutation uncertainty on a submitted action timeout',async()=>{
 const {createBroker,BrokerClient}=await import('../src/segmentBroker.js');let actions=0;
 const backend:UIBackend={snapshot:async()=>({nodes:[],identifiers:{udid:'exact'}}),
  perform:async()=>{actions++;await new Promise(r=>setTimeout(r,100));},release:async()=>({released:false,reason:'contract'})};
 const broker=await createBroker(backend);
 try{await assert.rejects(new BrokerClient(broker.socket,broker.token).perform('@e1~s1',{kind:'tap'},
  {runId:'r',attemptId:'a',origin:'test',signal:new AbortController().signal,timeoutMs:50}),{code:'ACTION_MAY_HAVE_COMMITTED',retryable:false});}
 finally{await broker.close();}
 assert.equal(actions,1);
});
 test('a real pinned controller action can complete beyond the upstream fifteen-second ceiling',async()=>{
 let actions=0,approved:string|undefined,remaining=0;
 const backend:UIBackend={snapshot:async()=>({truncated:false,refsGeneration:7,identifiers:{udid:'exact'},appBundleId:'com.example.App',nodes:[
  {index:1,ref:'@e1',identifier:actions?'done':'open',role:'button',label:actions?'Done':'Open',hittable:true,enabled:true,visibleToUser:true}]}),
  perform:async(_ref,_action,context,nodeId)=>{assert.equal(nodeId,approved);remaining=context.timeoutMs;await new Promise(r=>setTimeout(r,16050));actions++;},
  release:async()=>({released:false,reason:'contract fixture'})};
 const segment:Segment={scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'goal',leaseGeneration:1},operationId:'long-action-op',payloadDigest:'a'.repeat(64),phase:'setup',bindings:{},timeoutMs:50000,
  operations:[{id:'goal',kind:'navigateGoal',goal:{id:'goal',instruction:'Open the approved endpoint',endpoint:{kind:'testId',value:'done'},maximumCalls:12,maximumActions:30}}]};
 const {payloadDigest:ignored,...body}=segment;segment.payloadDigest=payloadDigest(body);
 await runWorker(backend,{id:'exact',platform:'ios',kind:'simulator',bundleId:'com.example.App',bundlePath:null,loginSession:null},segment,
  await mkdtemp(join(tmpdir(),'intents-long-action-contract-')),new AbortController().signal,async request=>{
   if(actions)return {kind:'finish'};approved=request.nodes.find(n=>n.testId==='open')!.id;return {kind:'tap',node:approved};
  });
 assert.equal(actions,1);assert.ok(remaining>16050 && remaining<=50000);
});

 test('real runner retains explicit backend mutation uncertainty across the broker without retry',async()=>{
 let actions=0;const backend:UIBackend={snapshot:async()=>({truncated:false,refsGeneration:7,identifiers:{udid:'exact'},appBundleId:'com.example.App',nodes:[
  {index:1,ref:'@e1',identifier:'open',role:'button',label:'Open',hittable:true,enabled:true,visibleToUser:true}]}),
  perform:async()=>{actions++;throw new EngineError('ACTION_MAY_HAVE_COMMITTED','unresolved backend',{retryable:false});},release:async()=>({released:false,reason:'contract fixture'})};
 const segment:Segment={scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'goal',leaseGeneration:1},operationId:'uncertain-action-op',payloadDigest:'a'.repeat(64),phase:'setup',bindings:{},timeoutMs:50000,
  operations:[{id:'goal',kind:'navigateGoal',goal:{id:'goal',instruction:'Open the approved endpoint',endpoint:{kind:'testId',value:'done'},maximumCalls:12,maximumActions:30}}]};
 const {payloadDigest:ignored,...body}=segment;segment.payloadDigest=payloadDigest(body);const root=await mkdtemp(join(tmpdir(),'intents-uncertain-action-contract-'));
 await assert.rejects(runWorker(backend,{id:'exact',platform:'ios',kind:'simulator',bundleId:'com.example.App',bundlePath:null,loginSession:null},segment,root,new AbortController().signal,
  async request=>({kind:'tap',node:request.nodes.find(n=>n.testId==='open')!.id})));
 assert.equal(actions,1);const {readFile}=await import('node:fs/promises');const log=await readFile(join(root,'worker.log'),'utf8');
 assert.match(log,/"code": "ACTION_MAY_HAVE_COMMITTED"/);
});

 test('submitted actions cannot succeed from incomplete or contradictory broker responses',async()=>{
 const {createServer}=await import('node:net');const {BrokerClient}=await import('../src/segmentBroker.js');
 for(const response of [{},{result:'unexpected'},{result:null,error:{code:'ENGINE_FAILURE',message:'failure'}}]){
  const root=await mkdtemp(join(tmpdir(),'ia-malformed-'));const socket=join(root,'b.sock');
  const server=createServer(client=>{client.on('error',()=>{});client.once('data',chunk=>{const message=JSON.parse(chunk.toString());client.end(JSON.stringify({id:message.id,...response})+'\n');});});
  await new Promise<void>((resolve,reject)=>{server.once('error',reject);server.listen(socket,resolve);});
  try{await assert.rejects(new BrokerClient(socket,'a'.repeat(64)).perform('@e1~s1',{kind:'tap'},
   {runId:'r',attemptId:'a',origin:'test',signal:new AbortController().signal,timeoutMs:1000}),{code:'ACTION_MAY_HAVE_COMMITTED',retryable:false});}
  finally{await new Promise<void>(r=>server.close(()=>r()));}
 }
});

test('real pinned runner preserves prototype-name and numeric operation receipts in a v2 segment',async()=>{
 const {segmentPayloadDigest}=await import('../src/payloadDigest.js');let snapshots=0;
 const backend:UIBackend={snapshot:async()=>({truncated:false,nodes:[{index:1,ref:'@e1',identifier:'result',label:'Result',value:'synthetic saved text',hittable:true,enabled:true,visibleToUser:true}],refsGeneration:++snapshots,identifiers:{udid:'exact'},appBundleId:'com.example.App'}),
  perform:async()=>{throw new Error('Read-only fixture must not mutate');},release:async()=>({released:false,reason:'SDK contract fixture'})};
 const body={scope:{protocolVersion:1 as const,runId:'r',attemptId:'a',segmentId:'observe',leaseGeneration:1},operationId:'reserved-op',digestVersion:2 as const,
  phase:'observe' as const,bindings:{'2':'two','10':'ten'},timeoutMs:50000,
  operations:[{id:'__proto__',kind:'observeProperty' as const,locator:{kind:'testId' as const,value:'result'},property:'value' as const},
   ...['constructor','2','10'].map(id=>({id,kind:'locate' as const,locator:{kind:'testId' as const,value:'result'}}))]};
 const segment:Segment={...body,payloadDigest:segmentPayloadDigest(body)};
 const root=await mkdtemp(join(tmpdir(),'intents-special-receipt-'));
 try{
  const receipt=await runWorker(backend,{id:'exact',platform:'ios',kind:'simulator',bundleId:'com.example.App',bundlePath:null,loginSession:null},segment,root,new AbortController().signal) as {outputs:Record<string,unknown>};
  const saved=JSON.parse(await readFile(join(root,'receipt.json'),'utf8')) as typeof receipt;
  assert.deepEqual(Object.keys(saved.outputs).sort(),['__proto__','constructor','2','10'].sort());
  assert.equal(Object.hasOwn(receipt.outputs,'__proto__'),true);
  assert.equal((saved.outputs.__proto__ as {nodes:{value:string}[]}).nodes[0]!.value,'synthetic saved text');
  for(const id of ['constructor','2','10'])assert.equal(saved.outputs[id],1);
 }finally{await rm(root,{recursive:true,force:true});}
});

const cancellationTarget={id:'exact',platform:'ios',kind:'simulator',bundleId:'com.example.App',bundlePath:null,loginSession:null} as const;
function cancellationSegment(operationId:string,timeoutMs=50000):Segment{
 const segment:Segment={scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'s',leaseGeneration:1},operationId,payloadDigest:'a'.repeat(64),phase:'setup',bindings:{},timeoutMs,
  operations:[{id:'tap',kind:'tap',locator:{kind:'testId',value:'done'}}]};
 const {payloadDigest:ignored,...body}=segment;segment.payloadDigest=payloadDigest(body);return segment;
}
const doneSnapshot=()=>({truncated:false,nodes:[{index:1,ref:'@e1',identifier:'done',role:'button',label:'Done',hittable:true,enabled:true,visibleToUser:true,rect:{x:0,y:0,width:100,height:50}}],
 refsGeneration:7,identifiers:{udid:'exact'},appBundleId:'com.example.App'});
async function workerProcessTree(root:string){
 const {execFileSync}=await import('node:child_process');const configPath=join(root,'e2e.config.mjs');
 const rows=execFileSync('ps',['-A','-o','pid=,ppid=,args='],{encoding:'utf8'}).trim().split('\n').map(line=>{
  const [pid,ppid,...args]=line.trim().split(/\s+/);return {pid:Number(pid),ppid:Number(ppid),args:args.join(' ')};});
 const tree=rows.filter(row=>row.ppid===process.pid && row.args.includes(configPath)).map(row=>row.pid);
 for(let i=0;i<tree.length;i++)for(const row of rows)if(row.ppid===tree[i] && !tree.includes(row.pid))tree.push(row.pid);
 return tree;
}
async function assertProcessesExit(pids:number[]){
 const alive=(pid:number)=>{try{process.kill(pid,0);return true;}catch(error){return (error as NodeJS.ErrnoException).code!=='ESRCH';}};
 for(const started=Date.now();pids.some(alive) && Date.now()-started<10000;)await new Promise(r=>setTimeout(r,50));
 assert.deepEqual(pids.filter(alive),[]);
}
async function spyWorkerKills(t:import('node:test').TestContext,deliverSIGTERM=true){
 const {ChildProcess}=await import('node:child_process');const signals:(NodeJS.Signals|number|undefined)[]=[];const kill=ChildProcess.prototype.kill;
 t.mock.method(ChildProcess.prototype,'kill',function(this:InstanceType<typeof ChildProcess>,signal?:NodeJS.Signals|number){
  // Earlier tests' grace timers may still target already-exited children; Node treats those as no-ops.
  if(this.exitCode===null && this.signalCode===null)signals.push(signal);return signal==='SIGTERM' && !deliverSIGTERM?true:kill.call(this,signal);});
 return signals;
}

test('a segment whose payload digest does not match is rejected before any state, broker or worker exists',async t=>{
 const signals=await spyWorkerKills(t);let calls=0;
 const backend:UIBackend={snapshot:async()=>{calls++;return doneSnapshot();},perform:async()=>{calls++;},release:async()=>({released:false,reason:'contract fixture'})};
 const base=await mkdtemp(join(tmpdir(),'intents-digest-mismatch-'));const root=join(base,'case');
 try{
  for(const tamper of [(s:Segment)=>{s.payloadDigest='b'.repeat(64);},(s:Segment)=>{s.operationId='other-op';},(s:Segment)=>{s.timeoutMs=60000;}]){
   const segment=cancellationSegment('digest-op');tamper(segment);
   await assert.rejects(runWorker(backend,cancellationTarget,segment,root,new AbortController().signal,async()=>{calls++;return {kind:'finish'};}),/Worker segment digest mismatch/);
  }
  await assert.rejects(readFile(root),{code:'ENOENT'});
 }finally{await rm(base,{recursive:true,force:true});}
 assert.equal(calls,0);assert.deepEqual(signals,[]);
});

test('an already-aborted signal terminates the worker before it reaches the device',async t=>{
 const signals=await spyWorkerKills(t);let calls=0;
 const backend:UIBackend={snapshot:async()=>{calls++;return doneSnapshot();},perform:async()=>{calls++;},release:async()=>({released:false,reason:'contract fixture'})};
 const root=await mkdtemp(join(tmpdir(),'intents-pre-aborted-'));const controller=new AbortController();controller.abort();
 try{
  await assert.rejects(runWorker(backend,cancellationTarget,cancellationSegment('pre-aborted-op'),root,controller.signal),/^Error: Segment cancelled$/);
  assert.deepEqual(signals,['SIGTERM']);assert.equal(calls,0);
  await assert.rejects(readFile(join(root,'receipt.json')),{code:'ENOENT'});await readFile(join(root,'worker.log'),'utf8');
 }finally{await rm(root,{recursive:true,force:true});}
});

test('aborting during the first snapshot terminates the live worker without any device action',async t=>{
 const signals=await spyWorkerKills(t);const root=await mkdtemp(join(tmpdir(),'intents-abort-snapshot-'));const controller=new AbortController();
 let snapshots=0,actions=0,pids:number[]=[],aborted=0;
 const backend:UIBackend={snapshot:async context=>{snapshots++;pids=await workerProcessTree(root);aborted=Date.now();controller.abort();
   await new Promise(r=>context!.signal.aborted?r(undefined):context!.signal.addEventListener('abort',r,{once:true}));return doneSnapshot();},
  perform:async()=>{actions++;},release:async()=>({released:false,reason:'contract fixture'})};
 try{
  await assert.rejects(runWorker(backend,cancellationTarget,cancellationSegment('abort-snapshot-op'),root,controller.signal),/^Error: Segment cancelled$/);
  // SIGTERM, not a worker-side timeout or the SIGKILL grace period, ends the run.
  assert.ok(Date.now()-aborted<4000);assert.equal(snapshots,1);assert.equal(actions,0);assert.deepEqual(signals,['SIGTERM']);assert.ok(pids.length>0);
  await assertProcessesExit(pids);await assert.rejects(readFile(join(root,'receipt.json')),{code:'ENOENT'});
 }finally{await rm(root,{recursive:true,force:true});}
});

test('the segment deadline terminates a worker blocked on a never-answering snapshot',async t=>{
 const signals=await spyWorkerKills(t);const root=await mkdtemp(join(tmpdir(),'intents-deadline-'));const signal=new AbortController().signal;
 let snapshots=0,actions=0,pids:number[]=[];
 const backend:UIBackend={snapshot:async context=>{snapshots++;pids=await workerProcessTree(root);
   await new Promise(r=>context!.signal.addEventListener('abort',r,{once:true}));return doneSnapshot();},
  perform:async()=>{actions++;},release:async()=>({released:false,reason:'contract fixture'})};
 try{
  // Leave ample room for a slow runner to start the real CLI before the deadline fires.
  const started=Date.now();
  await assert.rejects(runWorker(backend,cancellationTarget,cancellationSegment('deadline-op',10000),root,signal),/^Error: Worker failed; see owned log$/);
  assert.ok(Date.now()-started>=10000);assert.equal(signal.aborted,false);
  assert.equal(snapshots,1);assert.equal(actions,0);assert.deepEqual(signals,['SIGTERM']);assert.ok(pids.length>0);
  await assertProcessesExit(pids);await assert.rejects(readFile(join(root,'receipt.json')),{code:'ENOENT'});
 }finally{await rm(root,{recursive:true,force:true});}
});

test('a worker that survives SIGTERM is killed with SIGKILL after the grace period',async t=>{
 const signals=await spyWorkerKills(t,false);const root=await mkdtemp(join(tmpdir(),'intents-sigkill-'));const controller=new AbortController();
 let actions=0,pids:number[]=[],aborted=0;
 const backend:UIBackend={snapshot:async context=>{pids=await workerProcessTree(root);if(!controller.signal.aborted){aborted=Date.now();controller.abort();}
   await new Promise(r=>context!.signal.aborted?r(undefined):context!.signal.addEventListener('abort',r,{once:true}));return doneSnapshot();},
  perform:async()=>{actions++;},release:async()=>({released:false,reason:'contract fixture'})};
 try{
  await assert.rejects(runWorker(backend,cancellationTarget,cancellationSegment('sigkill-op'),root,controller.signal),/^Error: Segment cancelled$/);
  assert.ok(Date.now()-aborted>=5000);assert.equal(actions,0);assert.deepEqual(signals,['SIGTERM','SIGKILL']);assert.ok(pids.length>0);
  await assertProcessesExit(pids);
 }finally{await rm(root,{recursive:true,force:true});}
});

test('a completed worker receipt for another scope, operation or incomplete run is rejected',async t=>{
 const {ChildProcess}=await import('node:child_process');const {readFileSync,writeFileSync}=await import('node:fs');
 const emit=ChildProcess.prototype.emit;let tamper:((receipt:Record<string,unknown>)=>void)|undefined,receiptPath='';
 t.mock.method(ChildProcess.prototype,'emit',function(this:InstanceType<typeof ChildProcess>,event:string|symbol,...args:unknown[]){
  // The worker has exited with its genuine receipt; rewrite it before the runner reads it.
  if(event==='exit' && tamper){const receipt=JSON.parse(readFileSync(receiptPath,'utf8'));assert.equal(receipt.complete,true);tamper(receipt);writeFileSync(receiptPath,JSON.stringify(receipt));}
  return Reflect.apply(emit,this,[event,...args]) as boolean;});
 const backend:UIBackend={snapshot:async()=>doneSnapshot(),perform:async()=>{},release:async()=>({released:false,reason:'contract fixture'})};
 for(const mutate of [(r:Record<string,unknown>)=>{r.scope={...(r.scope as object),leaseGeneration:2};},(r:Record<string,unknown>)=>{r.scope={...(r.scope as object),runId:'other'};},
  (r:Record<string,unknown>)=>{r.operationId='other-op';},(r:Record<string,unknown>)=>{r.complete=false;}]){
  const root=await mkdtemp(join(tmpdir(),'intents-receipt-mismatch-'));receiptPath=join(root,'receipt.json');tamper=mutate;
  try{
   const segment=cancellationSegment('receipt-op');segment.operations=[{id:'endpoint',kind:'assertEndpoint',locator:{kind:'testId',value:'done'}}];
   const {payloadDigest:ignored,...body}=segment;segment.payloadDigest=payloadDigest(body);
   await assert.rejects(runWorker(backend,cancellationTarget,segment,root,new AbortController().signal),/^Error: Missing or mismatched UI receipt$/);
  }finally{tamper=undefined;await rm(root,{recursive:true,force:true});}
 }
 const root=await mkdtemp(join(tmpdir(),'intents-receipt-control-'));
 try{
  const segment=cancellationSegment('receipt-op');segment.operations=[{id:'endpoint',kind:'assertEndpoint',locator:{kind:'testId',value:'done'}}];
  const {payloadDigest:ignored,...body}=segment;segment.payloadDigest=payloadDigest(body);
  const receipt=await runWorker(backend,cancellationTarget,segment,root,new AbortController().signal) as {operationId:string;complete:boolean};
  assert.equal(receipt.operationId,'receipt-op');assert.equal(receipt.complete,true);
 }finally{await rm(root,{recursive:true,force:true});}
});

const iosTarget={id:'exact',platform:'ios' as const,kind:'simulator' as const,bundleId:'com.example.App',bundlePath:null,loginSession:null};
const sealed=async(body:Omit<Segment,'payloadDigest'>):Promise<Segment>=>{const {segmentPayloadDigest}=await import('../src/payloadDigest.js');return {...body,payloadDigest:segmentPayloadDigest(body)};};
const pathExists=async(path:string)=>{const {access}=await import('node:fs/promises');return access(path).then(()=>true,()=>false);};

test('real pinned runner records distinct readProperty value and text outputs and locate cardinality',async()=>{
 let snapshots=0;const backend:UIBackend={snapshot:async()=>({truncated:false,refsGeneration:++snapshots,identifiers:{udid:'exact'},appBundleId:'com.example.App',nodes:[
  {index:1,ref:'@e1',identifier:'title',label:'Title label',value:'typed value',hittable:true,enabled:true,visibleToUser:true},
  {index:2,ref:'@e2',identifier:'row',label:'First',hittable:true,enabled:true,visibleToUser:true},
  {index:3,ref:'@e3',identifier:'row',label:'Second',hittable:true,enabled:true,visibleToUser:true}]}),
  perform:async()=>{throw new Error('Read-only fixture must not mutate');},release:async()=>({released:false,reason:'SDK contract fixture'})};
 const segment=await sealed({scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'read',leaseGeneration:1},operationId:'read-op',digestVersion:2,phase:'observe',bindings:{},timeoutMs:50000,
  operations:[{id:'value',kind:'readProperty',locator:{kind:'testId',value:'title'},property:'value'},
   {id:'text',kind:'readProperty',locator:{kind:'testId',value:'title'},property:'text'},
   {id:'rows',kind:'locate',locator:{kind:'testId',value:'row'}},
   {id:'absent',kind:'locate',locator:{kind:'testId',value:'missing'}}]});
 const root=await mkdtemp(join(tmpdir(),'intents-read-property-'));
 try{
  const receipt=await runWorker(backend,iosTarget,segment,root,new AbortController().signal) as {outputs:Record<string,unknown>};
  const saved=JSON.parse(await readFile(join(root,'receipt.json'),'utf8')) as typeof receipt;
  assert.deepEqual(saved,receipt);
  assert.equal(saved.outputs.value,'typed value');
  // semanticTree maps label to name and never sets SemanticNode.text, so
  // textContent() is null on this path; value must not leak into text evidence.
  assert.equal(saved.outputs.text,null);
  assert.equal(saved.outputs.rows,2);assert.equal(saved.outputs.absent,0);
 }finally{await rm(root,{recursive:true,force:true});}
});

test('real pinned runner resolves textbox role fills and button-qualified label taps on iOS',async()=>{
 const performed:{ref:string;action:unknown}[]=[];let snapshots=0;
 const backend:UIBackend={snapshot:async()=>({truncated:false,refsGeneration:++snapshots,identifiers:{udid:'exact'},appBundleId:'com.example.App',nodes:[
  {index:1,ref:'@e1',role:'textbox',editable:true,hittable:true,enabled:true,visibleToUser:true},
  {index:2,ref:'@e2',role:'text',label:'Save',hittable:true,enabled:true,visibleToUser:true},
  {index:3,ref:'@e3',role:'button',label:'Save',hittable:true,enabled:true,visibleToUser:true}]}),
  perform:async(ref,action)=>{performed.push({ref,action});},release:async()=>({released:false,reason:'SDK contract fixture'})};
 const segment=await sealed({scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'roles',leaseGeneration:1},operationId:'roles-op',digestVersion:2,phase:'setup',bindings:{title:'approved title'},timeoutMs:50000,
  operations:[{id:'fill',kind:'fillBinding',locator:{kind:'role',value:'textbox'},binding:'title'},
   {id:'save',kind:'tap',locator:{kind:'label',value:'Save',role:'button'}}]});
 const root=await mkdtemp(join(tmpdir(),'intents-role-locators-'));
 try{
  await runWorker(backend,iosTarget,segment,root,new AbortController().signal);
  assert.deepEqual(performed.map(({ref,action})=>({ref:ref.split('~s')[0],action})),
   [{ref:'@e1',action:{kind:'fill',value:'approved title',sensitive:false}},{ref:'@e3',action:{kind:'tap'}}]);
 }finally{await rm(root,{recursive:true,force:true});}
});

test('real pinned runner refuses a fill whose approved binding is missing before any device action',async()=>{
 let actions=0;const backend:UIBackend={snapshot:async()=>({truncated:false,refsGeneration:1,identifiers:{udid:'exact'},appBundleId:'com.example.App',nodes:[
  {index:1,ref:'@e1',identifier:'title',role:'textbox',editable:true,hittable:true,enabled:true,visibleToUser:true}]}),
  perform:async()=>{actions++;},release:async()=>({released:false,reason:'SDK contract fixture'})};
 const segment=await sealed({scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'fill',leaseGeneration:1},operationId:'missing-binding-op',digestVersion:2,phase:'setup',bindings:{other:'unrelated'},timeoutMs:50000,
  operations:[{id:'fill',kind:'fillBinding',locator:{kind:'testId',value:'title'},binding:'title'}]});
 const root=await mkdtemp(join(tmpdir(),'intents-missing-binding-'));
 try{
  await assert.rejects(runWorker(backend,iosTarget,segment,root,new AbortController().signal),/Worker failed/);
  assert.equal(actions,0);assert.equal(await pathExists(join(root,'receipt.json')),false);
  assert.match(await readFile(join(root,'worker.log'),'utf8'),/Missing frozen fill binding|Missing approved binding/);
 }finally{await rm(root,{recursive:true,force:true});}
});

test('real pinned runner rejects a receipt over the evidence budget without writing it',async()=>{
 const large='x'.repeat(36000);let snapshots=0;
 const backend:UIBackend={snapshot:async()=>({truncated:false,refsGeneration:++snapshots,identifiers:{udid:'exact'},appBundleId:'com.example.App',nodes:[
  {index:1,ref:'@e1',identifier:'body',label:'Body',value:large,hittable:true,enabled:true,visibleToUser:true}]}),
  perform:async()=>{throw new Error('Read-only fixture must not mutate');},release:async()=>({released:false,reason:'SDK contract fixture'})};
 const segment=await sealed({scope:{protocolVersion:1,runId:'r',attemptId:'a',segmentId:'large',leaseGeneration:1},operationId:'large-op',digestVersion:2,phase:'observe',bindings:{},timeoutMs:110000,
  operations:Array.from({length:30},(_,i)=>({id:`read${i}`,kind:'readProperty' as const,locator:{kind:'testId' as const,value:'body'},property:'value' as const}))});
 const root=await mkdtemp(join(tmpdir(),'intents-receipt-budget-'));
 try{
  await assert.rejects(runWorker(backend,iosTarget,segment,root,new AbortController().signal),/Worker failed/);
  assert.ok(snapshots>=30);assert.equal(await pathExists(join(root,'receipt.json')),false);
  assert.match(await readFile(join(root,'worker.log'),'utf8'),/UI receipt exceeds evidence budget/);
 }finally{await rm(root,{recursive:true,force:true});}
});
