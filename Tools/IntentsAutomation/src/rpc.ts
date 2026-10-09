import { z } from 'zod';
import { randomUUID } from 'node:crypto';
import { FrameReader, MAX_FRAME, requestSchema } from './protocol.js';
const responseSchema=z.strictObject({jsonrpc:z.literal('2.0'),id:z.string().max(256),result:z.unknown().optional(),
 error:z.strictObject({code:z.number().int(),message:z.string().max(1024)}).optional()}).refine(v=>Object.hasOwn(v,'result')!==Object.hasOwn(v,'error'),'Response must contain exactly one of result/error');
export class RpcEndpoint {
 private reader=new FrameReader();private pending=new Map<string,{resolve:(v:unknown)=>void;reject:(e:Error)=>void;timer:NodeJS.Timeout}>();
 private active=0;private closed=false;
 constructor(private write:(frame:string)=>void,private dispatch:(method:string,params:unknown)=>Promise<unknown>){}
 // Input closure fences new work; stdout can still carry the final response to
 // a request admitted before EOF. No new callback may use the closed channel.
 send(message:unknown){if(this.closed && typeof message==='object' && message!==null && 'method' in message)throw new Error('Channel closed');const wire=JSON.stringify(message);if(Buffer.byteLength(wire)>MAX_FRAME) throw new Error('Response frame too large');this.write(wire+'\n');}
 async receive(chunk:Buffer){if(this.closed)throw new Error('Channel closed');for(const message of this.reader.push(chunk)){
  if(typeof message==='object' && message!==null && !('method' in message)){
   const response=responseSchema.parse(message);const pending=this.pending.get(response.id);
   if(!pending) throw new Error('Unknown response ID');this.pending.delete(response.id);clearTimeout(pending.timer);
   if(response.error) pending.reject(new Error(response.error.message));else pending.resolve(response.result);continue;
  }
  const request=requestSchema.parse(message);
  if(this.active>=64 && !['cancel','status','shutdown'].includes(request.method)){this.send({jsonrpc:'2.0',id:request.id,error:{code:-32000,message:'Too many active requests'}});continue;}
  this.active++;
  // Do not await dispatch here: callbacks and cancellation must keep flowing.
  void this.dispatch(request.method,request.params).then(result=>{try{this.send({jsonrpc:'2.0',id:request.id,result:result===undefined?null:result});}
    catch{this.send({jsonrpc:'2.0',id:request.id,error:{code:-32001,message:'Response exceeds frame limit'}});}},
   error=>this.send({jsonrpc:'2.0',id:request.id,error:{code:-32000,message:String(error instanceof Error?error.message:error).slice(0,1024)}}))
   .catch(()=>{}).finally(()=>{this.active--;});
 }}
 reverse(method:'policy.reviewAction'|'controller.decide'|'mac.helper.run'|'mac.helper.stop'|'ui.workerStarted'|'secret.fillBinding',params:unknown,timeoutMs=15000):Promise<unknown>{
  if(this.closed)return Promise.reject(new Error('Channel closed'));
  if(this.pending.size>=64) return Promise.reject(new Error('Pending request limit'));
  const id='node-'+randomUUID();return new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error('Reverse request timeout'));},timeoutMs);
   this.pending.set(id,{resolve,reject,timer});this.send({jsonrpc:'2.0',id,method,params});
  });
 }
 close(){if(this.closed)return;this.closed=true;for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(new Error('Channel closed'));}this.pending.clear();this.reader.finish();}
}
