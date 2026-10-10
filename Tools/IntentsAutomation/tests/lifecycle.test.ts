import {test,before,after} from 'node:test';import assert from 'node:assert/strict';
import {registerHooks} from 'node:module';import {mkdtemp,mkdir,writeFile,readFile,rm,access} from 'node:fs/promises';
import {join} from 'node:path';import {pathToFileURL} from 'node:url';

// The real stopPrivateDaemon runs unmodified. Only the `agent-device` package it
// resolves is replaced by a temp package whose pinned bin prints a canned report.
const root=await mkdtemp('/private/tmp/intents-lifecycle-');const pkg=join(root,'agent-device');
const qualifiedManifest={name:'agent-device',version:'0.21.20',type:'module',bin:{'agent-device':'bin/agent-device.mjs'}};
const binPath=join(pkg,'bin','agent-device.mjs'),indexURL=pathToFileURL(join(pkg,'dist','src','index.js')).href;
await mkdir(join(pkg,'bin'),{recursive:true});await mkdir(join(pkg,'dist','src'),{recursive:true});
await writeFile(join(pkg,'package.json'),JSON.stringify(qualifiedManifest));
await writeFile(binPath,`import {writeFileSync,readFileSync,existsSync} from 'node:fs';
 writeFileSync('invocation.json',JSON.stringify({argv:process.argv.slice(1),cwd:process.cwd(),env:process.env}));
 if(existsSync('daemon-stdout.txt'))process.stdout.write(readFileSync('daemon-stdout.txt','utf8'));
 if(existsSync('daemon-exit-code'))process.exitCode=Number(readFileSync('daemon-exit-code','utf8'));
`);
await writeFile(join(pkg,'dist','src','index.js'),`
 export const control={openFails:false,closeFails:false};
 const device={id:'device',platform:'ios',kind:'simulator',target:'mobile'};
 export function createAgentDeviceClient(config){return {
  devices:{list:async()=>[device],capabilities:async()=>({device})},
  apps:{open:async()=>{if(control.openFails)throw new Error('open failed');return {identifiers:{udid:'device',appBundleId:'example.App'}};}},
  sessions:{close:async()=>{if(control.closeFails)throw new Error('close failed');},list:async()=>[{name:config.session,device}]}};}
`);
registerHooks({resolve(specifier,context,next){
 if(specifier==='agent-device'&&(context.parentURL?.endsWith('/src/lifecycle.js')||context.parentURL?.endsWith('/src/deviceSession.js')))
  return {url:indexURL,shortCircuit:true};
 return next(specifier,context);}});
const {stopPrivateDaemon}=await import('../src/lifecycle.js');
const {DeviceSession,DeviceAcquisitionError}=await import('../src/deviceSession.js');
const {control}=await import(indexURL) as {control:{openFails:boolean;closeFails:boolean}};

const proved='Scoped daemon stop reports known release with no orphaned or unattributable claims';
const unproved='Owned runner termination could not be proved by scoped daemon cleanup';
function cleanReport(){return {success:true,data:{cleanupConfidence:'known',claimsOrphaned:[],claimsUnattributable:[],warnings:[],
 providerReleases:{status:'completed',pending:[]}}};}
let sequence=0;
async function stateDir(stdout?:string,exitCode?:number){const dir=join(root,'state-'+(++sequence));await mkdir(dir);
 if(stdout!==undefined)await writeFile(join(dir,'daemon-stdout.txt'),stdout);
 if(exitCode!==undefined)await writeFile(join(dir,'daemon-exit-code'),String(exitCode));return dir;}
async function invocation(dir:string){return JSON.parse(await readFile(join(dir,'invocation.json'),'utf8')) as {argv:string[];cwd:string;env:Record<string,string>};}
async function withManifest(manifest:unknown,body:()=>Promise<void>){
 await writeFile(join(pkg,'package.json'),JSON.stringify(manifest));
 try{await body();}finally{await writeFile(join(pkg,'package.json'),JSON.stringify(qualifiedManifest));}}
const scope={protocolVersion:1 as const,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:1};
const target={id:'device',platform:'ios' as const,kind:'simulator' as const,bundleId:'example.App',bundlePath:null,loginSession:null};
async function writeReport(dir:string,stdout:string,exitCode?:number){await writeFile(join(dir,'daemon-stdout.txt'),stdout);
 if(exitCode!==undefined)await writeFile(join(dir,'daemon-exit-code'),String(exitCode));}

before(()=>{process.env.INTENTS_LIFECYCLE_SENTINEL='must-not-leak';});
after(async()=>{delete process.env.INTENTS_LIFECYCLE_SENTINEL;control.openFails=false;control.closeFails=false;await rm(root,{recursive:true,force:true});});

test('clean known report proves release through the exact scoped daemon stop invocation',async()=>{
 const dir=await stateDir(JSON.stringify(cleanReport()));
 assert.deepEqual(await stopPrivateDaemon(dir),{released:true,reason:proved});
 const call=await invocation(dir);
 assert.deepEqual(call.argv,[binPath,'daemon','stop','--state-dir',dir,'--clean','--json']);
 assert.equal(call.cwd,dir);
 assert.equal(call.env.PATH,'/usr/bin:/bin:/usr/sbin:/sbin');assert.equal(call.env.HOME,dir);assert.equal(call.env.TMPDIR,dir);
 assert.equal(call.env.AGENT_DEVICE_STATE_DIR,dir);assert.equal(call.env.AGENT_DEVICE_NO_UPDATE_NOTIFIER,'1');
 assert.equal(call.env.INTENTS_LIFECYCLE_SENTINEL,undefined);
});

test('any orphaned, unattributable, warning or pending claim fails closed',async()=>{
 const mutations:Array<[string,(report:any)=>void]>=[
  ['orphaned claim',r=>{r.data.claimsOrphaned=[{device:'device'}];}],
  ['unattributable claim',r=>{r.data.claimsUnattributable=[{pid:42}];}],
  ['warning',r=>{r.data.warnings=['runner still alive'];}],
  ['pending provider release',r=>{r.data.providerReleases.pending=[{provider:'xctest'}];}],
  ['incomplete provider releases',r=>{r.data.providerReleases.status='partial';}],
  ['unknown cleanup confidence',r=>{r.data.cleanupConfidence='unknown';}],
  ['unsuccessful stop',r=>{r.success=false;}],
  ['missing claim list',r=>{delete r.data.claimsOrphaned;}],
  ['missing provider releases',r=>{delete r.data.providerReleases;}],
  ['missing data',r=>{delete r.data;}]];
 for(const [name,mutate] of mutations){
  const report=cleanReport();mutate(report);
  assert.deepEqual(await stopPrivateDaemon(await stateDir(JSON.stringify(report))),{released:false,reason:unproved},name);
 }
});

test('unparseable daemon output fails closed instead of throwing',async()=>{
 for(const stdout of ['','not json','{"success":true',JSON.stringify(cleanReport())+'\ntrailing','null','[]'])
  assert.deepEqual(await stopPrivateDaemon(await stateDir(stdout)),{released:false,reason:unproved},JSON.stringify(stdout));
});

test('an unqualified agent-device version or bin path is rejected before running anything',async()=>{
 const manifests=[{...qualifiedManifest,version:'0.21.21'},{...qualifiedManifest,bin:{'agent-device':'bin/other.mjs'}},
  {...qualifiedManifest,bin:'bin/agent-device.mjs'},(({bin,...rest})=>rest)(qualifiedManifest)];
 for(const manifest of manifests)await withManifest(manifest,async()=>{
  const dir=await stateDir(JSON.stringify(cleanReport()));
  await assert.rejects(stopPrivateDaemon(dir),/Unqualified agent-device package/,JSON.stringify(manifest));
  await assert.rejects(access(join(dir,'invocation.json')),{code:'ENOENT'});
 });
});

test('a daemon stop that exits non-zero rejects even with a clean report',async()=>{
 await assert.rejects(stopPrivateDaemon(await stateDir(JSON.stringify(cleanReport()),3)),(error:{code?:unknown})=>error.code===3);
});

test('DeviceSession.release returns the daemon proof and maps daemon failure to cleanup failure',async()=>{
 async function session(){const dir=join(root,'session-'+(++sequence));return {dir,session:await DeviceSession.create(dir,target,scope,async()=>{})};}
 let s=await session();await writeReport(s.dir,JSON.stringify(cleanReport()));
 assert.deepEqual(await s.session.release(),{released:true,reason:proved});
 const orphaned=cleanReport();orphaned.data.claimsOrphaned=[{device:'device'}] as never[];
 s=await session();await writeReport(s.dir,JSON.stringify(orphaned));
 assert.deepEqual(await s.session.release(),{released:false,reason:unproved});
 s=await session();await writeReport(s.dir,JSON.stringify(cleanReport()),1);
 assert.deepEqual(await s.session.release(),{released:false,reason:'Private daemon cleanup failed'});
 control.closeFails=true;
 try{s=await session();await writeReport(s.dir,JSON.stringify(cleanReport()));
  assert.deepEqual(await s.session.release(),{released:false,reason:'Owned session close failed'});
  assert.equal((await invocation(s.dir)).argv[1],'daemon');}
 finally{control.closeFails=false;}
});

test('failed acquisition reports release proved only when the daemon report proves it',async()=>{
 async function failedAcquire(stdout:string,exitCode?:number){const dir=join(root,'acquire-'+(++sequence));
  await mkdir(dir);await writeFile(join(dir,'intents-owner.json'),JSON.stringify({runId:scope.runId,targetId:target.id,bundleId:target.bundleId}));
  await writeReport(dir,stdout,exitCode);
  const error=await DeviceSession.create(dir,target,scope,async()=>{}).then(()=>assert.fail('acquisition succeeded'),(e:unknown)=>e);
  assert.ok(error instanceof DeviceAcquisitionError);return error;}
 control.openFails=true;
 try{
  const clean=await failedAcquire(JSON.stringify(cleanReport()));assert.equal(clean.released,true);assert.match(clean.message,/release proved$/);
  const unknown=cleanReport();unknown.data.cleanupConfidence='unknown';
  const unproven=await failedAcquire(JSON.stringify(unknown));assert.equal(unproven.released,false);assert.match(unproven.message,/release unverified$/);
  assert.equal((await failedAcquire(JSON.stringify(cleanReport()),2)).released,false);
 }finally{control.openFails=false;}
});
