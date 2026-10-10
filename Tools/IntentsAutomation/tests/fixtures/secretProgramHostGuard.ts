import {guardSyntheticDaemonHost} from './macDaemonHostGuard.js';
const guard=guardSyntheticDaemonHost();
process.on('exit',()=>process.stderr.write('SECRET_HOST_GUARD '+JSON.stringify(guard)+'\n'));
