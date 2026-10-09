import {execFile} from 'node:child_process';import {promisify} from 'node:util';import {createRequire} from 'node:module';
import {dirname,resolve,join} from 'node:path';import {fileURLToPath} from 'node:url';import {readFile} from 'node:fs/promises';import {z} from 'zod';
const run=promisify(execFile),require=createRequire(import.meta.url);
const reportSchema=z.object({success:z.literal(true),data:z.object({cleanupConfidence:z.literal('known'),
 claimsOrphaned:z.array(z.unknown()).length(0),claimsUnattributable:z.array(z.unknown()).length(0),warnings:z.array(z.unknown()).length(0),
 providerReleases:z.object({status:z.literal('completed'),pending:z.array(z.unknown()).length(0)})})});
export async function stopPrivateDaemon(stateDir:string):Promise<{released:boolean;reason:string}>{
 const packageRoot=resolve(dirname(fileURLToPath(import.meta.resolve('agent-device'))),'../..');
 const manifest=JSON.parse(await readFile(join(packageRoot,'package.json'),'utf8'));
 if(manifest.version!=='0.21.20' || manifest.bin?.['agent-device']!=='bin/agent-device.mjs')throw new Error('Unqualified agent-device package');
 const env:NodeJS.ProcessEnv={PATH:'/usr/bin:/bin:/usr/sbin:/sbin',HOME:stateDir,TMPDIR:stateDir,
  AGENT_DEVICE_NO_UPDATE_NOTIFIER:'1',AGENT_DEVICE_STATE_DIR:stateDir};
 const result=await run(process.execPath,[join(packageRoot,manifest.bin['agent-device']),'daemon','stop','--state-dir',stateDir,'--clean','--json'],
  {cwd:stateDir,env,shell:false,timeout:30000,maxBuffer:1024*1024});
 try{reportSchema.parse(JSON.parse(result.stdout));return {released:true,reason:'Scoped daemon stop reports known release with no orphaned or unattributable claims'};}
 catch{return {released:false,reason:'Owned runner termination could not be proved by scoped daemon cleanup'};}
}
