import {createServer,connect,type Socket} from 'node:net';import {mkdtemp,chmod,rm} from 'node:fs/promises';
import {policyDenialMessage} from './policyReview.js';
import {tmpdir} from 'node:os';import {join} from 'node:path';import {randomBytes} from 'node:crypto';
import {z} from 'zod';import {FrameReader,scopeSchema,type Scope} from './protocol.js';
import {EngineError,ENGINE_ERROR_CODES,type OperationContext} from 'e2e/engine';
import type {CaptureSnapshotResult} from 'agent-device';
import type {UIBackend} from './deviceSession.js';
import {controllerRequestSchema,type ControllerRequest} from './controllerProtocol.js';
export type ControllerBroker=(request:ControllerRequest,context:OperationContext)=>Promise<unknown>;
const actionSchema=z.discriminatedUnion('kind',[
 z.strictObject({kind:z.literal('tap')}),z.strictObject({kind:z.literal('fill'),value:z.string().max(32768),sensitive:z.literal(false)}),
 z.strictObject({kind:z.literal('swipe'),direction:z.enum(['up','down','left','right'])})]);
const messageSchema=z.strictObject({id:z.number().int().nonnegative().max(100000),token:z.string().length(64),
 method:z.enum(['snapshot','perform','controller']),timeoutMs:z.number().int().min(1).max(120000),ref:z.string().min(1).max(256).optional(),action:actionSchema.optional(),nodeId:z.string().min(1).max(256).optional(),request:controllerRequestSchema.optional()});
export async function createBroker(backend:UIBackend,decide?:ControllerBroker,scope?:Scope){
 const identity=scope?Object.freeze(scopeSchema.parse(scope)):Object.freeze({runId:'broker',attemptId:'broker'});
 const directory=await mkdtemp(join(tmpdir(),'ia-'));await chmod(directory,0o700);
 const socket=join(directory,'b.sock'),token=randomBytes(32).toString('hex');const clients=new Set<Socket>();
 let active=0,closed=false;let queue=Promise.resolve();let denialMessage:string|undefined;
 const server=createServer(client=>{
  const controller=new AbortController();client.on('close',()=>controller.abort());
  clients.add(client);client.on('close',()=>clients.delete(client));client.on('error',()=>{});const reader=new FrameReader();
  client.on('data',chunk=>{try{for(const raw of reader.push(chunk)){
   const message=messageSchema.parse(raw);const deadline=Date.now()+message.timeoutMs;if(message.token!==token || closed) throw new Error('Broker denied');
   if(active>=32) throw new Error('Broker command limit');active++;
   queue=queue.then(async()=>{
    try{let result:unknown;const context:OperationContext={runId:identity.runId,attemptId:identity.attemptId,origin:'test',signal:controller.signal,timeoutMs:Math.max(1,deadline-Date.now())};
     if(controller.signal.aborted || Date.now()>=deadline)throw new Error('Command cancelled or expired');
     if(message.method==='snapshot') result=await backend.snapshot(context);
     else if(message.method==='controller'){if(!decide || !message.request || message.ref || message.action)throw new Error('Controller is unavailable');result=await decide(message.request,context);}
     else {if(!message.ref || !message.action)throw new Error('Missing action');await backend.perform(message.ref,message.action,context,message.nodeId);result=null;}
     client.write(JSON.stringify({id:message.id,result})+'\n');
    }catch(e){const code=ENGINE_ERROR_CODES.find(code=>code===(e as {code?:unknown}|null)?.code)??'ENGINE_FAILURE';
     const denial=policyDenialMessage(e);denialMessage??=denial;
     client.write(JSON.stringify({id:message.id,error:{code,message:denial??'Broker command failed'}})+'\n');}
    finally{active--;}
   });
  }}catch{client.destroy();}});
 });
 await new Promise<void>((resolve,reject)=>{server.once('error',reject);server.listen(socket,resolve)});await chmod(socket,0o600);
 return {socket,token,policyDenial:()=>denialMessage,async close(){closed=true;await queue;for(const client of clients)client.destroy();
  await new Promise<void>(r=>server.close(()=>r()));await rm(directory,{recursive:true,force:true});}};
}
export class BrokerClient implements UIBackend {
 private sequence=0;
 constructor(private socket:string,private token:string){}
 private async request(method:'snapshot'|'perform'|'controller',context?:OperationContext,extra:object={}):Promise<unknown>{
  if(context?.signal.aborted) throw new Error('Broker command cancelled');
  return new Promise((resolve,reject)=>{const client=connect(this.socket);const reader=new FrameReader();const id=++this.sequence;
   const timeoutMs=Math.max(1,Math.min(120000,context?.timeoutMs??15000));let settled=false,sent=false;
   const finish=()=>{if(settled)return false;settled=true;clearTimeout(timer);context?.signal.removeEventListener('abort',abort);client.destroy();return true;};
   const failure=(message:string,cause?:unknown)=>method==='perform' && sent?new EngineError('ACTION_MAY_HAVE_COMMITTED',message+'; action outcome unresolved',{retryable:false,...(cause!==undefined?{cause}:{})}):new Error(message);
   const abort=()=>{if(finish())reject(failure('Broker command cancelled'));};
   const timer=setTimeout(()=>{if(finish())reject(failure('Broker timeout'));},timeoutMs);
   context?.signal.addEventListener('abort',abort,{once:true});
   client.on('error',e=>{if(finish())reject(failure('Broker connection failed',e))});
   client.on('connect',()=>{if(!settled&&!context?.signal.aborted){sent=true;client.write(JSON.stringify({id,token:this.token,method,timeoutMs,...extra})+'\n');}else abort();});
   client.on('data',chunk=>{try{for(const message of reader.push(chunk)){
    const result=z.strictObject({id:z.literal(id),result:z.unknown().optional(),error:z.strictObject({code:z.string(),message:z.string()}).optional()})
     .refine(value=>Object.hasOwn(value,'result')!==Object.hasOwn(value,'error'),{message:'Incomplete broker response'}).parse(message);
    if(method==='perform' && !result.error && result.result!==null)throw new Error('Malformed action receipt');
    if(!finish())return;if(result.error){const code=ENGINE_ERROR_CODES.find(code=>code===result.error!.code)??'ENGINE_FAILURE';reject(new EngineError(code,result.error.message,{retryable:false}));}else resolve(result.result);
   }}catch(e){if(finish())reject(failure('Broker response invalid',e));}});
   // An abort between the initial check and listener registration must also win.
   if(context?.signal.aborted)abort();
  });
 }
 async snapshot(context?:OperationContext):Promise<CaptureSnapshotResult>{return await this.request('snapshot',context) as Awaited<ReturnType<UIBackend['snapshot']>>;}
 async perform(ref:string,action:Parameters<UIBackend['perform']>[1],context:OperationContext,nodeId?:string){await this.request('perform',context,{ref,action,...(nodeId?{nodeId}:{})});}
 async decide(request:ControllerRequest,context:OperationContext){return await this.request('controller',context,{request});}
 async release(){return {released:false,reason:'Workers cannot release device leases'};}
}
