import {join} from 'node:path';
import {z} from 'zod';
import {MacOwnedDaemon,type PrivateMacDaemonSDK} from './macOwnedDaemon.js';
import {MacOwnedDaemonLifetime} from './macOwnedDaemonLifetime.js';
import {RpcEndpoint} from './rpc.js';
import {scopeSchema,targetSchema,type Scope,type Target} from './protocol.js';
import {requireMacOwnedInstance,type MacOwnedInstance} from './macOwnedSession.js';
import type {OperationContext} from 'e2e/engine';
import {MacOwnedSession} from './macOwnedSession.js';
import {MacOwnedProgramController} from './macOwnedProgramController.js';
import {OperationJournal} from './operationJournal.js';
import {segmentSchema} from './segment.js';
import {privateFillHelperSHA256} from './macOwnedHelperProvider.js';
import {requirePolicyApproval,PolicyDeniedError} from './policyReview.js';

// Separate private artifact entry. The normal product main never imports this file.
const helperSHA256=privateFillHelperSHA256;
const state=process.argv[process.argv.indexOf('--state-dir')+1];
if(!state || !state.startsWith('/'))throw new Error('Private state directory required');
let daemon:MacOwnedDaemon|undefined,scope:Scope|undefined,target:Target|undefined,instance:MacOwnedInstance|null=null;
let program:MacOwnedProgramController|undefined;
let acquiring=false;
const hello=z.strictObject({scope:scopeSchema,target:targetSchema,authentication:z.string().regex(/^[a-f0-9]{64}$/),helperSHA256:z.literal(helperSHA256)});
function sameScope(value:Scope){if(!scope || JSON.stringify(value)!==JSON.stringify(scope))throw new Error('Different private daemon scope');}
const lifetime=new MacOwnedDaemonLifetime<MacOwnedDaemon>(async value=>{
  if(!scope)throw new Error('Missing private cleanup scope');
  const programDrained=await program?.stop()??true;
  const native=await value.cleanup(scope,instance) as {commandsDrained:boolean;ownedHelperReaped:boolean;daemonStopped:boolean};
  const result={...native,commandsDrained:native.commandsDrained && programDrained};
  return {...result,resourcesReleased:result.commandsDrained && result.ownedHelperReaped && result.daemonStopped};
});
const cleanup=()=>{program?.cancel();return lifetime.stop();};
const endpoint=new RpcEndpoint(frame=>process.stdout.write(frame),async(method,params)=>{
  if(method==='hello'){
    if(!lifetime.canStart)throw new Error('Private daemon lifetime unavailable');
    const input=hello.parse(params);scope=input.scope;target=input.target;
    // Stager fixes this path; no environment or request can choose another SDK.
    const sdkURL=new URL('../../sdk/dist/src/intents-daemon.js',import.meta.url);
    daemon=await lifetime.start(async()=>{
      const sdk=await import(sdkURL.href) as PrivateMacDaemonSDK;
      return await MacOwnedDaemon.start(sdk,join(state,'owned-mac'),input.target,input.scope,helperSHA256,input.authentication,endpoint);
    });
    return {protocolVersion:1,artifactVariant:'private-owned-mac-daemon-integration',customerRuntimeEnabled:false,hardwareQualified:false};
  }
  if(method==='shutdown')return await cleanup();
  if(!lifetime.active || !daemon || !scope || !target)throw new Error('Private daemon unavailable');
  if(method==='status')return {artifactVariant:'private-owned-mac-daemon-integration',customerRuntimeEnabled:false,hardwareQualified:false};
  if(method==='ui.acquire'){
    const input=z.strictObject({scope:scopeSchema,programMode:z.literal(true).optional()}).parse(params);sameScope(input.scope);
    if(instance || program || acquiring)throw new Error('Private application already acquired');
    acquiring=true;
    try{
    if(input.programMode){
      requirePolicyApproval(await endpoint.reverse('policy.reviewAction',{...scope,effect:'activate',target}));
      if(!lifetime.active)throw new PolicyDeniedError('routeRevoked');
      const session=await MacOwnedSession.acquire(target,scope,daemon.transport,async(selected,action,context,nodeId)=>{
        if(!lifetime.active || context.signal.aborted)throw new PolicyDeniedError('routeRevoked');
        requirePolicyApproval(await endpoint.reverse('policy.reviewAction',
          {...selected,action,...(nodeId?{controllerNode:nodeId}:{})},Math.min(15000,context.timeoutMs)));
        if(!lifetime.active || context.signal.aborted)throw new PolicyDeniedError('routeRevoked');
      });
      instance=session.instance;
      const journal=new OperationJournal(join(state,'mac-program-operations.json'));await journal.load();
      if(!lifetime.active)throw new Error('Private Mac program acquisition stopped');
      const selected=scope;
      program=new MacOwnedProgramController(session,join(state,'mac-programs'),journal,async(pid,signal)=>{
        if(!lifetime.active || signal.aborted)throw new Error('Private Mac worker revoked');
        const admission=z.strictObject({allowed:z.literal(true)}).parse(await endpoint.reverse('ui.workerStarted',{...selected,pid},15000));
        if(!admission.allowed || !lifetime.active || signal.aborted)throw new Error('Private Mac worker revoked');
      },async(request,context)=>{
        if(!lifetime.active || context.signal.aborted)throw new Error('Private Mac controller revoked');
        const result=await endpoint.reverse('controller.decide',{...selected,request},Math.min(30000,context.timeoutMs));
        if(!lifetime.active || context.signal.aborted)throw new Error('Private Mac controller revoked');return result;
      });
      return {applicationTarget:instance};
    }
    const value=await daemon.transport.open({bundleId:target.bundleId,canonicalBundlePath:target.bundlePath!},scope,`intents-${scope.runId}-${scope.leaseGeneration}`);
    if(!lifetime.active)throw new Error('Private acquisition was stopped');
    instance=requireMacOwnedInstance(value.applicationTarget);
    return {applicationTarget:instance};
    }finally{acquiring=false;}
  }
  if(method==='ui.release'){
    const input=z.strictObject({scope:scopeSchema}).parse(params);sameScope(input.scope);return await cleanup();
  }
  if(method==='ui.runSegment'){
    if(program){
      const input=segmentSchema.parse(params);sameScope(input.scope);
      const receipt=await program.run(input);
      if(!lifetime.active)throw new Error('Private Mac program stopped');return {applicationTarget:instance,receipt};
    }
    const input=z.strictObject({scope:scopeSchema,operation:z.enum(['capture','press']),applicationTarget:z.unknown(),
      x:z.number().finite().optional(),y:z.number().finite().optional(),timeoutMs:z.number().int().min(1).max(60000)}).parse(params);
    sameScope(input.scope);if(!instance)throw new Error('No selected private application');
    requireMacOwnedInstance(input.applicationTarget,instance);
    const context:OperationContext={origin:'agent',runId:scope.runId,attemptId:scope.attemptId,timeoutMs:input.timeoutMs,signal:new AbortController().signal};
    if(input.operation==='capture'){
      if(input.x!==undefined || input.y!==undefined)throw new Error('Capture does not accept a point');
      const result=await daemon.transport.capture(instance,context);
      if(!lifetime.active)throw new Error('Private capture was stopped');return result;
    }
    if(input.x===undefined || input.y===undefined)throw new Error('Press requires a point');
    const result=await daemon.transport.press(instance,{x:input.x,y:input.y},context);
    if(!lifetime.active)throw new Error('Private input was stopped');return result;
  }
  if(method==='cancel')return await cleanup();
  throw new Error('Unsupported private daemon method');
});
let termination:Promise<void>|undefined;
function terminate(failed:boolean){
  if(failed)process.exitCode=1;
  if(termination)return termination;
  // Definitive input loss cannot yield any further native proof. Reject pending
  // callbacks before cleanup drains HTTP requests; retain the negative proof.
  try{endpoint.close();}catch{process.exitCode=1;}
  return termination=cleanup().then(result=>{if(!(result as {resourcesReleased:boolean}).resourcesReleased)process.exitCode=1;},()=>{process.exitCode=1;});
}
process.stdin.on('data',bytes=>{void endpoint.receive(bytes).catch(()=>{void terminate(true);process.stdin.destroy();});});
process.stdin.on('end',()=>{void terminate(false);});
process.stdin.on('close',()=>{void terminate(false);});
process.stdin.on('error',()=>{void terminate(true);});
