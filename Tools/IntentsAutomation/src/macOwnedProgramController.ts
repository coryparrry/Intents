import {join} from 'node:path';
import {MacOwnedSession} from './macOwnedSession.js';
import {OperationJournal} from './operationJournal.js';
import {runMacOwnedProgram,validateMacOwnedProgram,validateMacOwnedReceipt,type MacOwnedProgramReceipt} from './macOwnedProgram.js';
import {OwnedUIWorkerError,type OwnedUIWorkerAdmission} from './ownedUIWorker.js';
import type {ControllerBroker} from './segmentBroker.js';

type Execute=typeof runMacOwnedProgram;
/** One leased program at a time, with durable at-most-once dispatch. Closing
 * cancels the owned worker and joins completion without granting a late import. */
export class MacOwnedProgramController {
 private closed=false;
 private active:{controller:AbortController;completion:Promise<MacOwnedProgramReceipt>}|undefined;
 private unprovedDrain=false;
 private stopping:Promise<boolean>|undefined;
 constructor(private session:MacOwnedSession,private root:string,private journal:OperationJournal,
  private admit:OwnedUIWorkerAdmission,private decide?:ControllerBroker,private execute:Execute=runMacOwnedProgram){}
 async run(input:unknown):Promise<MacOwnedProgramReceipt>{
  if(this.closed || this.active || this.unprovedDrain)throw new Error('Private Mac program unavailable');
  const segment=validateMacOwnedProgram(input,this.session.supportsScroll,this.session.supportsOrdinaryFill);
  if(Object.keys(this.session.scope).some(key=>this.session.scope[key as keyof typeof this.session.scope]!==segment.scope[key as keyof typeof segment.scope]))
   throw new Error('Private Mac program scope differs');
  const controller=new AbortController();
  const completion=Promise.resolve().then(async()=>validateMacOwnedReceipt(await this.journal.dispatch(`${segment.scope.runId}:${segment.operationId}`,segment.payloadDigest,async()=>{
   if(this.closed || controller.signal.aborted)throw new Error('Private Mac pending program revoked');
   // The digest is the only path component derived from protocol data.
   return await this.execute(this.session,segment,join(this.root,'runs',segment.payloadDigest),controller.signal,
    async(pid,signal)=>{
     if(this.closed || controller.signal.aborted || signal.aborted)throw new Error('Private Mac worker admission revoked');
     await this.admit(pid,signal);
     if(this.closed || controller.signal.aborted || signal.aborted)throw new Error('Private Mac worker admission revoked');
    },this.decide);
  }),segment,this.session.target)).catch(error=>{
   if(error instanceof OwnedUIWorkerError && !error.commandsDrained)this.unprovedDrain=true;
   throw error;
  });
  this.active={controller,completion};
  try{
   const result=await completion;
   if(this.closed || controller.signal.aborted)throw new Error('Private Mac completed program revoked');
   return result;
  }finally{this.active=undefined;}
 }
 cancel(){this.closed=true;this.active?.controller.abort();}
 stop():Promise<boolean>{this.cancel();return this.stopping??=this.finish();}
 private async finish():Promise<boolean>{
  const active=this.active;
  if(!active)return !this.unprovedDrain;
  let timer:ReturnType<typeof setTimeout>|undefined;
  try{
   const settled=await Promise.race([active.completion.then(()=>true,()=>true),new Promise<boolean>(resolve=>{timer=setTimeout(()=>resolve(false),30000);})]);
   return settled && !this.unprovedDrain;
  }finally{if(timer)clearTimeout(timer);}
 }
}
