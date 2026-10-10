import {Socket} from 'node:net';
import {isAbsolute} from 'node:path';
import {pathToFileURL} from 'node:url';

// This sealed trampoline imports no UI runtime until its parent has persisted
// the exact direct child identity and acknowledged the inherited pipe.
const nonce=process.env.INTENTS_UI_WORKER_NONCE,entry=process.argv[2];
if(!nonce || !/^[a-f0-9]{64}$/.test(nonce) || !entry || !isAbsolute(entry))throw new Error('Owned worker gate unavailable');
const pipe=new Socket({fd:3,readable:true,writable:true});
await new Promise<void>((resolve,reject)=>{
 let bytes='',settled=false;
 const finish=(error?:Error)=>{if(settled)return;settled=true;clearTimeout(timer);pipe.removeAllListeners();pipe.destroy();error?reject(error):resolve();};
 const timer=setTimeout(()=>finish(new Error('Worker ownership acknowledgment expired')),10000);
 pipe.on('error',()=>finish(new Error('Worker ownership pipe failed')));
 pipe.on('end',()=>finish(new Error('Worker ownership pipe ended')));
 pipe.on('data',(chunk:Buffer)=>{
  bytes+=chunk.toString('utf8');
  if(Buffer.byteLength(bytes)>4096)return finish(new Error('Worker acknowledgment exceeded bound'));
  if(!bytes.includes('\n'))return;
  try{
   const value=JSON.parse(bytes);
   if(Object.keys(value).sort().join(',')!=='kind,nonce,pid' || value.kind!=='ack' || value.nonce!==nonce || value.pid!==process.pid)
    throw new Error('Worker acknowledgment identity differs');
   finish();
  }catch{finish(new Error('Worker acknowledgment invalid'));}
 });
 pipe.write(JSON.stringify({kind:'ready',nonce,pid:process.pid,ppid:process.ppid})+'\n');
});
delete process.env.INTENTS_UI_WORKER_NONCE;
process.argv=[process.execPath,entry,...process.argv.slice(3)];
await import(pathToFileURL(entry).href);
