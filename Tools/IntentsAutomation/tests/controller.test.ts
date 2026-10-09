import {test} from 'node:test';import assert from 'node:assert/strict';
import type {StepExecutorContext,ExecutorObservation} from 'e2e';
import {nativeControllerExecutor,positiveEndpoint} from '../src/e2e/nativeController.js';
import type {ControllerRequest,NavigationGoal} from '../src/controllerProtocol.js';
import {goalSchema} from '../src/controllerProtocol.js';
const goal:NavigationGoal={id:'open-form',instruction:'Open the test form',endpoint:{kind:'testId',value:'done'},maximumCalls:12,maximumActions:30};
const observed:ExecutorObservation={revision:'1',text:'redacted',truncated:false,viewport:{width:400,height:800},tree:{id:'node-1',name:'Done',attributes:{testId:'done',hittable:'true',editable:'true'},states:{},value:'current'}};
function context(observations:ExecutorObservation[]=[observed]){
 let actions=0,calls=0,index=0;const cancel=new AbortController();const dispatched:string[]=[];
 const ctx={step:{kind:'act',instruction:goal.instruction,params:{goalId:goal.id}},target:{name:'approved',platform:'ios',verbs:new Set(['tap','type','scroll'])},
  attempt:{signal:cancel.signal},signal:cancel.signal,budgets:{maxActions:30,maxModelCalls:12,remainingMs:()=>120000,actionsUsed:()=>actions,recordModelCall:()=>{calls++},
  runTool:()=>{throw new Error('Grammar actions must not be nested in runTool')}},observe:async()=>observations[Math.min(index++,observations.length-1)]!,
  actions:{tap:async(n:{id:string})=>{actions++;dispatched.push(n.id)},type:async(n:{id:string},v:string)=>{actions++;dispatched.push(n.id+':'+v)},scroll:async()=>{actions++;dispatched.push('scroll')}},attachTranscript:()=>{}} as unknown as StepExecutorContext;
 return {ctx,cancel,dispatched,calls:()=>calls};
}
test('finish requires a fresh independent endpoint observation',async()=>{
 const missing={...observed,tree:{id:'other',name:'Other',attributes:{hittable:'true'}}};
 const f=context([observed,missing]);const result=await nativeControllerExecutor(goal,{},'setup',async()=>({kind:'finish'})).runStep(f.ctx);
 assert.equal(result.status,'blocked');assert.equal(result.errorCode,'AUTOMATION_UNSUPPORTED');assert.equal(f.dispatched.length,0);
 const valid=context();assert.equal((await nativeControllerExecutor(goal,{},'setup',async()=>({kind:'finish'})).runStep(valid.ctx)).status,'passed');
});
test('partial or duplicate endpoint trees cannot establish completion',()=>{
 assert.equal(positiveEndpoint({...observed,truncated:true},goal),false);
 assert.equal(positiveEndpoint({...observed,tree:{id:'root',children:[observed.tree!,{...observed.tree!,id:'duplicate'}]}},goal),false);
});
test('save control must be tapped once before finish; a visible destination is insufficient',async()=>{
 const saveGoal:NavigationGoal={...goal,saveControl:{kind:'label',value:'Save'}};
 const screen={...observed,tree:{...observed.tree!,children:[{id:'save',role:'button',name:'Save',attributes:{hittable:'true'},states:{}}]}};
 const early=context([screen]);assert.equal((await nativeControllerExecutor(saveGoal,{},'setup',async()=>({kind:'finish'})).runStep(early.ctx)).status,'blocked');
 assert.deepEqual(early.dispatched,[]);
 let calls=0;const valid=context([screen]);
 assert.equal((await nativeControllerExecutor(saveGoal,{},'setup',async request=>{
  assert.equal(request.approvedSaveTap,calls>0);return calls++===0?{kind:'tap',node:'save'}:{kind:'finish'};
 }).runStep(valid.ctx)).status,'passed');assert.deepEqual(valid.dispatched,['save']);
 const repeat=context([screen]);
 assert.equal((await nativeControllerExecutor(saveGoal,{},'setup',async()=>({kind:'tap',node:'save'})).runStep(repeat.ctx)).status,'blocked');
 assert.deepEqual(repeat.dispatched,['save']);
});
test('clipped longer button labels cannot be approved save controls',()=>{
 assert.throws(()=>goalSchema.parse({...goal,saveControl:{kind:'label',value:'s'.repeat(512)}}));
 assert.throws(()=>nativeControllerExecutor({...goal,saveControl:{kind:'label',value:'Save'}},{},'observe',async()=>({kind:'finish'})));
});
test('repeated action and state stops without another mutation',async()=>{
 const f=context();const result=await nativeControllerExecutor(goal,{},'setup',async()=>({kind:'tap',node:'node-1'})).runStep(f.ctx);
 assert.equal(result.status,'blocked');assert.equal(result.summary,'navigationStalled');assert.deepEqual(f.dispatched,['node-1']);assert.equal(f.calls(),2);
});
test('secret sinks and unapproved bindings are rejected before dispatch',async()=>{
 let received:ControllerRequest|undefined;const secure={...observed,tree:{...observed.tree!,states:{secure:true},text:'secret-text-must-not-reach-controller',value:'must-not-reach-controller'}};
 const f=context([secure]);const result=await nativeControllerExecutor(goal,{approved:'test input'},'subject',async request=>{received=request;return {kind:'fill',node:'node-1',textBinding:'approved'}}).runStep(f.ctx);
 assert.equal(result.errorCode,'POLICY_DENIED');assert.equal(f.dispatched.length,0);assert.ok(!JSON.stringify(received).includes('must-not-reach-controller'));
 const g=context();assert.equal((await nativeControllerExecutor(goal,{approved:'input'},'subject',async()=>({kind:'fill',node:'node-1',textBinding:'invented'})).runStep(g.ctx)).errorCode,'POLICY_DENIED');assert.equal(g.dispatched.length,0);
});
test('observer cannot fill and unsupported native verbs are not offered',async()=>{
 const f=context();let offered:string[]=[];const result=await nativeControllerExecutor(goal,{approved:'input'},'observe',async request=>{offered=request.verbs;return {kind:'fill',node:'node-1',textBinding:'approved'}}).runStep(f.ctx);
 assert.equal(result.errorCode,'POLICY_DENIED');assert.deepEqual(offered,['tap','scroll']);assert.equal(f.dispatched.length,0);
});
test('controller unavailability, cancellation and uncertain replay block only the goal',async()=>{
 const f=context();assert.equal((await nativeControllerExecutor(goal,{},'setup',async()=>({kind:'cannotProceed',reason:'modelUnavailable'})).runStep(f.ctx)).errorCode,'MODEL_UNAVAILABLE');
 const g=context();assert.equal((await nativeControllerExecutor(goal,{},'setup',async()=>{g.cancel.abort();return {kind:'tap',node:'node-1'}}).runStep(g.ctx)).errorCode,'ENVIRONMENT_UNAVAILABLE');assert.equal(g.dispatched.length,0);
 const h=context();const replay={...h.ctx,replayedPrefix:{replayedActions:[],totalActions:1,stopReason:'action-uncertain' as const,uncertainAction:'tap'}};
 assert.equal((await nativeControllerExecutor(goal,{},'setup',async()=>{throw new Error('Must not call controller')}).runStep(replay)).status,'blocked');
});
test('assertion execution only observes the declared endpoint',async()=>{
 const f=context();const ctx={...f.ctx,step:{...f.ctx.step,kind:'assert' as const}};
 assert.equal((await nativeControllerExecutor(goal,{},'observe',async()=>{throw new Error('Assertions must not ask the controller')}).runStep(ctx)).status,'passed');assert.equal(f.calls(),0);assert.equal(f.dispatched.length,0);
});

test('a positive endpoint after the last permitted action or model call still completes navigation',async()=>{
 const missing={...observed,tree:{id:'node-1',name:'Open',attributes:{hittable:'true'}}};
 for(const budget of [{maximumActions:1},{maximumCalls:1}]){
  const f=context([missing,observed]);
  const result=await nativeControllerExecutor({...goal,...budget},{},'setup',async()=>({kind:'tap',node:'node-1'})).runStep(f.ctx);
  assert.equal(result.status,'passed');assert.equal(f.calls(),1);assert.deepEqual(f.dispatched,['node-1']);
 }
 const absent=context([missing]);assert.equal((await nativeControllerExecutor({...goal,maximumActions:1},{},'setup',async()=>({kind:'tap',node:'node-1'})).runStep(absent.ctx)).errorCode,'STEP_BUDGET_EXHAUSTED');
});
test('node-targeted scrolling is refused rather than silently scrolling the viewport',async()=>{
 const f=context();const result=await nativeControllerExecutor(goal,{},'setup',async()=>({kind:'scroll',direction:'down',node:'node-1'})).runStep(f.ctx);
 assert.equal(result.errorCode,'POLICY_DENIED');assert.equal(f.dispatched.length,0);
});
test('controller protocol refuses unredacted secure text and values',async()=>{
 const {controllerNodeSchema}=await import('../src/controllerProtocol.js');
 const base={id:'secret',editable:true,visible:true,disabled:false,secure:true};
 assert.equal(controllerNodeSchema.safeParse(base).success,true);
 for(const field of ['text','value'])assert.equal(controllerNodeSchema.safeParse({...base,[field]:'secret'}).success,false);
});

// The installed pinned validator is used only in this dependency contract test.
test('every controller blocked outcome satisfies the pinned runner verdict contract',async()=>{
 const {validateVerdict}=await import(new URL('./agent/act-validation.js',import.meta.resolve('e2e')).href) as {validateVerdict:(value:unknown,name:string)=>unknown};
 const unavailable={...observed,treeUnavailable:true as const};
 const ambiguous={...observed,tree:{...observed.tree!,children:[observed.tree!]}};
 const cases=[
  {f:context(),decision:{kind:'cannotProceed',reason:'noSafeAction'}},
  {f:context(),decision:{kind:'cannotProceed',reason:'modelUnavailable'}},
  {f:context([unavailable]),decision:{kind:'finish'}},
  {f:context([ambiguous]),decision:{kind:'finish'}},
  {f:context(),decision:{kind:'tap',node:'absent'}},
  {f:context(),decision:{kind:'fill',node:'node-1',textBinding:'unapproved'}},
  {f:context(),decision:{kind:'scroll',direction:'down',node:'node-1'}}
 ];
 for(const {f,decision} of cases){
  const result=await nativeControllerExecutor(goal,{},'setup',async()=>decision).runStep(f.ctx);
  assert.equal(result.status,'blocked');assert.doesNotThrow(()=>validateVerdict(result,'intents-native-foundation-controller'));
  assert.equal(f.dispatched.length,0);
 }
 const cancelled=context();cancelled.cancel.abort();
 const result=await nativeControllerExecutor(goal,{},'setup',async()=>{throw new Error('Must not run')}).runStep(cancelled.ctx);
 assert.doesNotThrow(()=>validateVerdict(result,'intents-native-foundation-controller'));
});

test('unknown editable reaches the controller unchanged while supported fill and explicit false stay distinct',async()=>{
 const field:ExecutorObservation={...observed,tree:{id:'field',role:'text-field',attributes:{hittable:'true',fillSupported:'true'},states:{}}};
 const f=context([field,observed]);let call=0;
 const result=await nativeControllerExecutor(goal,{approved:'value'},'setup',async request=>{
  if(call++===0){assert.equal(request.nodes[0]!.editable,undefined);assert.equal(request.nodes[0]!.fillSupported,true);
   return {kind:'fill',node:'field',textBinding:'approved'};}
  return {kind:'finish'};
 }).runStep(f.ctx);
 assert.equal(result.status,'passed');assert.deepEqual(f.dispatched,['field:value']);
 const denied=context([{...field,tree:{...field.tree!,attributes:{...field.tree!.attributes,editable:'false'}}}]);
 const blocked=await nativeControllerExecutor(goal,{approved:'value'},'setup',async()=>({kind:'fill',node:'field',textBinding:'approved'})).runStep(denied.ctx);
 assert.equal(blocked.errorCode,'POLICY_DENIED');assert.equal(denied.dispatched.length,0);
});

test('required binding activity cannot be replaced by a screen title or budget-boundary endpoint',async()=>{
 const required={...goal,minimumBindingUses:{approved:2}};
 const early=context();const finish=await nativeControllerExecutor(required,{approved:'value'},'setup',async()=>({kind:'finish'})).runStep(early.ctx);
 assert.equal(finish.status,'blocked');assert.equal(early.dispatched.length,0);
 const last=context();const boundary=await nativeControllerExecutor({...required,maximumCalls:1},{approved:'value'},'setup',async()=>({kind:'fill',node:'node-1',textBinding:'approved'})).runStep(last.ctx);
 assert.equal(boundary.errorCode,'STEP_BUDGET_EXHAUSTED');assert.deepEqual(last.dispatched,['node-1:value']);
 const valid=context();let calls=0;
 const success=await nativeControllerExecutor({...goal,minimumBindingUses:{approved:1}},{approved:'value'},'setup',async()=>calls++===0?{kind:'fill',node:'node-1',textBinding:'approved'}:{kind:'finish'}).runStep(valid.ctx);
 assert.equal(success.status,'passed');assert.deepEqual(valid.dispatched,['node-1:value']);
});

test('approved binding names that overlap Object properties retain numeric counts',async()=>{
 for(const key of ['constructor','toString','__proto__']){
  const f=context();let calls=0;
  const result=await nativeControllerExecutor({...goal,minimumBindingUses:{[key]:1}},{[key]:'value'},'setup',async()=>calls++===0?{kind:'fill',node:'node-1',textBinding:key}:{kind:'finish'}).runStep(f.ctx);
  assert.equal(result.status,'passed',key);assert.deepEqual(f.dispatched,['node-1:value']);
 }
});

test('required binding dictionary rejects malformed or excessive input activity',()=>{
 const excessive=Object.fromEntries(Array.from({length:31},(_,i)=>['binding'+i,1]));
 for(const minimumBindingUses of [null,[],{},new Date(),{approved:0},{approved:1.5},{approved:31},{approved:'1'},{'bad key':1},excessive,{first:20,second:20}])
  assert.equal(goalSchema.safeParse({...goal,minimumBindingUses}).success,false);
 const preserved=goalSchema.parse({...goal,minimumBindingUses:JSON.parse('{"constructor":1,"__proto__":1}')});
 assert.equal(JSON.stringify(preserved.minimumBindingUses),'{"constructor":1,"__proto__":1}');
});

test('endpoint observations cannot pass after either cancellation signal or deadline expires',async()=>{
 for(const route of ['assert','finish','boundary'] as const){
  for(const stop of ['step','attempt','deadline'] as const){
   const f=context();const attemptCancel=new AbortController();let remaining=120000,observations=0;
   const ctx={...f.ctx,attempt:{...f.ctx.attempt,signal:attemptCancel.signal},
    step:{...f.ctx.step,kind:route==='assert'?'assert' as const:'act' as const},
    budgets:{...f.ctx.budgets,remainingMs:()=>remaining},observe:async()=>{
     if(++observations===(route==='assert'?1:2)){
      if(stop==='step')f.cancel.abort();else if(stop==='attempt')attemptCancel.abort();else remaining=0;
     }
     return observed;
    }};
   const result=await nativeControllerExecutor({...goal,...(route==='boundary'?{maximumCalls:1}:{})},{},'setup',async()=>route==='boundary'?{kind:'tap',node:'node-1'}:{kind:'finish'}).runStep(ctx);
   assert.equal(result.status,'blocked',`${route}/${stop}`);
   assert.equal(result.errorCode,stop==='deadline'?'STEP_TIMEOUT':'ENVIRONMENT_UNAVAILABLE',`${route}/${stop}`);
  }
 }
});

test('attempt cancellation and deadline expiry during controller decision prevent dispatch',async()=>{
 for(const stop of ['attempt','deadline'] as const){
  const f=context();const attemptCancel=new AbortController();let remaining=120000;
  const ctx={...f.ctx,attempt:{...f.ctx.attempt,signal:attemptCancel.signal},budgets:{...f.ctx.budgets,remainingMs:()=>remaining}};
  const result=await nativeControllerExecutor(goal,{},'setup',async()=>{
   if(stop==='attempt')attemptCancel.abort();else remaining=0;
   return {kind:'tap',node:'node-1'};
  }).runStep(ctx);
  assert.equal(result.errorCode,stop==='deadline'?'STEP_TIMEOUT':'ENVIRONMENT_UNAVAILABLE');assert.deepEqual(f.dispatched,[]);
 }
});

 test('controller preserves exact observed test identifiers and omits oversized ones',async()=>{
 for(const testId of ['task.title','x'.repeat(1025)]){
  let received:ControllerRequest|undefined;
  const f=context([{...observed,tree:{...observed.tree!,attributes:{...observed.tree!.attributes,testId}}}]);
  await nativeControllerExecutor(goal,{},'setup',async request=>{received=request;return {kind:'cannotProceed',reason:'noSafeAction'}}).runStep(f.ctx);
  assert.equal(received!.nodes[0]!.testId,testId.length<=1024?testId:undefined);
  assert.equal(f.dispatched.length,0);
 }
});

test('clipped exact anchors make the native projection incomplete',async()=>{
 for(const tree of [{...observed.tree!,name:'x'.repeat(513)}, {...observed.tree!,attributes:{...observed.tree!.attributes,testId:'x'.repeat(1025)}}]) {
  let received:ControllerRequest|undefined;
  const f=context([{...observed,tree}]);
  await nativeControllerExecutor(goal,{},'setup',async request=>{received=request;return {kind:'cannotProceed',reason:'noSafeAction'}}).runStep(f.ctx);
  assert.equal(received?.truncated,true);assert.equal(received?.omittedNodes,0);assert.equal(f.dispatched.length,0);
 }
});

test('oversized values cannot masquerade as an exact 1024-unit binding match',async()=>{
 const prefix='x'.repeat(1024);
 for(const [value,expected] of [[prefix,prefix],[prefix+'suffix',undefined],['','']] as const){
  let received:ControllerRequest|undefined;const f=context([{...observed,tree:{...observed.tree!,value}}]);
  await nativeControllerExecutor(goal,{approved:prefix},'setup',async request=>{received=request;return {kind:'cannotProceed',reason:'noSafeAction'}}).runStep(f.ctx);
  assert.equal(received?.nodes[0]?.value,expected);assert.equal(received?.truncated,value.length>1024);assert.equal(f.dispatched.length,0);
 }
});
test('frozen fill whitelist rejects context bindings and allows absent legacy scope',async()=>{
 for(const allowedFillBindings of [['approved'],[]]){
  const f=context();const result=await nativeControllerExecutor({...goal,allowedFillBindings},{approved:'name',context:'Work'},'setup',async()=>({kind:'fill',node:'node-1',textBinding:'context'})).runStep(f.ctx);
  assert.equal(result.errorCode,'POLICY_DENIED');assert.equal(f.dispatched.length,0);
 }
 const legacy=context();await nativeControllerExecutor({...goal,maximumActions:1},{context:'Work'},'setup',async()=>({kind:'fill',node:'node-1',textBinding:'context'})).runStep(legacy.ctx);
 assert.deepEqual(legacy.dispatched,['node-1:Work']);
 assert.equal(goalSchema.safeParse({...goal,allowedFillBindings:['approved','approved']}).success,false);
 assert.equal(goalSchema.safeParse({...goal,minimumBindingUses:{approved:1},allowedFillBindings:[]}).success,false);
});

test('missing frozen goal values are rejected before observation or action',()=>{
 assert.throws(()=>nativeControllerExecutor({...goal,allowedFillBindings:['missing']},{},'setup',async()=>({kind:'finish'})),/no supplied value/);
 assert.throws(()=>nativeControllerExecutor({...goal,minimumBindingUses:{missing:1}},{},'setup',async()=>({kind:'finish'})),/no supplied value/);
 assert.throws(()=>nativeControllerExecutor({...goal,allowedFillBindings:[],selectionBindings:['missing']},{},'setup',async()=>({kind:'finish'})),/no supplied value/);
});

test('option selection bindings have a bounded explicit scope separate from input values',()=>{
 for(const selectionBindings of [[],['account','account'],['bad key'],Array.from({length:31},(_,i)=>`account${i}`)])
  assert.equal(goalSchema.safeParse({...goal,allowedFillBindings:[],selectionBindings}).success,false);
 assert.equal(goalSchema.safeParse({...goal,selectionBindings:['account']}).success,false);
 assert.equal(goalSchema.safeParse({...goal,allowedFillBindings:['account'],selectionBindings:['account']}).success,false);
 assert.equal(goalSchema.safeParse({...goal,allowedFillBindings:['name'],selectionBindings:['account']}).success,true);
});

test('known selection facts stay true or false and absent facts stay unknown',async()=>{
 for(const selected of [true,false,undefined]){
  let received:ControllerRequest|undefined;const f=context([{...observed,tree:{...observed.tree!,states:selected===undefined?{}:{selected}}}]);
  await nativeControllerExecutor(goal,{},'setup',async request=>{received=request;return {kind:'cannotProceed',reason:'noSafeAction'}}).runStep(f.ctx);
  assert.equal(received?.nodes[0]?.selected,selected);assert.equal(f.dispatched.length,0);
 }
});
