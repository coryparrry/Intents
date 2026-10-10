import {segmentPayloadDigest} from './payloadDigest.js';
import {mkdir,readFile,realpath} from 'node:fs/promises';import {join,isAbsolute} from 'node:path';
import {createAgentDeviceClient} from 'agent-device';import {z} from 'zod';
import {scopeSchema,targetSchema,identifier,type Scope} from './protocol.js';
import {DeviceSession,DeviceAcquisitionError} from './deviceSession.js';import {RpcEndpoint} from './rpc.js';
import {OperationJournal} from './operationJournal.js';import {segmentSchema} from './segment.js';
import {runWorker} from './workerRunner.js';
import {stopPrivateDaemon} from './lifecycle.js';
import {requirePolicyApproval} from './policyReview.js';
if(process.versions.node!=='24.21.0')throw new Error('Only the qualified private Node 24 runtime is supported');
if(process.argv.length!==4 || process.argv[2]!=='--state-dir' || !isAbsolute(process.argv[3]!))throw new Error('Explicit private state directory is required');
const root=process.argv[3]!;await mkdir(root,{recursive:true,mode:0o700});if(await realpath(root)!==root)throw new Error('Noncanonical state directory');
const journal=new OperationJournal(join(root,'operations.json'));await journal.load();
let lease:{scope:Scope;session:DeviceSession}|undefined;let acquiring=false,releasing=false,closing=false,inventoryUsed=false,acquisitionReleaseUnknown=false;
let readonlyCalls=0;
const operations=new Map<string,{controller:AbortController;state:string;completion:Promise<unknown>}>();
type CleanupReason = 'complete'|'pendingWork'|'inventoryUnreleased'|'sessionUnreleased'|'sessionReleaseError'|'acquisitionUnknown';
type CleanupResult={shutdownRequested:true;resourcesReleased:boolean;cleanupReason:CleanupReason};
const cleanupResult=(resourcesReleased:boolean,cleanupReason:CleanupReason):CleanupResult=>({shutdownRequested:true,resourcesReleased,cleanupReason});
let cleanupPromise:Promise<CleanupResult>|undefined;
function cleanup(){return cleanupPromise??= (async()=>{
 closing=true;for(const operation of operations.values())operation.controller.abort();
 const deadline=Date.now()+20000;
 while((acquiring || releasing || readonlyCalls>0 || [...operations.values()].some(o=>['pending','running'].includes(o.state))) && Date.now()<deadline)await new Promise(r=>setTimeout(r,50));
 if(acquiring || releasing || readonlyCalls>0 || [...operations.values()].some(o=>['pending','running'].includes(o.state)))return cleanupResult(false,'pendingWork');
 let inventoryReleased=true;
 if(inventoryUsed){try{inventoryReleased=(await stopPrivateDaemon(root)).released;}catch{inventoryReleased=false;}}
 try{
  if(lease){const result=await lease.session.release();if(!result.released)return cleanupResult(false,'sessionUnreleased');lease=undefined;}
  if(acquisitionReleaseUnknown)return cleanupResult(false,'acquisitionUnknown');
  return cleanupResult(inventoryReleased,inventoryReleased?'complete':'inventoryUnreleased');
 }catch{return cleanupResult(false,'sessionReleaseError');}
})().finally(()=>{cleanupPromise=undefined;});}
const endpoint=new RpcEndpoint(frame=>process.stdout.write(frame),async(method,input)=>{
 if(closing && !['cancel','status','shutdown'].includes(method))throw new Error('Sidecar is closing');
 switch(method){
  case 'hello':z.strictObject({protocolVersion:z.literal(1)}).parse(input);return {protocolVersion:1,adapterVersion:'0.1.0',nodeVersion:process.versions.node,
   methods:['hello','inventory','probe','ui.acquire','ui.runSegment','ui.release','cancel','status','shutdown'],mixedHandoffQualified:false,navigationReplay:false};
  case 'inventory':{z.strictObject({protocolVersion:z.literal(1)}).parse(input);inventoryUsed=true;readonlyCalls++;
   try{return await createAgentDeviceClient({stateDir:root,cwd:root,session:'intents-inventory'}).devices.list();}
   finally{readonlyCalls--;if(closing)void cleanup();}}
  case 'probe':{
   const uiProbe=z.strictObject({scope:scopeSchema,name:z.literal('uiTree')}).safeParse(input);
   if(uiProbe.success){if(!lease || JSON.stringify(uiProbe.data.scope)!==JSON.stringify(lease.scope))throw new Error('Probe lease mismatch');
    const session=lease.session;readonlyCalls++;
    try{return await session.snapshot();}finally{readonlyCalls--;if(closing)void cleanup();}}
   const request=z.strictObject({protocolVersion:z.literal(1),target:targetSchema}).parse(input);
   inventoryUsed=true;
   const client=createAgentDeviceClient({stateDir:root,cwd:root,session:'intents-inventory'});
   readonlyCalls++;try{const result=await client.devices.capabilities({platform:request.target.platform,udid:request.target.id});
   if(result.device.id!==request.target.id)throw new Error('Probe target mismatch');return result;}
   finally{readonlyCalls--;if(closing)void cleanup();}}
  case 'ui.acquire':{
   const request=z.strictObject({scope:scopeSchema,target:targetSchema,lifecycle:z.literal('persistedStateAcrossSegments')}).parse(input);
   if(lease || acquiring || acquisitionReleaseUnknown)throw new Error('Device control already owned or prior termination unverified');acquiring=true;
   try{requirePolicyApproval(await endpoint.reverse('policy.reviewAction',{...request.scope,effect:'activate',target:request.target}));
    if(closing)throw new Error('Acquisition cancelled by shutdown');
    const session=await DeviceSession.create(join(root,'device'),request.target,request.scope,async(scope,action,context,nodeId)=>{
     if(context.signal.aborted)throw new Error('Action cancelled');
     requirePolicyApproval(await endpoint.reverse('policy.reviewAction',{...scope,action,...(nodeId?{controllerNode:nodeId}:{})},Math.min(15000,context.timeoutMs)));
    });
    if(closing){acquisitionReleaseUnknown=true;try{acquisitionReleaseUnknown=!(await session.release()).released;}catch{};throw new Error('Acquisition ended during shutdown');}
    lease={scope:request.scope,session};return {acquired:true,scope:request.scope};
   }catch(error){if(error instanceof DeviceAcquisitionError)acquisitionReleaseUnknown=!error.released;throw error;}
   finally{acquiring=false;if(closing)void cleanup();}}
  case 'ui.runSegment':{
   const segment=segmentSchema.parse(input);if(!lease || releasing || JSON.stringify(segment.scope)!==JSON.stringify(lease.scope))throw new Error('Lease scope mismatch');
   if([...operations.values()].some(o=>['pending','running'].includes(o.state)))throw new Error('A UI segment already owns this control generation');
   const {payloadDigest:claimed,...body}=segment;if(segmentPayloadDigest(body)!==claimed)throw new Error('Segment digest mismatch');
   const session=lease.session;
   const controller=new AbortController();
   const completion=journal.dispatch(`${segment.scope.runId}:${segment.operationId}`,claimed,async()=>{
    if(closing || releasing || controller.signal.aborted || lease?.session!==session)throw new Error('Pending segment cancelled or lease revoked');
    operations.get(segment.operationId)!.state='running';
    try{const result=await runWorker(session,session.target,segment,join(root,'runs',segment.scope.runId,segment.operationId),controller.signal,async(request,context)=>{
     if(context.signal.aborted || lease?.session!==session || closing || releasing)throw new Error('Controller lease is revoked');
     const result=await endpoint.reverse('controller.decide',{...segment.scope,request},Math.min(30000,context.timeoutMs));
     if(context.signal.aborted || lease?.session!==session || closing || releasing)throw new Error('Controller lease is revoked');
     return result;
    });
     operations.get(segment.operationId)!.state='completed';return result;
    }catch(e){operations.get(segment.operationId)!.state='unresolved';throw e;}
   });
   operations.set(segment.operationId,{controller,state:'pending',completion});
   try{const result=await completion;operations.get(segment.operationId)!.state='completed';return result;}
   catch(error){operations.get(segment.operationId)!.state='unresolved';throw error;}}
  case 'ui.release':{const scope=scopeSchema.parse(input);if(!lease || JSON.stringify(scope)!==JSON.stringify(lease.scope))throw new Error('Lease scope mismatch');
   if(releasing || [...operations.values()].some(o=>['pending','running'].includes(o.state)))return {released:false,reason:'Worker or commands still running'};
   releasing=true;try{const result=await lease.session.release();if(result.released)lease=undefined;return result;}finally{releasing=false;}}
  case 'cancel':{const request=z.strictObject({protocolVersion:z.literal(1),operationId:identifier}).parse(input);const operation=operations.get(request.operationId);
   if(!operation)throw new Error('Unknown operation');operation.controller.abort();return {cancellationRequested:true,terminationProven:false};}
  case 'status':{const request=z.strictObject({protocolVersion:z.literal(1),operationId:identifier}).parse(input);return {state:operations.get(request.operationId)?.state??'unknown'};}
  case 'shutdown':z.strictObject({protocolVersion:z.literal(1)}).parse(input);return cleanup();
  default:throw new Error('Unknown method');
 }
});
function closeInput(){try{endpoint.close();}catch{process.exitCode=1;}finally{void cleanup();}}
process.stdin.on('data',chunk=>{void endpoint.receive(chunk).catch(()=>{process.stderr.write('Invalid protocol frame; input closed\n');process.stdin.destroy();process.exitCode=1;closeInput();});});
process.stdin.on('end',closeInput);
process.stdout.on('error',()=>{process.exitCode=1;process.stdin.destroy();closeInput();});
process.once('SIGTERM',()=>{process.stdin.destroy();closeInput();});
