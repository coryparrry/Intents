import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,mkdir,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';

const unit=process.env.INTENTS_PRIVATE_DAEMON_UNIT;
const helperSHA256='91dc95a1bf0715746dfc6cf4790a9714f60565aab8e025ce0acc9edafb2ce4a4';
for(const mode of ['valid','uncertain','eof','invalid-frame','eof-capture','eof-press'])test(`sealed private entry pipe integration: ${mode}`,{skip:!unit,timeout:30000},async()=>{
  const root=await mkdtemp('/private/tmp/intents-daemon-entry-');
  const state=join(root,'state'),app=join(root,'Fixture.app');await mkdir(state);await mkdir(app);
  const scope={protocolVersion:1,runId:'entry-run',attemptId:'entry-attempt',segmentId:'entry-segment',leaseGeneration:1};
  const target={id:'fixture-mac',platform:'macos',kind:'nativeMac',bundleId:'example.Fixture',bundlePath:app,loginSession:'synthetic'};
  const instance={bundleId:target.bundleId,canonicalBundlePath:app,pid:123,processStartIdentity:'100:0'};
  const authentication='b'.repeat(64),actions:string[]=[],pending=new Map<string,{resolve:(value:any)=>void;reject:(error:Error)=>void}>();
  const child=spawn(join(unit!,'node'),['--import',pathToFileURL(new URL('./fixtures/macDaemonEntryGuard.js',import.meta.url).pathname).href,
    join(unit!,'sidecar/src/macOwnedDaemonMain.js'),'--state-dir',state],
    {env:{PATH:'/usr/bin:/bin',AGENT_DEVICE_CLAIMS_DIR:join(state,'owned-mac/claims')},stdio:['pipe','pipe','pipe']});
  let frame='',stderr='',ordinal=0,protocolError:unknown;
  const send=(value:unknown)=>child.stdin.write(JSON.stringify(value)+'\n');
  const request=(method:string,params:unknown)=>new Promise<any>((resolve,reject)=>{
    const id='parent-'+(++ordinal);pending.set(id,{resolve,reject});send({jsonrpc:'2.0',id,method,params});
  });
  child.stderr.on('data',bytes=>{stderr=(stderr+bytes).slice(-65536);});
  child.stdout.on('data',bytes=>{
    try{
      frame+=bytes.toString('utf8');assert.ok(Buffer.byteLength(frame)<=1048576);
      while(frame.includes('\n')){
        const index=frame.indexOf('\n'),message=JSON.parse(frame.slice(0,index));frame=frame.slice(index+1);
        if(!message.method){
          const call=pending.get(message.id);assert.ok(call);pending.delete(message.id);
          if(message.error)call.reject(new Error(message.error.message));else call.resolve(message.result);
          continue;
        }
        assert.equal(message.params.authentication,authentication);
        let result:unknown;
        if(message.method==='mac.helper.stop'){
          assert.deepEqual(message.params.scope,scope);result={scope,applicationTarget:message.params.applicationTarget,commandsDrained:true,ownedHelperReaped:true};
        }else{
          assert.equal(message.method,'mac.helper.run');const native=message.params.request;
          assert.deepEqual(native.scope,scope);assert.deepEqual(native.selection,{bundleId:target.bundleId,canonicalBundlePath:app});actions.push(native.action.kind);
          if((mode==='eof-capture' && native.action.kind==='snapshot') || (mode==='eof-press' && native.action.kind==='press')){child.stdin.end();continue;}
          let data:unknown=instance;
          if(native.action.kind==='snapshot')data={applicationTarget:instance,surface:'frontmost-app',nodes:[{index:0,label:'Selected',depth:0}],truncated:false,backend:'macos-helper'};
          if(native.action.kind==='press')data={applicationTarget:instance,x:native.action.x,y:native.action.y,disposition:'submittedUnconfirmed',releaseSubmitted:mode!=='uncertain'};
          result={requestId:native.requestId,scope,helperABI:'startup-gate-v1',helperSHA256,ownedIdentity:{pid:456,startIdentity:'200:0'},
            startupAcknowledged:true,directChildReaped:true,pipesDrained:true,callbacksDrained:true,logsTruncated:false,exitCode:0,stderr:'',stdout:JSON.stringify({ok:true,data})};
        }
        // EOF/protocol-loss means Swift cannot send a native cleanup proof.
        if(!child.stdin.writableEnded)send({jsonrpc:'2.0',id:message.id,result});
      }
    }catch(error){protocolError=error;for(const call of pending.values())call.reject(error as Error);pending.clear();child.kill();}
  });
  const completion=new Promise<number|null>((resolve,reject)=>{child.once('error',reject);child.once('exit',code=>{
    for(const call of pending.values())call.reject(new Error('Private child exited'));pending.clear();resolve(code);
  });});
  const deadline=setTimeout(()=>child.kill(),25000);
  try{
    const hello=await request('hello',{scope,target,authentication,helperSHA256});
    assert.equal(hello.customerRuntimeEnabled,false);assert.equal(hello.hardwareQualified,false);
    assert.deepEqual((await request('ui.acquire',{scope})).applicationTarget,instance);
    if(mode==='eof')child.stdin.end();
    else if(mode==='invalid-frame')child.stdin.end(Buffer.from([0xff,0x0a]));
    else if(mode==='eof-capture')await assert.rejects(()=>request('ui.runSegment',{scope,operation:'capture',applicationTarget:instance,timeoutMs:60000}));
    else if(mode==='eof-press')await assert.rejects(()=>request('ui.runSegment',{scope,operation:'press',applicationTarget:instance,x:10,y:20,timeoutMs:60000}));
    else{
      await request('ui.runSegment',{scope,operation:'capture',applicationTarget:instance,timeoutMs:5000});
      const press=()=>request('ui.runSegment',{scope,operation:'press',applicationTarget:instance,x:10,y:20,timeoutMs:5000});
      if(mode==='uncertain'){await assert.rejects(press);await assert.rejects(press);}else await press();
      const cleanup=await request('ui.release',{scope});assert.equal(cleanup.resourcesReleased,true);
      await assert.rejects(()=>request('ui.acquire',{scope}));child.stdin.end();
    }
    assert.equal(await completion,mode.startsWith('eof') || mode==='invalid-frame'?1:0,stderr);
    assert.equal(protocolError,undefined);assert.equal(frame,'');
    assert.deepEqual(actions,['eof','invalid-frame'].includes(mode)?['acquire']:mode==='eof-capture'?['acquire','snapshot']:mode==='eof-press'?['acquire','press']:['acquire','snapshot','press']);
    const guardLine=stderr.split('\n').find(line=>line.startsWith('SYNTHETIC_HOST_GUARD '));assert.ok(guardLine,stderr);
    assert.deepEqual(JSON.parse(guardLine.slice('SYNTHETIC_HOST_GUARD '.length)).hostCalls,[]);
  }finally{
    clearTimeout(deadline);if(child.exitCode===null && child.signalCode===null)child.kill();await completion.catch(()=>{});await rm(root,{recursive:true,force:true});
  }
});
