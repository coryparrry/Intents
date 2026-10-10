import type {StepExecutor,StepExecutorContext,StepVerdict,ExecutorNode,ExecutorObservation} from 'e2e';
import {controllerRequestSchema,decisionSchema,goalSchema,type ControllerRequest,type NavigationGoal} from '../controllerProtocol.js';

function nodes(observation:ExecutorObservation):ExecutorNode[]{
 const result:ExecutorNode[]=[];const stack=observation.tree?[observation.tree]:[];
 while(stack.length){const node=stack.pop()!;if(result.length>=5000)throw new Error('Observation node budget');result.push(node);stack.push(...(node.children??[]));}
 return result;
}
export function positiveEndpoint(observation:ExecutorObservation,goal:NavigationGoal):boolean {
 if(observation.treeUnavailable || observation.truncated)return false;
 const matches=nodes(observation).filter(n=>goal.endpoint.kind==='testId'?n.attributes?.testId===goal.endpoint.value:n.name===goal.endpoint.value);
 return matches.length===1 && matches[0]!.attributes?.hittable==='true' && matches[0]!.states?.disabled!==true && matches[0]!.states?.hidden!==true;
}
export function nativeControllerExecutor(goalInput:NavigationGoal,bindings:Readonly<Record<string,string>>,phase:string,
 decide:(request:ControllerRequest,context:StepExecutorContext)=>Promise<unknown>):StepExecutor {
 const goal=goalSchema.parse(goalInput);
 if(goal.saveControl!==undefined && phase==='observe')throw new Error('Observer cannot use a save control');
 if([...(goal.allowedFillBindings??[]),...(goal.selectionBindings??[]),...Object.keys(goal.minimumBindingUses??{})].some(k=>!Object.hasOwn(bindings,k)))throw new Error('Declared goal binding has no supplied value');
 return {name:'intents-native-foundation-controller',version:'1',cache:'off',async runStep(ctx):Promise<StepVerdict>{
  const transcript:string[]=[];const bindingUses:Record<string,number>=Object.create(null);
  let saveTapped=false;
  const inputsComplete=()=>Object.entries(goal.minimumBindingUses??{}).every(([key,count])=>(bindingUses[key]??0)>=count) && (goal.saveControl===undefined || saveTapped);const blocked=(summary:string,errorCode:StepVerdict['errorCode']='TEST_SETUP_FAILED'):StepVerdict=>({status:'blocked',summary,errorCode});
  const started=Date.now(),usedBefore=ctx.budgets.actionsUsed();const seen=new Map<string,number>();let calls=0;
  const terminalStatus=():StepVerdict|undefined=>{
   if(ctx.signal.aborted || ctx.attempt.signal.aborted)return blocked('Controller cancelled','ENVIRONMENT_UNAVAILABLE');
   if(Date.now()-started>=120000 || ctx.budgets.remainingMs()<=0)return blocked('Controller deadline expired','STEP_TIMEOUT');
   return undefined;
  };
  try {
   if(ctx.step.instruction!==goal.instruction || ctx.step.params?.goalId!==goal.id)return blocked('Frozen navigation goal mismatch','POLICY_DENIED');
   if(ctx.replayedPrefix?.uncertainAction)return blocked('Replay has an uncertain mutation; review retained evidence','TEST_SETUP_FAILED');
   if(ctx.step.kind==='assert'){
    const terminal=terminalStatus();if(terminal)return terminal;
    const endpoint=await ctx.observe({tree:true});const afterObservation=terminalStatus();if(afterObservation)return afterObservation;
    return inputsComplete() && positiveEndpoint(endpoint,goal)?{status:'passed',summary:'Declared navigation endpoint observed'}:blocked('Endpoint could not be independently observed','AUTOMATION_UNSUPPORTED');
   }
   while(true){
    const terminal=terminalStatus();if(terminal)return terminal;
    const remainingMs=Math.floor(Math.min(120000-(Date.now()-started),ctx.budgets.remainingMs()));
    const remainingActions=Math.min(goal.maximumActions-(ctx.budgets.actionsUsed()-usedBefore),ctx.budgets.maxActions-ctx.budgets.actionsUsed());
    if(remainingMs<=0)return blocked('Controller deadline expired','STEP_TIMEOUT');
    if(remainingActions<=0 || calls>=Math.min(goal.maximumCalls,ctx.budgets.maxModelCalls)){
     const endpoint=await ctx.observe({tree:true});
     const afterObservation=terminalStatus();if(afterObservation)return afterObservation;
     return inputsComplete() && positiveEndpoint(endpoint,goal)?{status:'passed',summary:'Declared endpoint observed at the budget boundary'}:blocked('Controller budget exhausted','STEP_BUDGET_EXHAUSTED');
    }
    const observation=await ctx.observe({tree:true});
    const afterObservation=terminalStatus();if(afterObservation)return afterObservation;
    if(observation.treeUnavailable || !observation.tree)return blocked('No semantic observation is available','AUTOMATION_UNSUPPORTED');
    const all=nodes(observation),bounded=all.slice(0,200);
    if(new Set(all.map(n=>n.id)).size!==all.length)return blocked('Observation node identity is ambiguous','POLICY_DENIED');
    const verbs:ControllerRequest['verbs']=[];
    if(ctx.target.verbs.has('tap'))verbs.push('tap');
    if(phase!=='observe' && Object.keys(bindings).length && ctx.target.verbs.has('type'))verbs.push('fill');
    if(ctx.target.verbs.has('scroll'))verbs.push('scroll');
    // Unsupported back/key verbs remain capability gaps until the native engine qualifies them.
    const projectionIncomplete=all.some(n=>(n.name?.length??0)>512 || (n.role?.length??0)>128 || (n.attributes?.testId?.length??0)>1024 || (n.value?.length??0)>1024);
    const request=controllerRequestSchema.parse({goalId:goal.id,revision:observation.revision,truncated:observation.truncated || all.length>200 || projectionIncomplete,
     omittedNodes:Math.max(0,all.length-200),nodes:bounded.map(n=>({id:n.id,...(n.role?{role:n.role.slice(0,128)}:{}),...(n.name?{name:n.name.slice(0,512)}:{}),
      ...(n.attributes?.testId && n.attributes.testId.length<=1024?{testId:n.attributes.testId}:{}),
      ...(typeof n.states?.selected==='boolean'?{selected:n.states.selected}:{}),
      ...(n.text && n.states?.secure!==true?{text:n.text.slice(0,512)}:{}),...(n.value!==undefined && n.value.length<=1024 && n.states?.secure!==true?{value:n.value}:{}),
      ...(n.attributes?.editable!==undefined?{editable:n.attributes.editable==='true'}:{}),fillSupported:n.attributes?.fillSupported==='true',visible:n.attributes?.hittable==='true' && n.states?.hidden!==true,
      disabled:n.states?.disabled===true,secure:n.states?.secure===true})),verbs,recentActions:transcript.slice(-4).map(s=>s.slice(0,512)),remainingActions,remainingMs,approvedSaveTap:saveTapped});
    ctx.budgets.recordModelCall();calls++;
    const decision=decisionSchema.parse(await decide(request,ctx));
    const afterDecision=terminalStatus();if(afterDecision)return afterDecision;
    transcript.push(JSON.stringify({revision:request.revision,truncated:request.truncated,omittedNodes:request.omittedNodes,decision}));
    if(decision.kind==='cannotProceed')return blocked(decision.reason,decision.reason==='modelUnavailable'?'MODEL_UNAVAILABLE':'TEST_SETUP_FAILED');
    if(decision.kind==='finish' && !inputsComplete())return blocked('Required approved input activity is incomplete','TEST_SETUP_FAILED');
    if(decision.kind==='finish'){
     const endpoint=await ctx.observe({tree:true});const afterFinish=terminalStatus();if(afterFinish)return afterFinish;
     return positiveEndpoint(endpoint,goal)?{status:'passed',summary:'Declared navigation endpoint independently observed'}:blocked('Controller finish was not confirmed','AUTOMATION_UNSUPPORTED');
    }
    if(!verbs.includes(decision.kind))return blocked('Controller selected an unsupported verb','POLICY_DENIED');
    if(decision.kind==='scroll' && decision.node!==undefined)return blocked('Only viewport scrolling is qualified','POLICY_DENIED');
    const pair=JSON.stringify([request.nodes,decision]);const repetitions=(seen.get(pair)??0)+1;seen.set(pair,repetitions);
    if(repetitions>=2)return blocked('navigationStalled','TEST_SETUP_FAILED');
    if('node' in decision && decision.node!==undefined){const node=request.nodes.find(n=>n.id===decision.node);
     if(!node || node.disabled || (decision.kind!=='scroll' && !node.visible))return blocked('Controller selected a stale or inaccessible node','POLICY_DENIED');
     if(decision.kind==='fill' && ((node.editable!==true && node.fillSupported!==true) || node.editable===false || node.secure || !Object.hasOwn(bindings,decision.textBinding) || (goal.allowedFillBindings!==undefined && !goal.allowedFillBindings.includes(decision.textBinding))))return blocked('Unapproved input binding or sink','POLICY_DENIED');}
    // Grammar actions account and serialize themselves; nesting runTool would deadlock their queue.
    switch(decision.kind){
     case 'tap':{
      const node=request.nodes.find(n=>n.id===decision.node)!;
      const save=goal.saveControl!==undefined && node.role==='button' && !node.secure &&
       (goal.saveControl.kind==='testId'?node.testId===goal.saveControl.value:(node.name?.length??512)<512 && node.name===goal.saveControl.value);
      if(save && saveTapped)return blocked('Save control was already used','POLICY_DENIED');
      await ctx.actions.tap({id:decision.node});if(save)saveTapped=true;break;
     }
     case 'fill':await ctx.actions.type({id:decision.node},bindings[decision.textBinding]!);bindingUses[decision.textBinding]=(bindingUses[decision.textBinding]??0)+1;break;
     case 'scroll':await ctx.actions.scroll(decision.direction);break;
     default:return blocked('Unsupported native verb','POLICY_DENIED');
    }
   }
  }finally{ctx.attachTranscript(transcript.join('\n').slice(0,65536));}
 }};
}
