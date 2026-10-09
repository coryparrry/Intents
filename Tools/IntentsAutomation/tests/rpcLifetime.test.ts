import test from 'node:test';
import assert from 'node:assert/strict';
import {RpcEndpoint} from '../src/rpc.js';
import {MAX_FRAME} from '../src/protocol.js';

test('definitive pipe loss rejects callbacks and never admits new traffic',async()=>{
  const frames:string[]=[];
  const endpoint=new RpcEndpoint(frame=>frames.push(frame),async()=>undefined);
  const pending=endpoint.reverse('mac.helper.run',{synthetic:true},60000);
  endpoint.close();endpoint.close();
  await assert.rejects(pending,/Channel closed/);
  await assert.rejects(()=>endpoint.reverse('mac.helper.stop',{}),/Channel closed/);
  await assert.rejects(()=>endpoint.receive(Buffer.from('{}\n')),/Channel closed/);
  assert.throws(()=>endpoint.send({method:'mac.helper.stop'}),/Channel closed/);
  assert.equal(frames.length,1);
});

const tick=()=>new Promise(r=>setImmediate(r));
const request=(id:string,method:string)=>Buffer.from(JSON.stringify({jsonrpc:'2.0',id,method,params:{}})+'\n');

test('active request limit rejects new work but still admits cancel, status and shutdown',async()=>{
  const frames:string[]=[];const dispatched:string[]=[];const releases:Array<()=>void>=[];
  const endpoint=new RpcEndpoint(frame=>frames.push(frame),method=>{dispatched.push(method);
    return method==='inventory'?new Promise(resolve=>releases.push(()=>resolve({ok:true}))):Promise.resolve({method});});
  for(let i=0;i<64;i++) await endpoint.receive(request('busy-'+i,'inventory'));
  assert.equal(dispatched.length,64);assert.equal(frames.length,0);
  await endpoint.receive(request('overflow','inventory'));
  assert.deepEqual(JSON.parse(frames[0]!),{jsonrpc:'2.0',id:'overflow',error:{code:-32000,message:'Too many active requests'}});
  assert.equal(dispatched.length,64);
  for(const method of ['cancel','status','shutdown']) await endpoint.receive(request('ctl-'+method,method));
  await tick();
  assert.deepEqual(dispatched.slice(64),['cancel','status','shutdown']);
  for(const method of ['cancel','status','shutdown']) assert.ok(frames.map(f=>JSON.parse(f)).some(f=>f.id==='ctl-'+method && f.result?.method===method));
  releases[0]!();await tick();
  assert.ok(frames.map(f=>JSON.parse(f)).some(f=>f.id==='busy-0' && f.result?.ok===true));
  await endpoint.receive(request('after-release','inventory'));
  assert.equal(dispatched.at(-1),'inventory');assert.equal(dispatched.length,68);
  assert.ok(!frames.map(f=>JSON.parse(f)).some(f=>f.id==='after-release'));
  for(const release of releases) release();await tick();endpoint.close();
});

test('oversized dispatch result becomes a -32001 error response',async()=>{
  const frames:string[]=[];
  const endpoint=new RpcEndpoint(frame=>frames.push(frame),async()=>'x'.repeat(MAX_FRAME));
  await endpoint.receive(request('large','inventory'));await tick();
  assert.equal(frames.length,1);
  assert.deepEqual(JSON.parse(frames[0]!),{jsonrpc:'2.0',id:'large',error:{code:-32001,message:'Response exceeds frame limit'}});
  endpoint.close();
});

test('reverse timeout rejects and forgets the pending call',async()=>{
  const frames:string[]=[];
  const endpoint=new RpcEndpoint(frame=>frames.push(frame),async()=>undefined);
  await assert.rejects(endpoint.reverse('policy.reviewAction',{synthetic:true},10),/Reverse request timeout/);
  const sent=JSON.parse(frames[0]!);assert.equal(sent.method,'policy.reviewAction');
  await assert.rejects(()=>endpoint.receive(Buffer.from(JSON.stringify({jsonrpc:'2.0',id:sent.id,result:{allowed:true}})+'\n')),/Unknown response ID/);
  const expired=Array.from({length:64},()=>endpoint.reverse('controller.decide',{},10));
  for(const call of expired) await assert.rejects(call,/Reverse request timeout/);
  const next=endpoint.reverse('controller.decide',{},60000);
  assert.equal(frames.length,66);
  await endpoint.receive(Buffer.from(JSON.stringify({jsonrpc:'2.0',id:JSON.parse(frames[65]!).id,result:{kind:'finish'}})+'\n'));
  assert.deepEqual(await next,{kind:'finish'});endpoint.close();
});

test('pending reverse call limit rejects the 65th call without sending it',async()=>{
  const frames:string[]=[];
  const endpoint=new RpcEndpoint(frame=>frames.push(frame),async()=>undefined);
  const calls=Array.from({length:64},(_,i)=>endpoint.reverse('controller.decide',{step:i},60000));
  await assert.rejects(()=>endpoint.reverse('controller.decide',{step:64},60000),/Pending request limit/);
  assert.equal(frames.length,64);
  await endpoint.receive(Buffer.from(JSON.stringify({jsonrpc:'2.0',id:JSON.parse(frames[0]!).id,error:{code:1,message:'denied'}})+'\n'));
  await assert.rejects(calls[0]!,/denied/);
  const admitted=endpoint.reverse('controller.decide',{step:65},60000);assert.equal(frames.length,65);
  endpoint.close();
  for(const call of [...calls.slice(1),admitted]) await assert.rejects(call,/Channel closed/);
});
