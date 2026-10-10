import { createHash } from 'node:crypto';
import type { CaptureSnapshotResult, SnapshotNode } from 'agent-device';
import { EngineError, type SemanticNode, type EngineSnapshot } from 'e2e/engine';
export type RefEntry={backendRef:string;fingerprint:string};
// A scroll-hidden subtree is incomplete evidence, but does not make an already
// captured, positively hittable control unavailable for bounded navigation.
export function structurallyIncomplete(snapshot:CaptureSnapshotResult):boolean {
 const indices=new Set(snapshot.nodes.map(n=>n.index));
 return snapshot.truncated===true || snapshot.nodes.some(n=>n.parentIndex!==undefined && !indices.has(n.parentIndex));
}
export function positivelyVisible(node:SnapshotNode):boolean {
 return node.hittable===true && node.enabled!==false && node.visibleToUser!==false &&
  !node.hiddenContentAbove && !node.hiddenContentBelow && node.interactionBlocked!=='covered';
}
/** Supported text-entry action, distinct from an optional native editable fact.
 * The exact iOS whitelist is narrower than the pinned SDK is(editable) predicate.
 */
export function supportsFill(node:SnapshotNode,platform?:string):boolean {
 if(node.editable===false || node.password===true || node.userInteractionEnabled===false ||
    [node.kind,node.role,node.type,node.subrole].some(v=>/secure|password/i.test(v??'')) || !positivelyVisible(node))return false;
 if(node.editable===true)return true;
 const kinds:Record<string,string>= {TextField:'text-field',TextView:'text-view',SearchField:'search-field'};
 return platform==='ios' && node.enabled===true && kinds[node.type??'']!==undefined && (node.kind??node.role)===kinds[node.type!];
}
export function secureAncestry(node:SnapshotNode,nodes:ReadonlyMap<number,SnapshotNode>):boolean {
 const seen=new Set<number>();let current:SnapshotNode|undefined=node;
 while(current){
  if(seen.has(current.index) || seen.size>=32)return true;seen.add(current.index);
  if(current.password===true || [current.kind,current.role,current.type,current.subrole].some(v=>/secure|password/i.test(v??'')))return true;
  if(current.parentIndex===undefined)return false;
  current=nodes.get(current.parentIndex);if(!current)return true;
 }
 return true;
}
function semanticRole(node:SnapshotNode,platform?:string):string|undefined {
 if(platform==='macos'){
  const role=node.role??node.kind??node.type;
  if(role==='AXTextField' && node.subrole==='AXSearchField')return 'searchbox';
  if(['AXTextField','AXTextArea'].includes(role??''))return 'textbox';
 }
 return node.kind??node.role??node.type;
}
export function fingerprint(n:SnapshotNode):string {
 return JSON.stringify([n.bundleId,n.windowTitle,n.kind??n.role??n.type,n.identifier,n.label,n.parentIndex,n.password?'[redacted]':n.value,n.rect]);
}
export function semanticTree(snapshot:CaptureSnapshotResult,revision:number,platform?:string,stableIdentifiedRefs=false):{snapshot:EngineSnapshot;refs:Map<string,RefEntry>}{
 if(snapshot.nodes.length>5000)throw new EngineError('ENGINE_FAILURE','Snapshot node budget exceeded',{retryable:false});
 const parents=new Map(snapshot.nodes.map(n=>[n.index,n.parentIndex]));
 const observedNodes=new Map(snapshot.nodes.map(n=>[n.index,n]));
 for(const node of snapshot.nodes){let id:number|undefined=node.index;const seen=new Set<number>();
  while(id!==undefined){if(seen.has(id) || seen.size>32)throw new EngineError('ENGINE_FAILURE','Malformed snapshot ancestry',{retryable:false});
   seen.add(id);id=parents.get(id);}}
 // Stable controller identity is available only for an exact identifier unique
 // in this complete capture. Mutable value/geometry remain in the dispatch
 // fingerprint; anonymous or duplicate identifiers retain observation refs.
 const identifiedKey=(n:SnapshotNode)=>n.identifier?JSON.stringify([n.bundleId??snapshot.appBundleId,n.windowTitle,n.kind??n.role??n.type,n.identifier,secureAncestry(n,observedNodes)]):undefined;
 const identifierCounts=new Map<string,number>();
 for(const n of snapshot.nodes){if(n.identifier)identifierCounts.set(n.identifier,(identifierCounts.get(n.identifier)??0)+1);}
 const identityComplete=!structurallyIncomplete(snapshot) && snapshot.truncated===false && snapshot.visibility?.partial!==true && !snapshot.nodes.some(n=>n.hiddenContentAbove || n.hiddenContentBelow);
 const refs=new Map<string,RefEntry>();const byIndex=new Map<number,SemanticNode & {children:SemanticNode[]}>();
 for(const n of snapshot.nodes){
  const secure=secureAncestry(n,observedNodes);
  // Indices distinguish repeated containers only in this observation. perform
  // still requires a unique fingerprint in a new capture before any mutation.
  const identified=identifiedKey(n);const identity=stableIdentifiedRefs && identityComplete && identified && identifierCounts.get(n.identifier!)===1?['identified',identified]:[fingerprint(n),n.index];
  const id=`node-${createHash('sha256').update(JSON.stringify(identity)).digest('hex')}`;if(byIndex.has(n.index)) throw new EngineError('ENGINE_FAILURE','Duplicate snapshot index',{retryable:false});
  const node:SemanticNode & {children:SemanticNode[]}={ref:{id,revision:String(revision)},children:[],
   ...(semanticRole(n,platform)?{role:semanticRole(n,platform)!}:{}),...(n.label?{name:n.label}:{}),
   ...(n.value!==undefined && !secure?{value:n.value}:{}),...(n.identifier?{testId:n.identifier}:{}),
   ...(n.rect?{rect:n.rect}:{}),attributes:{ownerBundle:n.bundleId??'',window:n.windowTitle??'',...(n.editable!==undefined?{editable:String(n.editable)}:{}),fillSupported:String(!secure && supportsFill(n,platform)),
    hittable:String(positivelyVisible(n)),testId:n.identifier??''},
   states:{...(n.enabled!==undefined?{disabled:!n.enabled}:{}),...(n.selected!==undefined?{selected:n.selected}:{}),
    ...(n.visibleToUser!==undefined?{hidden:!n.visibleToUser}:{}),...(n.checked!==undefined?{checked:n.checked}:{}),
    ...(n.focused!==undefined?{focused:n.focused}:{}),secure}};
  byIndex.set(n.index,node);refs.set(id,{backendRef:n.ref,fingerprint:fingerprint(n)});
 }
 const children:SemanticNode[]=[];
 for(const n of snapshot.nodes){const node=byIndex.get(n.index)!;const parent=n.parentIndex===undefined?undefined:byIndex.get(n.parentIndex);
  if(parent && parent!==node) parent.children.push(node);else children.push(node);
 }
 const bounds=snapshot.nodes.map(n=>n.rect).filter(n=>n!==undefined);
 const width=Math.max(0,...bounds.map(r=>r.x+r.width));const height=Math.max(0,...bounds.map(r=>r.y+r.height));
 return {refs,snapshot:{root:{ref:{id:'root',revision:String(revision)},role:'root',children},viewport:{width,height},
  truncated:snapshot.truncated!==false || snapshot.visibility?.partial===true || snapshot.nodes.some(n=>n.hiddenContentAbove || n.hiddenContentBelow || (n.parentIndex!==undefined && !byIndex.has(n.parentIndex))), ...(snapshot.nodes.length===0?{treeUnavailable:true as const}:{})}};
}
