import test from 'node:test';
import assert from 'node:assert/strict';
import {requireMacOpenEcho, requireMacPressEcho, validateMacOwnedPress} from './mac-owned-wire.ts';
const target = {bundleId:'example.Target',canonicalBundlePath:'/Applications/Selected.app',pid:123,processStartIdentity:'100:0'};
const selection = {bundleId:target.bundleId,canonicalBundlePath:target.canonicalBundlePath};
test('open requires the exact selected bundle and path',()=>{
  assert.deepEqual(requireMacOpenEcho(target,selection),target);
  for(const change of [{bundleId:'example.Other'},{canonicalBundlePath:'/Applications/Other.app'}])
    assert.throws(()=>requireMacOpenEcho({...target,...change},selection));
});
test('press requires exact target, coordinates and completed release submission',()=>{
  const receipt = {applicationTarget:target,x:10,y:-20,disposition:'submittedUnconfirmed',releaseSubmitted:true};
  requireMacPressEcho(receipt,target,{x:10,y:-20});
  for(const change of [{applicationTarget:{...target,pid:124}},{x:11},{y:20},{disposition:'completed'},
    {releaseSubmitted:false},{applicationTarget:undefined}])
    assert.throws(()=>requireMacPressEcho({...receipt,...change},target,{x:10,y:-20}));
});
test('press rejects invalid arguments before helper submission',()=>{
  validateMacOwnedPress(0,0,{});
  for(const options of [{holdMs:-1},{holdMs:5001},{holdMs:1.2},{clicks:0},{clicks:9},{intervalMs:-1},
    {intervalMs:1001},{doubleClick:'true'},{clicks:8,holdMs:5000,doubleClick:true}])
    assert.throws(()=>validateMacOwnedPress(0,0,options));
  for(const x of [NaN,Infinity,1_000_001]) assert.throws(()=>validateMacOwnedPress(x,0,{}));
});
