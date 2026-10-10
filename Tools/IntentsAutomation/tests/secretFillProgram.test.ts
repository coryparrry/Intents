import {test} from 'node:test';import assert from 'node:assert/strict';
import {payloadDigest,nativePayloadDigest} from '../src/payloadDigest.js';
import {createHash} from 'node:crypto';
import {runSecretFillProgram,type SecretFillBroker} from '../src/secretFillProgram.js';
import type {Scope} from '../src/protocol.js';
const scope:Scope={protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'setup',leaseGeneration:1};
const reference='FC630209-A968-416D-B23C-98CCE968CA83';
function program(extra:object={}){
 const body={scope,operationId:'secret-program',phase:'setup',operations:[{id:'fill-password',kind:'fillSecretBinding',binding:'credential'}],
  bindings:{credential:reference},timeoutMs:30000,...extra};return {...body,payloadDigest:nativePayloadDigest(body)};
}
const signal=()=>new AbortController().signal;
const broker:SecretFillBroker=async(_method,request)=>({scope:request.scope,operationId:request.operationId,disposition:'submittedUnconfirmed'});
test('opaque program sends only the exact scoped handle and returns unconfirmed delivery',async()=>{
 let calls=0;const result=await runSecretFillProgram(program(),scope,signal(),async(method,request)=>{
  calls++;assert.equal(method,'secret.fillBinding');assert.deepEqual(request,{scope,operationId:'fill-password',binding:'credential',referenceID:reference});
  assert.equal(Object.hasOwn(request,'value'),false);return broker(method,request,signal());
 });assert.equal(calls,1);assert.deepEqual(result.outputs,{'fill-password':{disposition:'submittedUnconfirmed'}});
});
test('missing broker and aborted program never dispatch',async()=>{
 await assert.rejects(runSecretFillProgram(program(),scope,signal()),/unavailable/);
 let calls=0;const controller=new AbortController();controller.abort();
 await assert.rejects(runSecretFillProgram(program(),scope,controller.signal,async()=>{calls++;}),/unavailable/);assert.equal(calls,0);
});
test('public text, extra handles, ambiguous declarations and observer input are denied before broker',async()=>{
 let calls=0;const trap:SecretFillBroker=async()=>{calls++;throw new Error();};
 for(const input of [program({bindings:{credential:'SYNTHETIC-CREDENTIAL'}}),program({bindings:{credential:reference,extra:reference}}),
  program({phase:'observe'}),program({operations:[]}),program({operations:[{id:'x',kind:'fillBinding',binding:'credential',value:'secret'}]}),
  program({operations:[{id:'x',kind:'fillSecretBinding',binding:'credential'},{id:'x',kind:'fillSecretBinding',binding:'other'}],bindings:{credential:reference,other:'68C0D2C1-7C46-488B-9598-3FF44644F7DB'}}),
  {...program(),value:'secret'}])await assert.rejects(runSecretFillProgram(input,scope,signal(),trap),/program was denied/);
 assert.equal(calls,0);
});
test('changed digest, scope, generation and correlated identity are denied',async()=>{
 let calls=0;const trap:SecretFillBroker=async()=>{calls++;throw new Error();};
 await assert.rejects(runSecretFillProgram({...program(),payloadDigest:'a'.repeat(64)},scope,signal(),trap),/program was denied/);
 for(const key of ['runId','attemptId','segmentId','leaseGeneration'] as const){
  const changed={...scope,[key]:key==='leaseGeneration'?2:'other'};
  await assert.rejects(runSecretFillProgram(program({scope:changed}),scope,signal(),trap),/program was denied/);
 }assert.equal(calls,0);
});
test('lying, extra or credential-bearing native responses and errors stay sanitized',async()=>{
 const sentinel='SYNTHETIC-CREDENTIAL';
 for(const response of [{scope,operationId:'wrong',disposition:'submittedUnconfirmed'},
  {scope:{...scope,attemptId:'other'},operationId:'fill-password',disposition:'submittedUnconfirmed'},
  {scope,operationId:'fill-password',disposition:'replacementVerified'},
  {scope,operationId:'fill-password',disposition:'submittedUnconfirmed',value:sentinel}]){
  await assert.rejects(runSecretFillProgram(program(),scope,signal(),async()=>response),error=>{
   assert.equal(String(error).includes(sentinel),false);return /dispatch is unresolved/.test(String(error));
  });
 }
 await assert.rejects(runSecretFillProgram(program(),scope,signal(),async()=>{throw new Error(sentinel);}),error=>{
  assert.equal(String(error).includes(sentinel),false);return /dispatch is unresolved/.test(String(error));
 });
});
test('cancellation retains uncooperative broker work and rejects its late completion',async()=>{
 const controller=new AbortController();let entered!:()=>void,release!:()=>void,finished=false;
 const ready=new Promise<void>(resolve=>{entered=resolve;}),gate=new Promise<void>(resolve=>{release=resolve;});
 const result=runSecretFillProgram(program(),scope,controller.signal,async(method,request)=>{entered();await gate;return broker(method,request,signal());});
 const observed=result.finally(()=>{finished=true;});void observed.catch(()=>{});
 await ready;controller.abort();await new Promise(resolve=>setImmediate(resolve));assert.equal(finished,false);release();
 await assert.rejects(result,/dispatch is unresolved/);assert.equal(finished,true);
});

test('special operation IDs retain own serialized receipts',async()=>{
 const result=await runSecretFillProgram(program({operations:[{id:'__proto__',kind:'fillSecretBinding',binding:'credential'}]}),scope,signal(),broker);
 assert.equal(Object.hasOwn(result.outputs,'__proto__'),true);
 assert.deepEqual(JSON.parse(JSON.stringify(result.outputs)),JSON.parse('{"__proto__":{"disposition":"submittedUnconfirmed"}}'));
});
test('opaque numeric binding hash matches native lexical order while legacy hash stays unchanged',()=>{
 const input={bindings:{'2':'a','10':'b'}},hash=(text:string)=>createHash('sha256').update(text).digest('hex');
 assert.equal(payloadDigest(input),hash('{"bindings":{"2":"a","10":"b"}}'));
 assert.equal(nativePayloadDigest(input),hash('{"bindings":{"10":"b","2":"a"}}'));
});
test('deadline aborts broker signal and retains its work before rejecting late delivery',async()=>{
 let entered!:()=>void,release!:()=>void,finished=false,received:AbortSignal|undefined;
 const ready=new Promise<void>(resolve=>{entered=resolve;}),gate=new Promise<void>(resolve=>{release=resolve;});
 const result=runSecretFillProgram(program({timeoutMs:100}),scope,signal(),async(method,request,signal)=>{
  received=signal;entered();await gate;return broker(method,request,signal);
 });
 const observed=result.finally(()=>{finished=true;});void observed.catch(()=>{});
 await ready;await new Promise(resolve=>setTimeout(resolve,125));assert.equal(received?.aborted,true);assert.equal(finished,false);
 release();await assert.rejects(result,/dispatch is unresolved/);
});

test('opaque prototype-name binding is preserved with exact UUID-only admission',async()=>{
 const selected=program({operations:[{id:'fill-password',kind:'fillSecretBinding',binding:'__proto__'}],bindings:Object.fromEntries([['__proto__',reference]])});
 let calls=0;await runSecretFillProgram(selected,scope,signal(),async(method,request)=>{
  calls++;assert.equal(request.binding,'__proto__');assert.equal(request.referenceID,reference);return broker(method,request,signal());
 });assert.equal(calls,1);
});
