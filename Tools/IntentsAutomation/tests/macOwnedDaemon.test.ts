import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,rm} from 'node:fs/promises';
import {join} from 'node:path';

const sdk=process.env.INTENTS_PRIVATE_DAEMON_ENTRY;
for(const mode of ['valid','uncertain','cancel','startup-fail','invalid-port','cleanup-fail'])test(`actual private daemon/client synthetic native channel: ${mode}`,{skip:!sdk},async()=>{
  const root=await mkdtemp('/private/tmp/intents-daemon-fixture-');
  try{
    const app=join(root,'Fixture.app');await mkdir(app);
    const directory=join(root,'state');
    const config={directory,sdk,mode,target:{id:'fixture-mac',platform:'macos',kind:'nativeMac',bundleId:'example.Fixture',bundlePath:app,loginSession:'synthetic'},
      scope:{protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'segment',leaseGeneration:1}};
    const child=spawn(process.execPath,[new URL('./fixtures/macDaemonFixture.js',import.meta.url).pathname,Buffer.from(JSON.stringify(config)).toString('base64')],
      {env:{PATH:'/usr/bin:/bin',AGENT_DEVICE_CLAIMS_DIR:join(directory,'claims')},stdio:['ignore','pipe','pipe']});
    let output='',errors='';child.stdout.on('data',chunk=>{output+=chunk;if(output.length>65536)child.kill();});
    child.stderr.on('data',chunk=>{errors=(errors+chunk).slice(-65536);});
    const deadline=setTimeout(()=>child.kill(),30000);
    const code=await new Promise<number|null>((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);});clearTimeout(deadline);
    assert.equal(code,0,errors);const result=JSON.parse(output);
    assert.equal(result.cleanup.daemonStopped,true);assert.deepEqual(result.hostCalls,[]);assert.equal(result.requests.length,['startup-fail','invalid-port'].includes(mode)?0:3);
  }finally{await rm(root,{recursive:true,force:true});}
});
