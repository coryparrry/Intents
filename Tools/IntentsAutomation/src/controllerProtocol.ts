import {z} from 'zod';
import {identifier} from './protocol.js';

// Treat binding identifiers as dictionary keys, including Object prototype names.
const minimumBindingUsesSchema=z.unknown().transform((value,ctx):Record<string,number>|typeof z.NEVER=>{
 if(value===null || typeof value!=='object' || ![Object.prototype,null].includes(Object.getPrototypeOf(value))){
  ctx.addIssue({code:'custom',message:'Expected a binding count dictionary'});return z.NEVER;
 }
 const entries=Object.entries(value);const result:Record<string,number>=Object.create(null);
 if(entries.length===0 || entries.length>30){ctx.addIssue({code:'custom',message:'Binding count dictionary is outside its bounds'});return z.NEVER;}
 for(const [key,count] of entries){
  if(!identifier.safeParse(key).success || typeof count!=='number' || !Number.isInteger(count) || count<1 || count>30){
   ctx.addIssue({code:'custom',message:'Invalid binding count',path:[key]});return z.NEVER;
  }
  result[key]=count;
 }
 return result;
});
export const goalSchema=z.strictObject({id:identifier,instruction:z.string().min(1).max(4096),endpoint:z.strictObject({kind:z.enum(['testId','label']),value:z.string().min(1).max(1024)}),
 maximumCalls:z.number().int().min(1).max(12),maximumActions:z.number().int().min(1).max(30),minimumBindingUses:minimumBindingUsesSchema.optional(),allowedFillBindings:z.array(identifier).max(30).optional(),selectionBindings:z.array(identifier).min(1).max(30).optional(),
 saveControl:z.strictObject({kind:z.enum(['testId','label']),value:z.string().min(1).max(1024)})
  .refine(c=>c.kind!=='label' || c.value.length<512).optional()})
 .refine(g=>g.minimumBindingUses===undefined || (Object.keys(g.minimumBindingUses).length>0 && Object.keys(g.minimumBindingUses).length<=30 && Object.values(g.minimumBindingUses).reduce((a,b)=>a+b,0)<=g.maximumActions))
 .refine(g=>g.allowedFillBindings===undefined || (new Set(g.allowedFillBindings).size===g.allowedFillBindings.length && Object.keys(g.minimumBindingUses??{}).every(k=>g.allowedFillBindings!.includes(k))))
 .refine(g=>g.selectionBindings===undefined || (g.allowedFillBindings!==undefined && new Set(g.selectionBindings).size===g.selectionBindings.length && g.selectionBindings.every(k=>!g.allowedFillBindings!.includes(k))));
export type NavigationGoal=z.infer<typeof goalSchema>;
export const decisionSchema=z.discriminatedUnion('kind',[
 z.strictObject({kind:z.literal('tap'),node:identifier}),
 z.strictObject({kind:z.literal('fill'),node:identifier,textBinding:identifier}),
 z.strictObject({kind:z.literal('scroll'),node:identifier.optional(),direction:z.enum(['up','down','left','right'])}),
 z.strictObject({kind:z.literal('pressKey'),key:z.string().min(1).max(64)}),
 z.strictObject({kind:z.literal('back')}),z.strictObject({kind:z.literal('finish')}),
 z.strictObject({kind:z.literal('cannotProceed'),reason:z.enum(['modelUnavailable','unsupportedObservation','navigationStalled','budgetExhausted','noSafeAction'])})]);
export type ControllerDecision=z.infer<typeof decisionSchema>;
export const controllerNodeSchema=z.strictObject({id:identifier,role:z.string().max(128).optional(),name:z.string().max(512).optional(),testId:z.string().min(1).max(1024).optional(),selected:z.boolean().optional(),
 text:z.string().max(512).optional(),value:z.string().max(1024).optional(),editable:z.boolean().optional(),fillSupported:z.boolean().optional(),visible:z.boolean(),disabled:z.boolean(),secure:z.boolean()}).refine(n=>!n.secure || (n.text===undefined && n.value===undefined),{message:"Secure node text and value must be redacted"});
export const controllerRequestSchema=z.strictObject({goalId:identifier,revision:z.string().min(1).max(256),
 nodes:z.array(controllerNodeSchema).max(200),truncated:z.boolean(),omittedNodes:z.number().int().min(0).max(5000),
 verbs:z.array(z.enum(['tap','fill','scroll','pressKey','back'])).max(5),recentActions:z.array(z.string().max(512)).max(4),
 remainingActions:z.number().int().min(0).max(30),remainingMs:z.number().int().min(1).max(120000),approvedSaveTap:z.boolean().optional()});
export type ControllerRequest=z.infer<typeof controllerRequestSchema>;
