import {ownRecord} from './ownRecord.js';
import {z} from 'zod';
import {identifier,digest,scopeSchema,type Scope} from './protocol.js';
import {nativePayloadDigest} from './payloadDigest.js';

const operationSchema=z.strictObject({kind:z.literal('fillSecretBinding'),id:identifier,binding:identifier});
export const secretFillProgramSchema=z.strictObject({scope:scopeSchema,operationId:identifier,payloadDigest:digest,
 phase:z.enum(['setup','subject','cleanup']),operations:z.array(operationSchema).min(1).max(30),
 bindings:ownRecord(z.string().uuid()),timeoutMs:z.number().int().min(100).max(120000)}).superRefine((v,c)=>{
 const ids=v.operations.map(o=>o.id),bindings=v.operations.map(o=>o.binding),references=Object.values(v.bindings);
 if(new Set(ids).size!==ids.length || new Set(bindings).size!==bindings.length || new Set(references).size!==references.length)
  c.addIssue({code:'custom',message:'Opaque secret operations and references must be unique'});
 if(Object.keys(v.bindings).length!==bindings.length || bindings.some(binding=>!Object.hasOwn(v.bindings,binding)))
  c.addIssue({code:'custom',message:'Opaque secret mapping differs from declared operations'});
});
export type SecretFillProgram=z.infer<typeof secretFillProgramSchema>;
export interface SecretFillRequest {scope:Scope;operationId:string;binding:string;referenceID:string;}
export type SecretFillBroker=(method:'secret.fillBinding',request:SecretFillRequest,signal:AbortSignal)=>Promise<unknown>;
const receiptSchema=z.strictObject({scope:scopeSchema,operationId:identifier,disposition:z.literal('submittedUnconfirmed')});

/** No SDK, screen, literal fill, capture, controller, or artifact interface exists here.
 * Only native code can resolve handles and verify consent/sink/lease authority. */
export async function runSecretFillProgram(input:unknown,scope:Scope,signal:AbortSignal,broker?:SecretFillBroker){
 let program:SecretFillProgram;
 try {
  program=secretFillProgramSchema.parse(input);
  const {payloadDigest:claimed,...body}=program;
  if(nativePayloadDigest(body)!==claimed || nativePayloadDigest(program.scope)!==nativePayloadDigest(scopeSchema.parse(scope)))throw new Error();
 }catch{throw new Error('Opaque secret program was denied');}
 if(!broker || signal.aborted)throw new Error('Opaque secret broker is unavailable');
 const control=new AbortController(),expires=performance.now()+program.timeoutMs;
 const cancel=()=>control.abort();signal.addEventListener('abort',cancel,{once:true});if(signal.aborted)cancel();
 const timer=setTimeout(cancel,program.timeoutMs);
 const expired=()=>control.signal.aborted || performance.now()>=expires;
 try {
 const outputs:Record<string,{disposition:'submittedUnconfirmed'}>={};
 for(const operation of program.operations){
  if(expired())throw new Error('Opaque secret dispatch is unresolved');
  try {
   const receipt=receiptSchema.parse(await broker('secret.fillBinding',{scope:program.scope,operationId:operation.id,
    binding:operation.binding,referenceID:program.bindings[operation.binding]!},control.signal));
   if(expired() || receipt.operationId!==operation.id || nativePayloadDigest(receipt.scope)!==nativePayloadDigest(program.scope))throw new Error();
   Object.defineProperty(outputs,operation.id,{value:{disposition:receipt.disposition},enumerable:true});
  }catch{throw new Error('Opaque secret dispatch is unresolved');}
 }
 return {schemaVersion:1 as const,scope:program.scope,operationId:program.operationId,complete:true as const,outputs};
 }finally{clearTimeout(timer);signal.removeEventListener('abort',cancel);}
}
