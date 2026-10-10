import type {AgentDeviceClient,CaptureSnapshotResult} from 'agent-device';
import {z} from 'zod';
import type {OperationContext} from 'e2e/engine';
import {scopeSchema,targetSchema,type Scope,type Target} from './protocol.js';
import {requireMacOwnedInstance,type MacOwnedInstance,type MacOwnedSelection,type MacOwnedTransport} from './macOwnedSession.js';

import {validateMacOrdinaryFillPoint,validateMacOrdinaryFillValue} from './macOrdinaryFill.js';

type OpenOptions=Parameters<AgentDeviceClient['apps']['open']>[0] & {macBundlePath:string};
export interface MacOwnedSDKClient {
  apps:{open(options:OpenOptions):Promise<{session:string;appBundleId?:string;
    identifiers:{deviceId?:string};applicationTarget?:unknown}>};
  capture:{snapshot(options:Parameters<AgentDeviceClient['capture']['snapshot']>[0]):Promise<CaptureSnapshotResult & {applicationTarget?:unknown}>};
  interactions:{press(options:Parameters<AgentDeviceClient['interactions']['press']>[0]):Promise<unknown>};
}
export type MacOwnedCleanup=(scope:Scope,instance:MacOwnedInstance|null)=>Promise<unknown>;
const pressSchema=z.object({applicationTarget:z.unknown(),x:z.number().finite(),y:z.number().finite(),
  disposition:z.literal('submittedUnconfirmed'),releaseSubmitted:z.literal(true)});

/** Private SDK source connector; caller must validate its packaged SDK/helper before construction.
 * Cleanup is injected because a daemon report alone cannot prove native helper drain/reap.
 * No caller in the customer route constructs this transport while Mac qualification is absent.
 */
export class MacOwnedSDKTransport implements MacOwnedTransport {
  readonly ordinaryFill?: NonNullable<MacOwnedTransport['ordinaryFill']>;
  readonly scroll?: NonNullable<MacOwnedTransport['scroll']>;
  private readonly target:Target;private readonly scope:Scope;private readonly name:string;
  private openStarted=false;private closing=false;private instance:MacOwnedInstance|null=null;
  private commands=0;private cleanupAttempt:Promise<unknown>|undefined;
  private inputUncertain=false;
  constructor(private client:MacOwnedSDKClient,target:Target,scope:Scope,private cleanup:MacOwnedCleanup,
    artifactVariant:'private-owned-mac-source',nativeScroll?:NonNullable<MacOwnedTransport['scroll']>,nativeFill?:NonNullable<MacOwnedTransport['ordinaryFill']>) {
    this.target=Object.freeze(targetSchema.parse(target));this.scope=Object.freeze(scopeSchema.parse(scope));
    if(artifactVariant!=='private-owned-mac-source' || this.target.platform!=='macos' || this.target.kind!=='nativeMac')
      throw new Error('Require the verified private Mac source SDK');
    this.name=`intents-${this.scope.runId}-${this.scope.leaseGeneration}`;
    if(nativeFill)this.ordinaryFill=(instance,request,context)=>this.fillNative(instance,request,context,nativeFill);
    if(nativeScroll)this.scroll=(instance,request,context)=>this.scrollNative(instance,request,context,nativeScroll);
  }
  private fillNative(instance:MacOwnedInstance,request:Readonly<{x:number;y:number;value:string}>,
    context:OperationContext,execute:NonNullable<MacOwnedTransport['ordinaryFill']>):Promise<unknown> {
    this.checkContext(context);requireMacOwnedInstance(instance,this.instance??undefined);
    validateMacOrdinaryFillPoint(request);validateMacOrdinaryFillValue(request.value);
    if(!this.instance || this.inputUncertain)throw new Error('Ordinary Mac fill unavailable');
    return this.command(async()=>{
      try {
        const value=z.strictObject({applicationTarget:z.unknown(),x:z.number().finite(),y:z.number().finite(),
          disposition:z.literal('replacementVerified')}).parse(await execute(instance,request,context));
        this.checkContext(context);requireMacOwnedInstance(value.applicationTarget,instance);
        if(value.x!==request.x || value.y!==request.y)throw new Error('Ordinary Mac point differs');
        return value;
      }catch(error){this.inputUncertain=true;throw error;}
    });
  }
  private scrollNative(instance:MacOwnedInstance,request:Readonly<{x:number;y:number;direction:'up'|'down'|'left'|'right'}>,
    context:OperationContext,execute:NonNullable<MacOwnedTransport['scroll']>):Promise<unknown> {
    this.checkContext(context);
    requireMacOwnedInstance(instance,this.instance??undefined);
    if(!this.instance || this.inputUncertain || !['up','down','left','right'].includes(request.direction) ||
      ![request.x,request.y].every(value=>Number.isFinite(value) && Math.abs(value)<=1_000_000))throw new Error('Invalid or uncertain Mac scroll');
    return this.command(async()=>{
      try {
        const value=z.object({applicationTarget:z.unknown(),x:z.number().finite(),y:z.number().finite(),
          direction:z.literal(request.direction),disposition:z.literal('submittedUnconfirmed')}).parse(await execute(instance,request,context));
        this.checkContext(context);requireMacOwnedInstance(value.applicationTarget,instance);
        if(value.x!==request.x || value.y!==request.y)throw new Error('Mac scroll point differs');
        return value;
      }catch(error){this.inputUncertain=true;throw error;}
    });
  }
  private requireScope(scope:Scope):void {
    const value=scopeSchema.parse(scope);
    if(Object.keys(value).some(key=>value[key as keyof Scope]!==this.scope[key as keyof Scope]))throw new Error('Different Mac SDK scope');
  }
  private async command<T>(body:()=>Promise<T>):Promise<T> {
    if(this.closing || this.commands)throw new Error('Mac SDK transport unavailable');
    this.commands++;
    try{return await body();}finally{this.commands--;}
  }
  private checkContext(context?:OperationContext):void {
    if(context && (context.signal.aborted || !Number.isFinite(context.timeoutMs) || context.timeoutMs<=0 ||
      context.timeoutMs>60_000 || context.runId!==this.scope.runId || context.attemptId!==this.scope.attemptId))
      throw new Error('Invalid or cancelled Mac SDK context');
  }
  open(selection:MacOwnedSelection,scope:Scope,sessionName:string):ReturnType<MacOwnedTransport['open']> {
    this.requireScope(scope);
    if(this.openStarted || sessionName!==this.name || selection.bundleId!==this.target.bundleId ||
      selection.canonicalBundlePath!==this.target.bundlePath)throw new Error('Different Mac SDK selection');
    this.openStarted=true;
    return this.command(async()=>{
      const result=await this.client.apps.open({platform:'macos',target:'desktop',udid:this.target.id,app:this.target.bundleId,
        macBundlePath:selection.canonicalBundlePath,session:this.name,surface:'frontmost-app',relaunch:false});
      // Retain the observed tuple even if the surrounding envelope later fails acquisition.
      this.instance=requireMacOwnedInstance(result.applicationTarget);
      return {applicationTarget:this.instance,deviceId:result.identifiers.deviceId??'',sessionName:result.session,
        appBundleId:result.appBundleId??''};
    });
  }
  capture(instance:MacOwnedInstance,context?:OperationContext):ReturnType<MacOwnedTransport['capture']> {
    if(!this.instance)throw new Error('Mac SDK instance is not acquired');
    requireMacOwnedInstance(instance,this.instance);
    this.checkContext(context);
    return this.command(async()=>{
      const value=await this.client.capture.snapshot({platform:'macos',target:'desktop',udid:this.target.id,session:this.name,
        depth:24,raw:true,forceFull:true,timeoutMs:context?.timeoutMs??60_000});
      return {...value,applicationTarget:requireMacOwnedInstance(value.applicationTarget,instance)};
    });
  }
  press(instance:MacOwnedInstance,point:Readonly<{x:number;y:number}>,context:OperationContext):Promise<unknown> {
    if(!this.instance)throw new Error('Mac SDK instance is not acquired');
    requireMacOwnedInstance(instance,this.instance);
    this.checkContext(context);
    if(this.inputUncertain)throw new Error('Earlier Mac SDK input is unresolved');
    if(![point.x,point.y].every(value=>Number.isFinite(value) && Math.abs(value)<=1_000_000))throw new Error('Invalid Mac SDK point');
    return this.command(async()=>{
      try {
        const value=pressSchema.parse(await this.client.interactions.press({platform:'macos',target:'desktop',udid:this.target.id,
          session:this.name,x:point.x,y:point.y,timeoutMs:context.timeoutMs}));
        this.checkContext(context);
        // Public SDK responses contain normal command metadata in addition to the owned receipt.
        // Project its required fields; the session rechecks identity/point and preserves uncertainty.
        return {...value,applicationTarget:requireMacOwnedInstance(value.applicationTarget,instance)};
      }catch(error){this.inputUncertain=true;throw error;}
    });
  }
  async release(scope:Scope,instance:MacOwnedInstance|null):Promise<unknown> {
    this.requireScope(scope);this.closing=true;
    if(this.commands)throw new Error('Mac SDK commands have not drained');
    if(this.instance){
      if(instance)requireMacOwnedInstance(instance,this.instance);
    }else if(instance)throw new Error('Unknown Mac SDK instance');
    // Do not call app close or sessions.close: the owned private route rejects close,
    // and app-targeted close can quit a different copy through bundle-ID resolution.
    if(!this.cleanupAttempt)this.cleanupAttempt=Promise.resolve().then(()=>this.cleanup(this.scope,this.instance));
    return this.cleanupAttempt;
  }
}
