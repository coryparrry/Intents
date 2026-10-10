import { defineEngine, ENGINE_SPI_VERSION, EngineError, resolveExpression, type NodeRef, type LocatorAction,
 type EngineHandle, type EngineSnapshot, type OperationContext } from 'e2e/engine';
import { fingerprint, semanticTree, structurallyIncomplete, positivelyVisible, supportsFill, secureAncestry, type RefEntry } from './semanticTree.js';
import type { UIBackend } from '../deviceSession.js';
export function intentsUIEngine(backend:UIBackend,platform:'ios'|'macos',bundleId:string,allowVisibleNavigation=false,controllerAction?:{node:()=>string|undefined;consume:()=>void},actions:('tap'|'fill'|'swipe')[]=['tap','fill','swipe']):EngineHandle {
 let revision=0;let refs=new Map<string,RefEntry>();
 async function observe(context:OperationContext):Promise<EngineSnapshot>{
  const deadline=Date.now()+context.timeoutMs;
  if(context.signal.aborted)throw new EngineError('CANCELLED','Observation cancelled',{retryable:false});
  const result=semanticTree(await backend.snapshot(context),++revision,platform,controllerAction!==undefined);
  if(context.signal.aborted || Date.now()>=deadline)throw new EngineError('OPERATION_TIMEOUT','Observation ended',{retryable:false});refs=result.refs;return result.snapshot;}
 async function perform(ref:NodeRef,action:LocatorAction,context:OperationContext):Promise<void>{
  if(!actions.includes(action.kind as 'tap'|'fill'|'swipe'))throw new EngineError('UNSUPPORTED_CAPABILITY','Action is outside this owned backend capability set',{retryable:false});
  // Generic e2e relocation must never substitute a controller-approved target.
  if(controllerAction && ref.id!==controllerAction.node())throw new EngineError('ENGINE_FAILURE','Controller target changed before dispatch',{retryable:false});
  const deadline=Date.now()+context.timeoutMs;
  const check=()=>{if(context.signal.aborted)throw new EngineError('CANCELLED','Operation cancelled',{retryable:false});
   if(Date.now()>=deadline)throw new EngineError('OPERATION_TIMEOUT','Action deadline expired',{retryable:false});};check();
  if(action.kind==='swipe'){
   if(ref.id!=='root' || (action.momentum!==undefined && action.momentum!=='slow'))throw new EngineError('UNSUPPORTED_CAPABILITY','Only the qualified viewport scroll is supported',{retryable:false});
   action={kind:'swipe',direction:action.direction};
  }
  if(ref.id==='root' && action.kind==='swipe'){await backend.snapshot(context);check();controllerAction?.consume();await backend.perform('root',action,{...context,timeoutMs:Math.max(1,deadline-Date.now())},ref.id);return;}
  const previous=refs.get(ref.id);if(!previous) throw new EngineError('NODE_STALE','Node disappeared',{retryable:true});
  const fresh=await backend.snapshot(context);
  const partial=semanticTree(fresh,revision,platform,controllerAction!==undefined).snapshot.truncated;
  if(structurallyIncomplete(fresh))throw new EngineError('ENGINE_FAILURE','Fresh capture is incomplete',{retryable:false});
  const matches=fresh.nodes.filter(n=>fingerprint(n)===previous.fingerprint);
  if(matches.length!==1) throw new EngineError('NODE_STALE','Node changed or became ambiguous',{retryable:true});
  if(action.kind==='fill'){
   if(!supportsFill(matches[0]!,platform))throw new EngineError('UNSUPPORTED_CAPABILITY','Fresh node has no qualified text-entry action',{retryable:false});
   // A caller's sensitivity flag cannot downgrade the actual fresh field.
   const nodes=new Map(fresh.nodes.map(node=>[node.index,node]));
   const secure=action.sensitive===true || secureAncestry(matches[0]!,nodes);
   if(secure)throw new EngineError('UNSUPPORTED_CAPABILITY','Secret filling is not qualified',{retryable:false});
  }
  if(partial && (!allowVisibleNavigation || !positivelyVisible(matches[0]!)))throw new EngineError('ENGINE_FAILURE','Partial capture cannot establish a visible action target',{retryable:false});
  if(controllerAction && !positivelyVisible(matches[0]!))throw new EngineError('ENGINE_FAILURE','Controller target is no longer accessible',{retryable:false});
  check();
  if(fresh.refsGeneration===undefined)throw new EngineError('ENGINE_FAILURE','Snapshot epoch missing',{retryable:false});
  controllerAction?.consume();
  await backend.perform(`@${matches[0]!.ref.split('~s')[0]!.replace(/^@/,'')}~s${fresh.refsGeneration}`,action,{...context,timeoutMs:Math.max(1,deadline-Date.now())},ref.id);
 }
 return defineEngine({name:'IntentsUIEngine',version:'0.1.0',spiVersion:ENGINE_SPI_VERSION,platform,workers:1,
  actions,observe,perform,
  async locate(expression,context){
   const deadline=Date.now()+context.timeoutMs;
   if(context.signal.aborted)throw new EngineError('CANCELLED','Observation cancelled',{retryable:false});
   const raw=await backend.snapshot(context);const result=semanticTree(raw,++revision,platform,controllerAction!==undefined);refs=result.refs;
   if(context.signal.aborted)throw new EngineError('CANCELLED','Observation cancelled',{retryable:false});
   if(Date.now()>=deadline)throw new EngineError('OPERATION_TIMEOUT','Observation ended',{retryable:false});
   if(structurallyIncomplete(raw) || result.snapshot.treeUnavailable)throw new EngineError('ENGINE_FAILURE','Incomplete accessibility tree',{retryable:false});
   const matches=resolveExpression(expression,[result.snapshot.root]);
   if(result.snapshot.truncated){
    const exact=allowVisibleNavigation && expression.kind==='query' && !expression.scope && expression.query.visible===true && ['testId','label'].includes(expression.query.kind) &&
     expression.query.value.kind==='string' && expression.query.value.exact;
    if(!exact || matches.length===0 || matches.some(node=>!raw.nodes.some(n=>fingerprint(n)===refs.get(node.ref.id)?.fingerprint && positivelyVisible(n))))
     throw new EngineError('ENGINE_FAILURE','Partial tree cannot prove absence, cardinality, or an unobserved target',{retryable:false});
   }
   return matches;},
  validateApp(app){if(app.bundleId!==bundleId) throw new Error('Worker app identity mismatch');},
  async init(){},async endAttempt(){},async dispose(){} });
}
