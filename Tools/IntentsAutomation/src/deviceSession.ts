import { createAgentDeviceClient, type AgentDeviceClient, type AgentDeviceDevice, type CaptureSnapshotResult } from 'agent-device';
import { EngineError, type LocatorAction, type OperationContext } from 'e2e/engine';
import { mkdir, realpath, readFile, writeFile, readdir } from 'node:fs/promises';
import {stopPrivateDaemon} from './lifecycle.js';
import {join} from 'node:path';
import type { Scope, Target } from './protocol.js';
export type Policy = (scope:Scope, action:LocatorAction, context:OperationContext,nodeId?:string)=>Promise<void>;
export class DeviceAcquisitionError extends Error {
 constructor(readonly released:boolean,reason='Exact device acquisition failed'){super(reason+'; release '+(released?'proved':'unverified'));}
}
export interface UIBackend {
  readonly implementedActions?: readonly ('tap'|'fill'|'swipe')[];
  snapshot(context?:OperationContext):Promise<CaptureSnapshotResult>;
  perform(ref:string,action:LocatorAction,context:OperationContext,nodeId?:string):Promise<void>;
  release():Promise<{released:boolean;reason:string}>;
}
export function selectExact(devices:AgentDeviceDevice[],target:Target):AgentDeviceDevice {
  const matches=devices.filter(d=>d.id===target.id && d.platform===target.platform &&
    (target.kind==='nativeMac'?d.target==='desktop':d.kind===(target.kind==='physical'?'device':'simulator')));
  if(matches.length!==1) throw new Error('Exact target is missing or ambiguous');return matches[0]!;
}
export class DeviceSession implements UIBackend {
  private inFlight=0;private closing=false;
  private captures=0;
  selectionEvidence:unknown;
  private constructor(private client:AgentDeviceClient,readonly target:Target,readonly scope:Scope,private policy:Policy,private stateDir:string){}
  static async create(stateDir:string,target:Target,scope:Scope,policy:Policy):Promise<DeviceSession>{
    // The pinned Mac helper resolves apps by bundle ID and posts global HID
    // events. A selected bundle path cannot prove the recipient of that input.
    // Reject before allocating state, creating a client or activating any app.
    if(target.kind==='nativeMac')throw new DeviceAcquisitionError(true,'Native Mac exact-process input ownership is not qualified');
    await mkdir(stateDir,{recursive:true,mode:0o700});
    if(await realpath(stateDir)!==stateDir)throw new Error('Noncanonical private device state');
    const marker=join(stateDir,'intents-owner.json');
    try{const owner=JSON.parse(await readFile(marker,'utf8'));
      if(owner.runId!==scope.runId || owner.targetId!==target.id || owner.bundleId!==target.bundleId)throw new Error('Foreign device state directory');
    }catch(error){if((error as NodeJS.ErrnoException).code!=='ENOENT')throw error;
      if((await readdir(stateDir)).length)throw new Error('Unowned nonempty device state directory');
      await writeFile(marker,JSON.stringify({runId:scope.runId,targetId:target.id,bundleId:target.bundleId}),{mode:0o600,flag:'wx'});
    }
    const client=createAgentDeviceClient({stateDir,session:`intents-${scope.runId}-${scope.leaseGeneration}`,cwd:stateDir,
      lockPolicy:'reject'});
    try{
    const devices=await client.devices.list({platform:target.platform});selectExact(devices,target);
    if(target.platform==='macos' && await realpath(target.bundlePath!)!==target.bundlePath) throw new Error('Noncanonical Mac path');
    const capabilities=await client.devices.capabilities({platform:target.platform,udid:target.id});
    selectExact([capabilities.device],target);
    // Activation is explicit acquisition, never an engine lifecycle or observation hook.
    const opened=await client.apps.open({platform:target.platform,udid:target.id,
      app:target.bundlePath??target.bundleId,relaunch:false});
    if((opened.identifiers.udid??opened.identifiers.deviceId)!==target.id || opened.identifiers.appBundleId!==target.bundleId)
      throw new Error('Backend selected a different app or target');
    return new DeviceSession(client,target,scope,policy,stateDir);
    }catch{
      let released=false;
      try{released=(await stopPrivateDaemon(stateDir)).released;}catch{}
      throw new DeviceAcquisitionError(released);
    }
  }
  private async command<T>(body:()=>Promise<T>):Promise<T>{
    if(this.closing) throw new Error('UI lease is closing');this.inFlight++;
    try{return await body();}finally{this.inFlight--;}
  }
  async snapshot(context?:OperationContext):Promise<CaptureSnapshotResult>{return this.command(async()=>{
    // The pinned SDK allows 45s for a cold XCTest connection. Keep that inside
    // a bounded capture budget without extending a shorter caller deadline.
    const requested=context?.timeoutMs??60000;
    if(!Number.isSafeInteger(requested)||requested<=0)throw new EngineError('OPERATION_TIMEOUT','Invalid snapshot deadline',{retryable:false});
    const timeoutMs=Math.min(60000,requested),deadline=Date.now()+timeoutMs;
    const check=()=>{if(context?.signal.aborted)throw new EngineError('CANCELLED','Snapshot cancelled',{retryable:false});
      if(Date.now()>=deadline)throw new EngineError('OPERATION_TIMEOUT','Snapshot expired',{retryable:false});};
    check();
    const capture=++this.captures;if(capture>512)throw new EngineError('ENGINE_FAILURE','Capture limit reached',{retryable:false});
    // Full raw capture disables the SDK's presentation delta optimization.
    // Evidence and fresh locator resolution must not use an abbreviated diff.
    const result=await this.client.capture.snapshot({depth:24,raw:true,forceFull:true,timeoutMs});
    check();
    if(result.nodes.length>5000)throw new EngineError('ENGINE_FAILURE','Capture exceeds evidence bound',{retryable:false});
    const capturedIndices=new Set(result.nodes.map(node=>node.index));
    await writeFile(join(this.stateDir,`generation-${this.scope.leaseGeneration}-snapshot-${capture}.metadata.json`),JSON.stringify({schemaVersion:1,
      nodes:result.nodes.length,truncated:result.truncated??null,partial:result.visibility?.partial??null,
      visibleNodes:result.visibility?.visibleNodeCount??null,totalNodes:result.visibility?.totalNodeCount??null,
      appBundleId:result.appBundleId??null,session:result.identifiers?.session??null,
      missingParents:result.nodes.filter(node=>node.parentIndex!==undefined&&!capturedIndices.has(node.parentIndex)).length,
      hiddenContent:result.nodes.filter(node=>node.hiddenContentAbove||node.hiddenContentBelow).length}),{flag:'wx',mode:0o600});
    const name=`intents-${this.scope.runId}-${this.scope.leaseGeneration}`;
    const sessions=(await this.client.sessions.list()).filter(session=>session.name===name);
    check();
    if(sessions.length!==1 || sessions[0]!.device.id!==this.target.id || result.identifiers?.session!==name || result.appBundleId!==this.target.bundleId)
      throw new Error('Snapshot/session identity mismatch');
    this.selectionEvidence={scope:this.scope,sessionName:name,device:sessions[0]!.device,observedBundleId:result.appBundleId};
    return {...result,nodes:result.nodes.map(node=>{if(!node.password)return node;const {value,...safe}=node;return safe;})};
  });}
  async perform(ref:string,action:LocatorAction,context:OperationContext,nodeId?:string):Promise<void>{
    const deadline=Date.now()+context.timeoutMs;
    const check=()=>{if(context.signal.aborted)throw new EngineError('CANCELLED','Action cancelled',{retryable:false});
      if(Date.now()>=deadline)throw new EngineError('OPERATION_TIMEOUT','Action expired',{retryable:false});};
    check();await this.policy(this.scope,action,context,nodeId);check();
    await this.command(async()=>{
      try {
        switch(action.kind){
          case 'tap': await this.client.interactions.press({ref,verify:true});break;
          case 'fill':
            if(action.sensitive) throw new EngineError('UNSUPPORTED_CAPABILITY','Secret filling is not qualified',{retryable:false});
            await this.client.interactions.fill({ref,text:action.value,verify:true});break;
          case 'swipe': await this.client.interactions.scroll({direction:action.direction});break;
          default: throw new EngineError('UNSUPPORTED_CAPABILITY',`Unsupported action ${action.kind}`,{retryable:false});
        }
      } catch(error){
        if(error instanceof EngineError) throw error;
        // Backend errors after a mutation dispatch are never considered safe retries.
        throw new EngineError('ACTION_MAY_HAVE_COMMITTED','Backend action outcome is unresolved',{retryable:false,cause:error});
      }
    });
  }
  async release():Promise<{released:boolean;reason:string}>{
    this.closing=true;if(this.inFlight) return {released:false,reason:'Commands are still running'};
    let sessionClosed=true;
    try{await this.client.sessions.close({saveScript:false});}catch{sessionClosed=false;}
    // SDK application-lifecycle cleanup can fail after its runner stops. Always
    // attempt the separate owned-daemon cleanup, retaining either failure.
    let daemon:{released:boolean;reason:string};
    try{daemon=await stopPrivateDaemon(this.stateDir);}catch{return {released:false,reason:'Private daemon cleanup failed'};}
    return sessionClosed?daemon:{released:false,reason:'Owned session close failed'};
  }
}
