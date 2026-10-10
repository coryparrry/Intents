import test from 'node:test';import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';import {mkdtemp,rm,readFile} from 'node:fs/promises';
import {join} from 'node:path';import {pathToFileURL} from 'node:url';
import {nativePayloadDigest} from '../src/payloadDigest.js';
import {OperationJournal} from '../src/operationJournal.js';
import {SecretProgramController} from '../src/secretProgramController.js';
import type {Scope} from '../src/protocol.js';
const scope:Scope={protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'setup',leaseGeneration:1};
const reference='FC630209-A968-416D-B23C-98CCE968CA83',sentinel='SYNTHETIC-NATIVE-SECRET-ERROR';
function program(extra:object={}){const body={scope,operationId:'secret-program',phase:'setup',operations:[{id:'__proto__',kind:'fillSecretBinding',binding:'10'}],
 bindings:{'10':reference},timeoutMs:30000,...extra};return {...body,payloadDigest:nativePayloadDigest(body)};}
for(const mode of ['valid','wrong-scope','bad-reference','uncertain','timeout','stop-held','eof-held'])
 test(`secret-only owned entry: ${mode}`,{timeout:15000},async()=>{
  const root=await mkdtemp('/private/tmp/intents-secret-entry-');
  const unit=process.env.INTENTS_PRIVATE_SECRET_DAEMON_UNIT;
  const entry=unit?join(unit,'sidecar/src/secretProgramMain.js'):new URL('../src/secretProgramMain.js',import.meta.url).pathname;
  const child=spawn(unit?join(unit,'node'):process.execPath,['--import',pathToFileURL(new URL('./fixtures/secretProgramHostGuard.js',import.meta.url).pathname).href,entry,'--state-dir',root],
   {env:{PATH:'/usr/bin:/bin'},stdio:['pipe','pipe','pipe']});
  let lines='',stderr='',sequence=0,calls=0,held:undefined|{id:string;params:any},ready!:()=>void;
  const entered=new Promise<void>(resolve=>{ready=resolve;});
  const pending=new Map<string,{resolve:(v:any)=>void;reject:(e:Error)=>void}>();
  const send=(message:object)=>child.stdin.write(JSON.stringify(message)+'\n');
  const request=(method:string,params:unknown)=>new Promise<any>((resolve,reject)=>{const id='host-'+(++sequence);pending.set(id,{resolve,reject});send({jsonrpc:'2.0',id,method,params});});
  const respond=(message:{id:string;params:any},error=false)=>send(error?{jsonrpc:'2.0',id:message.id,error:{code:-32000,message:sentinel}}:
   {jsonrpc:'2.0',id:message.id,result:{scope:message.params.scope,operationId:message.params.operationId,disposition:'submittedUnconfirmed'}});
  child.stderr.on('data',value=>{stderr+=value.toString();});
  child.stdout.on('data',value=>{lines+=value.toString();while(lines.includes('\n')){
   const at=lines.indexOf('\n'),message=JSON.parse(lines.slice(0,at));lines=lines.slice(at+1);
   if(message.method){assert.equal(message.method,'secret.fillBinding');calls++;assert.deepEqual(message.params,{scope,operationId:'__proto__',binding:'10',referenceID:reference});
    assert.equal(JSON.stringify(message).includes(sentinel),false);
    if(['timeout','stop-held','eof-held'].includes(mode)){held=message;ready();}else respond(message,mode==='uncertain');
   }else{const waiter=pending.get(message.id);assert.ok(waiter);pending.delete(message.id);message.error?waiter.reject(new Error(message.error.message)):waiter.resolve(message.result);}
  }});
  const exited=new Promise<number|null>(resolve=>child.on('exit',resolve));
  try{
   await assert.rejects(request('secret.runProgram',program()),/denied or unresolved/);assert.equal(calls,0);
   assert.equal((await request('hello',{protocolVersion:1,scope})).artifactVariant,'private-opaque-secret-program');
   for(const method of ['ui.acquire','ui.runSegment','inventory','probe'])await assert.rejects(request(method,program()),/denied or unresolved/);
   assert.equal(calls,0);
   const input=mode==='wrong-scope'?program({scope:{...scope,leaseGeneration:2}}):mode==='bad-reference'?program({bindings:{'10':sentinel}}):program({timeoutMs:mode==='timeout'?100:30000});
   const run=request('secret.runProgram',input);void run.catch(()=>{});
   if(mode==='timeout'){await entered;await new Promise(resolve=>setTimeout(resolve,130));respond(held!);}
   if(mode==='stop-held'){
    await entered;let done=false;const stop=request('cancel',{}).then(value=>{done=true;return value;});
    await new Promise(resolve=>setTimeout(resolve,20));assert.equal(done,false);respond(held!);assert.deepEqual(await stop,{commandsDrained:true});
   }
   if(mode==='eof-held'){await entered;child.stdin.end();await exited;assert.equal(calls,1);}
   else{
    if(mode==='valid'){const result=await run;assert.deepEqual(result.outputs,JSON.parse('{"__proto__":{"disposition":"submittedUnconfirmed"}}'));assert.equal(result.complete,true);}
    else await assert.rejects(run,error=>!String(error).includes(sentinel) && /denied or unresolved/.test(String(error)));
    await assert.rejects(request('secret.runProgram',input),/denied or unresolved/);
    assert.equal(calls,['wrong-scope','bad-reference'].includes(mode)?0:1);
    await request('shutdown',{});child.stdin.end();assert.equal(await exited,0);
   }
   assert.equal(stderr.includes(sentinel),false);
   const guard=JSON.parse(stderr.split('SECRET_HOST_GUARD ')[1]!.trim());assert.deepEqual(guard,{hostCalls:[],metadataCalls:[],ownedWorkerCalls:[]});
   if(!['wrong-scope','bad-reference'].includes(mode)){const journal=await readFile(join(root,'opaque-secret-journal.json'),'utf8');assert.equal(journal.includes(reference),false);assert.equal(journal.includes(sentinel),false);}
  }finally{if(child.exitCode===null){child.stdin.end();await exited;}await rm(root,{recursive:true,force:true});}
 });
test('uncertain secret dispatch stays journaled and cannot replay after reopen',async()=>{
 const root=await mkdtemp('/private/tmp/intents-secret-journal-');let calls=0;
 const make=()=>new SecretProgramController(scope,new OperationJournal(join(root,'journal.json')),async()=>{calls++;throw new Error(sentinel);});
 try{await assert.rejects(make().run(program()),/unresolved/);await assert.rejects(make().run(program()),/unresolved/);assert.equal(calls,1);}
 finally{await rm(root,{recursive:true,force:true});}
});
