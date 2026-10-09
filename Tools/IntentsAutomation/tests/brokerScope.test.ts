import test from 'node:test';import assert from 'node:assert/strict';
import {createBroker,BrokerClient} from '../src/segmentBroker.js';import type {UIBackend} from '../src/deviceSession.js';
import type {OperationContext} from 'e2e/engine';

test('broker binds capture and action context to its frozen native scope',async()=>{
 const scope={protocolVersion:1 as const,runId:'campaign-run',attemptId:'campaign-attempt',segmentId:'segment',leaseGeneration:1};
 const contexts:OperationContext[]=[];
 const backend:UIBackend={snapshot:async context=>{contexts.push(context!);return {nodes:[],identifiers:{}};},
  perform:async(_ref,_action,context)=>{contexts.push(context);},release:async()=>({released:false,reason:'Synthetic fixture'})};
 const broker=await createBroker(backend,undefined,scope);
 scope.runId='changed-after-binding';
 const client=new BrokerClient(broker.socket,broker.token),context={runId:'worker-forged-run',attemptId:'worker-forged-attempt',origin:'test' as const,signal:new AbortController().signal,timeoutMs:1000};
 try{
  await client.snapshot(context);await client.perform('@e1~s1',{kind:'tap'},context);
  assert.equal(contexts.length,2);
  for(const observed of contexts){assert.equal(observed.runId,'campaign-run');assert.equal(observed.attemptId,'campaign-attempt');}
 }finally{await broker.close();}
});
test('broker rejects a malformed native scope before opening its socket',async()=>{
 const backend:UIBackend={snapshot:async()=>({nodes:[],identifiers:{}}),perform:async()=>{},release:async()=>({released:false,reason:'Synthetic fixture'})};
 await assert.rejects(createBroker(backend,undefined,{protocolVersion:1,runId:'',attemptId:'attempt',segmentId:'segment',leaseGeneration:1}));
});
