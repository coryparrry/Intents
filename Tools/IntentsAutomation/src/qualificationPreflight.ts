import {readFile} from 'node:fs/promises';
import {z} from 'zod';
import {identifier,targetSchema} from './protocol.js';
import {segmentSchema} from './segment.js';

/** Pure admission check: no SDK client or device is created by this module. */
export function preflight(input:unknown):void {
 const request=z.object({runID:identifier,attemptID:identifier,target:targetSchema,
  setup:z.strictObject({operations:z.array(z.unknown()).min(1).max(30),bindings:z.record(identifier,z.string().max(32768)),
   approvedEffects:z.array(z.enum(['activate','tap','fill','swipe'])).min(1).max(4)})}).parse(input);
 const segment=segmentSchema.parse({scope:{protocolVersion:1,runId:request.runID,attemptId:request.attemptID,segmentId:'setup',leaseGeneration:1},
  operationId:'setup',payloadDigest:'0'.repeat(64),phase:'setup',timeoutMs:60000,operations:request.setup.operations,bindings:request.setup.bindings});
 for(const operation of segment.operations){
  const effect=operation.kind==='fillBinding'?'fill':operation.kind==='scroll'?'swipe':operation.kind==='tap'?'tap':undefined;
  if(effect && !request.setup.approvedEffects.includes(effect))throw new Error('UI operation lacks frozen authority');
  if(operation.kind==='fillBinding' && !Object.hasOwn(segment.bindings,operation.binding))throw new Error('Missing frozen fill binding');
 }
}
if(['--profile','--stdin'].includes(process.argv[2]??'') && process.versions.node!=='24.21.0')throw new Error('Pinned private runtime required');
if(process.argv[2]==='--profile'){
 if(process.argv.length!==4)throw new Error('Exact preflight profile required');
 const data=await readFile(process.argv[3]!);if(data.length>65536)throw new Error('Profile budget exceeded');
 preflight(JSON.parse(data.toString('utf8')));
}

if(process.argv[2]==='--stdin'){
 if(process.argv.length!==3)throw new Error('Exact preflight input required');
 const chunks:Buffer[]=[];let bytes=0;
 for await(const chunk of process.stdin){bytes+=chunk.length;if(bytes>65536)throw new Error('Profile budget exceeded');chunks.push(chunk);}
 preflight(JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(Buffer.concat(chunks))));
}
