import {spawn} from 'node:child_process';import {createRequire} from 'node:module';
import {dirname,resolve,join} from 'node:path';import {fileURLToPath,pathToFileURL} from 'node:url';
import {mkdir,writeFile,readFile} from 'node:fs/promises';
import type {Target} from './protocol.js';import {type Segment} from './segment.js';
import type {UIBackend} from './deviceSession.js';import {createBroker,type ControllerBroker} from './segmentBroker.js';
import {runOwnedUIWorker,OwnedUIWorkerError,type OwnedUIWorkerAdmission} from './ownedUIWorker.js';
const require=createRequire(import.meta.url);
const ownDirectory=dirname(fileURLToPath(import.meta.url));
export {payloadDigest} from './payloadDigest.js';
import {segmentPayloadDigest} from './payloadDigest.js';
export async function runWorker(backend:UIBackend,target:Target,segment:Segment,root:string,signal:AbortSignal,decide?:ControllerBroker,ownedAdmission?:OwnedUIWorkerAdmission){
 const {payloadDigest:claimed,...body}=segment;if(segmentPayloadDigest(body)!==claimed)throw new Error('Worker segment digest mismatch');
 await mkdir(root,{recursive:true,mode:0o700});const broker=await createBroker(backend,decide,segment.scope);
 try {
 const segmentPath=join(root,'segment.json'),receiptPath=join(root,'receipt.json');
 const configPath=join(root,'e2e.config.mjs');
 await writeFile(configPath,`export { default } from ${JSON.stringify(pathToFileURL(join(ownDirectory,'e2e','config.js')).href)};\n`,{mode:0o600});
 await writeFile(join(root,'segment.e2e.mjs'),`import ${JSON.stringify(pathToFileURL(join(ownDirectory,'e2e','segment.e2e.js')).href)};\n`,{mode:0o600});
 await writeFile(segmentPath,JSON.stringify(segment),{mode:0o600});
 const entry=require.resolve('e2e');const packageRoot=resolve(dirname(entry),'..');
 const manifest=JSON.parse(await readFile(join(packageRoot,'package.json'),'utf8'));
 if(manifest.version!=='0.17.0' || manifest.bin?.e2e!=='./dist/cli/bin.js')throw new Error('Unqualified e2e package');
 const env:NodeJS.ProcessEnv={PATH:'/usr/bin:/bin:/usr/sbin:/sbin',HOME:join(root,'home'),TMPDIR:root,
 E2E_TELEMETRY_DISABLED:'1',AGENT_DEVICE_NO_UPDATE_NOTIFIER:'1',INTENTS_TARGET:JSON.stringify(target),
 INTENTS_BROKER_SOCKET:broker.socket,INTENTS_BROKER_TOKEN:broker.token,INTENTS_SEGMENT:segmentPath,
 INTENTS_SEGMENT_RECEIPT:receiptPath,INTENTS_INTERPRETER:'segment.e2e.mjs',INTENTS_OUTPUT:'e2e'};
 if(target.kind==='nativeMac' && backend.implementedActions?.includes('fill'))env.INTENTS_MAC_FILL_IMPLEMENTED='1';
 if(target.kind==='nativeMac' && backend.implementedActions?.includes('swipe'))env.INTENTS_MAC_SCROLL_IMPLEMENTED='1';
 await mkdir(env.HOME!,{recursive:true,mode:0o700});
 if(ownedAdmission){
  try{
   const result=await runOwnedUIWorker(join(packageRoot,manifest.bin.e2e),['run','--config',configPath],root,env,signal,segment.timeoutMs,ownedAdmission);
   await writeFile(join(root,'worker.log'),result.logs,{mode:0o600});
   const receipt=JSON.parse(await readFile(receiptPath,'utf8'));
   if(receipt.complete!==true || JSON.stringify(receipt.scope)!==JSON.stringify(segment.scope) || receipt.operationId!==segment.operationId)
    throw new Error('Missing or mismatched UI receipt');
   return receipt as unknown;
  }catch(error){
   if(error instanceof OwnedUIWorkerError){
    await writeFile(join(root,'worker.log'),error.logs,{mode:0o600});
    // Preserve the owned worker's drain proof; only the bounded diagnostic changes.
    if(!signal.aborted && broker.policyDenial())error.message=broker.policyDenial()!;
   }
   throw error;
  }
 }
 const child=spawn(process.execPath,[join(packageRoot,manifest.bin.e2e),'run','--config',configPath],
  {cwd:root,env,shell:false,stdio:['ignore','pipe','pipe']});
 let logs='';const log=(chunk:Buffer)=>{if(Buffer.byteLength(logs)<256*1024) logs+=chunk.toString('utf8');};
 child.stdout.on('data',log);child.stderr.on('data',log);
 const cancel=()=>{if(child.exitCode===null){child.kill('SIGTERM');const kill=setTimeout(()=>{if(child.exitCode===null)child.kill('SIGKILL')},5000);kill.unref();}};
 signal.addEventListener('abort',cancel,{once:true});if(signal.aborted)cancel();const deadline=setTimeout(cancel,segment.timeoutMs);
 try {
  const exit=await new Promise<number|null>((done,reject)=>{child.once('error',reject);child.once('exit',done)});
  await writeFile(join(root,'worker.log'),logs,{mode:0o600});
  if(exit!==0 || signal.aborted)throw new Error(signal.aborted?'Segment cancelled':broker.policyDenial()??'Worker failed; see owned log');
  const receipt=JSON.parse(await readFile(receiptPath,'utf8'));
  if(receipt.complete!==true || JSON.stringify(receipt.scope)!==JSON.stringify(segment.scope) || receipt.operationId!==segment.operationId)
   throw new Error('Missing or mismatched UI receipt');
  return receipt as unknown;
 }finally{clearTimeout(deadline);signal.removeEventListener('abort',cancel);}
 }finally{await broker.close();}
}
