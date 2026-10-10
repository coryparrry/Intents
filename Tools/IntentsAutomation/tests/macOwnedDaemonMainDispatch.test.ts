import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,realpath,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {privateFillHelperSHA256} from '../src/macOwnedHelperProvider.js';

// Runs the real private entry with only the SDK and daemon composition replaced by module hooks.
async function harness(releaseResources:boolean){
  const root=await realpath(await mkdtemp(join(tmpdir(),'intents-daemon-main-')));
  const app=join(root,'Fixture.app');await mkdir(app);
  const mainURL=new URL('../src/macOwnedDaemonMain.js',import.meta.url);
  const instance={bundleId:'example.Fixture',canonicalBundlePath:app,pid:123,processStartIdentity:'100:0'};
  await writeFile(join(root,'sdk.mjs'),'export const synthetic=true;\n');
  await writeFile(join(root,'daemon.mjs'),`const instance=${JSON.stringify(instance)};
export class MacOwnedDaemon {
  static async start(){return new MacOwnedDaemon();}
  get transport(){return {
    open:async()=>({applicationTarget:{...instance},deviceId:'fixture-mac',sessionName:'session',appBundleId:instance.bundleId}),
    capture:async()=>({applicationTarget:{...instance},nodes:[]}),
    press:async(_instance,point)=>({applicationTarget:{...instance},...point,disposition:'submittedUnconfirmed',releaseSubmitted:true})};}
  async cleanup(scope,applicationTarget){return {scope,applicationTarget,commandsDrained:true,ownedHelperReaped:true,daemonStopped:${releaseResources}};}
}
`);
  await writeFile(join(root,'hook.mjs'),`import {registerHooks} from 'node:module';
const main=${JSON.stringify(mainURL.href)},root=${JSON.stringify(pathToFileURL(root+'/').href)};
registerHooks({resolve(specifier,context,next){
  if(context.parentURL===main&&specifier==='./macOwnedDaemon.js')return {url:new URL('daemon.mjs',root).href,shortCircuit:true};
  if(context.parentURL===main&&specifier.endsWith('/sdk/dist/src/intents-daemon.js'))return {url:new URL('sdk.mjs',root).href,shortCircuit:true};
  return next(specifier,context);}});
`);
  const child=spawn(process.execPath,['--import',join(root,'hook.mjs'),fileURLToPath(mainURL),'--state-dir',join(root,'state')],
    {env:{PATH:'/usr/bin:/bin',HOME:root},stdio:['pipe','pipe','pipe']});
  let text='',diagnostics='',sequence=0;const pending=new Map<string,(frame:any)=>void>();
  child.stderr.on('data',chunk=>{diagnostics=(diagnostics+chunk).slice(-65536);});
  child.stdout.on('data',chunk=>{text+=chunk;let index;
    while((index=text.indexOf('\n'))>=0){const frame=JSON.parse(text.slice(0,index));text=text.slice(index+1);pending.get(frame.id)?.(frame);pending.delete(frame.id);}});
  const exited=new Promise<number|null>((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);});
  const request=(method:string,params:unknown)=>new Promise<any>((resolve,reject)=>{
    const id='test-'+(++sequence),timer=setTimeout(()=>reject(new Error('Deadline '+method+' '+diagnostics)),10000);
    pending.set(id,frame=>{clearTimeout(timer);resolve(frame);});
    child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');});
  const finish=async()=>{child.stdin.end();const watchdog=setTimeout(()=>child.kill('SIGKILL'),5000);
    const code=await exited;clearTimeout(watchdog);await rm(root,{recursive:true,force:true});return code;};
  return {app,instance,request,finish};
}
const scope={protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:1};
const rejected=(frame:any,pattern?:RegExp)=>{assert.equal(frame.result,undefined);assert.ok(frame.error,'expected an error frame');
  if(pattern)assert.match(frame.error.message,pattern);};

test('private daemon entry admits one scoped session and rejects out-of-contract dispatch',async()=>{
  const h=await harness(true);
  let code:number|null|undefined;
  try{
    const hello={scope,target:{id:'fixture-mac',platform:'macos',kind:'nativeMac',bundleId:h.instance.bundleId,bundlePath:h.app,loginSession:'synthetic'},
      authentication:'b'.repeat(64),helperSHA256:privateFillHelperSHA256};
    rejected(await h.request('ui.acquire',{scope}),/Private daemon unavailable/);
    rejected(await h.request('hello',{...hello,helperSHA256:'a'.repeat(64)}));
    const first=await h.request('hello',hello);
    assert.equal(first.result.artifactVariant,'private-owned-mac-daemon-integration');assert.equal(first.result.customerRuntimeEnabled,false);
    rejected(await h.request('hello',hello),/lifetime unavailable/);
    rejected(await h.request('ui.acquire',{scope:{...scope,runId:'other'}}),/Different private daemon scope/);
    assert.deepEqual((await h.request('ui.acquire',{scope})).result,{applicationTarget:h.instance});
    rejected(await h.request('ui.acquire',{scope}),/already acquired/);
    const segment={scope,applicationTarget:h.instance,timeoutMs:1000};
    rejected(await h.request('ui.runSegment',{...segment,operation:'capture',x:1,y:2}),/Capture does not accept a point/);
    rejected(await h.request('ui.runSegment',{...segment,operation:'press',x:1}),/Press requires a point/);
    rejected(await h.request('ui.runSegment',{...segment,operation:'press',x:1,y:2,applicationTarget:{...h.instance,pid:124}}),/Different Mac application instance/);
    rejected(await h.request('ui.runSegment',{...segment,operation:'press',x:1,y:2,timeoutMs:60001}));
    assert.deepEqual((await h.request('ui.runSegment',{...segment,operation:'capture'})).result,{applicationTarget:h.instance,nodes:[]});
    assert.equal((await h.request('ui.runSegment',{...segment,operation:'press',x:1,y:2})).result.x,1);
    const shutdown=await h.request('shutdown',{});
    assert.equal(shutdown.result.resourcesReleased,true);
    rejected(await h.request('ui.runSegment',{...segment,operation:'capture'}),/Private daemon unavailable/);
    rejected(await h.request('status',{}),/Private daemon unavailable/);
    rejected(await h.request('hello',hello),/lifetime unavailable/);
  }finally{code=await h.finish();}
  assert.equal(code,0);
});

test('private daemon entry exits nonzero when cleanup cannot prove resources released',async()=>{
  const h=await harness(false);
  let code:number|null|undefined;
  try{
    const first=await h.request('hello',{scope,target:{id:'fixture-mac',platform:'macos',kind:'nativeMac',bundleId:h.instance.bundleId,bundlePath:h.app,loginSession:'synthetic'},
      authentication:'b'.repeat(64),helperSHA256:privateFillHelperSHA256});
    assert.ok(first.result);
    const shutdown=await h.request('shutdown',{});
    assert.equal(shutdown.result.resourcesReleased,false);assert.equal(shutdown.result.daemonStopped,false);
  }finally{code=await h.finish();}
  assert.equal(code,1);
});
