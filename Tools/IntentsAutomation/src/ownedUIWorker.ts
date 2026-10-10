import {spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {z} from 'zod';
import type {Duplex} from 'node:stream';
import {StringDecoder} from 'node:string_decoder';

export type OwnedUIWorkerAdmission=(pid:number,signal:AbortSignal)=>Promise<void>;
export class OwnedUIWorkerError extends Error {
 constructor(message:string,readonly commandsDrained:boolean,readonly logs=''){super(message);}
}
/** Runs only an owned direct child. An inherited gate prevents runtime import
 * before durable native admission; cancellation never acknowledges a late grant. */
export async function runOwnedUIWorker(entry:string,args:string[],directory:string,env:NodeJS.ProcessEnv,
 signal:AbortSignal,timeoutMs:number,admit:OwnedUIWorkerAdmission):Promise<{logs:string;pid:number}> {
 if(signal.aborted || !Number.isSafeInteger(timeoutMs) || timeoutMs<1 || timeoutMs>120000)
  throw new OwnedUIWorkerError('Worker unavailable before dispatch',true);
 const nonce=randomBytes(32).toString('hex');
 const child=spawn(process.execPath,[fileURLToPath(new URL('./ownedUIWorkerGate.js',import.meta.url)),entry,...args],
  {cwd:directory,env:{...env,INTENTS_UI_WORKER_NONCE:nonce},shell:false,stdio:['ignore','pipe','pipe','pipe']});
 const pipe=child.stdio[3] as Duplex;
 const controller=new AbortController();
 let logs='',truncated=false,killTimer:ReturnType<typeof setTimeout>|undefined;
 let closed=false,readySettled=false;
 const closedResult=new Promise<{code:number|null;error?:Error}>(resolve=>{
  let error:Error|undefined;
  child.once('error',value=>{error=value;});
  child.once('close',code=>{closed=true;resolve(error?{code,error}:{code});});
 });
 const append=(fragment:string)=>{if(Buffer.byteLength(logs)+Buffer.byteLength(fragment)>256*1024){truncated=true;stop();}else logs+=fragment;};
 for(const output of [child.stdout!,child.stderr!]){
  const decoder=new StringDecoder('utf8');
  output.on('data',(chunk:Buffer)=>append(decoder.write(chunk)));
  output.on('end',()=>append(decoder.end()));
 }
 function stop(){
  controller.abort();pipe.destroy();
  if(!closed && child.exitCode===null && child.signalCode===null){
   child.kill('SIGTERM');
   killTimer??=setTimeout(()=>{if(!closed && child.exitCode===null && child.signalCode===null)child.kill('SIGKILL');},5000);
  }
 }
 const cancelled=new Promise<never>((_,reject)=>{
  controller.signal.addEventListener('abort',()=>reject(new Error('Owned worker cancelled')),{once:true});
 });
 // The cancellation promise may lose a race; still observe its rejection.
 void cancelled.catch(()=>{});
 const deadline=setTimeout(stop,timeoutMs);
 signal.addEventListener('abort',stop,{once:true});if(signal.aborted)stop();
 let failure:unknown;
 try{
  const ready=await Promise.race([new Promise<{pid:number}>((resolve,reject)=>{
   let frame='';
   const fail=(error:Error)=>{if(!readySettled){readySettled=true;reject(error);}};
   pipe.on('error',()=>fail(new Error('Worker ownership pipe failed')));
   pipe.on('end',()=>fail(new Error('Worker ownership pipe ended')));
   child.once('error',fail);
   void closedResult.then(()=>fail(new Error('Worker ended before ownership acknowledgment')));
   pipe.on('data',(chunk:Buffer)=>{
    frame+=chunk.toString('utf8');
    if(Buffer.byteLength(frame)>4096)return fail(new Error('Worker readiness exceeded bound'));
    if(!frame.includes('\n'))return;
    try{
     const value=z.strictObject({kind:z.literal('ready'),nonce:z.literal(nonce),pid:z.literal(child.pid!),ppid:z.literal(process.pid)}).parse(JSON.parse(frame));
     if(readySettled)return;readySettled=true;resolve({pid:value.pid});
    }catch{fail(new Error('Worker readiness identity differs'));}
   });
  }),cancelled]);
  await Promise.race([admit(ready.pid,controller.signal),cancelled]);
  if(controller.signal.aborted || signal.aborted || closed)throw new Error('Worker ownership revoked before acknowledgment');
  pipe.write(JSON.stringify({kind:'ack',nonce,pid:ready.pid})+'\n');
  const result=await Promise.race([closedResult,cancelled]);
  if(result.error || result.code!==0 || truncated)throw new Error('Owned UI worker failed');
  return {logs,pid:ready.pid};
 }catch(error){failure=error;stop();}
 finally{clearTimeout(deadline);signal.removeEventListener('abort',stop);}
 // Wait for close, not merely exit: both output pipes must have drained.
 let drainTimer:ReturnType<typeof setTimeout>|undefined;
 const drained=await Promise.race([closedResult.then(()=>true),new Promise<boolean>(resolve=>{drainTimer=setTimeout(()=>resolve(false),11000);})]);
 if(drainTimer)clearTimeout(drainTimer);if(killTimer)clearTimeout(killTimer);
 throw new OwnedUIWorkerError(failure instanceof Error?failure.message:'Owned UI worker failed',drained,logs);
}
