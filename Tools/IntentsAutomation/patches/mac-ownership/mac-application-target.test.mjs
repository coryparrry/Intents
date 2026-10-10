import test from 'node:test';
import assert from 'node:assert/strict';
import {parseMacApplicationSelection, parseMacApplicationTarget, requireMacApplicationTargetEcho,
  macApplicationTargetArguments} from './mac-application-target.ts';

const selected = {bundleId:'example.Target',canonicalBundlePath:'/Applications/Selected café.app',pid:123,processStartIdentity:'100:999999'};

test('target validation copies and freezes complete identity data',()=>{
  const input = {...selected}, result = parseMacApplicationTarget(input);
  input.pid=456; assert.equal(result.pid,123); assert.ok(Object.isFrozen(result)); assert.deepEqual(result,selected);
});
test('unknown, missing, inherited and nonobject identity fields fail closed',()=>{
  for(const value of [null,[],Object.create(selected),{...selected,unknown:true},
    {bundleId:selected.bundleId,canonicalBundlePath:selected.canonicalBundlePath,pid:selected.pid}]) {
    assert.throws(()=>parseMacApplicationTarget(value),TypeError);
  }
});
test('PID and process-start tokens are canonical bounded values',()=>{
  for(const pid of [0,-1,1.5,2147483648,NaN,Infinity,'123',true]) assert.throws(()=>parseMacApplicationTarget({...selected,pid}),TypeError);
  for(const processStartIdentity of ['0:0','01:0','1:01','1:1000000','18446744073709551616:0','1:0\n','+1:0'])
    assert.throws(()=>parseMacApplicationTarget({...selected,processStartIdentity}),TypeError);
  assert.equal(parseMacApplicationTarget({...selected,processStartIdentity:'18446744073709551615:0'}).processStartIdentity,'18446744073709551615:0');
});
test('selection paths are absolute and lexically canonical with bounded UTF8',()=>{
  for(const canonicalBundlePath of ['Selected.app','/Applications/Selected.app/','/Applications//Selected.app',
    '/Applications/../Selected.app','/Applications/./Selected.app','/Applications/Selected.app\0','/Applications/Other',
    '/'+ '🧪'.repeat(1024)+'.app']) assert.throws(()=>parseMacApplicationTarget({...selected,canonicalBundlePath}),TypeError);
  assert.equal(parseMacApplicationTarget(selected).canonicalBundlePath,selected.canonicalBundlePath);
});
test('selection rejects names and aliases in place of bundle IDs',()=>{
  for(const bundleId of ['Selected',' example.Target','example.Target\n','example/Target','example.'+'a'.repeat(256)])
    assert.throws(()=>parseMacApplicationTarget({...selected,bundleId}),TypeError);
  assert.deepEqual(parseMacApplicationSelection({bundleId:selected.bundleId,canonicalBundlePath:selected.canonicalBundlePath}),
    {bundleId:selected.bundleId,canonicalBundlePath:selected.canonicalBundlePath});
});
test('operation echo must match every instance field',()=>{
  assert.deepEqual(requireMacApplicationTargetEcho({...selected},selected),selected);
  for(const change of [{bundleId:'example.Other'},{canonicalBundlePath:'/Applications/Other.app'},{pid:124},{processStartIdentity:'101:0'}])
    assert.throws(()=>requireMacApplicationTargetEcho({...selected,...change},selected),TypeError);
  assert.throws(()=>requireMacApplicationTargetEcho(undefined,selected),TypeError);
});
test('serialized target arguments preserve exact path and process token as data',()=>{
  assert.deepEqual(macApplicationTargetArguments(selected,selected.bundleId,'frontmost-app'),
    ['--target-bundle-path',selected.canonicalBundlePath,'--target-pid','123','--target-process-start','100:999999']);
  for(const [bundleId,surface] of [[undefined,'frontmost-app'],['example.Other','frontmost-app'],[selected.bundleId,'desktop'],[selected.bundleId,undefined]])
    assert.throws(()=>macApplicationTargetArguments(selected,bundleId,surface),TypeError);
});
