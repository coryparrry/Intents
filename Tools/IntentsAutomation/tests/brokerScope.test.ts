import test from 'node:test';import assert from 'node:assert/strict';
import {createBroker,BrokerClient} from '../src/segmentBroker.js';import type {UIBackend} from '../src/deviceSession.js';
import type {OperationContext} from 'e2e/engine';
import {connect} from 'node:net';import {FrameReader} from '../src/protocol.js';

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
function rawConnection(socket:string){
 const client=connect(socket),reader=new FrameReader(),frames:Record<string,unknown>[]=[];let closed=false,wake=()=>{};
 client.on('data',chunk=>{frames.push(...reader.push(chunk) as Record<string,unknown>[]);wake();});client.on('close',()=>{closed=true;wake();});client.on('error',()=>{});
 const ready=new Promise<void>(resolve=>client.once('connect',()=>resolve()));
 return {ready,send(...messages:object[]){client.write(messages.map(message=>JSON.stringify(message)+'\n').join(''));},
  async until(count:number,waitMs=2000){const deadline=Date.now()+waitMs;
   while(frames.length<count && !closed && Date.now()<deadline)await new Promise<void>(resolve=>{wake=resolve;setTimeout(resolve,deadline-Date.now()).unref();});
   return {frames:[...frames],closed};},
  destroy(){client.destroy();}};
}
function countingBackend(){
 const calls={snapshot:0,perform:0};let release=()=>{},started=()=>{};
 const gate=new Promise<void>(resolve=>{release=resolve;}),firstSnapshot=new Promise<void>(resolve=>{started=resolve;});
 const backend:UIBackend={snapshot:async()=>{calls.snapshot++;started();await gate;return {nodes:[],identifiers:{}};},
  perform:async()=>{calls.perform++;},release:async()=>({released:false,reason:'Synthetic fixture'})};
 return {backend,calls,release,firstSnapshot};
}
const failed={code:'ENGINE_FAILURE',message:'Broker command failed'};
const controllerRequest={goalId:'goal',revision:'r1',nodes:[],truncated:false,omittedNodes:0,verbs:['tap' as const],recentActions:[],remainingActions:1,remainingMs:1000};
const clientContext=()=>({runId:'r',attemptId:'a',origin:'test' as const,signal:new AbortController().signal,timeoutMs:1000});
test('broker drops a connection presenting a forged token without touching the backend',async()=>{
 const {backend,calls,release}=countingBackend();release();const broker=await createBroker(backend);
 const forged=(broker.token[0]==='0'?'1':'0')+broker.token.slice(1);assert.match(forged,/^[0-9a-f]{64}$/);
 const connection=rawConnection(broker.socket);
 try{
  connection.send({id:1,token:forged,method:'perform',timeoutMs:1000,ref:'@e1~s1',action:{kind:'tap'}});
  assert.deepEqual(await connection.until(1),{frames:[],closed:true});
  assert.deepEqual(calls,{snapshot:0,perform:0});
  await new BrokerClient(broker.socket,broker.token).snapshot(clientContext());assert.equal(calls.snapshot,1);
 }finally{connection.destroy();await broker.close();}
});
test('broker refuses correctly authenticated commands once close has started',async()=>{
 const {backend,calls,release,firstSnapshot}=countingBackend();const broker=await createBroker(backend);
 const pending=rawConnection(broker.socket),late=rawConnection(broker.socket);
 try{
  await Promise.all([pending.ready,late.ready]);
  pending.send({id:1,token:broker.token,method:'snapshot',timeoutMs:5000});await firstSnapshot;
  const closing=broker.close();
  late.send({id:2,token:broker.token,method:'perform',timeoutMs:1000,ref:'@e1~s1',action:{kind:'tap'}});
  assert.deepEqual(await late.until(1),{frames:[],closed:true});
  release();await closing;
  assert.deepEqual(calls,{snapshot:1,perform:0});
 }finally{release();pending.destroy();late.destroy();}
});
test('controller commands fail closed without a controller or with action fields attached',async()=>{
 const {backend,calls,release}=countingBackend();release();
 const withoutController=await createBroker(backend);
 try{
  await assert.rejects(new BrokerClient(withoutController.socket,withoutController.token).decide(controllerRequest,clientContext()),failed);
 }finally{await withoutController.close();}
 const decisions:unknown[]=[];
 const broker=await createBroker(backend,async request=>{decisions.push(request);return {kind:'finish'};});
 const connection=rawConnection(broker.socket);
 try{
  connection.send({id:1,token:broker.token,method:'controller',timeoutMs:1000,request:controllerRequest,ref:'@e1~s1'},
   {id:2,token:broker.token,method:'controller',timeoutMs:1000,request:controllerRequest,action:{kind:'tap'}},
   {id:3,token:broker.token,method:'controller',timeoutMs:1000});
  const {frames}=await connection.until(3);
  assert.deepEqual(frames,[{id:1,error:failed},{id:2,error:failed},{id:3,error:failed}]);
  assert.equal(decisions.length,0);assert.deepEqual(calls,{snapshot:0,perform:0});
  assert.deepEqual(await new BrokerClient(broker.socket,broker.token).decide(controllerRequest,clientContext()),{kind:'finish'});
  assert.equal(decisions.length,1);
 }finally{connection.destroy();await broker.close();}
});
test('perform commands missing a ref or action never reach the backend',async()=>{
 const {backend,calls,release}=countingBackend();release();const broker=await createBroker(backend);const connection=rawConnection(broker.socket);
 try{
  connection.send({id:1,token:broker.token,method:'perform',timeoutMs:1000,action:{kind:'tap'}},
   {id:2,token:broker.token,method:'perform',timeoutMs:1000,ref:'@e1~s1'});
  const {frames}=await connection.until(2);
  assert.deepEqual(frames,[{id:1,error:failed},{id:2,error:failed}]);
  assert.deepEqual(calls,{snapshot:0,perform:0});
 }finally{connection.destroy();await broker.close();}
});
test('queued commands whose deadline passed are rejected without reaching the backend',async()=>{
 const {backend,calls,release,firstSnapshot}=countingBackend();const broker=await createBroker(backend);const connection=rawConnection(broker.socket);
 try{
  connection.send({id:1,token:broker.token,method:'snapshot',timeoutMs:5000});await firstSnapshot;
  connection.send({id:2,token:broker.token,method:'perform',timeoutMs:1,ref:'@e1~s1',action:{kind:'tap'}});
  await new Promise(resolve=>setTimeout(resolve,20));release();
  const {frames}=await connection.until(2);
  assert.deepEqual(frames,[{id:1,result:{nodes:[],identifiers:{}}},{id:2,error:failed}]);
  assert.deepEqual(calls,{snapshot:1,perform:0});
 }finally{release();connection.destroy();await broker.close();}
});
test('broker admits at most 32 outstanding commands and frees capacity as they finish',async()=>{
 const {backend,calls,release,firstSnapshot}=countingBackend();const broker=await createBroker(backend);
 const saturating=rawConnection(broker.socket),overflow=rawConnection(broker.socket);
 try{
  await overflow.ready;
  saturating.send(...Array.from({length:32},(_,index)=>({id:index+1,token:broker.token,method:'snapshot',timeoutMs:5000})));
  await firstSnapshot;await new Promise(resolve=>setTimeout(resolve,20));
  overflow.send({id:33,token:broker.token,method:'perform',timeoutMs:5000,ref:'@e1~s1',action:{kind:'tap'}});
  assert.deepEqual(await overflow.until(1),{frames:[],closed:true});
  release();
  const {frames}=await saturating.until(32);
  assert.deepEqual(frames.map(frame=>frame.id),Array.from({length:32},(_,index)=>index+1));
  assert.ok(frames.every(frame=>Object.hasOwn(frame,'result')));
  assert.deepEqual(calls,{snapshot:32,perform:0});
  await new BrokerClient(broker.socket,broker.token).perform('@e1~s1',{kind:'tap'},clientContext());assert.equal(calls.perform,1);
 }finally{release();saturating.destroy();overflow.destroy();await broker.close();}
});
