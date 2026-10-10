import {requireMacOwnedInstance} from '../../src/macOwnedSession.js';
import assert from 'node:assert/strict';
import {guardSyntheticDaemonHost} from './macDaemonHostGuard.js';
import {pathToFileURL} from 'node:url';
import {join} from 'node:path';
import {RpcEndpoint} from '../../src/rpc.js';
import {MacOwnedDaemon,type PrivateMacDaemonSDK} from '../../src/macOwnedDaemon.js';
import {scopeSchema,targetSchema} from '../../src/protocol.js';
import type {OperationContext} from 'e2e/engine';

// Synthetic integration entry only: SDK path is test configuration, never customer input.
const state=process.argv[process.argv.indexOf('--state-dir')+1]!;
const {hostCalls,metadataCalls}=guardSyntheticDaemonHost();
let daemon:MacOwnedDaemon|undefined,used=false;
const endpoint=new RpcEndpoint(frame=>process.stdout.write(frame),async(method,input:any)=>{
  assert.equal(method,'hello');assert.equal(used,false);used=true;
  const scope=scopeSchema.parse(input.scope),target=targetSchema.parse(input.target);
  const sdk=await import(pathToFileURL(input.sdk).href) as PrivateMacDaemonSDK;
  daemon=await MacOwnedDaemon.start(sdk,join(state,'owned-mac'),target,scope,input.helperSHA256,input.authentication,endpoint);
  const session=`intents-${scope.runId}-${scope.leaseGeneration}`,transport=daemon.transport;
  const acquired=await transport.open({bundleId:target.bundleId,canonicalBundlePath:target.bundlePath!},scope,session);
  const instance=requireMacOwnedInstance(acquired.applicationTarget);
  const context:OperationContext={origin:'test',runId:scope.runId,attemptId:scope.attemptId,timeoutMs:5000,signal:new AbortController().signal};
  await transport.capture(instance,context);
  let uncertain=false;
  try{await transport.press(instance,{x:10,y:20},context);}catch(error){if(input.mode!=='uncertain')throw error;uncertain=true;}
  if(uncertain)await assert.rejects(()=>transport.press(instance,{x:10,y:20},context));
  const cleanup=await transport.release(scope,instance);
  assert.deepEqual(hostCalls,[]);return {instance,cleanup,uncertain,hostCalls,metadataCalls};
});
process.stdin.on('data',bytes=>{void endpoint.receive(bytes).catch(error=>{process.stderr.write(String(error));process.exitCode=1;process.stdin.destroy();});});
process.stdin.on('end',()=>{void(async()=>{
  if(daemon){/* release was already checked by the parent; no application close is issued */}
  endpoint.close();
})();});
