import {randomUUID} from 'node:crypto';
import {performance} from 'node:perf_hooks';
import {z} from 'zod';
import {scopeSchema,targetSchema,type Scope,type Target} from './protocol.js';
import {requireMacOwnedInstance,requireMacOwnedSelection,type MacOwnedInstance,type MacOwnedSelection} from './macOwnedSession.js';

import {validateMacOrdinaryFillPoint,validateMacOrdinaryFillValue} from './macOrdinaryFill.js';

type HelperOptions={allowFailure?:boolean;timeoutMs?:number;signal?:AbortSignal;kill?:{signal:NodeJS.Signals;graceMs:number}};
export const privateScrollHelperSHA256='068dfd47b668ddb656fdef257382f4763357fe49c0dbdeb89ea1bd634564be4f';
export const privateFillHelperSHA256='e1a073e759f643fa6f04799b4a492fc7cf0ef63d8fd13959e5aca7bbcbd4f576';
export type MacNativeHelperAction =
  | Readonly<{kind:'acquire'}>
  | Readonly<{kind:'snapshot';instance:MacOwnedInstance}>
  | Readonly<{kind:'press';instance:MacOwnedInstance;x:number;y:number}>
  | Readonly<{kind:'scroll';instance:MacOwnedInstance;x:number;y:number;direction:'up'|'down'|'left'|'right'}>
  | Readonly<{kind:'ordinaryFill';instance:MacOwnedInstance;x:number;y:number;value:string}>;
export type MacNativeHelperRequest=Readonly<{requestId:string;scope:Scope;selection:MacOwnedSelection;
  action:MacNativeHelperAction;timeoutMs:number}>;
export type MacNativeHelperExecutor=(request:MacNativeHelperRequest,signal?:AbortSignal)=>Promise<unknown>;
const helperIdentity=z.strictObject({pid:z.number().int().positive().max(2147483647),
  startIdentity:z.string().regex(/^[1-9][0-9]{0,19}:(?:0|[1-9][0-9]{0,5})$/)
    .refine(value=>BigInt(value.split(':')[0]!)<=18446744073709551615n)});
const replySchema=z.strictObject({requestId:z.string().uuid(),scope:scopeSchema,helperABI:z.enum(['startup-gate-v1','startup-gate-v2-private-input']),
  helperSHA256:z.string().regex(/^[a-f0-9]{64}$/),ownedIdentity:helperIdentity,
  startupAcknowledged:z.literal(true),directChildReaped:z.literal(true),pipesDrained:z.literal(true),
  callbacksDrained:z.literal(true),logsTruncated:z.literal(false),exitCode:z.number().int().min(0).max(255),
  stdout:z.string().refine(value=>Buffer.byteLength(value)<=1_048_576),
  stderr:z.string().refine(value=>Buffer.byteLength(value)<=1_048_576)});

/** Private provider boundary only. A native authenticated executor must own the gated
 * helper and lease. This factory does not authenticate a channel, compose the daemon,
 * or qualify GUI input; the customer Mac route remains fenced.
 */
export class MacOwnedHelperProvider {
  private readonly scope:Scope;
  private readonly selection:MacOwnedSelection;
  private instance:MacOwnedInstance|null=null;
  private opened=false;
  private active=false;
  private disabled=false;
  constructor(targetValue:Target,scopeValue:Scope,private helperSHA256:string,private execute:MacNativeHelperExecutor) {
    const target=targetSchema.parse(targetValue);
    this.scope=Object.freeze(scopeSchema.parse(scopeValue));
    if(target.kind!=='nativeMac' || target.platform!=='macos' || !target.bundlePath ||
      !/^[a-f0-9]{64}$/.test(helperSHA256))throw new Error('Require an exact private native helper target');
    this.selection=requireMacOwnedSelection({bundleId:target.bundleId,canonicalBundlePath:target.bundlePath});
  }
  disable():void {this.disabled=true;}
  get inFlight():boolean {return this.active;}
  get supportsScroll():boolean {return this.helperSHA256===privateScrollHelperSHA256 || this.supportsOrdinaryFill;}
  get supportsOrdinaryFill():boolean {return this.helperSHA256===privateFillHelperSHA256;}
  async ordinaryFill(instance:MacOwnedInstance,request:Readonly<{x:number;y:number;value:string}>,context:{timeoutMs:number;signal:AbortSignal}):Promise<unknown> {
    if(!this.supportsOrdinaryFill || !this.instance)throw new Error('Ordinary Mac filling is unavailable');
    requireMacOwnedInstance(instance,this.instance);validateMacOrdinaryFillPoint(request);validateMacOrdinaryFillValue(request.value);
    const action=Object.freeze({kind:'ordinaryFill' as const,instance:this.instance,x:request.x,y:request.y,value:request.value});
    const reply=await this.runAction(action,{timeoutMs:context.timeoutMs,signal:context.signal});
    return z.object({ok:z.literal(true),data:z.unknown()}).parse(JSON.parse(reply.stdout)).data;
  }
  async scroll(instance:MacOwnedInstance,request:Readonly<{x:number;y:number;direction:'up'|'down'|'left'|'right'}>,context:{timeoutMs:number;signal:AbortSignal}):Promise<unknown> {
    requireMacOwnedInstance(instance,this.instance??undefined);
    const reply=await this.run(['owned-scroll','--x',String(request.x),'--y',String(request.y),'--direction',request.direction,
      '--bundle-id',instance.bundleId,'--target-bundle-path',instance.canonicalBundlePath,'--target-pid',String(instance.pid),
      '--target-process-start',instance.processStartIdentity,'--surface','frontmost-app'],{timeoutMs:context.timeoutMs,signal:context.signal});
    return z.object({ok:z.literal(true),data:z.unknown()}).parse(JSON.parse(reply.stdout)).data;
  }
  overrides() {
    const deny=async(..._args:unknown[]):Promise<never>=>{throw new Error('Unowned Apple tool route denied');};
    return {runCommand:deny,macosHelper:{run:(args:string[],options?:HelperOptions)=>this.run(args,options)},
      macosHost:{openBundle:deny,openTarget:deny,readClipboard:deny,writeClipboard:deny,
        readDarkMode:deny,setDarkMode:deny,listApps:deny}};
  }
  private action(args:string[]):MacNativeHelperAction {
    if(!Array.isArray(args) || args.length>32 || args.some(arg=>typeof arg!=='string' || arg.includes('\0') || Buffer.byteLength(arg)>4096))
      throw new Error('Invalid native helper arguments');
    const command=args[0];
    const start=command==='app'?2:1;
    if(command==='app' && args[1]!=='open')throw new Error('Only exact Mac acquisition is allowed');
    const flags=new Map<string,string>();
    for(let index=start;index<args.length;index+=2){
      const key=args[index],value=args[index+1];
      if(!key || !key.startsWith('--') || value===undefined || flags.has(key))throw new Error('Ambiguous native helper arguments');
      flags.set(key,value);
    }
    if(command==='app'){
      if(this.opened || flags.size!==2 || flags.get('--bundle-id')!==this.selection.bundleId ||
        flags.get('--bundle-path')!==this.selection.canonicalBundlePath)throw new Error('Different Mac acquisition');
      return Object.freeze({kind:'acquire'});
    }
    if(!this.instance || !['snapshot','press','owned-scroll'].includes(command??'') || (command==='owned-scroll' && !this.supportsScroll))throw new Error('Owned implemented Mac instance is required');
    const allowed=new Set(['--bundle-id','--target-bundle-path','--target-pid','--target-process-start','--surface']);
    if(command==='press' || command==='owned-scroll'){allowed.add('--x');allowed.add('--y');}
    if(command==='owned-scroll')allowed.add('--direction');
    if(flags.size!==allowed.size || [...flags.keys()].some(key=>!allowed.has(key)) || flags.get('--surface')!=='frontmost-app')
      throw new Error('Unsupported native helper action');
    requireMacOwnedInstance({bundleId:flags.get('--bundle-id'),canonicalBundlePath:flags.get('--target-bundle-path'),
      pid:Number(flags.get('--target-pid')),processStartIdentity:flags.get('--target-process-start')},this.instance);
    if(flags.get('--target-pid')!==String(this.instance.pid))throw new Error('Noncanonical target PID');
    if(command==='snapshot')return Object.freeze({kind:'snapshot',instance:this.instance});
    const x=Number(flags.get('--x')),y=Number(flags.get('--y'));
    if(!Number.isFinite(x) || !Number.isFinite(y) || Math.abs(x)>1_000_000 || Math.abs(y)>1_000_000 ||
      flags.get('--x')!==String(x) || flags.get('--y')!==String(y))throw new Error('Invalid native helper coordinates');
    if(command==='owned-scroll'){
      const direction=z.enum(['up','down','left','right']).parse(flags.get('--direction'));
      return Object.freeze({kind:'scroll',instance:this.instance,x,y,direction});
    }
    return Object.freeze({kind:'press',instance:this.instance,x,y});
  }
  async run(args:string[],options:HelperOptions={}):Promise<{stdout:string;stderr:string;exitCode:number}> {
    return this.runAction(this.action(args),options);
  }
  private async runAction(action:MacNativeHelperAction,options:HelperOptions):Promise<{stdout:string;stderr:string;exitCode:number}> {
    if(this.disabled || this.active)throw new Error('Native helper provider unavailable');
    const permitted=new Set(['allowFailure','timeoutMs','signal','kill']);
    if(Object.keys(options).some(key=>!permitted.has(key)) ||
      (options.allowFailure!==undefined && typeof options.allowFailure!=='boolean') ||
      (options.kill && (options.kill.signal!=='SIGTERM' || options.kill.graceMs!==1000 || Object.keys(options.kill).length!==2)))
      throw new Error('Unowned helper process options denied');
    const timeoutMs=options.timeoutMs??30_000;
    if(!Number.isInteger(timeoutMs) || timeoutMs<=0 || timeoutMs>60_000 || options.signal?.aborted)
      throw new Error('Invalid or cancelled native helper budget');
    const deadline=performance.now()+timeoutMs;
    const request=Object.freeze({requestId:randomUUID(),scope:this.scope,selection:this.selection,action,timeoutMs});
    this.active=true;
    if(action.kind==='acquire')this.opened=true;
    try{
      const reply=replySchema.parse(await this.execute(request,options.signal));
      if(this.disabled || options.signal?.aborted || performance.now()>=deadline || reply.requestId!==request.requestId ||
        reply.helperSHA256!==this.helperSHA256 || reply.helperABI!==(this.supportsOrdinaryFill?'startup-gate-v2-private-input':'startup-gate-v1') || Object.keys(this.scope).some(key=>reply.scope[key as keyof Scope]!==this.scope[key as keyof Scope]))
        throw new Error('Native helper ownership reply differs');
      if(reply.exitCode!==0)throw new Error('Native helper action failed; input may have committed');
      const envelope=z.object({ok:z.literal(true),data:z.unknown()}).parse(JSON.parse(reply.stdout));
      if(action.kind==='acquire'){
        const instance=requireMacOwnedInstance(envelope.data);
        if(instance.bundleId!==this.selection.bundleId || instance.canonicalBundlePath!==this.selection.canonicalBundlePath)
          throw new Error('Different acquired Mac instance');
        this.instance=instance;
      }else{
        const data=z.object({applicationTarget:z.unknown()}).parse(envelope.data);
        requireMacOwnedInstance(data.applicationTarget,action.instance);
        if(action.kind==='press'){
          const receipt=z.object({x:z.number().finite(),y:z.number().finite(),
            disposition:z.literal('submittedUnconfirmed'),releaseSubmitted:z.literal(true)}).parse(envelope.data);
          if(receipt.x!==action.x || receipt.y!==action.y)throw new Error('Native input submission differs');
        }
        if(action.kind==='ordinaryFill'){
          const receipt=z.strictObject({applicationTarget:z.unknown(),x:z.number().finite(),y:z.number().finite(),
            disposition:z.literal('replacementVerified')}).parse(envelope.data);
          if(receipt.x!==action.x || receipt.y!==action.y)throw new Error('Ordinary Mac replacement differs');
        }
        if(action.kind==='scroll'){
          const receipt=z.object({x:z.number().finite(),y:z.number().finite(),direction:z.literal(action.direction),
            disposition:z.literal('submittedUnconfirmed')}).parse(envelope.data);
          if(receipt.x!==action.x || receipt.y!==action.y)throw new Error('Native scroll submission differs');
        }
      }
      return {stdout:reply.stdout,stderr:reply.stderr,exitCode:reply.exitCode};
    }catch(error){this.disabled=true;throw error;}finally{this.active=false;}
  }
}
