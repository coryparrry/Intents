import {join} from 'node:path';
import {z} from 'zod';
import {scopeSchema,type Scope} from './protocol.js';
import {RpcEndpoint} from './rpc.js';
import {OperationJournal} from './operationJournal.js';
import {SecretProgramController} from './secretProgramController.js';

// Dedicated private entry: never imports the SDK, helper, ordinary UI or model.
const state=process.argv[process.argv.indexOf('--state-dir')+1];
if(!state || !state.startsWith('/'))throw new Error('Private state directory required');
let scope:Scope|undefined,program:SecretProgramController|undefined,closed=false;
const cleanup=async()=>{closed=true;return await program?.stop()??{commandsDrained:true};};
const endpoint=new RpcEndpoint(frame=>process.stdout.write(frame),async(method,params)=>{
 try{
  if(method==='hello'){
   if(closed || scope)throw new Error();
   const input=z.strictObject({protocolVersion:z.literal(1),scope:scopeSchema}).parse(params);
   scope=input.scope;program=new SecretProgramController(scope,new OperationJournal(join(state,'opaque-secret-journal.json')),
    async(method,request,signal)=>{
     if(closed || signal.aborted)throw new Error();
     const result=await endpoint.reverse(method,request,121000);
     if(closed || signal.aborted)throw new Error();return result;
    });
   return {protocolVersion:1,artifactVariant:'private-opaque-secret-program',customerRuntimeEnabled:false,hardwareQualified:false};
  }
  if(method==='cancel' || method==='shutdown')return await cleanup();
  if(closed || !scope || !program)throw new Error();
  if(method==='secret.runProgram')return await program.run(params);
  throw new Error();
 }catch{throw new Error('Opaque secret request was denied or unresolved');}
});
let termination:Promise<void>|undefined;
function terminate(){
 if(termination)return termination;
 try{endpoint.close();}catch{process.exitCode=1;}
 return termination=cleanup().then(()=>{},()=>{process.exitCode=1;});
}
process.stdin.on('data',bytes=>{void endpoint.receive(bytes).catch(()=>{void terminate();process.stdin.destroy();});});
process.stdin.on('end',()=>{void terminate();});
process.stdin.on('close',()=>{void terminate();});
process.stdin.on('error',()=>{process.exitCode=1;void terminate();});
