/** Public approved literals only; opaque credentials never use this codec. */
export function validateMacOrdinaryFillValue(value:unknown):asserts value is string {
  if(typeof value!=='string' || value.length>16384 || value.includes('\0') ||
    Buffer.byteLength(value,'utf8')>65536 || Buffer.from(value,'utf8').toString('utf8')!==value)
    throw new Error('Invalid ordinary Mac literal');
}
export function validateMacOrdinaryFillPoint(value:Readonly<{x:number;y:number}>):void {
  if(![value.x,value.y].every(point=>Number.isFinite(point) && Math.abs(point)<=1_000_000))
    throw new Error('Invalid ordinary Mac point');
}
