// Source IPC fixture only: no SDK, helper, GUI, credential, capture or artifact API.
import {createInterface} from 'node:readline';
import {scopeSchema} from '../../src/protocol.js';
import {runSecretFillProgram,type SecretFillRequest} from '../../src/secretFillProgram.js';
const lines=createInterface({input:process.stdin});
const pending=new Map<string,{resolve:(value:unknown)=>void;reject:()=>void}>();let sequence=0,issued=false;
const send=(frame:object)=>process.stdout.write(JSON.stringify(frame)+'\n');
async function reverse(method:string,request:SecretFillRequest):Promise<unknown>{
 const id='secret-'+(++sequence);const response=new Promise<unknown>((resolve,reject)=>{pending.set(id,{resolve,reject:()=>reject(new Error('Native request denied'))});});
 send({jsonrpc:'2.0',id,method,params:request});return response;
}
lines.on('line',line=>{void (async()=>{
 const frame=JSON.parse(line) as {jsonrpc:string;id:string;method?:string;params?:unknown;result?:unknown;error?:unknown};
 if(frame.jsonrpc!=='2.0' || typeof frame.id!=='string')throw new Error();
 if(!frame.method){const waiting=pending.get(frame.id);if(!waiting)throw new Error();pending.delete(frame.id);
  if(frame.error)waiting.reject();else waiting.resolve(frame.result);return;}
 try {
  if(frame.method==='ui.runSegment' && !issued){
   issued=true;const params=frame.params as {scope:unknown};
   const result=await runSecretFillProgram(params,scopeSchema.parse(params.scope),new AbortController().signal,reverse);
   send({jsonrpc:'2.0',id:frame.id,result});return;
  }
  if(frame.method==='shutdown'){send({jsonrpc:'2.0',id:frame.id,result:{stopped:true}});lines.close();process.stdin.pause();return;}
  throw new Error();
 }catch{send({jsonrpc:'2.0',id:frame.id,error:{code:-32000,message:'Opaque worker request denied'}});}
})().catch(()=>{process.stderr.write('Opaque worker protocol failed\n');process.exitCode=1;lines.close();process.stdin.pause();});});
