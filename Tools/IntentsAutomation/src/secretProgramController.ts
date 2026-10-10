import {type Scope} from './protocol.js';
import {nativePayloadDigest} from './payloadDigest.js';
import {OperationJournal} from './operationJournal.js';
import {runSecretFillProgram,secretFillProgramSchema,type SecretFillBroker} from './secretFillProgram.js';

/** One opaque program per native consent context. No ordinary UI dependencies. */
export class SecretProgramController {
 private closed=false;private used=false;private control=new AbortController();private task:Promise<unknown>|undefined;
 constructor(private scope:Scope,private journal:OperationJournal,private broker:SecretFillBroker){}
 async run(input:unknown):Promise<unknown>{
  if(this.closed || this.used)throw new Error('Opaque secret program is unavailable');
  let program;
  try{
   program=secretFillProgramSchema.parse(input);const {payloadDigest,...body}=program;
   if(payloadDigest!==nativePayloadDigest(body) || nativePayloadDigest(program.scope)!==nativePayloadDigest(this.scope))throw new Error();
  }catch{throw new Error('Opaque secret program was denied');}
  this.used=true;
  const task=this.journal.dispatch(program.operationId,program.payloadDigest,()=>runSecretFillProgram(program,this.scope,this.control.signal,this.broker));
  this.task=task;
  try{const result=await task;if(this.closed || this.control.signal.aborted)throw new Error();return result;}
  catch{throw new Error('Opaque secret dispatch is unresolved');}
 }
 async stop(){this.closed=true;this.control.abort();await this.task?.catch(()=>{});return {commandsDrained:true};}
}
