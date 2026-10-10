import { z } from 'zod';
export const identifier = z.string().min(1).max(256).regex(/^[A-Za-z0-9_.:-]+$/);
export const digest = z.string().regex(/^[a-f0-9]{64}$/);
export const scopeSchema = z.strictObject({ protocolVersion: z.literal(1), runId: identifier, attemptId: identifier,
  segmentId: identifier, leaseGeneration: z.number().int().positive().max(Number.MAX_SAFE_INTEGER) });
export type Scope = z.infer<typeof scopeSchema>;
export const targetSchema = z.strictObject({ id: identifier, platform: z.enum(['ios', 'macos']),
  kind: z.enum(['simulator', 'physical', 'nativeMac']), bundleId: identifier,
  bundlePath: z.string().min(1).max(4096).nullable(), loginSession: identifier.nullable() }).superRefine((v,c)=>{
  if (v.platform === 'macos' && (v.kind !== 'nativeMac' || !v.bundlePath || !v.loginSession))
    c.addIssue({code:'custom',message:'Mac requires canonical bundle path and GUI login session'});
  if (v.platform === 'ios' && v.kind === 'nativeMac') c.addIssue({code:'custom',message:'Invalid iOS target kind'});
  if (v.platform === 'ios' && v.bundlePath!==null) c.addIssue({code:'custom',message:'UI acquisition cannot install an iOS bundle; choose its installed bundle ID'});
});
export type Target = z.infer<typeof targetSchema>;
export const valueSchema: z.ZodType<Value> = z.lazy(()=>z.discriminatedUnion('kind',[
  z.strictObject({kind:z.literal('text'),value:z.string().max(32768)}),
  z.strictObject({kind:z.literal('bool'),value:z.boolean()}),
  z.strictObject({kind:z.literal('integer'),value:z.string().regex(/^-?(0|[1-9][0-9]*)$/).max(128)}),
  z.strictObject({kind:z.literal('decimal'),value:z.string().regex(/^-?(0|[1-9][0-9]*)(\.[0-9]+)?$/).max(256)}),
  z.strictObject({kind:z.literal('date'),value:z.string().datetime({offset:true}),timeZone:z.string().min(1).max(128).refine(zone=>{try{new Intl.DateTimeFormat('en',{timeZone:zone});return true;}catch{return false;}})}),
  z.strictObject({kind:z.literal('enum'),typeId:identifier,value:identifier}),
  z.strictObject({kind:z.literal('entity'),typeId:identifier,value:z.string().min(1).max(1024)}),
  z.strictObject({kind:z.literal('artifact'),value:identifier,sha256:digest}),
  z.strictObject({kind:z.literal('array'),value:z.array(valueSchema).max(1000)}),
  z.strictObject({kind:z.literal('object'),value:z.record(identifier,valueSchema)}),
  z.strictObject({kind:z.literal('null')}),z.strictObject({kind:z.literal('omission')})
]));
export type Value = {kind:'text'|'integer'|'decimal';value:string}|{kind:'bool';value:boolean}|
 {kind:'date';value:string;timeZone:string}|{kind:'enum'|'entity';typeId:string;value:string}|
 {kind:'artifact';value:string;sha256:string}|{kind:'array';value:Value[]}|{kind:'object';value:Record<string,Value>}|
 {kind:'null'|'omission'};
export function validateValue(input:unknown):Value {
  let count=0;
  const visit=(v:unknown,depth:number):void=>{
    if(depth>16 || ++count>10000) throw new Error('Value nesting/node limit exceeded');
    if(v && typeof v==='object' && 'kind' in v && 'value' in v){
      if(v.kind==='array' && Array.isArray(v.value)) for(const child of v.value)visit(child,depth+1);
      if(v.kind==='object' && v.value && typeof v.value==='object')for(const child of Object.values(v.value))visit(child,depth+1);
    }
  };
  visit(input,0);return valueSchema.parse(input);
}
export const requestSchema=z.strictObject({jsonrpc:z.literal('2.0'),id:identifier,
  method:z.enum(['hello','inventory','probe','ui.acquire','ui.runSegment','secret.runProgram','ui.release','cancel','status','shutdown']),
  params:z.unknown()});
export const MAX_FRAME=1024*1024;
export class FrameReader {
  private buffer=Buffer.alloc(0);
  push(chunk:Buffer):unknown[]{
    this.buffer=Buffer.concat([this.buffer,chunk]);const out:unknown[]=[];
    for(;;){const end=this.buffer.indexOf(10);if(end<0) break;
      if(end>MAX_FRAME) throw new Error('Oversized frame');
      const frame=this.buffer.subarray(0,end);this.buffer=this.buffer.subarray(end+1);
      const text=new TextDecoder('utf-8',{fatal:true}).decode(frame);out.push(JSON.parse(text));
    }
    if(this.buffer.length>MAX_FRAME) throw new Error('Oversized frame');return out;
  }
  finish(){if(this.buffer.length) throw new Error('Incomplete frame');}
}
