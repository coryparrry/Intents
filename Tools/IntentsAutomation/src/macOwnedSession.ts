import {z} from 'zod';
import type {CaptureSnapshotResult} from 'agent-device';
import {EngineError, type LocatorAction, type OperationContext} from 'e2e/engine';
import {DeviceAcquisitionError, type Policy, type UIBackend} from './deviceSession.js';
import {scopeSchema, targetSchema, type Scope, type Target} from './protocol.js';
import {validateMacOrdinaryFillValue} from './macOrdinaryFill.js';
import {fingerprint, supportsFill, positivelyVisible, secureAncestry, structurallyIncomplete} from './e2e/semanticTree.js';

const selectionSchema = z.strictObject({
  bundleId:z.string().regex(/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$/).max(256),
  canonicalBundlePath:z.string().refine(path=>path.startsWith('/') && path.toLowerCase().endsWith('.app') &&
    !path.includes('\0') && new TextEncoder().encode(path).length<=4096 &&
    !path.split('/').slice(1).some(part=>['','.','..'].includes(part))),
});
const instanceSchema = selectionSchema.extend({pid:z.number().int().positive().max(2147483647),
  processStartIdentity:z.string().regex(/^[1-9][0-9]{0,19}:(?:0|[1-9][0-9]{0,5})$/)
    .refine(value=>BigInt(value.split(':')[0]!)<=18446744073709551615n),
});
export type MacOwnedSelection = Readonly<z.infer<typeof selectionSchema>>;
export type MacOwnedInstance = Readonly<z.infer<typeof instanceSchema>>;
export function requireMacOwnedSelection(value:unknown):MacOwnedSelection {
  if(!value || typeof value!=='object' || ![Object.prototype,null].includes(Object.getPrototypeOf(value)))
    throw new Error('Mac selection must be plain identity data');
  return Object.freeze(selectionSchema.parse(value));
}
export function requireMacOwnedInstance(value:unknown, expected?:MacOwnedInstance):MacOwnedInstance {
  if(!value || typeof value!=='object' || ![Object.prototype,null].includes(Object.getPrototypeOf(value)))
    throw new Error('Mac instance must be plain identity data');
  const instance=Object.freeze(instanceSchema.parse(value));
  if(expected && Object.keys(instance).some(key=>instance[key as keyof MacOwnedInstance]!==expected[key as keyof MacOwnedInstance]))
    throw new Error('Different Mac application instance');
  return instance;
}

export interface MacOwnedTransport {
  open(selection:MacOwnedSelection,scope:Scope,sessionName:string):Promise<{
    applicationTarget:unknown;deviceId:string;sessionName:string;appBundleId:string;
  }>;
  capture(instance:MacOwnedInstance,context?:OperationContext):Promise<CaptureSnapshotResult & {applicationTarget:unknown}>;
  press(instance:MacOwnedInstance,point:Readonly<{x:number;y:number}>,context:OperationContext):Promise<unknown>;
  ordinaryFill?(instance:MacOwnedInstance,request:Readonly<{x:number;y:number;value:string}>,context:OperationContext):Promise<unknown>;
  scroll?(instance:MacOwnedInstance,request:Readonly<{x:number;y:number;direction:'up'|'down'|'left'|'right'}>,context:OperationContext):Promise<unknown>;
  release(scope:Scope,instance:MacOwnedInstance|null):Promise<unknown>;
}
const releaseSchema=z.strictObject({scope:scopeSchema,applicationTarget:instanceSchema.nullable(),
  commandsDrained:z.boolean(),ownedHelperReaped:z.boolean(),daemonStopped:z.boolean(),subjectTerminated:z.literal(false)});
function released(value:unknown,scope:Scope,instance:MacOwnedInstance|null):boolean {
  const evidence=releaseSchema.parse(value);
  if(Object.keys(scope).some(key=>scope[key as keyof Scope]!==evidence.scope[key as keyof Scope]))return false;
  if(instance)requireMacOwnedInstance(evidence.applicationTarget,instance);
  else if(evidence.applicationTarget!==null)return false;
  return evidence.commandsDrained && evidence.ownedHelperReaped && evidence.daemonStopped;
}
function check(context:OperationContext|undefined,deadline:number):void {
  if(context && (!Number.isFinite(context.timeoutMs) || context.timeoutMs<=0 || context.timeoutMs>60_000))
    throw new EngineError('OPERATION_TIMEOUT','Invalid Mac operation budget',{retryable:false});
  if(context?.signal.aborted)throw new EngineError('CANCELLED','Mac operation cancelled',{retryable:false});
  if(Date.now()>=deadline)throw new EngineError('OPERATION_TIMEOUT','Mac operation expired',{retryable:false});
}
function reference(ref:string):string {
  if(!/^@?[A-Za-z0-9_-]{1,128}(?:~s[1-9][0-9]*)?$/.test(ref))throw new Error('Invalid Mac node reference');
  return `@${ref.split('~s')[0]!.replace(/^@/,'')}`;
}

/** Injected source contract only. DeviceSession.create retains the customer Mac fence.
 * A production transport still needs packaged SDK provenance and independent native release qualification.
 */
export class MacOwnedSession implements UIBackend {
  readonly implementedActions: readonly ('tap'|'fill'|'swipe')[];
  get supportsOrdinaryFill():boolean {return this.implementedActions.includes('fill');}
  get supportsScroll():boolean {return this.implementedActions.includes('swipe');}
  private closing=false;private inFlight=0;private releaseAttempt:Promise<{released:boolean;reason:string}>|undefined;
  private observedRefs=new Map<string,{fingerprint:string;reference:string}>();
  private inputUncertain=false;
  selectionEvidence:Readonly<Record<string,unknown>>;
  private constructor(readonly target:Target,readonly scope:Scope,readonly instance:MacOwnedInstance,
    private transport:MacOwnedTransport,private policy:Policy,private sessionName:string) {
    this.implementedActions=Object.freeze(['tap',...(transport.ordinaryFill?['fill' as const]:[]),...(transport.scroll?['swipe' as const]:[])] as ('tap'|'fill'|'swipe')[]);
    this.selectionEvidence=Object.freeze({scope,deviceId:target.id,sessionName,applicationTarget:instance,
      artifactVariant:'private-owned-mac-source',hardwareQualified:false});
  }
  static async acquire(targetValue:Target,scopeValue:Scope,transport:MacOwnedTransport,policy:Policy):Promise<MacOwnedSession> {
    const target=Object.freeze(targetSchema.parse(targetValue)),scope=Object.freeze(scopeSchema.parse(scopeValue));
    if(target.kind!=='nativeMac' || target.platform!=='macos' || !target.bundlePath || !target.loginSession)
      throw new DeviceAcquisitionError(true,'Mac source adapter requires exact application selection');
    const selection=Object.freeze(selectionSchema.parse({bundleId:target.bundleId,canonicalBundlePath:target.bundlePath}));
    const name=`intents-${scope.runId}-${scope.leaseGeneration}`;
    let instance:MacOwnedInstance|null=null;
    try {
      const result=await transport.open(selection,scope,name);
      const observed=requireMacOwnedInstance(result.applicationTarget);
      instance=observed;
      if(observed.bundleId!==selection.bundleId || observed.canonicalBundlePath!==selection.canonicalBundlePath ||
        result.deviceId!==target.id || result.sessionName!==name || result.appBundleId!==target.bundleId)
        throw new Error('Mac open selection mismatch');
      return new MacOwnedSession(target,scope,instance,transport,policy,name);
    }catch(error) {
      let cleanup=false;
      try{cleanup=released(await transport.release(scope,instance),scope,instance);}catch{}
      throw new DeviceAcquisitionError(cleanup,'Mac source acquisition failed');
    }
  }
  private async command<T>(body:()=>Promise<T>):Promise<T> {
    this.ensureOpen();
    if(this.inFlight)throw new EngineError('ENGINE_FAILURE','Mac source command already running',{retryable:false});
    this.inFlight++;
    try{return await body();}finally{this.inFlight--;}
  }
  private ensureOpen():void {
    if(this.closing)throw new EngineError('ENGINE_FAILURE','Mac source session is closing',{retryable:false});
  }
  private async capture(context?:OperationContext):Promise<CaptureSnapshotResult> {
    const timeout=context?.timeoutMs??60_000;
    if(!Number.isFinite(timeout) || timeout<=0 || timeout>60_000)
      throw new EngineError('OPERATION_TIMEOUT','Invalid Mac capture budget',{retryable:false});
    const deadline=Date.now()+timeout;check(context,deadline);
    const result=await this.transport.capture(this.instance,context);check(context,deadline);
    requireMacOwnedInstance(result.applicationTarget,this.instance);
    if(result.appBundleId!==this.target.bundleId || result.identifiers?.session!==this.sessionName ||
      !Array.isArray(result.nodes) || result.nodes.length>5000 || new Set(result.nodes.map(n=>n.index)).size!==result.nodes.length ||
      !Number.isSafeInteger(result.refsGeneration) || result.refsGeneration!<=0)
      throw new EngineError('ENGINE_FAILURE','Mac snapshot identity or bounds differ',{retryable:false});
    const nodes=new Map(result.nodes.map(node=>[node.index,node]));
    return {...result,nodes:result.nodes.map(node=>{
      if(!secureAncestry(node,nodes))return node;
      const {value,...safe}=node;return safe;
    })};
  }
  snapshot(context?:OperationContext):Promise<CaptureSnapshotResult> {return this.command(async()=>{
    const result=await this.capture(context);this.observedRefs.clear();
    const counts=new Map<string,number>();
    for(const node of result.nodes){const key=reference(node.ref);counts.set(key,(counts.get(key)??0)+1);}
    for(const node of result.nodes){
      const key=reference(node.ref);
      if(counts.get(key)===1)this.observedRefs.set(`${key}~s${result.refsGeneration}`,{fingerprint:fingerprint(node),reference:key});
    }
    return result;
  });}
  perform(ref:string,action:LocatorAction,context:OperationContext,nodeId?:string):Promise<void> {
    return this.command(async()=>{
      const deadline=Date.now()+context.timeoutMs;check(context,deadline);
      if(this.inputUncertain)throw new EngineError('ACTION_MAY_HAVE_COMMITTED','Earlier Mac input is unresolved',{retryable:false});
      if(action.kind!=='tap' && !(action.kind==='fill' && this.supportsOrdinaryFill && this.transport.ordinaryFill && action.sensitive!==true) && !(action.kind==='swipe' && this.supportsScroll && this.transport.scroll &&
        ['up','down','left','right'].includes(action.direction) && (action.momentum===undefined || action.momentum==='slow') && ref==='root'))
        throw new EngineError('UNSUPPORTED_CAPABILITY','Mac action is outside implemented input capabilities',{retryable:false});
      if(action.kind==='fill')validateMacOrdinaryFillValue(action.value);
      const scrollAction=action.kind==='swipe'?action:undefined;
      const observed=action.kind!=='swipe'?this.observedRefs.get(ref):undefined;
      if(action.kind!=='swipe' && !observed)throw new EngineError('NODE_STALE','Mac action has no prior unique observation',{retryable:false});
      await this.policy(this.scope,action,context,nodeId);check(context,deadline);this.ensureOpen();
      const snapshot=await this.capture({...context,timeoutMs:Math.min(60_000,deadline-Date.now())});
      check(context,deadline);this.ensureOpen();
      const matches=snapshot.nodes.filter(node=>action.kind!=='swipe'?reference(node.ref)===observed!.reference:
        [node.role,node.kind].some(value=>['axscrollarea','scrollarea'].includes(value?.toLowerCase().replace(/[^a-z]/g,'')??'')));
      const node=matches.length===1?matches[0]:undefined;
      const nodes=new Map(snapshot.nodes.map(candidate=>[candidate.index,candidate]));
      const prior=action.kind!=='swipe'?observed:node?[...this.observedRefs.values()].find(value=>value.reference===reference(node.ref) && value.fingerprint===fingerprint(node)):undefined;
      if(!node || !prior || fingerprint(node)!==prior.fingerprint || !positivelyVisible(node) || secureAncestry(node,nodes) ||
        structurallyIncomplete(snapshot) || snapshot.truncated!==false || snapshot.visibility?.partial===true ||
        (node.bundleId!==undefined && node.bundleId!==this.target.bundleId) || !node.rect)
        throw new EngineError('NODE_STALE','Mac input requires one fresh visible owned node',{retryable:false});
      if(action.kind==='fill' && (!['AXTextField','AXTextArea'].includes(node.role??'') || node.editable!==true || !supportsFill(node,'macos')))throw new EngineError('UNSUPPORTED_CAPABILITY','Fresh Mac field has no text-entry capability',{retryable:false});
      const {x,y,width,height}=node.rect;
      const point=Object.freeze({x:x+width/2,y:y+height/2});
      if(![x,y,width,height,point.x,point.y].every(Number.isFinite) || width<=0 || height<=0 ||
        Math.abs(point.x)>1_000_000 || Math.abs(point.y)>1_000_000)
        throw new EngineError('NODE_STALE','Mac node coordinates invalid',{retryable:false});
      check(context,deadline);
      try {
        const value=action.kind==='tap'?await this.transport.press(this.instance,point,{...context,timeoutMs:deadline-Date.now()}):
          action.kind==='fill'?await this.transport.ordinaryFill!(this.instance,{...point,value:action.value},{...context,timeoutMs:deadline-Date.now()}):
          await this.transport.scroll!(this.instance,{...point,direction:scrollAction!.direction},{...context,timeoutMs:deadline-Date.now()});
        check(context,deadline);
        const receipt=action.kind==='tap'?z.strictObject({applicationTarget:instanceSchema,x:z.number(),y:z.number(),
          disposition:z.literal('submittedUnconfirmed'),releaseSubmitted:z.literal(true)}).parse(value):
          action.kind==='fill'?z.strictObject({applicationTarget:instanceSchema,x:z.number(),y:z.number(),disposition:z.literal('replacementVerified')}).parse(value):
          z.strictObject({applicationTarget:instanceSchema,x:z.number(),y:z.number(),direction:z.literal(scrollAction!.direction),
            disposition:z.literal('submittedUnconfirmed')}).parse(value);
        requireMacOwnedInstance(receipt.applicationTarget,this.instance);
        if(receipt.x!==point.x || receipt.y!==point.y)throw new Error('Mac point echo mismatch');
        this.selectionEvidence=Object.freeze({...this.selectionEvidence,lastInputDisposition:action.kind==='fill'?'replacementVerified':'submittedUnconfirmed'});
      }catch(error) {
        this.inputUncertain=true;
        throw new EngineError('ACTION_MAY_HAVE_COMMITTED','Mac input submission is unresolved',{retryable:false,cause:error});
      }
    });
  }
  async release():Promise<{released:boolean;reason:string}> {
    this.closing=true;
    if(this.inFlight)return {released:false,reason:'Mac commands are still running'};
    if(!this.releaseAttempt)this.releaseAttempt=(async()=>{
      try {
        const proved=released(await this.transport.release(this.scope,this.instance),this.scope,this.instance);
        return {released:proved,reason:proved?'Injected Mac cleanup evidence matched':'Mac owned cleanup is unverified'};
      }catch{return {released:false,reason:'Mac owned cleanup is unverified'};}
    })();
    return this.releaseAttempt;
  }
}
