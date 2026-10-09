import {segmentPayloadDigest} from './payloadDigest.js';
import {readFile,writeFile,mkdir} from 'node:fs/promises';import {join,isAbsolute} from 'node:path';import {z} from 'zod';
import {targetSchema,scopeSchema} from './protocol.js';import {segmentSchema} from './segment.js';
import {DeviceSession} from './deviceSession.js';import {runWorker} from './workerRunner.js';
const profileSchema=z.strictObject({schemaVersion:z.literal(1),target:targetSchema,scope:scopeSchema,
 stateDirectory:z.string().refine(isAbsolute),evidenceDirectory:z.string().refine(isAbsolute),
 segment:segmentSchema.omit({payloadDigest:true}).optional(),approvedEffects:z.array(z.enum(['activate','tap','fill','swipe']))});
if(process.argv.length!==4 || process.argv[2]!=='--profile')throw new Error('Explicit authorised qualification profile required');
const profile=profileSchema.parse(JSON.parse(await readFile(process.argv[3]!,'utf8')));
if(!profile.approvedEffects.includes('activate'))throw new Error('Activation is not approved');
await mkdir(profile.evidenceDirectory,{recursive:true,mode:0o700});
const session=await DeviceSession.create(profile.stateDirectory,profile.target,profile.scope,async(_scope,action)=>{
 if(!profile.approvedEffects.includes(action.kind as 'tap'|'fill'|'swipe'))throw new Error('Qualification action is not approved');
});
let released=false;
try{
 if(profile.segment){if(JSON.stringify(profile.segment.scope)!==JSON.stringify(profile.scope))throw new Error('Profile scope mismatch');
  await runWorker(session,profile.target,{...profile.segment,payloadDigest:segmentPayloadDigest(profile.segment)},join(profile.evidenceDirectory,'worker'),new AbortController().signal);}
 const snapshot=await session.snapshot();await writeFile(join(profile.evidenceDirectory,'snapshot.json'),JSON.stringify(snapshot,null,2),{mode:0o600});
 await writeFile(join(profile.evidenceDirectory,'selection.json'),JSON.stringify(session.selectionEvidence,null,2),{mode:0o600});
 console.log(JSON.stringify({targetID:profile.target.id,appBundleID:snapshot.appBundleId,nodes:snapshot.nodes.map(n=>({kind:n.kind,label:n.label,identifier:n.identifier})).slice(0,80)}));
}finally{
 const result=await session.release();released=result.released;await writeFile(join(profile.evidenceDirectory,'release.json'),JSON.stringify(result,null,2),{mode:0o600});
 console.log(JSON.stringify(result));if(!released)process.exitCode=1;
}
