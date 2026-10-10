import {test} from 'node:test';import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';import {fileURLToPath,pathToFileURL} from 'node:url';import {setTimeout as delay} from 'node:timers/promises';
import {payloadDigest} from '../src/workerRunner.js';

// The real production executable and protocol run in a child. Only external
// device/worker/journal dependencies are replaced by deterministic module hooks.
async function harness(scenario:string){
 const root=await mkdtemp('/private/tmp/intents-main-');const state=join(root,'state');
 const mainURL=new URL('../src/main.js',import.meta.url),workerURL=new URL('../src/workerRunner.js',import.meta.url);
 const common=`import {appendFile,access} from 'node:fs/promises';import {join} from 'node:path';import {setTimeout as delay} from 'node:timers/promises';
 const root=process.env.INTENTS_TEST_ROOT, scenario=process.env.INTENTS_TEST_SCENARIO;
 async function event(kind,extra={}){await appendFile(join(root,'events.jsonl'),JSON.stringify({kind,...extra})+'\\n');}
 async function gate(){for(let n=0;n<6000;n++){try{await access(join(root,'gate'));return;}catch{await delay(5)}}throw new Error('Test gate deadline');}
 const device=scenario==='native-mac'?{id:'host-macos-local',name:'same',platform:'macos',target:'desktop',kind:'device',identifiers:{deviceId:'host-macos-local'}}:{id:'device',name:'same',platform:'ios',target:'mobile',kind:'simulator',identifiers:{udid:'device'}};
`;
 await writeFile(join(root,'sdk.mjs'),common+`
 export function createAgentDeviceClient(config){return {
 devices:{list:async()=>{await event('list-start',{state:config.stateDir});if(scenario==='inventory-delay')await gate();await event('list-done');return scenario==='missing-target'||scenario==='unproved-acquire'?[]:[device]},capabilities:async options=>{await event('capabilities',{selector:options.udid,nameSelector:options.device});return {device}}},
 apps:{open:async options=>{await event('open-start',{selector:options.udid,nameSelector:options.device});if(scenario==='late-acquire')await gate();await event('opened');return {identifiers:{udid:device.id,appBundleId:'example.App'}}}},
 sessions:{close:async()=>{await event('session-closed');if(scenario==='close-failure')throw new Error('SDK lifecycle cleanup failed');},list:async()=>[{name:config.session,device}]},
 capture:{snapshot:async()=>{await event('snapshot-start');if(scenario==='snapshot-delay')await gate();await event('snapshot-done');return {refsGeneration:1,appBundleId:'example.App',identifiers:{session:config.session},nodes:[]}}},
 interactions:{press:async()=>{},fill:async()=>{},scroll:async()=>{}}};}
 `);
 await writeFile(join(root,'lifecycle.mjs'),common+`export async function stopPrivateDaemon(state){await event('daemon-stopped',{state});return {released:scenario!=='unproved-acquire',reason:'test-only deterministic release'};}`);
 await writeFile(join(root,'journal.mjs'),common+`export class OperationJournal {async load(){} async dispatch(_id,_digest,operation){if(scenario==='pending-journal'){await event('journal-pending');await gate();}return operation();}}`);
 await writeFile(join(root,'worker.mjs'),common+`export {payloadDigest} from ${JSON.stringify(workerURL.href)};
 export async function runWorker(_session,_target,segment,_directory,signal){await event('worker-started');if(scenario==='active-worker'){await new Promise((resolve,reject)=>{signal.addEventListener('abort',()=>reject(new Error('cancelled')),{once:true});});}return {schemaVersion:1,scope:segment.scope,operationId:segment.operationId,complete:true,outputs:{}};}`);
 const hook=`import {registerHooks} from 'node:module';const main=${JSON.stringify(mainURL.href)};const root=${JSON.stringify(pathToFileURL(root+'/').href)};
 registerHooks({resolve(specifier,context,next){
 if(specifier==='agent-device'&&(context.parentURL===main||context.parentURL?.endsWith('/src/deviceSession.js')))return {url:new URL('sdk.mjs',root).href,shortCircuit:true};
 if(specifier==='./lifecycle.js'&&(context.parentURL===main||context.parentURL?.endsWith('/src/deviceSession.js')))return {url:new URL('lifecycle.mjs',root).href,shortCircuit:true};
 if(context.parentURL===main&&specifier==='./operationJournal.js')return {url:new URL('journal.mjs',root).href,shortCircuit:true};
 if(context.parentURL===main&&specifier==='./workerRunner.js')return {url:new URL('worker.mjs',root).href,shortCircuit:true};
 return next(specifier,context);}});`;
 await writeFile(join(root,'hook.mjs'),hook);
 const child=spawn(process.execPath,['--import',join(root,'hook.mjs'),fileURLToPath(mainURL),'--state-dir',state],{
  env:{PATH:'/usr/bin:/bin',HOME:root,TMPDIR:'/private/tmp',INTENTS_TEST_ROOT:root,INTENTS_TEST_SCENARIO:scenario},stdio:['pipe','pipe','pipe']});
 let text='',diagnostics='',sequence=0;const pending=new Map<string,{resolve:(v:any)=>void;reject:(e:Error)=>void;timer:NodeJS.Timeout}>();
 child.stderr.on('data',c=>{diagnostics+=String(c)});
 child.stdout.on('data',c=>{text+=String(c);let index;
  while((index=text.indexOf('\n'))>=0){const frame=JSON.parse(text.slice(0,index));text=text.slice(index+1);
   if(frame.method){child.stdin.write(JSON.stringify({jsonrpc:'2.0',id:frame.id,result:{allowed:true}})+'\n');continue;}
   const task=pending.get(frame.id);if(task){pending.delete(frame.id);clearTimeout(task.timer);task.resolve(frame);}
  }});
 const exited=new Promise<number|null>((resolve,reject)=>{child.once('error',reject);child.once('exit',code=>resolve(code));});
 async function request(method:string,params:unknown){const id='test-'+(++sequence);return await new Promise<any>((resolve,reject)=>{
  const timer=setTimeout(()=>{pending.delete(id);reject(new Error('Protocol deadline '+method+' '+diagnostics))},35000);
  pending.set(id,{resolve,reject,timer});child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');});}
 async function events():Promise<Array<{kind:string;state?:string;selector?:string;nameSelector?:string}>>{try{return (await readFile(join(root,'events.jsonl'),'utf8')).trim().split('\n').filter(Boolean).map(s=>JSON.parse(s));}catch{return [];}}
 async function waitEvent(kind:string){for(let n=0;n<1000;n++){if((await events()).some(e=>e.kind===kind))return;await delay(5);}throw new Error('Missing event '+kind+' '+diagnostics);}
 async function dispose(){child.stdin.end();const watchdog=setTimeout(()=>child.kill('SIGKILL'),3000);await exited;clearTimeout(watchdog);for(const p of pending.values())clearTimeout(p.timer);await rm(root,{recursive:true,force:true});}
 return {child,request,events,waitEvent,exited,dispose,openGate:()=>writeFile(join(root,'gate'),'approved')};
}
const scope={protocolVersion:1 as const,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:1};
const target={id:'device',platform:'ios',kind:'simulator',bundleId:'example.App',bundlePath:null,loginSession:null};
const acquire={scope,target,lifecycle:'persistedStateAcrossSegments'};
function segment(operationId='operation'){
 const body={scope,operationId,phase:'setup',bindings:{},timeoutMs:1000,operations:[{id:'tap',kind:'tap',locator:{kind:'testId',value:'done'}}]};
 return {...body,payloadDigest:payloadDigest(body)};
}
test('failed actual acquisition cleans its private device resources before success is reported',async()=>{
 const h=await harness('missing-target');try{
  assert.ok((await h.request('ui.acquire',acquire)).error);
  assert.ok((await h.events()).some(e=>e.kind==='daemon-stopped' && e.state?.endsWith('/device')));
  assert.equal((await h.request('shutdown',{protocolVersion:1})).result.resourcesReleased,true);
 }finally{await h.dispose();}
});
test('unproved acquisition termination blocks shutdown success and another acquisition',async()=>{
 const h=await harness('unproved-acquire');try{
  assert.ok((await h.request('ui.acquire',acquire)).error);
  const shutdown=await h.request('shutdown',{protocolVersion:1});assert.equal(shutdown.result.resourcesReleased,false);
  assert.equal(shutdown.result.cleanupReason,'acquisitionUnknown');
 }finally{await h.dispose();}
});
test('pending journal admission blocks release and cannot start a worker after shutdown',async()=>{
 const h=await harness('pending-journal');try{
  assert.equal((await h.request('ui.acquire',acquire)).result.acquired,true);
  const operation=h.request('ui.runSegment',segment());await h.waitEvent('journal-pending');
  assert.equal((await h.request('ui.release',scope)).result.released,false);
  assert.ok((await h.request('ui.runSegment',segment('second'))).error);
  const shutdown=h.request('shutdown',{protocolVersion:1});await delay(30);await h.openGate();
  assert.ok((await operation).error);assert.equal((await shutdown).result.resourcesReleased,true);
  assert.equal((await h.events()).some(e=>e.kind==='worker-started'),false);
 }finally{await h.dispose();}
});
test('partial-frame and oversized-frame input failures still release the owned session',async()=>{
 for(const invalid of ['{"jsonrpc":','x'.repeat(1_048_577)]){
  const h=await harness('normal');try{
   assert.equal((await h.request('ui.acquire',acquire)).result.acquired,true);
   h.child.stdin.end(invalid);assert.equal(await h.exited,1);
   assert.ok((await h.events()).some(e=>e.kind==='session-closed'));
   assert.ok((await h.events()).some(e=>e.kind==='daemon-stopped'));
  }finally{await h.dispose();}
 }
});
test('shutdown drains an admitted inventory call before stopping its daemon',async()=>{
 const h=await harness('inventory-delay');try{
  const inventory=h.request('inventory',{protocolVersion:1});await h.waitEvent('list-start');
  const shutdown=h.request('shutdown',{protocolVersion:1});await delay(30);
  assert.equal((await h.events()).some(e=>e.kind==='daemon-stopped'),false);
  await h.openGate();assert.ok((await inventory).result);assert.equal((await shutdown).result.resourcesReleased,true);
  const events=await h.events();assert.ok(events.findIndex(e=>e.kind==='list-done')<events.findIndex(e=>e.kind==='daemon-stopped'));
 }finally{await h.dispose();}
});
test('an acquisition settling after the shutdown deadline releases itself',async()=>{
 const h=await harness('late-acquire');try{
  const acquisition=h.request('ui.acquire',acquire);await h.waitEvent('open-start');
  const shutdown=await h.request('shutdown',{protocolVersion:1});assert.equal(shutdown.result.resourcesReleased,false);
  assert.equal(shutdown.result.cleanupReason,'pendingWork');
  await h.openGate();assert.ok((await acquisition).error);await h.waitEvent('session-closed');
  assert.equal((await h.request('shutdown',{protocolVersion:1})).result.resourcesReleased,true);
 }finally{await h.dispose();}
});

test('EOF drains an admitted UI snapshot before releasing its private daemon',async()=>{
 const h=await harness('snapshot-delay');try{
  assert.equal((await h.request('ui.acquire',acquire)).result.acquired,true);
  const snapshot=h.request('probe',{scope,name:'uiTree'});await h.waitEvent('snapshot-start');
  h.child.stdin.end();await delay(30);
  assert.equal((await h.events()).some(e=>e.kind==='session-closed'),false);
  await h.openGate();assert.ok((await snapshot).result);assert.equal(await h.exited,0);
  const events=await h.events();
  assert.ok(events.findIndex(e=>e.kind==='snapshot-done')<events.findIndex(e=>e.kind==='session-closed'));
  assert.ok(events.some(e=>e.kind==='daemon-stopped'));
 }finally{await h.dispose();}
});

test('unproved device cleanup does not skip independent inventory cleanup',async()=>{
 const h=await harness('unproved-acquire');try{
  assert.ok((await h.request('inventory',{protocolVersion:1})).result);
  assert.ok((await h.request('ui.acquire',acquire)).error);
  assert.equal((await h.request('shutdown',{protocolVersion:1})).result.resourcesReleased,false);
  const stops=(await h.events()).filter(e=>e.kind==='daemon-stopped');
  assert.ok(stops.some(e=>e.state?.endsWith('/device')));
  assert.ok(stops.some(e=>e.state===stops.find(e=>e.state?.endsWith('/device'))!.state!.replace(/\/device$/,'')));
 }finally{await h.dispose();}
});

test('Mac inventory uses the exact SDK selector while unqualified input ownership blocks acquisition',async()=>{
 const h=await harness('native-mac');try{
  const mac={id:'host-macos-local',platform:'macos',kind:'nativeMac',bundleId:'example.App',bundlePath:'/System/Applications/TextEdit.app',loginSession:'console-501'};
  assert.ok((await h.request('probe',{protocolVersion:1,target:mac})).result);
  assert.ok((await h.request('ui.acquire',{...acquire,target:mac})).error);
  assert.ok((await h.request('ui.acquire',{...acquire,target:mac})).error);
  assert.ok((await h.request('ui.runSegment',segment())).error);
  assert.equal((await h.request('shutdown',{protocolVersion:1})).result.resourcesReleased,true);
  const events=(await h.events()).filter(e=>e.kind==='capabilities'||e.kind==='open-start');
  assert.equal(events.length,1);
  assert.ok(events.every(e=>e.selector==='host-macos-local' && e.nameSelector===undefined));
  assert.equal((await h.events()).some(e=>['open-start','opened','worker-started','list-start'].includes(e.kind)),false);
 }finally{await h.dispose();}
});

test('inherited fill names cannot enter the worker or dispatch journal',async()=>{
 const h=await harness('pending-journal');try{
  assert.equal((await h.request('ui.acquire',acquire)).result.acquired,true);
  for(const binding of ['constructor','toString','__proto__']){
   const body={...segment('bad-'+binding),operations:[{id:'fill',kind:'fillBinding',locator:{kind:'testId',value:'name'},binding}],bindings:{}};
   const {payloadDigest:ignored,...payload}=body;body.payloadDigest=payloadDigest(payload);
   assert.ok((await h.request('ui.runSegment',body)).error);
  }
  assert.equal((await h.events()).some(e=>['worker-started','journal-pending'].includes(e.kind)),false);
  assert.equal((await h.request('ui.release',scope)).result.released,true);
 }finally{await h.dispose();}
});

test('SDK session close failure still stops its owned daemon without claiming release',async()=>{
 const h=await harness('close-failure');try{
  assert.equal((await h.request('ui.acquire',acquire)).result.acquired,true);
  const shutdown=await h.request('shutdown',{protocolVersion:1});
  assert.equal(shutdown.result.resourcesReleased,false);assert.equal(shutdown.result.cleanupReason,'sessionUnreleased');
  const events=await h.events();assert.ok(events.some(e=>e.kind==='session-closed'));
  assert.ok(events.some(e=>e.kind==='daemon-stopped'&&e.state?.endsWith('/device')));
  assert.ok((await h.request('ui.acquire',acquire)).error);
 }finally{await h.dispose();}
});
