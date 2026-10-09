import {mkdir,realpath,readdir} from 'node:fs/promises';
import {dirname,join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {z} from 'zod';
import {scopeSchema,targetSchema,type Scope,type Target} from './protocol.js';
import {MacOwnedHelperProvider} from './macOwnedHelperProvider.js';
import {MacOwnedSDKTransport,type MacOwnedSDKClient} from './macOwnedSDKTransport.js';
import {requireMacOwnedInstance,type MacOwnedInstance,type MacOwnedTransport} from './macOwnedSession.js';
import type {RpcEndpoint} from './rpc.js';
import type {OperationContext} from 'e2e/engine';

type NativeChannel=Pick<RpcEndpoint,'reverse'>;
type Device={platform:'apple';appleOs:'macos';id:string;name:string;kind:'device';target:'desktop'};
type Controller={httpPort?:number;token:string;drainOwnedRequests?:(timeoutMs:number)=>Promise<boolean>;shutdown():Promise<void>};
type WireRequest=Record<string,unknown>;
export interface PrivateMacDaemonSDK {
  startDaemonRuntime(options:{env:Record<string,string>;registerProcessHandlers:false;exit:(code:number)=>void;
    stdout:{write:(text:string)=>void};stderr:{write:(text:string)=>void};
    appleToolProvider:(context:{device:{id:string};session?:{name:string}})=>unknown;
    intentsOwnedMac:{deviceId:string;inventory:{discover:()=>Promise<{kind:'inventory';devices:Device[]}>};
      admitRequest:(request:unknown)=>boolean}}):Promise<Controller|null>;
  createLocalAppleToolProvider(overrides:ReturnType<MacOwnedHelperProvider['overrides']>):unknown;
  createAgentDeviceClient(config:{cwd:string;stateDir:string;session:string;daemonAuthToken:string},
    dependencies:{transport:(request:WireRequest)=>Promise<any>}):MacOwnedSDKClient;
}
const wire=z.object({session:z.string(),command:z.enum(['open','snapshot','press']),positionals:z.array(z.string()).max(2),
  flags:z.record(z.string(),z.unknown()),meta:z.strictObject({cwd:z.string(),sessionExplicit:z.literal(true),requestId:z.string().min(1).max(128).optional(),tenantId:z.undefined().optional(),sessionIsolation:z.undefined().optional()}),runtime:z.record(z.string(),z.unknown()).optional(),input:z.unknown().optional()});
const nativeCleanup=z.strictObject({scope:scopeSchema,applicationTarget:z.unknown(),commandsDrained:z.boolean(),ownedHelperReaped:z.boolean()});

/** Private composition only; caller must verify the enclosing SDK, Node and native helper bytes.
 * The inherited pipe supplies native authority; loopback HTTP still authenticates every SDK request.
 */
export class MacOwnedDaemon {
  private readonly target:Target;
  private readonly scope:Scope;
  private readonly session:string;
  private readonly provider:MacOwnedHelperProvider;
  private controller:Controller|null=null;
  private bridge:MacOwnedSDKTransport|undefined;
  private active=0;
  private operationBusy=false;
  private closing=false;
  private activeSignal:AbortSignal|undefined;
  private nativeStopAttempt:Promise<unknown>|undefined;
  private cleanupAttempt:Promise<unknown>|undefined;
  private diagnostics='';
  private constructor(private api:PrivateMacDaemonSDK,private directory:string,target:Target,scope:Scope,
    helperSHA256:string,private authentication:string,private channel:NativeChannel) {
    this.target=Object.freeze(targetSchema.parse(target));this.scope=Object.freeze(scopeSchema.parse(scope));
    if(this.target.kind!=='nativeMac' || !/^[a-f0-9]{64}$/.test(authentication))throw new Error('Private native authority required');
    this.session=`intents-${this.scope.runId}-${this.scope.leaseGeneration}`;
    this.provider=new MacOwnedHelperProvider(this.target,this.scope,helperSHA256,async(request,signal)=>{
      if(signal?.aborted)throw new Error('Native action cancelled before dispatch');
      return await this.channel.reverse('mac.helper.run',{authentication:this.authentication,request},request.timeoutMs+5000);
    });
  }
  static async start(api:PrivateMacDaemonSDK,directory:string,target:Target,scope:Scope,helperSHA256:string,
    authentication:string,channel:NativeChannel):Promise<MacOwnedDaemon> {
    // A private sidecar child sets this before importing the SDK. Never rewrite shared process state.
    if(process.env.AGENT_DEVICE_CLAIMS_DIR!==join(directory,'claims'))throw new Error('Require state-local private claim environment');
    const value=new MacOwnedDaemon(api,directory,target,scope,helperSHA256,authentication,channel);
    if(await realpath(dirname(directory))!==dirname(directory))throw new Error('Noncanonical daemon parent');
    await mkdir(directory,{mode:0o700});
    if(await realpath(directory)!==directory || (await readdir(directory)).length)throw new Error('Require fresh private daemon state');
    const device:Device={platform:'apple',appleOs:'macos',id:value.target.id,name:'Owned Mac',kind:'device',target:'desktop'};
    let unexpectedExit=false;
    const log=(text:string)=>{value.diagnostics=(value.diagnostics+text).slice(-65536);};
    try {
    value.controller=await api.startDaemonRuntime({env:{AGENT_DEVICE_STATE_DIR:directory,AGENT_DEVICE_DAEMON_SERVER_MODE:'http',
      AGENT_DEVICE_NO_UPDATE_NOTIFIER:'1',AGENT_DEVICE_DAEMON_IDLE_TIMEOUT_MS:'0',AGENT_DEVICE_SESSION_IDLE_TIMEOUT_MS:'0'},
      registerProcessHandlers:false,exit:(code)=>{if(code!==0)unexpectedExit=true;},stdout:{write:log},stderr:{write:log},
      appleToolProvider:(context)=>{
        if(context.device.id!==device.id || (context.session && context.session.name!==value.session))throw new Error('Different native provider scope');
        return api.createLocalAppleToolProvider(value.provider.overrides());
      },intentsOwnedMac:{deviceId:device.id,inventory:{discover:async()=>({kind:'inventory',devices:[device]})},
        admitRequest:(request)=>value.admit(request)}});
    if(!value.controller || unexpectedExit || !Number.isInteger(value.controller.httpPort) || !value.controller.httpPort || typeof value.controller.drainOwnedRequests!=='function' || value.controller.httpPort!<1 || value.controller.httpPort!>65535 ||
       !/^[a-f0-9]{48}$/.test(value.controller.token))throw new Error('Private daemon did not start');
    const client=api.createAgentDeviceClient({cwd:directory,stateDir:directory,session:value.session,daemonAuthToken:value.controller.token},
      {transport:async(request)=>value.send(request)});
    value.bridge=new MacOwnedSDKTransport(client,value.target,value.scope,async(scope,instance)=>value.cleanup(scope,instance),'private-owned-mac-source',
      value.provider.supportsScroll?(instance,request,context)=>value.provider.scroll(instance,request,context):undefined,
      value.provider.supportsOrdinaryFill?(instance,request,context)=>value.provider.ordinaryFill(instance,request,context):undefined);
    return value;
    } catch (error) {
      value.closing=true;value.provider.disable();
      // Startup has not admitted a UI command. Still close any loopback server already created.
      if(value.controller) {
        try { await value.controller.shutdown(); }
        catch(cleanup) { throw new AggregateError([error,cleanup],'Private daemon startup and shutdown failed'); }
      }
      throw error;
    }
  }
  get transport():MacOwnedTransport {
    const bridge=this.bridge;if(!bridge)throw new Error('Private daemon unavailable');
    return {open:(...args)=>this.operation(undefined,()=>bridge.open(...args)),
      capture:(instance,context)=>this.operation(context?.signal,()=>bridge.capture(instance,context)),
      press:(instance,point,context)=>this.operation(context.signal,()=>bridge.press(instance,point,context)),
      ...(bridge.ordinaryFill?{ordinaryFill:(instance:MacOwnedInstance,request:Readonly<{x:number;y:number;value:string}>,context:OperationContext)=>
        this.operation(context.signal,()=>bridge.ordinaryFill!(instance,request,context))}:{}),
      ...(bridge.scroll?{scroll:(instance:MacOwnedInstance,request:Readonly<{x:number;y:number;direction:'up'|'down'|'left'|'right'}>,context:OperationContext)=>
        this.operation(context.signal,()=>bridge.scroll!(instance,request,context))}:{}),
      release:(scope,instance)=>bridge.release(scope,instance)};
  }
  private admit(input:unknown):boolean {
    const parsed=wire.safeParse(input);if(!parsed.success || this.closing)return false;
    const req=parsed.data;if(req.session!==this.session || req.meta.cwd!==this.directory || req.input!==undefined ||
      (req.runtime!==undefined && Object.keys(req.runtime).length))return false;
    const flags=Object.fromEntries(Object.entries(req.flags).filter(([,value])=>value!==undefined));
    const permitted=new Set(['stateDir','session','platform','target','udid','surface','timeoutMs',
      ...(req.command==='open'?['macBundlePath','relaunch']:req.command==='snapshot'?['snapshotDepth','snapshotRaw','snapshotForceFull']:[])]);
    if(flags.stateDir!==this.directory || flags.session!==this.session || Object.keys(flags).some(key=>!permitted.has(key)) || flags.platform!=='macos' || flags.target!=='desktop' ||
      flags.udid!==this.target.id || (flags.surface!==undefined && flags.surface!=='frontmost-app'))return false;
    if(flags.timeoutMs!==undefined && (!Number.isInteger(flags.timeoutMs) || Number(flags.timeoutMs)<1 || Number(flags.timeoutMs)>60_000))return false;
    if(req.command==='open')return req.positionals.length===1 && req.positionals[0]===this.target.bundleId &&
      flags.macBundlePath===this.target.bundlePath && flags.surface==='frontmost-app' && flags.relaunch===false;
    if(req.command==='snapshot')return req.positionals.length===0 && flags.snapshotDepth===24 && flags.snapshotRaw===true && flags.snapshotForceFull===true;
    return req.positionals.length===2 && req.positionals.every(point=>Number.isFinite(Number(point)) &&
      Math.abs(Number(point))<=1_000_000 && String(Number(point))===point);
  }
  private async send(request:WireRequest):Promise<any> {
    if(!this.controller || !this.admit(request))throw new Error('Unsupported or unscoped private Mac request');
    const id=randomUUID(),url=`http://127.0.0.1:${this.controller.httpPort}/rpc`;
    this.active++;
    try{
      const response=await fetch(url,{method:'POST',headers:{'content-type':'application/json',authorization:`Bearer ${this.controller.token}`},
        body:JSON.stringify({jsonrpc:'2.0',id,method:'agent_device.command',params:request}),signal:this.activeSignal??null,redirect:'error'});
      if(!response.body)throw new Error('Private daemon response missing body');
      const reader=response.body.getReader(),chunks:Uint8Array[]=[];let bytes=0;
      try {
        while(true){
          const part=await reader.read();if(part.done)break;
          bytes+=part.value.byteLength;
          if(bytes>1_048_576){await reader.cancel();throw new Error('Private daemon response exceeds bound');}
          chunks.push(part.value);
        }
      } finally { reader.releaseLock(); }
      const text=Buffer.concat(chunks,bytes).toString('utf8');
      const envelope=z.object({jsonrpc:z.literal('2.0'),id:z.literal(id),result:z.unknown().optional(),error:z.object({message:z.string(),data:z.unknown().optional()}).optional()}).parse(JSON.parse(text));
      if(envelope.error)throw new Error(envelope.error.message);
      if(!response.ok || !envelope.result)throw new Error('Private daemon response failed');
      return envelope.result;
    }finally{this.active--;}
  }
  private async operation<T>(signal:AbortSignal|undefined,body:()=>Promise<T>):Promise<T> {
    if(this.closing || this.operationBusy || this.active || signal?.aborted)throw new Error('Private Mac operation unavailable');
    const abort=()=>{this.closing=true;this.provider.disable();void this.stopNative(null).catch(()=>{});};
    this.operationBusy=true;this.activeSignal=signal;signal?.addEventListener('abort',abort,{once:true});
    try{return await body();}finally{signal?.removeEventListener('abort',abort);this.activeSignal=undefined;this.operationBusy=false;}
  }
  private stopNative(instance:MacOwnedInstance|null):Promise<unknown> {
    return this.nativeStopAttempt??=this.channel.reverse('mac.helper.stop',
      {authentication:this.authentication,scope:this.scope,applicationTarget:instance},10000);
  }
  cleanup(scope:Scope,instance:MacOwnedInstance|null):Promise<unknown> {
    if(JSON.stringify(scopeSchema.parse(scope))!==JSON.stringify(this.scope))return Promise.reject(new Error('Different cleanup scope'));
    if(instance)requireMacOwnedInstance(instance);
    return this.cleanupAttempt??=this.finish(instance);
  }
  private async finish(instance:MacOwnedInstance|null):Promise<unknown> {
    this.closing=true;this.provider.disable();
    let drained=false,reaped=false,daemonStopped=false;
    try{
      const native=nativeCleanup.parse(await this.stopNative(instance));
      if(JSON.stringify(native.scope)!==JSON.stringify(this.scope))throw new Error('Different native cleanup scope');
      if(native.applicationTarget!==null)requireMacOwnedInstance(native.applicationTarget,instance??undefined);
      drained=native.commandsDrained;reaped=native.ownedHelperReaped;
    }catch{}
    const deadline=Date.now()+5000;
    while((this.operationBusy || this.active || this.provider.inFlight) && Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,10));
    drained=drained && !this.operationBusy && !this.active && !this.provider.inFlight;
    // Listener ownership is independent of native cleanup. Once every local
    // request has drained, close our listener even if the native channel was lost;
    // its missing cleanup proof still keeps commandsDrained/ownedHelperReaped false.
    if(!this.operationBusy && !this.active && !this.provider.inFlight && this.controller){
      try{
        const requestsDrained=await this.controller.drainOwnedRequests!(5000);
        drained=drained && requestsDrained;
        if(requestsDrained){await this.controller.shutdown();daemonStopped=true;}
      }catch{drained=false;}
    }
    return {scope:this.scope,applicationTarget:instance,commandsDrained:drained,ownedHelperReaped:reaped,daemonStopped,subjectTerminated:false};
  }
}
