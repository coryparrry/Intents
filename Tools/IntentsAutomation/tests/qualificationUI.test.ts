import {test} from 'node:test';import assert from 'node:assert/strict';
import {spawn,type ChildProcess} from 'node:child_process';import {mkdtemp,writeFile,readFile,rm,stat,access} from 'node:fs/promises';
import {join} from 'node:path';import {fileURLToPath,pathToFileURL} from 'node:url';
import {segmentPayloadDigest} from '../src/payloadDigest.js';

// The real qualification entry and DeviceSession run in a child. Only the SDK,
// the scoped daemon cleanup and the worker are replaced by deterministic hooks.
const scope={protocolVersion:1 as const,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:1};
const target={id:'device',platform:'ios',kind:'simulator',bundleId:'example.App',bundlePath:null,loginSession:null};
const segment={scope,operationId:'operation',phase:'setup',bindings:{name:'Ada'},timeoutMs:1000,
 operations:[{id:'tap',kind:'tap',locator:{kind:'testId',value:'done'}},{id:'fill',kind:'fillBinding',locator:{kind:'testId',value:'name'},binding:'name'}]};
type Event={kind:string;action?:string;error?:string;digest?:string;state?:string};
async function qualify(options:{scenario?:string;args?:(profile:string)=>string[];profile?:(root:string)=>Record<string,unknown>;timeoutMs?:number;onSpawn?:(pid:number)=>void}={}){
 const root=await mkdtemp('/private/tmp/intents-qualification-');
 let child:ChildProcess|undefined,closed:Promise<number|null>|undefined,watchdog:ReturnType<typeof setTimeout>|undefined,returned=false;
 async function dispose(){
  clearTimeout(watchdog);
  try{
   if(child&&child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');
   await closed;
  }finally{await rm(root,{recursive:true,force:true});}
 }
 try{
 const entryURL=new URL('../src/qualificationUI.js',import.meta.url);
 const common=`import {appendFile} from 'node:fs/promises';import {join} from 'node:path';
 const root=process.env.INTENTS_TEST_ROOT, scenario=process.env.INTENTS_TEST_SCENARIO;
 async function event(kind,extra={}){await appendFile(join(root,'events.jsonl'),JSON.stringify({kind,...extra})+'\\n');}
 const device={id:'device',name:'same',platform:'ios',target:'mobile',kind:'simulator',identifiers:{udid:'device'}};
`;
 await writeFile(join(root,'sdk.mjs'),common+`
 export function createAgentDeviceClient(config){return {
 devices:{list:async()=>{await event('list');if(scenario==='hang'){setInterval(()=>{},1000);await new Promise(()=>{});}return [device]},capabilities:async()=>{await event('capabilities');return {device}}},
 apps:{open:async()=>{await event('opened');return {identifiers:{udid:device.id,appBundleId:'example.App'}}}},
 sessions:{close:async()=>{await event('session-closed')},list:async()=>[{name:config.session,device}]},
 capture:{snapshot:async()=>{await event('snapshot');return {refsGeneration:1,appBundleId:'example.App',identifiers:{session:config.session},
  nodes:[{index:0,kind:'button',label:'Done',identifier:'done'},{index:1,kind:'textField',label:'Name',identifier:'name',value:'secret',password:true}]}}},
 interactions:{press:async()=>{await event('press')},fill:async options=>{await event('fill',{text:options.text})},scroll:async()=>{await event('scroll')}}};}
 `);
 await writeFile(join(root,'lifecycle.mjs'),common+`export async function stopPrivateDaemon(state){await event('daemon-stopped',{state});
 if(scenario==='corrupt-events')await appendFile(join(root,'events.jsonl'),'{broken');
 if(scenario==='directory-events'){const fs=await import('node:fs/promises');await fs.rm(join(root,'events.jsonl'));await fs.mkdir(join(root,'events.jsonl'));}
 if(scenario==='large-output'){process.stdout.write('x'.repeat(300000));process.stderr.write('y'.repeat(300000));}
 return scenario==='unproved-release'?{released:false,reason:'test-only unproved release'}:{released:true,reason:'test-only deterministic release'};}`);
 // Dispatches each frozen operation through the real DeviceSession policy and records its outcome.
 await writeFile(join(root,'worker.mjs'),common+`
 export async function runWorker(session,_target,segment,_directory,signal){await event('worker-started',{digest:segment.payloadDigest});
  for(const operation of segment.operations){
   const action=operation.kind==='fillBinding'?{kind:'fill',value:segment.bindings[operation.binding]}:{kind:operation.kind};
   try{await session.perform('ref-'+operation.id,action,{timeoutMs:1000,signal});await event('allowed',{action:action.kind});}
   catch(error){await event('rejected',{action:action.kind,error:error.message});}
  }
  return {schemaVersion:1,scope:segment.scope,operationId:segment.operationId,complete:true,outputs:{}};}`);
 const hook=`import {registerHooks} from 'node:module';const entry=${JSON.stringify(entryURL.href)};const root=${JSON.stringify(pathToFileURL(root+'/').href)};
 registerHooks({resolve(specifier,context,next){
 if(specifier==='agent-device'&&context.parentURL?.endsWith('/src/deviceSession.js'))return {url:new URL('sdk.mjs',root).href,shortCircuit:true};
 if(specifier==='./lifecycle.js'&&context.parentURL?.endsWith('/src/deviceSession.js'))return {url:new URL('lifecycle.mjs',root).href,shortCircuit:true};
 if(specifier==='./workerRunner.js'&&context.parentURL===entry)return {url:new URL('worker.mjs',root).href,shortCircuit:true};
 return next(specifier,context);}});`;
 await writeFile(join(root,'hook.mjs'),hook);
 const evidence=join(root,'evidence'),profilePath=join(root,'profile.json');
 const profile={schemaVersion:1,target,scope,stateDirectory:join(root,'state'),evidenceDirectory:evidence,segment,approvedEffects:['activate','tap','fill'],
  ...options.profile?.(root)};
 await writeFile(profilePath,JSON.stringify(profile));
 child=spawn(process.execPath,['--import',join(root,'hook.mjs'),fileURLToPath(entryURL),...(options.args?.(profilePath)??['--profile',profilePath])],{
  env:{PATH:'/usr/bin:/bin',HOME:root,TMPDIR:'/private/tmp',INTENTS_TEST_ROOT:root,INTENTS_TEST_SCENARIO:options.scenario??'normal'},stdio:['ignore','pipe','pipe']});
 let stdout='',stderr='';child.stdout!.on('data',c=>{stdout+=String(c)});child.stderr!.on('data',c=>{stderr+=String(c)});
 let spawnError:Error|undefined,timedOut=false;
 closed=new Promise<number|null>(resolve=>{child!.once('error',error=>{spawnError=error;});child!.once('close',resolve);});
 watchdog=setTimeout(()=>{timedOut=true;child!.kill('SIGKILL');},options.timeoutMs??30000);
 options.onSpawn?.(child.pid!);
 const code=await closed;
 if(spawnError)throw spawnError;
 if(timedOut)throw new Error('Qualification fixture deadline expired');
 let contents:string;
 try{contents=await readFile(join(root,'events.jsonl'),'utf8');}
 catch(error){if((error as NodeJS.ErrnoException).code!=='ENOENT')throw error;contents='';}
 const events:Event[]=contents.trim().split('\n').filter(Boolean).map(line=>JSON.parse(line));
 const exists=async(name:string)=>{try{await access(join(evidence,name));return true;}catch{return false;}};
 const json=async(name:string)=>JSON.parse(await readFile(join(evidence,name),'utf8'));
 const mode=async(name:string)=>(await stat(join(evidence,name))).mode&0o777;
 returned=true;
 return {root,code,stdout,stderr,events,exists,json,mode,evidence,dispose};
 }finally{clearTimeout(watchdog);if(!returned)await dispose();}
}
const kinds=(events:Event[])=>events.map(e=>e.kind);

test('the entry refuses to run without exactly one explicit profile argument',async()=>{
 for(const args of [()=>[],(p:string)=>[p],(p:string)=>['--config',p],(p:string)=>['--profile',p,'extra']]){
  const q=await qualify({args});try{
   assert.notEqual(q.code,0);assert.match(q.stderr,/Explicit authorised qualification profile required/);
   assert.deepEqual(q.events,[]);assert.equal(await q.exists('.'),false);
  }finally{await q.dispose();}
 }
});

test('a profile without approved activation fails before any device SDK call',async()=>{
 const q=await qualify({profile:()=>({approvedEffects:['tap','fill','swipe']})});try{
  assert.notEqual(q.code,0);assert.match(q.stderr,/Activation is not approved/);
  assert.deepEqual(q.events,[]);assert.equal(await q.exists('.'),false);
 }finally{await q.dispose();}
});

test('an invalid profile is rejected before any device SDK call',async()=>{
 for(const change of [{approvedEffects:['activate','press']},{stateDirectory:'relative/state'},{unexpected:true}]){
  const q=await qualify({profile:()=>change});try{
   assert.notEqual(q.code,0);assert.match(q.stderr,/ZodError/);assert.deepEqual(q.events,[]);assert.equal(await q.exists('.'),false);
  }finally{await q.dispose();}
 }
});

test('the device policy dispatches only the action kinds the profile approves',async()=>{
 for(const [approved,allowed,rejected] of [[['activate','tap'],'tap','fill'],[['activate','fill'],'fill','tap']] as const){
  const q=await qualify({profile:()=>({approvedEffects:approved})});try{
   assert.equal(q.code,0,q.stderr);
   assert.deepEqual(q.events.filter(e=>e.kind==='allowed').map(e=>e.action),[allowed]);
   const refusal=q.events.filter(e=>e.kind==='rejected');
   assert.deepEqual(refusal.map(e=>e.action),[rejected]);assert.equal(refusal[0]!.error,'Qualification action is not approved');
   assert.equal(kinds(q.events).includes(rejected==='fill'?'fill':'press'),false);
   assert.equal(kinds(q.events).filter(k=>k===(allowed==='fill'?'fill':'press')).length,1);
   assert.equal((await q.json('release.json')).released,true);
  }finally{await q.dispose();}
 }
});

test('a segment scoped to a different lease fails without running and still records release',async()=>{
 const q=await qualify({profile:()=>({segment:{...segment,scope:{...scope,leaseGeneration:2}}})});try{
  assert.notEqual(q.code,0);assert.match(q.stderr,/Profile scope mismatch/);
  assert.equal(kinds(q.events).includes('worker-started'),false);
  assert.equal(kinds(q.events).includes('snapshot'),false);
  assert.ok(kinds(q.events).includes('session-closed'));
  assert.ok(q.events.some(e=>e.kind==='daemon-stopped'&&e.state===join(q.root,'state')));
  assert.equal(await q.exists('snapshot.json'),false);assert.equal(await q.exists('selection.json'),false);
  assert.deepEqual(await q.json('release.json'),{released:true,reason:'test-only deterministic release'});
  assert.equal(await q.mode('release.json'),0o600);
 }finally{await q.dispose();}
});

test('an unproved release is reported with a failing exit code',async()=>{
 const q=await qualify({scenario:'unproved-release'});try{
  assert.equal(q.code,1);
  assert.ok(await q.exists('snapshot.json'));
  assert.deepEqual(await q.json('release.json'),{released:false,reason:'test-only unproved release'});
  assert.deepEqual(JSON.parse(q.stdout.trim().split('\n').at(-1)!),{released:false,reason:'test-only unproved release'});
 }finally{await q.dispose();}
});

test('a released successful run writes private snapshot, selection and release evidence',async()=>{
 const q=await qualify();try{
  assert.equal(q.code,0,q.stderr);
  assert.deepEqual(kinds(q.events),['list','capabilities','opened','worker-started','press','allowed','fill','allowed','snapshot','session-closed','daemon-stopped']);
  assert.equal(q.events.find(e=>e.kind==='worker-started')!.digest,segmentPayloadDigest(segment));
  assert.equal((await stat(q.evidence)).mode&0o777,0o700);
  for(const name of ['snapshot.json','selection.json','release.json'])assert.equal(await q.mode(name),0o600,name);
  const snapshot=await q.json('snapshot.json');assert.equal(snapshot.appBundleId,'example.App');
  assert.equal(snapshot.nodes[1].value,undefined);
  assert.deepEqual(await q.json('selection.json'),{scope,sessionName:'intents-run-1',device:{id:'device',name:'same',platform:'ios',target:'mobile',kind:'simulator',identifiers:{udid:'device'}},observedBundleId:'example.App'});
  assert.deepEqual(await q.json('release.json'),{released:true,reason:'test-only deterministic release'});
  const [summary,release]=q.stdout.trim().split('\n').map(line=>JSON.parse(line));
  assert.deepEqual(summary,{targetID:'device',appBundleID:'example.App',nodes:[{kind:'button',label:'Done',identifier:'done'},{kind:'textField',label:'Name',identifier:'name'}]});
  assert.deepEqual(release,{released:true,reason:'test-only deterministic release'});
 }finally{await q.dispose();}
});

test('a profile without a segment captures evidence without starting a worker',async()=>{
 const q=await qualify({profile:()=>({segment:undefined})});try{
  assert.equal(q.code,0,q.stderr);
  assert.deepEqual(kinds(q.events),['list','capabilities','opened','snapshot','session-closed','daemon-stopped']);
  assert.ok(await q.exists('selection.json'));
 }finally{await q.dispose();}
});

test('qualification fixture drains large stdout and stderr before returning',async()=>{
 const q=await qualify({scenario:'large-output'});try{
  assert.equal(q.code,0);assert.equal(q.stderr,'y'.repeat(300000));
  assert.ok(q.stdout.includes('x'.repeat(300000)));
  assert.deepEqual(JSON.parse(q.stdout.slice(q.stdout.lastIndexOf('x')+1).trim()),{released:true,reason:'test-only deterministic release'});
 }finally{await q.dispose();}
});
test('qualification fixture rejects corrupt and unreadable event logs and cleans failed setup',async()=>{
 for(const scenario of ['corrupt-events','directory-events']){
  let root='',pid=0;
  const pending=qualify({scenario,profile:value=>{root=value;return {};},onSpawn:value=>{pid=value;}});
  try{await assert.rejects(pending,
   error=>scenario==='corrupt-events'?error instanceof SyntaxError:(error as NodeJS.ErrnoException).code==='EISDIR');}
  finally{await pending.then(q=>q.dispose(),()=>{});}
  await assert.rejects(access(root),{code:'ENOENT'});
  assert.throws(()=>process.kill(pid,0),{code:'ESRCH'});
 }
});
test('qualification fixture removes its directory when profile setup throws',async()=>{
 let root='';
 await assert.rejects(qualify({profile:value=>{root=value;throw new Error('fixture setup failed');}}),/fixture setup failed/);
 await assert.rejects(access(root),{code:'ENOENT'});
});
test('qualification fixture deadline reaps a hanging child and removes its directory',async()=>{
 let root='',pid=0;
 const pending=qualify({scenario:'hang',timeoutMs:300,profile:value=>{root=value;return {};},onSpawn:value=>{pid=value;}});
 try{await assert.rejects(pending,/Qualification fixture deadline expired/);}
 finally{await pending.then(q=>q.dispose(),()=>{});}
 await assert.rejects(access(root),{code:'ENOENT'});
 assert.throws(()=>process.kill(pid,0),{code:'ESRCH'});
});
