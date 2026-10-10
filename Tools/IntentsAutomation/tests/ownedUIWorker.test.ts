import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import type {Duplex} from 'node:stream';
import {fileURLToPath} from 'node:url';
import {tmpdir} from 'node:os';
import {runOwnedUIWorker,OwnedUIWorkerError} from '../src/ownedUIWorker.js';

async function fixture(body:string){
 const root=await mkdtemp(join(tmpdir(),'intents-owned-ui-worker-'));
 const entry=join(root,'entry.mjs'),marker=join(root,'imported');
 await writeFile(entry,`import fs from 'node:fs';fs.writeFileSync(${JSON.stringify(marker)},String(process.pid));${body}`,{mode:0o600});
 return {root,entry,marker,remove:()=>rm(root,{recursive:true,force:true})};
}
const tick=()=>new Promise<void>(resolve=>setImmediate(resolve));
async function noImport(marker:string){await assert.rejects(readFile(marker),{code:'ENOENT'});}
function absent(pid:number){assert.throws(()=>process.kill(pid,0),{code:'ESRCH'});}

test('owned worker imports only after admission and drains both output pipes',async()=>{
 const f=await fixture("process.stdout.write('out');process.stderr.write('err');");
 try{
  let pid=0;
  const result=await runOwnedUIWorker(f.entry,[],f.root,{PATH:'/usr/bin:/bin'},new AbortController().signal,10000,async value=>{
   pid=value;await noImport(f.marker);assert.doesNotThrow(()=>process.kill(pid,0));
  });
  assert.equal(result.pid,pid);assert.equal(Number(await readFile(f.marker,'utf8')),pid);
  assert.match(result.logs,/out/);assert.match(result.logs,/err/);absent(pid);
 }finally{await f.remove();}
});
test('denied worker admission never imports the UI runtime and reaps the child',async()=>{
 const f=await fixture('');let pid=0;
 try{
  await assert.rejects(runOwnedUIWorker(f.entry,[],f.root,{},new AbortController().signal,10000,async value=>{pid=value;throw new Error('Native lease denied');}),error=>{
   assert.ok(error instanceof OwnedUIWorkerError);assert.equal(error.commandsDrained,true);assert.match(error.message,/Native lease denied/);return true;
  });
  await noImport(f.marker);absent(pid);
 }finally{await f.remove();}
});
test('cancelled suspended admission cannot acknowledge or import a late grant',async()=>{
 const f=await fixture('');const controller=new AbortController();let pid=0;
 let resume!:()=>void,entered!:()=>void;
 const entering=new Promise<void>(resolve=>{entered=resolve;});
 const pending=new Promise<void>(resolve=>{resume=resolve;});
 try{
  const run=runOwnedUIWorker(f.entry,[],f.root,{},controller.signal,10000,async value=>{pid=value;entered();await pending;});
  const rejected=assert.rejects(run,error=>error instanceof OwnedUIWorkerError && error.commandsDrained);
  await entering;controller.abort();await rejected;resume();await tick();
  await noImport(f.marker);absent(pid);
 }finally{resume();await f.remove();}
});
test('cancellation after import drains and reaps the running owned child',async()=>{
 const f=await fixture('setInterval(()=>{},1000);await new Promise(()=>{});');const controller=new AbortController();let pid=0;
 try{
  const run=runOwnedUIWorker(f.entry,[],f.root,{},controller.signal,10000,async value=>{pid=value;});
  const rejected=assert.rejects(run,error=>error instanceof OwnedUIWorkerError && error.commandsDrained);
  const deadline=Date.now()+5000;
  while(Date.now()<deadline){try{await readFile(f.marker);break;}catch{await tick();}}
  assert.equal(Number(await readFile(f.marker,'utf8')),pid);controller.abort();await rejected;absent(pid);
 }finally{controller.abort();await f.remove();}
});
test('nonzero worker exit preserves the log and negative operation result',async()=>{
 const f=await fixture("process.stderr.write('failed fixture');process.exitCode=4;");let pid=0;
 try{
  await assert.rejects(runOwnedUIWorker(f.entry,[],f.root,{},new AbortController().signal,10000,async value=>{pid=value;}),error=>{
   assert.ok(error instanceof OwnedUIWorkerError);assert.equal(error.commandsDrained,true);assert.equal(error.logs,'failed fixture');return true;
  });absent(pid);
 }finally{await f.remove();}
});
test('excess worker output fails rather than producing a successful truncated log',async()=>{
 const f=await fixture("process.stdout.write('x'.repeat(300000));");let pid=0;
 try{
  await assert.rejects(runOwnedUIWorker(f.entry,[],f.root,{},new AbortController().signal,10000,async value=>{pid=value;}),error=>{
   assert.ok(error instanceof OwnedUIWorkerError);assert.equal(error.commandsDrained,true);assert.ok(Buffer.byteLength(error.logs)<=256*1024);return true;
  });absent(pid);
 }finally{await f.remove();}
});
test('pre-cancelled worker cannot start or request native admission',async()=>{
 const f=await fixture('');const controller=new AbortController();controller.abort();let admissions=0;
 try{
  await assert.rejects(runOwnedUIWorker(f.entry,[],f.root,{},controller.signal,10000,async()=>{admissions++;}));
  assert.equal(admissions,0);await noImport(f.marker);
 }finally{await f.remove();}
});
test('invalid UTF-8 expansion cannot bypass the rendered log bound',async()=>{
 const f=await fixture("process.stdout.write(Buffer.alloc(65536,255));process.stdout.write(Buffer.alloc(65536,255));");
 try{
  await assert.rejects(runOwnedUIWorker(f.entry,[],f.root,{},new AbortController().signal,10000,async()=>{}),error=>{
   assert.ok(error instanceof OwnedUIWorkerError);assert.equal(error.commandsDrained,true);assert.ok(Buffer.byteLength(error.logs)<=256*1024);return true;
  });
 }finally{await f.remove();}
});
test('split multibyte output preserves exact UTF-8 text',async()=>{
 const f=await fixture("process.stdout.write(Buffer.from([0xe2]));await new Promise(r=>setTimeout(r,10));process.stdout.write(Buffer.from([0x82,0xac]));");
 try{
  const result=await runOwnedUIWorker(f.entry,[],f.root,{},new AbortController().signal,10000,async()=>{});
  assert.equal(result.logs,'€');
 }finally{await f.remove();}
});

const gate=fileURLToPath(new URL('../src/ownedUIWorkerGate.js',import.meta.url));
function spawnGate(entry:string,cwd:string,nonce:string|undefined,options:{gatePath?:string;readyTimeoutMs?:number;closeTimeoutMs?:number}={}){
 const env:NodeJS.ProcessEnv={PATH:'/usr/bin:/bin'};if(nonce!==undefined)env.INTENTS_UI_WORKER_NONCE=nonce;
 const child=spawn(process.execPath,[options.gatePath??gate,entry],{cwd,env,shell:false,stdio:['ignore','pipe','pipe','pipe']});
 const pipe=child.stdio[3] as Duplex;let stderr='';
 child.stderr!.setEncoding('utf8').on('data',(chunk:string)=>{stderr+=chunk;});
 pipe.on('error',()=>{});
 const closed=new Promise<{code:number|null,stderr:string}>(resolve=>child.once('close',code=>resolve({code,stderr})));
 const timers=new Set<ReturnType<typeof setTimeout>>();
 function bounded<T>(promise:Promise<T>,milliseconds:number,message:string):Promise<T>{
  return new Promise<T>((resolve,reject)=>{
   const timer=setTimeout(()=>reject(new Error(message)),milliseconds);timers.add(timer);
   void promise.then(resolve,reject).finally(()=>{clearTimeout(timer);timers.delete(timer);});
  });
 }
 const exited=bounded(closed,options.closeTimeoutMs??15000,'Gate close deadline expired');
 const ready=bounded(new Promise<Record<string,unknown>>((resolve,reject)=>{
  let bytes='';
  child.once('error',reject);
  pipe.on('data',(chunk:Buffer)=>{
   bytes+=chunk.toString('utf8');const end=bytes.indexOf('\n');if(end<0)return;
   try{resolve(JSON.parse(bytes.slice(0,end)));}catch(error){reject(error);}
  });
  void closed.then(()=>reject(new Error('Gate exited before ready')));
 }),options.readyTimeoutMs??5000,'Gate readiness deadline expired');
 void ready.catch(()=>{});void exited.catch(()=>{});
 async function dispose(){
  for(const timer of timers)clearTimeout(timer);timers.clear();
  if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');
  await bounded(closed,5000,'Gate cleanup deadline expired');
 }
 return {child,pipe,ready,exited,dispose};
}
async function refusedAck(ack:(nonce:string,pid:number)=>string,message:RegExp){
 const f=await fixture('');const nonce=randomBytes(32).toString('hex');let g:ReturnType<typeof spawnGate>|undefined;
 try{
  g=spawnGate(f.entry,f.root,nonce);const ready=await g.ready;
  assert.deepEqual(ready,{kind:'ready',nonce,pid:g.child.pid,ppid:process.pid});
  g.pipe.write(ack(nonce,g.child.pid!));
  const {code,stderr}=await g.exited;
  assert.notEqual(code,0);assert.match(stderr,message);await noImport(f.marker);
 }finally{try{await g?.dispose();}finally{await f.remove();}}
}
async function refusedStart(entry:(f:{entry:string})=>string,nonce:string|undefined){
 const f=await fixture('');let g:ReturnType<typeof spawnGate>|undefined;
 try{
  g=spawnGate(entry(f),f.root,nonce);const {code,stderr}=await g.exited;
  await assert.rejects(g.ready,/Gate exited before ready/);
  assert.notEqual(code,0);assert.match(stderr,/Owned worker gate unavailable/);await noImport(f.marker);
 }finally{try{await g?.dispose();}finally{await f.remove();}}
}
test('gate imports the entry for an exact acknowledgment from the owning pipe',async()=>{
 const f=await fixture('');const nonce=randomBytes(32).toString('hex');let g:ReturnType<typeof spawnGate>|undefined;
 try{
  g=spawnGate(f.entry,f.root,nonce);await g.ready;await noImport(f.marker);
  g.pipe.write(JSON.stringify({kind:'ack',nonce,pid:g.child.pid})+'\n');
  const {code}=await g.exited;
  assert.equal(code,0);assert.equal(Number(await readFile(f.marker,'utf8')),g.child.pid);
 }finally{try{await g?.dispose();}finally{await f.remove();}}
});
test('gate refuses an acknowledgment carrying a different nonce',()=>
 refusedAck((_,pid)=>JSON.stringify({kind:'ack',nonce:randomBytes(32).toString('hex'),pid})+'\n',/Worker acknowledgment invalid/));
test('gate refuses an acknowledgment for a different pid',()=>
 refusedAck((nonce,pid)=>JSON.stringify({kind:'ack',nonce,pid:pid+1})+'\n',/Worker acknowledgment invalid/));
test('gate refuses an acknowledgment with an extra key',()=>
 refusedAck((nonce,pid)=>JSON.stringify({kind:'ack',nonce,pid,grant:true})+'\n',/Worker acknowledgment invalid/));
test('gate refuses an acknowledgment of the wrong kind',()=>
 refusedAck((nonce,pid)=>JSON.stringify({kind:'ready',nonce,pid})+'\n',/Worker acknowledgment invalid/));
test('gate refuses a malformed acknowledgment frame',()=>
 refusedAck(()=>'{"kind":"ack"\n',/Worker acknowledgment invalid/));
test('gate refuses an unterminated acknowledgment beyond the 4096 byte bound',()=>
 refusedAck(()=>'x'.repeat(4097),/Worker acknowledgment exceeded bound/));
test('gate refuses a missing nonce environment',()=>refusedStart(f=>f.entry,undefined));
test('gate refuses a short nonce environment',()=>refusedStart(f=>f.entry,'ab'.repeat(16)));
test('gate refuses a non-lowercase-hex nonce environment',()=>refusedStart(f=>f.entry,'A'.repeat(64)));
test('gate refuses a relative entry even when it resolves from the working directory',()=>
 refusedStart(()=>'entry.mjs',randomBytes(32).toString('hex')));
test('gate acknowledgment expires and never imports without a reply',{timeout:20000},async()=>{
 const f=await fixture('');const nonce=randomBytes(32).toString('hex');let g:ReturnType<typeof spawnGate>|undefined;
 try{
  g=spawnGate(f.entry,f.root,nonce);await g.ready;const started=Date.now();
  const {code,stderr}=await g.exited;
  assert.notEqual(code,0);assert.match(stderr,/Worker ownership acknowledgment expired/);
  assert.ok(Date.now()-started>=9000);await noImport(f.marker);
 }finally{try{await g?.dispose();}finally{await f.remove();}}
});

test('gate fixture bounds missing readiness and reaps its child after failure',async()=>{
 const f=await fixture('setInterval(()=>{},1000);');let g:ReturnType<typeof spawnGate>|undefined;
 try{
  g=spawnGate(f.entry,f.root,undefined,{gatePath:f.entry,readyTimeoutMs:100});
  await assert.rejects(g.ready,/Gate readiness deadline expired/);
 }finally{try{await g?.dispose();}finally{await f.remove();}}
 absent(g!.child.pid!);
});
test('gate fixture bounds missing close and reaps a ready child after failure',async()=>{
 const f=await fixture(`fs.writeSync(3,JSON.stringify({kind:'ready'})+'\\n');setInterval(()=>{},1000);`);let g:ReturnType<typeof spawnGate>|undefined;
 try{
  g=spawnGate(f.entry,f.root,undefined,{gatePath:f.entry,closeTimeoutMs:300});
  await g.ready;await assert.rejects(g.exited,/Gate close deadline expired/);
 }finally{try{await g?.dispose();}finally{await f.remove();}}
 absent(g!.child.pid!);
});
