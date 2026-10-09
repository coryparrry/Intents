import {test} from 'node:test';import assert from 'node:assert/strict';
import type {CaptureSnapshotResult} from 'agent-device';
import {captureReadback,verifyReadback} from '../src/uiReadback.js';
const target={id:'owned',platform:'ios' as const,kind:'simulator' as const,bundleId:'example.App',bundlePath:null,loginSession:null};
const raw:CaptureSnapshotResult={identifiers:{udid:'owned'},truncated:false,appBundleId:'example.App',nodes:[{index:1,ref:'@e1',identifier:'result',label:'Result',value:'actual',checked:false,hittable:true,enabled:true,visibleToUser:true}]};
const operation={id:'result',kind:'observeProperty' as const,locator:{kind:'testId' as const,value:'result'},property:'value' as const};
test('secure roles and descendants are redacted even when observing an unrelated ordinary field',()=>{
 const identities:Partial<CaptureSnapshotResult['nodes'][number]>[]=[
  {type:'SecureTextField',password:false},{subrole:'AXSecureTextField'},
  {role:'secure-text-field'},{kind:'password-field'},{password:true}
 ];
 for(const identity of identities){
  const proof=captureReadback({...raw,nodes:[raw.nodes[0]!,
   {index:2,ref:'@e2',identifier:'protected',label:'private-sentinel-label',value:'private-sentinel-value',hittable:true,enabled:true,visibleToUser:true,...identity},
   {index:3,ref:'@e3',identifier:'child',parentIndex:2,label:'private-sentinel-child-label',value:'private-sentinel-child-value',hittable:true,enabled:true,visibleToUser:true}
  ]},target);
  assert.equal(verifyReadback(proof,operation),'actual');
  assert.ok(!JSON.stringify(proof).includes('private-sentinel'));
  for(const identifier of ['protected','child']){
   assert.equal(proof.nodes.find(n=>n.identifier===identifier)!.secure,true);
   assert.throws(()=>verifyReadback(proof,{...operation,locator:{kind:'testId',value:identifier}}));
  }
 }
});
test('fresh complete readback preserves actual values including false and explicit empty text',()=>{
 assert.equal(verifyReadback(captureReadback(raw,target),operation),'actual');
 assert.equal(verifyReadback(captureReadback(raw,target),{...operation,property:'checked'}),false);
 assert.equal(verifyReadback(captureReadback({...raw,nodes:[{...raw.nodes[0]!,value:''}]},target),operation),'');
});
test('unknown or partial capture and wrong app cannot establish business evidence',()=>{
 const {truncated:ignored,...unknown}=raw;assert.throws(()=>captureReadback(unknown,target));
 for(const change of [{truncated:true},{visibility:{partial:true,visibleNodeCount:1,totalNodeCount:2,reasons:[]}},{appBundleId:'other'},
  {nodes:[{...raw.nodes[0]!,hiddenContentBelow:true}]},{nodes:[{...raw.nodes[0]!,parentIndex:99}]}])
  assert.throws(()=>captureReadback({...raw,...change},target));
});
test('ambiguous, invisible, missing, secure or malformed readback cannot return a guessed value',()=>{
 const proof=captureReadback(raw,target);
 for(const nodes of [[...proof.nodes,{...proof.nodes[0]!,index:2}],[],[{...proof.nodes[0]!,visible:false}],
  [{...proof.nodes[0]!,value:undefined}],[{...proof.nodes[0]!,secure:true}],
  [{...proof.nodes[0]!,parentIndex:1}]])assert.throws(()=>verifyReadback({...proof,nodes},operation));
 const secret=captureReadback({...raw,nodes:[{...raw.nodes[0]!,password:true,label:'secret-label',value:'secret-value'}]},target);
 assert.ok(!JSON.stringify(secret).includes('secret-'));assert.throws(()=>verifyReadback(secret,operation));
});

test('explicit foreign node ownership and hidden or secure ancestry cannot become app evidence',()=>{
 const foreign=captureReadback({...raw,nodes:[{...raw.nodes[0]!,bundleId:'foreign.App'}]},target);
 assert.throws(()=>verifyReadback(foreign,operation));
 for(const parent of [{visibleToUser:false},{interactionBlocked:'covered' as const},{password:true,label:'secret parent',value:'secret value'},{bundleId:'foreign.App'}]){
  const proof=captureReadback({...raw,nodes:[{...raw.nodes[0]!,parentIndex:2},{index:2,ref:'@e2',...parent}]},target);
  assert.throws(()=>verifyReadback(proof,operation));
  if('password' in parent)assert.ok(!JSON.stringify(proof).includes('secret'));
 }
});

test('ordinary fill role cannot be interpreted as a label readback oracle',()=>{
 const proof=captureReadback({...raw,nodes:[{...raw.nodes[0]!,label:'textbox'}]},target);
 assert.throws(()=>verifyReadback(proof,{...operation,locator:{kind:'role',value:'textbox'}}));
});
