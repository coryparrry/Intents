import {guardSyntheticDaemonHost} from './macDaemonHostGuard.js';
import {dirname,join} from 'node:path';

// Explicit test preload; never part of the packaged runtime's startup contract.
const unit=dirname(dirname(dirname(process.argv[1]!))),state=process.argv[process.argv.indexOf('--state-dir')+1]!;
const guard=guardSyntheticDaemonHost(process.env.INTENTS_SYNTHETIC_PROGRAM_WORKER==='1'?{
 gate:join(unit,'sidecar/src/ownedUIWorkerGate.js'),entry:join(unit,'node_modules/e2e/dist/cli/bin.js'),root:join(state,'mac-programs')}:undefined);
process.on('exit',()=>process.stderr.write('SYNTHETIC_HOST_GUARD '+JSON.stringify(guard)+'\n'));
