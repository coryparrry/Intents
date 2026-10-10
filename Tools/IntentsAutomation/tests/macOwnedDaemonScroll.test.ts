import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {join} from 'node:path';

for(const mode of ['valid','uncertain','old-helper'])test(`synthetic SDK daemon composition retains scroll capability and drain: ${mode}`,async()=>{
 const root=await mkdtemp('/private/tmp/intents-scroll-composition-');
 try {
  const child=spawn(process.execPath,[new URL('./fixtures/macDaemonScrollFixture.js',import.meta.url).pathname,
   Buffer.from(JSON.stringify({root,mode})).toString('base64')],{env:{PATH:'/usr/bin:/bin',AGENT_DEVICE_CLAIMS_DIR:join(root,'state','claims')},stdio:['ignore','pipe','pipe']});
  let output='',diagnostics='';child.stdout.on('data',bytes=>{output+=bytes;if(output.length>65536)child.kill();});
  child.stderr.on('data',bytes=>{diagnostics=(diagnostics+bytes).slice(-65536);});
  const deadline=setTimeout(()=>child.kill(),10000);
  try {
   const code=await new Promise<number|null>((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);});
   assert.equal(code,0,diagnostics);const result=JSON.parse(output);assert.equal(result.scrolls,mode==='old-helper'?0:1);
   assert.equal(result.released,true);assert.equal(result.shutdown,1);
  }finally{clearTimeout(deadline);}
 }finally{await rm(root,{recursive:true,force:true});}
});
