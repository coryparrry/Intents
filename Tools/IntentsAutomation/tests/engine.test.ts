import {test} from 'node:test';import assert from 'node:assert/strict';
import type {CaptureSnapshotResult,AgentDeviceDevice} from 'agent-device';
import {EngineError,type OperationContext} from 'e2e/engine';
import {supportsFill,semanticTree} from '../src/e2e/semanticTree.js';
import {intentsUIEngine} from '../src/e2e/engine.js';import {selectExact,type UIBackend} from '../src/deviceSession.js';
const context:OperationContext={signal:new AbortController().signal,timeoutMs:1000,runId:'run',attemptId:'attempt',origin:'test'};
const snapshot:CaptureSnapshotResult={truncated:false,refsGeneration:1,identifiers:{udid:'exact'},appBundleId:'com.example.App',nodes:[
 {index:1,ref:'@e1',role:'button',label:'Done',identifier:'done'},
 {index:2,ref:'@e2',role:'button',label:'Done',identifier:'other'}]};
function fake(){let data=structuredClone(snapshot);let actions=0;const backend:UIBackend={snapshot:async()=>data,
 perform:async()=>{actions++},release:async()=>({released:false,reason:'not qualified'})};
 return {backend,set:(next:CaptureSnapshotResult)=>{data=next},calls:()=>actions};}
test('C06 exact selection ignores duplicate names and rejects mismatch',()=>{
 const devices:AgentDeviceDevice[]=['one','two'].map(id=>({id,name:'iPhone',platform:'ios',target:'mobile',kind:'simulator',identifiers:{udid:id}}));
 assert.equal(selectExact(devices,{id:'two',platform:'ios',kind:'simulator',bundleId:'com.example.App',bundlePath:null,loginSession:null}).id,'two');
 assert.throws(()=>selectExact(devices,{id:'missing',platform:'ios',kind:'simulator',bundleId:'com.example.App',bundlePath:null,loginSession:null}));
});
test('C07 locators return every immediate match',async()=>{
 const f=fake();const engine=intentsUIEngine(f.backend,'ios','com.example.App');
 const matches=await engine.locate!({kind:'query',query:{kind:'role',value:{kind:'string',value:'button',exact:true},name:{kind:'string',value:'Done',exact:true}}},context);
 assert.equal(matches.length,2);
});
test('C08 stale references and truncated captures are not absence evidence',async()=>{
 const f=fake();const e=intentsUIEngine(f.backend,'ios','com.example.App');const observed=await e.observe!(context);
 f.set({...snapshot,nodes:[]});await assert.rejects(()=>e.perform!(observed.root.children![0]!.ref,{kind:'tap'},context),{code:'NODE_STALE'});assert.equal(f.calls(),0);
 f.set({...snapshot,truncated:true});await assert.rejects(()=>e.locate!({kind:'query',query:{kind:'testId',value:{kind:'string',value:'missing',exact:true}}},context));
});
test('C10 committed ambiguity reaches runner as nonretryable',async()=>{
 const f=fake();f.backend.perform=async()=>{throw new EngineError('ACTION_MAY_HAVE_COMMITTED','ambiguous',{retryable:true})};
 const e=intentsUIEngine(f.backend,'macos','com.example.App');const observed=await e.observe!(context);
 await assert.rejects(()=>e.perform!(observed.root.children![0]!.ref,{kind:'tap'},context),(error:unknown)=>error instanceof EngineError && !error.retryable);
});
test('C11 engine lifecycle cannot open/reset/restart the subject',async()=>{
 const f=fake();const e=intentsUIEngine(f.backend,'macos','com.example.App');assert.equal(e.session,undefined);assert.equal(e.platform,'macos');
 await e.observe!(context);assert.equal(f.calls(),0);
});
test('production roles, secret redaction and unknown states remain faithful',async()=>{
 const f=fake();f.set({...snapshot,nodes:[{index:1,ref:'@e1',type:'TextField',kind:'textbox',password:true,value:'secret'}]});
 const e=intentsUIEngine(f.backend,'ios','com.example.App');const observed=await e.observe!(context);const node=observed.root.children![0]!;
 assert.equal(node.role,'textbox');assert.equal(node.value,undefined);assert.equal(node.states?.secure,true);assert.equal(node.states?.checked,undefined);
});
test('fresh partial capture and cancelled context cannot dispatch',async()=>{
 const f=fake();const e=intentsUIEngine(f.backend,'ios','com.example.App');const observed=await e.observe!(context);
 f.set({...snapshot,truncated:true});await assert.rejects(()=>e.perform!(observed.root.children![0]!.ref,{kind:'tap'},context));
 f.set(snapshot);const cancelled=new AbortController();cancelled.abort();await assert.rejects(()=>e.perform!(observed.root.children![0]!.ref,{kind:'tap'},{...context,signal:cancelled.signal}));
 assert.equal(f.calls(),0);
});
test('virtualized fresh capture cannot establish a unique mutation target',async()=>{
 const f=fake();const e=intentsUIEngine(f.backend,'ios','com.example.App');const observed=await e.observe!(context);
 f.set({...snapshot,nodes:snapshot.nodes.map(n=>({...n,hiddenContentBelow:true}))});
 await assert.rejects(()=>e.perform!(observed.root.children![0]!.ref,{kind:'tap'},context));assert.equal(f.calls(),0);
});
test('scroll-hidden content permits positive visible navigation without absence evidence',async()=>{
 const f=fake();f.set({...snapshot,nodes:[{index:0,ref:'e1',kind:'scroll-area',hiddenContentBelow:true},
  {index:1,parentIndex:0,ref:'e2',kind:'button',identifier:'done',hittable:true}]});
 const e=intentsUIEngine(f.backend,'ios','com.example.App',true);
 assert.equal((await e.observe!(context)).truncated,true);
 const query={kind:'query' as const,query:{kind:'testId' as const,visible:true,value:{kind:'string' as const,value:'done',exact:true}}};
 const matches=await e.locate!(query,context);assert.equal(matches.length,1);
 await e.perform!(matches[0]!.ref,{kind:'tap'},context);assert.equal(f.calls(),1);
 await assert.rejects(()=>e.locate!({...query,query:{...query.query,value:{...query.query.value,value:'missing'}}},context));
 await assert.rejects(()=>e.locate!({kind:'index',source:query,index:'first'},context));
 await assert.rejects(()=>e.locate!({...query,query:{...query.query,visible:false}},context));
 const observer=intentsUIEngine(f.backend,'ios','com.example.App');await assert.rejects(()=>observer.locate!(query,context));
 f.set({...snapshot,nodes:[{index:0,ref:'e1',kind:'scroll-area',hiddenContentBelow:true},
  {index:1,parentIndex:0,ref:'e2',kind:'button',identifier:'done'}]});
 await assert.rejects(()=>e.locate!(query,context));
});
test('metadata-only partial capture cannot be counted or asserted complete',async()=>{
 const f=fake();f.set({...snapshot,visibility:{partial:true,visibleNodeCount:2,totalNodeCount:2,reasons:['scroll-hidden-below']}});
 const e=intentsUIEngine(f.backend,'ios','com.example.App');assert.equal((await e.observe!(context)).truncated,true);
 await assert.rejects(()=>e.locate!({kind:'query',query:{kind:'testId',value:{kind:'string',value:'done',exact:true}}},context));
});
test('fresh covered or non-hittable controls cannot dispatch from partial navigation',async()=>{
 for(const flags of [{hittable:false},{hittable:true,enabled:false},{hittable:true,interactionBlocked:'covered' as const}]){
  const f=fake();const original:CaptureSnapshotResult={...snapshot,visibility:{partial:true,visibleNodeCount:1,totalNodeCount:1,reasons:['scroll-hidden-below']},
   nodes:[{index:1,ref:'e1',kind:'button',identifier:'done',hittable:true}]};f.set(original);
  const e=intentsUIEngine(f.backend,'ios','com.example.App',true);
  const nodes=await e.locate!({kind:'query',query:{kind:'testId',visible:true,value:{kind:'string',value:'done',exact:true}}},context);
  f.set({...original,nodes:original.nodes.map(n=>({...n,...flags}))});
  await assert.rejects(()=>e.perform!(nodes[0]!.ref,{kind:'tap'},context));assert.equal(f.calls(),0);
 }
});

test('unknown capture completeness cannot establish absence or cardinality',async()=>{
 const f=fake();const {truncated,...unknown}=snapshot;f.set(unknown);
 const e=intentsUIEngine(f.backend,'ios','com.example.App');
 assert.equal((await e.observe!(context)).truncated,true);
 await assert.rejects(()=>e.locate!({kind:'query',query:{kind:'testId',value:{kind:'string',value:'missing',exact:true}}},context));
});

test('C13 deterministic fills cannot downgrade fresh secure fields or ancestor contexts',async()=>{
 for(const mode of ['password','secure-role','secure-type','secure-subrole','secure-parent','secure-parent-subrole','caller-sensitive','ordinary']){
  const f=fake();const field={index:2,ref:'e2',kind:mode==='secure-role'?'secure-text-field':'text-field',identifier:'field',editable:true,hittable:true,
   ...(mode==='password'?{password:true}:{}),...(mode==='secure-type'?{type:'SecureTextField'}:{}),
   ...(mode==='secure-subrole'?{role:'AXTextField',subrole:'AXSecureTextField'}:{}),
   ...(mode.startsWith('secure-parent')?{parentIndex:1}:{})};
  f.set({...snapshot,nodes:mode.startsWith('secure-parent')?[{index:1,ref:'e1',kind:'group',
   ...(mode==='secure-parent'?{password:true}:{subrole:'AXSecureTextField'})},field]:[field]});
  const engine=intentsUIEngine(f.backend,'ios','com.example.App');
  const matches=await engine.locate!({kind:'query',query:{kind:'testId',value:{kind:'string',value:'field',exact:true}}},context);
  const fill={kind:'fill' as const,value:'synthetic input',sensitive:mode==='caller-sensitive'};
  if(mode==='ordinary'){await engine.perform!(matches[0]!.ref,fill,context);assert.equal(f.calls(),1);}
  else{await assert.rejects(()=>engine.perform!(matches[0]!.ref,fill,context),{code:'UNSUPPORTED_CAPABILITY'});assert.equal(f.calls(),0);}
 }
});

test('role and exact accessible name disambiguate menu text without weakening uniqueness or partial capture',async()=>{
 const f=fake();f.set({...snapshot,nodes:[{index:0,ref:'e1',kind:'text',label:'Wrong record',hittable:true},
  {index:1,ref:'e2',kind:'button',label:'Wrong record',hittable:true}]});
 const e=intentsUIEngine(f.backend,'ios','com.example.App',true);
 const query={kind:'query' as const,query:{kind:'role' as const,visible:true,value:{kind:'string' as const,value:'button',exact:true},name:{kind:'string' as const,value:'Wrong record',exact:true}}};
 const label={kind:'query' as const,query:{kind:'label' as const,visible:true,value:{kind:'string' as const,value:'Wrong record',exact:true}}};
 assert.equal((await e.locate!(label,context)).length,2);
 const matches=await e.locate!(query,context);assert.equal(matches.length,1);assert.equal(matches[0]!.role,'button');
 await e.perform!(matches[0]!.ref,{kind:'tap'},context);assert.equal(f.calls(),1);
 f.set({...snapshot,nodes:[{index:0,ref:'e1',kind:'button',label:'Wrong record',hittable:true,identifier:'one'},
  {index:1,ref:'e2',kind:'button',label:'Wrong record',hittable:true,identifier:'two'}]});
 assert.equal((await e.locate!(query,context)).length,2);
 f.set({...snapshot,truncated:true});await assert.rejects(()=>e.locate!(query,context));assert.equal(f.calls(),1);
});

test('repeated structural nodes get unique observation refs while ambiguous actions remain refused',async()=>{
 const f=fake();
 f.set({...snapshot,nodes:[{index:1,ref:'@e1',role:'other',label:'Container'},
                         {index:2,ref:'@e2',role:'other',label:'Container'},
                         {index:3,ref:'@e3',role:'button',label:'Add task',identifier:'add',hittable:true,enabled:true}]});
 const engine=intentsUIEngine(f.backend,'ios','com.example.App');const observed=await engine.observe!(context);
 const children=observed.root.children!;assert.equal(new Set(children.map(n=>n.ref.id)).size,3);
 await engine.perform!(children[2]!.ref,{kind:'tap'},context);assert.equal(f.calls(),1);
 await assert.rejects(()=>engine.perform!(children[0]!.ref,{kind:'tap'},context),{code:'NODE_STALE'});
 assert.equal(f.calls(),1);
});

test('iOS supported fill path preserves unavailable editable fact and rejects negative facts',()=>{
 const field={index:1,ref:'e1',type:'TextField',kind:'text-field',hittable:true,enabled:true};
 const observed=semanticTree({...snapshot,nodes:[field]},1,'ios').snapshot.root.children![0]!;
 assert.equal(observed.attributes?.editable,undefined);assert.equal(observed.attributes?.fillSupported,'true');
 for(const changed of [{editable:false},{enabled:false},{hittable:false},{userInteractionEnabled:false},{kind:'button'},{type:'Other'},{password:true}])
  assert.equal(supportsFill({...field,...changed},'ios'),false);
 assert.equal(supportsFill(field,'macos'),false);
 for(const [type,kind] of [['TextField','text-field'],['TextView','text-view'],['SearchField','search-field']] as const)
  assert.equal(supportsFill({...field,type,kind},'ios'),true);
 const secure=semanticTree({...snapshot,nodes:[{index:0,ref:'e0',type:'SecureTextField'},
  {...field,parentIndex:0,value:'private-value'}]},1,'ios').snapshot.root.children![0]!.children![0]!;
 assert.equal(secure.value,undefined);assert.equal(secure.states?.secure,true);assert.equal(secure.attributes?.fillSupported,'false');
});
test('fresh capture must retain the observed qualified fill path',async()=>{
 const f=fake();const field={index:1,ref:'e1',type:'TextField',kind:'text-field',hittable:true,enabled:true};
 f.set({...snapshot,nodes:[field]});const e=intentsUIEngine(f.backend,'ios','com.example.App');const observed=await e.observe!(context);
 f.set({...snapshot,nodes:[{...field,editable:false}]});
 await assert.rejects(()=>e.perform!(observed.root.children![0]!.ref,{kind:'fill',value:'approved',sensitive:false},context),{code:'UNSUPPORTED_CAPABILITY'});assert.equal(f.calls(),0);
 f.set({...snapshot,nodes:[field]});await e.perform!(observed.root.children![0]!.ref,{kind:'fill',value:'approved',sensitive:false},context);assert.equal(f.calls(),1);
});

 test('stable identified refs require complete unique identifiers and retain owner and security identity',()=>{
 const field={index:1,ref:'e1',identifier:'field',kind:'text-field',type:'TextField',hittable:true,enabled:true,rect:{x:0,y:0,width:100,height:50}};
 const node=(capture:CaptureSnapshotResult)=>semanticTree(capture,1,'ios',true).snapshot.root.children![0]!;
 const base={...snapshot,nodes:[field]};const id=node(base).ref.id;
 const moved={...field,index:4,rect:{...field.rect,x:20},value:'changed'};
 assert.equal(node({...base,nodes:[moved]}).ref.id,id);
 const {truncated:ignored,...unknown}=base;
 const incomplete:CaptureSnapshotResult[]=[{...base,truncated:true},{...base,visibility:{partial:true,visibleNodeCount:1,totalNodeCount:2,reasons:['scroll-hidden-below']}},unknown];
 for(const capture of incomplete)assert.notEqual(node({...capture,nodes:[moved]}).ref.id,id);
 for(const flags of [{hiddenContentAbove:true},{hiddenContentBelow:true},{parentIndex:99}])
  assert.notEqual(node({...base,nodes:[{...moved,...flags}]}).ref.id,id);
 assert.notEqual(node({...base,nodes:[field,{...field,index:2,ref:'e2',kind:'button'}]}).ref.id,id);
 for(const identity of [{bundleId:'other.app'},{windowTitle:'other window'},{password:true},{kind:'button'}])
  assert.notEqual(node({...base,nodes:[{...field,...identity}]}).ref.id,id);
});
 test('controller exact dispatch token cannot be reused and fresh inaccessible targets never dispatch',async()=>{
 const f=fake();const field={index:1,ref:'e1',identifier:'field',kind:'text-field',type:'TextField',hittable:true,enabled:true};
 f.set({...snapshot,nodes:[field]});let approved:string|undefined;let consumed=0;
 const engine=intentsUIEngine(f.backend,'ios','com.example.App',true,{node:()=>approved,consume:()=>{approved=undefined;consumed++;}});
 const observed=await engine.observe!(context);approved=observed.root.children![0]!.ref.id;
 f.set({...snapshot,nodes:[{...field,hittable:false}]});
 await assert.rejects(engine.perform!(observed.root.children![0]!.ref,{kind:'tap'},context));assert.equal(f.calls(),0);assert.equal(consumed,0);
 f.set({...snapshot,nodes:[field]});await engine.perform!(observed.root.children![0]!.ref,{kind:'tap'},context);
 assert.equal(f.calls(),1);assert.equal(consumed,1);
 await assert.rejects(engine.perform!(observed.root.children![0]!.ref,{kind:'tap'},context));assert.equal(f.calls(),1);
});

test('fresh Mac ancestor cycle preserves field fingerprint but rejects promptly before filling',async()=>{
 const f=fake();const field={index:1,ref:'e1',role:'AXTextField',parentIndex:2,editable:true,hittable:true,enabled:true,visibleToUser:true};
 f.set({...snapshot,nodes:[field,{index:2,ref:'e2',role:'AXGroup',hittable:true,enabled:true}]});
 const engine=intentsUIEngine(f.backend,'macos','com.example.App',false,undefined,['tap','fill']);
 const matches=await engine.locate!({kind:'query',query:{kind:'role',value:{kind:'string',value:'textbox',exact:true}}},context);assert.equal(matches.length,1);
 f.set({...snapshot,nodes:[field,{index:2,ref:'e2',role:'AXGroup',parentIndex:3},{index:3,ref:'e3',role:'AXGroup',parentIndex:2}]});
 await assert.rejects(engine.perform!(matches[0]!.ref,{kind:'fill',value:'public',sensitive:false},context),{code:'ENGINE_FAILURE'});assert.equal(f.calls(),0);
});
