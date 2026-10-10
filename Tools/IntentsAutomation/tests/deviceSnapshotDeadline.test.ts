import {test} from 'node:test';import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';import {join} from 'node:path';
import {spawn} from 'node:child_process';import {fileURLToPath} from 'node:url';

test('production DeviceSession bounds cold snapshots and fences short, expired and cancelled callers',async()=>{
 const root=await mkdtemp('/private/tmp/intents-snapshot-deadline-');
 try{
  await writeFile(join(root,'sdk.mjs'),`
   const device={id:'device',platform:'ios',kind:'simulator',target:'mobile'};
   export const calls=[];export let onCapture=()=>{};export function setCapture(fn){onCapture=fn;}
   export function createAgentDeviceClient(config){return {
    devices:{list:async()=>[device],capabilities:async()=>({device})},
    apps:{open:async()=>({identifiers:{udid:'device',appBundleId:'example.App'}})},
    sessions:{list:async()=>[{name:config.session,device}]},
    capture:{snapshot:async options=>{calls.push(options);await onCapture();return {
     refsGeneration:1,appBundleId:'example.App',identifiers:{session:config.session},nodes:[]};}}
   };}
  `);
  await writeFile(join(root,'hook.mjs'),`
   import {registerHooks} from 'node:module';registerHooks({resolve(specifier,context,next){
    if(specifier==='agent-device'&&context.parentURL?.endsWith('/src/deviceSession.js'))
     return {url:new URL('./sdk.mjs',import.meta.url).href,shortCircuit:true};
    return next(specifier,context);}});
  `);
  await writeFile(join(root,'check.mjs'),`
   import assert from 'node:assert/strict';
   import {DeviceSession} from ${JSON.stringify(new URL('../src/deviceSession.js',import.meta.url).href)};
   import {calls,setCapture} from './sdk.mjs';
   const session=await DeviceSession.create(${JSON.stringify(join(root,'state'))},
    {id:'device',platform:'ios',kind:'simulator',bundleId:'example.App',bundlePath:null,loginSession:null},
    {protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:1},async()=>{});
   const controller=new AbortController();const context={runId:'run',attemptId:'attempt',origin:'test',signal:controller.signal,timeoutMs:120000};
   await session.snapshot();await session.snapshot(context);await session.snapshot({...context,timeoutMs:733});
   assert.deepEqual(calls.map(call=>call.timeoutMs),[60000,60000,733]);
   assert.ok(calls.every(call=>call.raw===true&&call.forceFull===true&&call.depth===24));
   for(const timeoutMs of [0,-1,NaN,Infinity,1.5])
    await assert.rejects(session.snapshot({...context,timeoutMs}),error=>error.code==='OPERATION_TIMEOUT');
   const cancelled=new AbortController();cancelled.abort();
   await assert.rejects(session.snapshot({...context,signal:cancelled.signal}),error=>error.code==='CANCELLED');
   assert.equal(calls.length,3);
   const realNow=Date.now;let now=realNow();Date.now=()=>now;
   try{
    setCapture(async()=>{now+=25});
    await assert.rejects(session.snapshot({...context,timeoutMs:5}),error=>error.code==='OPERATION_TIMEOUT');
   }finally{Date.now=realNow;}
   setCapture(async()=>controller.abort());
   await assert.rejects(session.snapshot(context),error=>error.code==='CANCELLED');
   assert.equal(calls.length,5);
  `);
  const child=spawn(process.execPath,['--import',join(root,'hook.mjs'),join(root,'check.mjs')],{
   env:{PATH:'/usr/bin:/bin',HOME:root,TMPDIR:'/private/tmp'},stdio:['ignore','pipe','pipe']});
  let output='';child.stdout.on('data',data=>output+=String(data));child.stderr.on('data',data=>output+=String(data));
  const timer=setTimeout(()=>child.kill('SIGKILL'),10000);
  const code=await new Promise<number|null>((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve)});clearTimeout(timer);
  assert.equal(code,0,output);
 }finally{await rm(root,{recursive:true,force:true});}
});
