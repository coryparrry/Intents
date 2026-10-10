import {ownRecord} from './ownRecord.js';
import {segmentPayloadDigest} from './payloadDigest.js';
import {z} from 'zod';
import {EngineError} from 'e2e/engine';
import {segmentSchema,type Segment} from './segment.js';
import {scopeSchema,type Scope,type Target} from './protocol.js';
import {MacOwnedSession} from './macOwnedSession.js';
import {validateMacOrdinaryFillValue} from './macOrdinaryFill.js';
import {runWorker} from './workerRunner.js';
import type {OwnedUIWorkerAdmission} from './ownedUIWorker.js';
import type {ControllerBroker} from './segmentBroker.js';
import {readbackSchema,verifyReadback,type UIReadback} from './uiReadback.js';

export interface MacOwnedProgramReceipt {
 schemaVersion:1;scope:Scope;operationId:string;complete:true;
 outputs:Record<string,string|null|number|UIReadback>;
}

/** Capability preflight precedes worker dispatch; unimplemented Mac input never
 * becomes a controller verb or a partially executed deterministic program. */
export function validateMacOwnedProgram(input:unknown,scrollImplemented=false,fillImplemented=false):Segment {
 const segment=segmentSchema.parse(input);
 const {payloadDigest:claimed,...body}=segment;
 if(segmentPayloadDigest(body)!==claimed)throw new Error('Private Mac program digest mismatch');
 for(const operation of segment.operations){
  if((operation.kind==='fillBinding' && !fillImplemented) || (operation.kind==='scroll' && !scrollImplemented) ||
   (!fillImplemented && operation.kind==='navigateGoal' && ((operation.goal.allowedFillBindings?.length??0)>0 ||
     Object.values(operation.goal.minimumBindingUses??{}).some(count=>count>0))))
   throw new EngineError('UNSUPPORTED_CAPABILITY','Private Mac operation requires an implemented input capability',{retryable:false});
 }
 if(fillImplemented)for(const value of Object.values(segment.bindings))validateMacOrdinaryFillValue(value);
 return segment;
}
export async function runMacOwnedProgram(session:MacOwnedSession,input:unknown,root:string,signal:AbortSignal,
 admit:OwnedUIWorkerAdmission,decide?:ControllerBroker):Promise<MacOwnedProgramReceipt> {
 const segment=validateMacOwnedProgram(input,session.supportsScroll,session.supportsOrdinaryFill);
 if(session.target.kind!=='nativeMac' || Object.keys(session.scope).some(key=>
   session.scope[key as keyof typeof session.scope]!==segment.scope[key as keyof typeof segment.scope]))
  throw new Error('Private Mac program scope differs');
 const raw=await runWorker(session,session.target,segment,root,signal,decide,admit);
 return validateMacOwnedReceipt(raw,segment,session.target);
}
export function validateMacOwnedReceipt(raw:unknown,segment:Segment,target:Target):MacOwnedProgramReceipt {
 const result=z.strictObject({schemaVersion:z.literal(1),scope:scopeSchema,operationId:z.literal(segment.operationId),
  complete:z.literal(true),outputs:ownRecord(z.unknown())}).parse(raw);
 if(Object.keys(segment.scope).some(key=>segment.scope[key as keyof typeof segment.scope]!==result.scope[key as keyof typeof result.scope]))
  throw new Error('Private Mac receipt scope differs');
 const expected=segment.operations.filter(operation=>['observeProperty','readProperty','locate'].includes(operation.kind)).map(operation=>operation.id);
 if(Object.keys(result.outputs).length!==expected.length || expected.some(id=>!Object.hasOwn(result.outputs,id)))
  throw new Error('Private Mac receipt outputs differ');
 const outputs:MacOwnedProgramReceipt['outputs']=Object.create(null);
 for(const operation of segment.operations){
  const value=result.outputs[operation.id];
  if(operation.kind==='observeProperty'){
   const proof=readbackSchema.parse(value);
   if(proof.appBundleId!==target.bundleId || proof.targetId!==target.id)throw new Error('Private Mac readback identity differs');
   verifyReadback(proof,operation);outputs[operation.id]=proof;
  }
  if(operation.kind==='readProperty')outputs[operation.id]=z.string().max(32768).nullable().parse(value);
  if(operation.kind==='locate')outputs[operation.id]=z.number().int().min(0).max(5000).parse(value);
 }
 return {...result,outputs};
}
