import {createRequire,syncBuiltinESMExports} from 'node:module';

/** Test guard: allow only SDK reads of its own process identity and CPU architecture. */
export function guardSyntheticDaemonHost(ownedWorker?:{gate:string;entry:string;root:string}){
  const childProcess=createRequire(import.meta.url)('node:child_process');
  const hostCalls:string[]=[],metadataCalls:string[]=[],ownedWorkerCalls:number[]=[];
  for(const name of ['spawn','spawnSync','exec','execSync','execFile','execFileSync','fork']){
    const original=childProcess[name];
    childProcess[name]=(...args:any[])=>{
      const [binary,argv]=args;
      const identity=name==='spawnSync' &&
        ((binary==='/bin/ps' && JSON.stringify(argv)===JSON.stringify(['-p',String(process.pid),'-o','lstart='])) ||
         (binary==='ps' && JSON.stringify(argv)===JSON.stringify(['-p',String(process.pid),'-o','pid=,state=,lstart='])));
      const architecture=name==='spawn' && binary==='/usr/sbin/sysctl' && JSON.stringify(argv)===JSON.stringify(['-n','hw.optional.arm64']);
      if(identity || architecture){metadataCalls.push(identity?'self-process-identity':'cpu-architecture');return original(...args);}
      const options=args[2];
      const worker=name==='spawn' && ownedWorker && binary===process.execPath && Array.isArray(argv) && argv.length===5 &&
        argv[0]===ownedWorker.gate && argv[1]===ownedWorker.entry && argv[2]==='run' && argv[3]==='--config' &&
        typeof argv[4]==='string' && argv[4].startsWith(ownedWorker.root+'/runs/') &&
        /^[a-f0-9]{64}\/e2e\.config\.mjs$/.test(argv[4].slice((ownedWorker.root+'/runs/').length)) &&
        options?.shell===false && JSON.stringify(options.stdio)===JSON.stringify(['ignore','pipe','pipe','pipe']);
      if(worker){const child=original(...args);ownedWorkerCalls.push(child.pid);return child;}
      hostCalls.push(name+':'+JSON.stringify(args.slice(0,2)));throw new Error('Fixture denies host process fallback');
    };
  }
  syncBuiltinESMExports();return {hostCalls,metadataCalls,ownedWorkerCalls};
}
