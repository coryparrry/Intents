import {ownRecord} from './ownRecord.js';
import {z} from 'zod';import {identifier,scopeSchema,digest} from './protocol.js';
import {goalSchema} from './controllerProtocol.js';
export const locatorSchema=z.strictObject({kind:z.enum(['testId','label','role']),value:z.string().min(1).max(1024),role:z.literal('button').optional()});
export const operationSchema=z.discriminatedUnion('kind',[
 z.strictObject({kind:z.literal('tap'),id:identifier,locator:locatorSchema}),
 z.strictObject({kind:z.literal('fillBinding'),id:identifier,locator:locatorSchema,binding:identifier}),
 z.strictObject({kind:z.literal('observeProperty'),id:identifier,locator:locatorSchema,property:z.enum(['text','value','checked','selected'])}),
 z.strictObject({kind:z.literal('readProperty'),id:identifier,locator:locatorSchema,property:z.enum(['text','value'])}),
 z.strictObject({kind:z.literal('assertEndpoint'),id:identifier,locator:locatorSchema}),
 z.strictObject({kind:z.literal('locate'),id:identifier,locator:locatorSchema}),
 z.strictObject({kind:z.literal('scroll'),id:identifier,direction:z.enum(['up','down','left','right'])}),
 z.strictObject({kind:z.literal('navigateGoal'),id:identifier,goal:goalSchema})
]);
export const segmentSchema=z.strictObject({scope:scopeSchema,operationId:identifier,payloadDigest:digest,digestVersion:z.literal(2).optional(),
 phase:z.enum(['setup','subject','observe','cleanup']),operations:z.array(operationSchema).min(1).max(30),
 bindings:ownRecord(z.string().max(32768)),timeoutMs:z.number().int().min(100).max(120000)}).superRefine((v,c)=>{
 if(new Set(v.operations.map(o=>o.id)).size!==v.operations.length)c.addIssue({code:'custom',message:'Duplicate operation IDs'});
 for(const operation of v.operations){if(operation.kind==='fillBinding' && !Object.hasOwn(v.bindings,operation.binding))c.addIssue({code:'custom',message:'Missing frozen fill binding'});}
 for(const operation of v.operations)if('locator' in operation && operation.locator.kind==='role' && (operation.kind!=='fillBinding' || !['textbox','searchbox'].includes(operation.locator.value)))c.addIssue({code:'custom',message:'Role locators support only ordinary textbox or searchbox fill'});
 for(const operation of v.operations)if('locator' in operation && operation.locator.role!==undefined && (operation.kind!=='tap' || operation.locator.kind!=='label'))c.addIssue({code:'custom',message:'A button role can only qualify an exact tap label'});
 if(v.phase==='observe' && v.operations.some(o=>o.kind==='fillBinding'))c.addIssue({code:'custom',message:'Observation cannot fill inputs'});
 for(const o of v.operations)if(o.kind==='navigateGoal' && [...(o.goal.allowedFillBindings??[]),...(o.goal.selectionBindings??[]),...Object.keys(o.goal.minimumBindingUses??{})].some(k=>!Object.hasOwn(v.bindings,k)))c.addIssue({code:'custom',message:'Declared goal binding has no supplied value'});
 for(const o of v.operations)if(o.kind==='navigateGoal' && (v.operations.length!==1 || o.goal.id!==o.id || (v.phase==='observe' && Object.keys(v.bindings).length)))c.addIssue({code:'custom',message:'Ambiguous goal or observer inputs'});
});
export type Segment=z.infer<typeof segmentSchema>;
