import {z} from 'zod';
import {identifier} from './protocol.js';

/** Protocol IDs are own dictionary keys, including Object prototype names. */
export function ownRecord<Value>(schema:z.ZodType<Value>,maximumEntries=30){
 return z.unknown().transform((value,ctx):Record<string,Value>|typeof z.NEVER=>{
  if(value===null || typeof value!=='object' || ![Object.prototype,null].includes(Object.getPrototypeOf(value))){
   ctx.addIssue({code:'custom',message:'Expected an own-entry protocol dictionary'});return z.NEVER;
  }
  const entries=Object.entries(value),result:Record<string,Value>=Object.create(null);
  if(entries.length>maximumEntries){ctx.addIssue({code:'custom',message:'Protocol dictionary exceeds its bounds'});return z.NEVER;}
  for(const [key,item] of entries){
   const parsed=schema.safeParse(item);
   if(!identifier.safeParse(key).success || !parsed.success){ctx.addIssue({code:'custom',message:'Invalid protocol dictionary entry'});return z.NEVER;}
   result[key]=parsed.data;
  }
  return result;
 });
}
