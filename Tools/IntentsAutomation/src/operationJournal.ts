import {readFile,mkdir,rename,open,unlink,type FileHandle} from 'node:fs/promises';
import {dirname} from 'node:path';import {z} from 'zod';
import {digest as digestSchema,identifier} from './protocol.js';
const entrySchema=z.strictObject({digest:digestSchema,state:z.enum(['dispatched','completed']),response:z.unknown().optional()});
export type Entry=z.infer<typeof entrySchema>;
export class OperationJournal {
 private entries:Record<string,Entry>=Object.create(null);private queue=Promise.resolve();
 constructor(private path:string,private syncDirectory:(directory:string)=>Promise<void>=async directory=>{
  const parent=await open(directory,'r');try{await parent.sync();}finally{await parent.close();}
 }){}
 async load(){try{const data=await readFile(this.path,'utf8');if(Buffer.byteLength(data)>16*1024*1024)throw new Error('Journal size limit');
  const parsed:unknown=JSON.parse(data);
  if(!parsed || typeof parsed!=='object' || Array.isArray(parsed))throw new Error('Invalid journal object');
  const entries:Record<string,Entry>=Object.create(null);for(const [key,value] of Object.entries(parsed)){identifier.parse(key);entries[key]=entrySchema.parse(value);}
  this.entries=entries;
 }catch(e){if((e as NodeJS.ErrnoException).code!=='ENOENT')throw e;this.entries=Object.create(null);}}
 async dispatch(id:string,digest:string,body:()=>Promise<unknown>):Promise<unknown>{
  identifier.parse(id);digestSchema.parse(digest);
  const cached=await this.transaction(async()=>{
   const prior=this.entries[id];if(prior){if(prior.digest!==digest)throw new Error('Conflicting operation payload');
    if(prior.state!=='completed')throw new Error('ACTION_MAY_HAVE_COMMITTED');return {found:true,response:prior.response};}
   if(Object.keys(this.entries).length>=10000)throw new Error('Operation journal count limit');
   this.entries[id]={digest,state:'dispatched'};await this.persist();return {found:false,response:null};
  });
  if(cached.found)return cached.response;
  const response=(await body())??null;
  await this.transaction(async()=>{const prior=this.entries[id];
   if(!prior || prior.digest!==digest || prior.state!=='dispatched')throw new Error('Conflicting completion');
   this.entries[id]={digest,state:'completed',response};await this.persist();});return response;
 }
 private async transaction<T>(body:()=>Promise<T>):Promise<T>{
  let unlock!:()=>void;const previous=this.queue;this.queue=new Promise<void>(r=>{unlock=r});await previous;
  let lock:FileHandle|undefined;
  try{await mkdir(dirname(this.path),{recursive:true,mode:0o700});lock=await open(this.path+'.lock','wx',0o600);
   await this.load();return await body();
  }finally{try{if(lock){try{await lock.close();}finally{await unlink(this.path+'.lock');}}}finally{unlock();}}
 }
 private async persist(){
  const data=JSON.stringify(this.entries);if(Buffer.byteLength(data)>16*1024*1024)throw new Error('Journal size limit');
  const temporary=this.path+'.tmp';const file=await open(temporary,'w',0o600);
  try{await file.writeFile(data);await file.sync();}finally{await file.close();}
  await rename(temporary,this.path);
  await this.syncDirectory(dirname(this.path));
 }
}
