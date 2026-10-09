import test from 'node:test';
import assert from 'node:assert/strict';
import {RpcEndpoint} from '../src/rpc.js';

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
