import {createInterface} from 'node:readline';
process.stderr.write('SYNTHETIC-SECRET-WORKER-DIAGNOSTIC\n');
const lines=createInterface({input:process.stdin});
lines.on('line',line=>{const message=JSON.parse(line);process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:message.id,result:{ready:true}})+'\n');});
