import {test} from 'node:test';import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';import {join} from 'node:path';
import {spawn} from 'node:child_process';

// The production DeviceSession runs in a child process. Only the agent-device
// SDK and the private daemon cleanup are replaced by scripted module hooks.
async function runScenario(check:string){
 const root=await mkdtemp('/private/tmp/intents-device-session-');
 try{
  await writeFile(join(root,'sdk.mjs'),`
   export const device={id:'device',platform:'ios',kind:'simulator',target:'mobile'};
   export const sdk={};
   export function reset(){Object.assign(sdk,{configs:[],calls:[],devices:[device],opened:null,sessions:null,snapshot:null,gate:null,errors:{}});}
   reset();
   export function createAgentDeviceClient(config){sdk.configs.push(config);
    const record=(name,options)=>{sdk.calls.push([name,options]);const error=sdk.errors[name];if(error)throw error;};
    return {
     devices:{list:async()=>sdk.devices,capabilities:async()=>({device})},
     apps:{open:async options=>{record('open',options);return sdk.opened??{identifiers:{udid:'device',appBundleId:'example.App'}};}},
     sessions:{list:async()=>sdk.sessions??[{name:config.session,device}],close:async options=>record('close',options)},
     capture:{snapshot:async options=>{record('snapshot',options);if(sdk.gate)await sdk.gate;
      const base={refsGeneration:1,appBundleId:'example.App',identifiers:{session:config.session},nodes:[]};
      return sdk.snapshot?sdk.snapshot(base):base;}},
     interactions:{press:async options=>record('press',options),fill:async options=>record('fill',options),scroll:async options=>record('scroll',options)}
    };}
  `);
  await writeFile(join(root,'lifecycle.mjs'),`
   export const daemon={calls:[],result:{released:true,reason:'test-only release'}};
   export async function stopPrivateDaemon(stateDir){daemon.calls.push(stateDir);if(daemon.result instanceof Error)throw daemon.result;return daemon.result;}
  `);
  await writeFile(join(root,'hook.mjs'),`
   import {registerHooks} from 'node:module';registerHooks({resolve(specifier,context,next){
    if(context.parentURL?.endsWith('/src/deviceSession.js')){
     if(specifier==='agent-device')return {url:new URL('./sdk.mjs',import.meta.url).href,shortCircuit:true};
     if(specifier==='./lifecycle.js')return {url:new URL('./lifecycle.mjs',import.meta.url).href,shortCircuit:true};
    }
    return next(specifier,context);}});
  `);
  await writeFile(join(root,'check.mjs'),`
   import assert from 'node:assert/strict';
   import {readFile,writeFile,mkdir,stat,readdir,symlink} from 'node:fs/promises';import {join} from 'node:path';
   import {DeviceSession,DeviceAcquisitionError} from ${JSON.stringify(new URL('../src/deviceSession.js',import.meta.url).href)};
   import {sdk,reset,device} from './sdk.mjs';import {daemon} from './lifecycle.mjs';
   const root=${JSON.stringify(root)};
   const target={id:'device',platform:'ios',kind:'simulator',bundleId:'example.App',bundlePath:null,loginSession:null};
   const scope={protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:1};
   let dirs=0;const fresh=()=>join(root,'state-'+(++dirs));
   let policy=async()=>{};const policyCalls=[];
   const create=(dir=fresh())=>DeviceSession.create(dir,target,scope,async(...args)=>{policyCalls.push(args);await policy(...args);});
   const context=(extra={})=>({runId:'run',attemptId:'attempt',origin:'test',signal:new AbortController().signal,timeoutMs:120000,...extra});
   const calls=(...names)=>sdk.calls.filter(([name])=>names.includes(name));
   const interactions=()=>calls('press','fill','scroll');
   const engine=(code,message)=>error=>{assert.equal(error.name,'EngineError');assert.equal(error.code,code);assert.equal(error.retryable,false);
    if(message!==undefined)assert.equal(error.message,message);return true;};
   const plain=message=>error=>{assert.ok(!(error instanceof DeviceAcquisitionError));assert.equal(error.message,message);return true;};
   function resetAll(){reset();daemon.calls.length=0;daemon.result={released:true,reason:'test-only release'};policy=async()=>{};policyCalls.length=0;}
  `+check);
  const child=spawn(process.execPath,['--import',join(root,'hook.mjs'),join(root,'check.mjs')],{
   env:{PATH:'/usr/bin:/bin',HOME:root,TMPDIR:'/private/tmp'},stdio:['ignore','pipe','pipe']});
  let output='';child.stdout.on('data',data=>output+=String(data));child.stderr.on('data',data=>output+=String(data));
  const timer=setTimeout(()=>child.kill('SIGKILL'),20000);
  const code=await new Promise<number|null>((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve)});clearTimeout(timer);
  assert.equal(code,0,output);
 }finally{await rm(root,{recursive:true,force:true});}
}

test('DeviceSession.create claims empty state and rejects foreign, unowned or noncanonical state before creating a client',()=>runScenario(`
 const dir=fresh();await create(dir);
 assert.deepEqual(JSON.parse(await readFile(join(dir,'intents-owner.json'),'utf8')),{runId:'run',targetId:'device',bundleId:'example.App'});
 assert.equal((await stat(join(dir,'intents-owner.json'))).mode&0o777,0o600);
 assert.equal(sdk.configs.length,1);
 assert.deepEqual(sdk.configs[0],{stateDir:dir,session:'intents-run-1',cwd:dir,lockPolicy:'reject'});
 assert.deepEqual(calls('open'),[['open',{platform:'ios',udid:'device',app:'example.App',relaunch:false}]]);
 await writeFile(join(dir,'evidence.json'),'{}');await create(dir);
 assert.equal(sdk.configs.length,2,'the same owner may reacquire its nonempty state directory');
 for(const owner of [{runId:'other',targetId:'device',bundleId:'example.App'},{runId:'run',targetId:'other',bundleId:'example.App'},
  {runId:'run',targetId:'device',bundleId:'other.App'}]){
  const foreign=fresh();await mkdir(foreign,{recursive:true});const marker=JSON.stringify(owner);
  await writeFile(join(foreign,'intents-owner.json'),marker);
  await assert.rejects(create(foreign),plain('Foreign device state directory'));
  assert.equal(await readFile(join(foreign,'intents-owner.json'),'utf8'),marker);
 }
 const unowned=fresh();await mkdir(unowned,{recursive:true});await writeFile(join(unowned,'other-run.json'),'{}');
 await assert.rejects(create(unowned),plain('Unowned nonempty device state directory'));
 assert.deepEqual(await readdir(unowned),['other-run.json']);
 const corrupt=fresh();await mkdir(corrupt,{recursive:true});await writeFile(join(corrupt,'intents-owner.json'),'not json');
 await assert.rejects(create(corrupt),error=>error instanceof SyntaxError);
 const real=fresh();await mkdir(real,{recursive:true});const link=fresh();await symlink(real,link);
 await assert.rejects(create(link),plain('Noncanonical private device state'));
 assert.deepEqual(await readdir(real),[]);
 assert.equal(sdk.configs.length,2);assert.deepEqual(daemon.calls,[]);
`));

test('DeviceSession.create reports DeviceAcquisitionError with the cleanup outcome when the backend selects another app or target',()=>runScenario(`
 for(const [identifiers,result,released] of [
  [{udid:'other',appBundleId:'example.App'},{released:true,reason:'test-only release'},true],
  [{udid:'device',appBundleId:'other.App'},{released:false,reason:'test-only unproved release'},false],
  [{deviceId:'other',appBundleId:'example.App'},new Error('daemon stop crashed'),false],
  [{udid:'device'},{released:true,reason:'test-only release'},true]]){
  resetAll();sdk.opened={identifiers};daemon.result=result;const dir=fresh();
  await assert.rejects(create(dir),error=>{assert.ok(error instanceof DeviceAcquisitionError);assert.equal(error.released,released);
   assert.equal(error.message,'Exact device acquisition failed; release '+(released?'proved':'unverified'));return true;});
  assert.deepEqual(daemon.calls,[dir]);
 }
 resetAll();sdk.devices=[];const missing=fresh();
 await assert.rejects(create(missing),error=>error instanceof DeviceAcquisitionError&&error.released===true);
 assert.deepEqual(calls('open'),[],'no app is activated on an unselected target');assert.deepEqual(daemon.calls,[missing]);
 resetAll();sdk.opened={identifiers:{deviceId:'device',appBundleId:'example.App'}};
 assert.ok(await create() instanceof DeviceSession);assert.deepEqual(daemon.calls,[]);
`));

test('DeviceSession.perform dispatches after the policy and maps backend failures to non-retryable ACTION_MAY_HAVE_COMMITTED',()=>runScenario(`
 const session=await create();
 await session.perform('e1',{kind:'tap'},context(),'node-1');
 await session.perform('e2',{kind:'fill',value:'hello',sensitive:false},context());
 await session.perform('e3',{kind:'swipe',direction:'down'},context());
 assert.deepEqual(interactions(),[['press',{ref:'e1',verify:true}],['fill',{ref:'e2',text:'hello',verify:true}],['scroll',{direction:'down'}]]);
 assert.equal(policyCalls.length,3);
 assert.deepEqual(policyCalls[0][0],scope);assert.deepEqual(policyCalls[0][1],{kind:'tap'});assert.equal(policyCalls[0][2].origin,'test');
 assert.equal(policyCalls[0][3],'node-1');
 for(const [name,action] of [['press',{kind:'tap'}],['fill',{kind:'fill',value:'x',sensitive:false}],['scroll',{kind:'swipe',direction:'up'}]]){
  const cause=new Error(name+' transport lost');sdk.errors[name]=cause;
  await assert.rejects(session.perform('e',action,context()),error=>engine('ACTION_MAY_HAVE_COMMITTED','Backend action outcome is unresolved')(error)&&error.cause===cause);
  delete sdk.errors[name];
 }
 assert.equal(interactions().length,6);
 assert.deepEqual(await session.release(),{released:true,reason:'test-only release'},'failed commands leave no command in flight');
`));

test('DeviceSession.perform refuses secret fills, unsupported kinds, policy denials and dead contexts without touching the device',()=>runScenario(`
 const session=await create();
 await assert.rejects(session.perform('e',{kind:'fill',value:'hunter2',sensitive:true},context()),engine('UNSUPPORTED_CAPABILITY','Secret filling is not qualified'));
 await assert.rejects(session.perform('e',{kind:'doubleTap'},context()),engine('UNSUPPORTED_CAPABILITY','Unsupported action doubleTap'));
 const denial=new Error('Policy denied');policy=async()=>{throw denial;};
 await assert.rejects(session.perform('e',{kind:'tap'},context()),error=>error===denial);
 policy=async()=>{};const cancelled=new AbortController();cancelled.abort();
 await assert.rejects(session.perform('e',{kind:'tap'},context({signal:cancelled.signal})),engine('CANCELLED'));
 const during=new AbortController();policy=async()=>during.abort();
 await assert.rejects(session.perform('e',{kind:'tap'},context({signal:during.signal})),engine('CANCELLED'));
 policy=async()=>{};
 await assert.rejects(session.perform('e',{kind:'tap'},context({timeoutMs:0})),engine('OPERATION_TIMEOUT'));
 assert.deepEqual(interactions(),[]);
 assert.equal(policyCalls.length,4,'pre-dispatch deadline and cancellation checks run before the policy');
`));

test('DeviceSession.snapshot proves session identity, strips password values and stops at the capture limit',()=>runScenario(`
 const dir=fresh();const session=await create(dir);
 sdk.snapshot=base=>({...base,nodes:[{index:0,type:'TextField',value:'visible'},
  {index:1,parentIndex:0,type:'SecureTextField',password:true,value:'hunter2',label:'Password'}]});
 const result=await session.snapshot();
 assert.deepEqual(result.nodes,[{index:0,type:'TextField',value:'visible'},{index:1,parentIndex:0,type:'SecureTextField',password:true,label:'Password'}]);
 assert.ok(!('value' in result.nodes[1]));
 assert.deepEqual(session.selectionEvidence,{scope,sessionName:'intents-run-1',device,observedBundleId:'example.App'});
 const metadata=await readFile(join(dir,'generation-1-snapshot-1.metadata.json'),'utf8');
 assert.ok(!metadata.includes('hunter2'));
 assert.equal(JSON.parse(metadata).nodes,2);assert.equal(JSON.parse(metadata).session,'intents-run-1');
 for(const mismatch of [base=>({...base,identifiers:{session:'intents-other-1'}}),base=>({...base,appBundleId:'other.App'}),
  base=>({...base,identifiers:{}})]){
  sdk.snapshot=mismatch;await assert.rejects(session.snapshot(),plain('Snapshot/session identity mismatch'));
 }
 sdk.snapshot=null;
 for(const sessions of [[],[{name:'intents-run-1',device:{...device,id:'other'}}],[{name:'intents-run-1',device},{name:'intents-run-1',device}]]){
  sdk.sessions=sessions;await assert.rejects(session.snapshot(),plain('Snapshot/session identity mismatch'));
 }
 sdk.sessions=null;
 for(let capture=8;capture<=512;capture++)await session.snapshot();
 assert.equal(calls('snapshot').length,512);
 await assert.rejects(session.snapshot(),engine('ENGINE_FAILURE','Capture limit reached'));
 assert.equal(calls('snapshot').length,512,'the 513th capture never reaches the device');
`));

test('DeviceSession.release refuses while commands run and reports session and daemon cleanup failures',()=>runScenario(`
 let open;sdk.gate=new Promise(resolve=>open=resolve);
 const dir=fresh();const session=await create(dir);const pending=session.snapshot();
 assert.deepEqual(await session.release(),{released:false,reason:'Commands are still running'});
 assert.deepEqual(calls('close'),[]);assert.deepEqual(daemon.calls,[]);
 await assert.rejects(session.snapshot(),plain('UI lease is closing'));
 await assert.rejects(session.perform('e',{kind:'tap'},context()),plain('UI lease is closing'));
 assert.deepEqual(interactions(),[]);assert.equal(calls('snapshot').length,1);
 open();await pending;
 assert.deepEqual(await session.release(),{released:true,reason:'test-only release'});
 assert.deepEqual(calls('close'),[['close',{saveScript:false}]]);assert.deepEqual(daemon.calls,[dir]);
 for(const [closeError,result,expected] of [
  [null,new Error('daemon stop crashed'),{released:false,reason:'Private daemon cleanup failed'}],
  [new Error('SDK lifecycle cleanup failed'),{released:true,reason:'test-only release'},{released:false,reason:'Owned session close failed'}],
  [new Error('SDK lifecycle cleanup failed'),new Error('daemon stop crashed'),{released:false,reason:'Private daemon cleanup failed'}],
  [null,{released:false,reason:'test-only unproved release'},{released:false,reason:'test-only unproved release'}]]){
  resetAll();const dir=fresh();const session=await create(dir);
  if(closeError)sdk.errors.close=closeError;daemon.result=result;
  assert.deepEqual(await session.release(),expected);
  assert.equal(calls('close').length,1);assert.deepEqual(daemon.calls,[dir],'daemon cleanup is always attempted');
 }
`));
