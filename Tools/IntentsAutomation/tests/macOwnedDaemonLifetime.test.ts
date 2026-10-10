import test from 'node:test';
import assert from 'node:assert/strict';
import {MacOwnedDaemonLifetime} from '../src/macOwnedDaemonLifetime.js';

test('termination before initialization fences later startup',async()=>{
  let factories=0;
  const lifetime=new MacOwnedDaemonLifetime(async()=>{throw new Error('No resource to dispose');});
  assert.deepEqual(await lifetime.stop(),{resourcesReleased:true});
  await assert.rejects(()=>lifetime.start(async()=>{factories++;return {};}));assert.equal(factories,0);
});
test('termination waits for pending startup and disposes its exact resource once',async()=>{
  let resolve!:(value:{id:string})=>void,dispose=0;
  const pending=new Promise<{id:string}>(done=>{resolve=done;});
  const value={id:'owned'};
  const lifetime=new MacOwnedDaemonLifetime<{id:string}>(async resource=>{assert.equal(resource,value);dispose++;return {resourcesReleased:true};});
  const starting=lifetime.start(()=>pending);
  const failure=assert.rejects(()=>starting,/startup was stopped/);
  const stop=lifetime.stop();let settled=false;void stop.then(()=>{settled=true;});
  await new Promise(done=>setImmediate(done));assert.equal(settled,false);assert.equal(dispose,0);
  resolve(value);assert.deepEqual(await stop,{resourcesReleased:true});await failure;
  assert.equal(lifetime.active,false);assert.equal(dispose,1);assert.equal(lifetime.stop(),stop);
});
test('failed asynchronous startup retains negative release proof',async()=>{
  let dispose=0;const lifetime=new MacOwnedDaemonLifetime(async()=>{dispose++;return {resourcesReleased:true};});
  await assert.rejects(()=>lifetime.start(async()=>{throw new Error('Startup failed');}));
  assert.deepEqual(await lifetime.stop(),{resourcesReleased:false});assert.equal(dispose,0);
});
