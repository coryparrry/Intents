import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
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
