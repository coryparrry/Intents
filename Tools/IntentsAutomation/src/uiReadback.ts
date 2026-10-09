import {z} from 'zod';
import type {CaptureSnapshotResult} from 'agent-device';
import type {Target} from './protocol.js';
import type {Segment} from './segment.js';
import {semanticTree} from './e2e/semanticTree.js';
const nodeSchema=z.strictObject({index:z.number().int().nonnegative(),parentIndex:z.number().int().nonnegative().optional(),
 identifier:z.string().max(1024).optional(),label:z.string().max(32768).optional(),value:z.string().max(32768).optional(),
 ownerBundle:z.string().max(256).optional(),blocked:z.boolean(),hidden:z.boolean(),visible:z.boolean(),disabled:z.boolean(),secure:z.boolean(),checked:z.boolean().optional(),selected:z.boolean().optional()});
export const readbackSchema=z.strictObject({schemaVersion:z.literal(1),appBundleId:z.string().min(1).max(256),targetId:z.string().min(1).max(256),
 complete:z.literal(true),nodes:z.array(nodeSchema).min(1).max(5000)});
export type UIReadback=z.infer<typeof readbackSchema>;
export function captureReadback(raw:CaptureSnapshotResult,target:Target):UIReadback {
 const capture=semanticTree(raw,1).snapshot;
 if(capture.truncated || capture.treeUnavailable || raw.appBundleId!==target.bundleId)throw new Error('Complete app-bound readback unavailable');
 const parents=new Map(raw.nodes.map(n=>[n.index,n]));
 const secure=(index:number)=>{let node=parents.get(index);const visited=new Set<number>();
  while(node){if(visited.has(node.index))throw new Error('Invalid ancestry');visited.add(node.index);if(node.password)return true;node=node.parentIndex===undefined?undefined:parents.get(node.parentIndex);}return false;};
 return readbackSchema.parse({schemaVersion:1,appBundleId:raw.appBundleId,targetId:target.id,complete:true,nodes:raw.nodes.map(n=>({index:n.index,
  ...(n.parentIndex!==undefined?{parentIndex:n.parentIndex}:{}),...(n.identifier!==undefined?{identifier:n.identifier}:{}),
  ...(n.label!==undefined && !secure(n.index)?{label:n.label}:{}),...(n.value!==undefined && !secure(n.index)?{value:n.value}:{}),
  ...(n.bundleId!==undefined?{ownerBundle:n.bundleId}:{}),blocked:n.interactionBlocked==='covered',hidden:n.visibleToUser===false,visible:n.hittable===true && n.enabled!==false && n.visibleToUser!==false && n.interactionBlocked!=='covered',disabled:n.enabled===false,secure:secure(n.index),
  ...(n.checked!==undefined?{checked:n.checked}:{}),...(n.selected!==undefined?{selected:n.selected}:{})}))});
}
export function verifyReadback(proof:UIReadback,operation:Extract<Segment['operations'][number],{kind:'observeProperty'}>):string|boolean {
 if(operation.locator.role!==undefined || operation.locator.kind==='role')throw new Error('Role-qualified property readback is not supported');
 const p=readbackSchema.parse(proof);const ids=new Set(p.nodes.map(n=>n.index));
 if(ids.size!==p.nodes.length || p.nodes.some(n=>n.parentIndex!==undefined && !ids.has(n.parentIndex)))throw new Error('Incomplete or duplicate readback ancestry');
 for(const n of p.nodes){let cursor:typeof n|undefined=n;const seen=new Set<number>();
  while(cursor){if(seen.has(cursor.index) || seen.size>32)throw new Error('Invalid readback ancestry');seen.add(cursor.index);cursor=p.nodes.find(n=>n.index===cursor!.parentIndex);}}
 const matches=p.nodes.filter(n=>operation.locator.kind==='testId'?n.identifier===operation.locator.value:n.label===operation.locator.value);
 if(matches.length!==1 || !matches[0]!.visible || matches[0]!.disabled || matches[0]!.secure)throw new Error('Readback requires a unique visible nonsecure node');
 const node=matches[0]!;let ancestor:typeof node|undefined=node;
 while(ancestor){if(ancestor.blocked || ancestor.hidden || ancestor.disabled || ancestor.secure || (ancestor.ownerBundle && ancestor.ownerBundle!==p.appBundleId))throw new Error('Readback node ancestry or app owner conflicts');ancestor=ancestor.parentIndex===undefined?undefined:p.nodes.find(n=>n.index===ancestor!.parentIndex);}
 const value=operation.property==='text'?node.label:node[operation.property];
 if(value===undefined)throw new Error('Readback property was not observed');
 return value;
}
