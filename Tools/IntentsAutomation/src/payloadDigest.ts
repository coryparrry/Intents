import {createHash} from 'node:crypto';
/** Historical v1 JSON.stringify object ordering. Keep frozen payload hashes unchanged. */
export function payloadDigest(input:object):string {
 const canonical=(v:unknown):unknown=>Array.isArray(v)?v.map(canonical):v && typeof v==='object'?
 Object.fromEntries(Object.entries(v).sort(([a],[b])=>a<b?-1:a>b?1:0).map(([k,x])=>[k,canonical(x)])):v;
 return createHash('sha256').update(JSON.stringify(canonical(input))).digest('hex');
}
/** Matches Swift AutomationCanonicalJSON directly, including numeric object keys.
 * Keep the public program digest above unchanged for existing frozen programs. */
export function nativePayloadDigest(input:object):string {
 const encode=(value:unknown):string=>{
  if(Array.isArray(value))return '['+value.map(encode).join(',')+']';
  if(value!==null && typeof value==='object')return '{'+Object.entries(value).sort(([a],[b])=>a<b?-1:a>b?1:0)
   .map(([key,item])=>JSON.stringify(key)+':'+encode(item)).join(',')+'}';
  const result=JSON.stringify(value);if(result===undefined || (typeof value==='number' && !Number.isSafeInteger(value)))throw new Error('Invalid canonical protocol value');
  return result;
 };
 return createHash('sha256').update(encode(input)).digest('hex');
}

/** Public envelope version is part of its digest and cannot select a fallback hash. */
export function segmentPayloadDigest(input:object):string {
 const version=(input as {digestVersion?:unknown}).digestVersion;
 if(version===undefined)return payloadDigest(input);
 if(version===2)return nativePayloadDigest(input);
 throw new Error('Unsupported segment digest version');
}
