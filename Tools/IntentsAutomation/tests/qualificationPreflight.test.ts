import {test} from 'node:test';import assert from 'node:assert/strict';import {preflight} from '../src/qualificationPreflight.js';
const profile={runID:'run',attemptID:'attempt',target:{id:'device',platform:'ios',kind:'simulator',bundleId:'example.App',bundlePath:null,loginSession:null},
 setup:{operations:[{id:'fill',kind:'fillBinding',locator:{kind:'testId',value:'name'},binding:'fixture'}],bindings:{fixture:'Synthetic'},approvedEffects:['activate','fill']}};
test('pure UI admission rejects missing authority, bindings and invalid scope before activation',()=>{
 preflight(profile);
 for(const name of ['constructor','toString','__proto__'])assert.throws(()=>preflight({...profile,setup:{...profile.setup,bindings:{},operations:[{...profile.setup.operations[0],binding:name}]}}));
 assert.throws(()=>preflight({...profile,runID:'../escape'}));
 assert.throws(()=>preflight({...profile,setup:{...profile.setup,bindings:{}}}));
 assert.throws(()=>preflight({...profile,setup:{...profile.setup,approvedEffects:['activate']}}));
 assert.throws(()=>preflight({...profile,setup:{...profile.setup,operations:[{kind:'arbitrary',id:'bad'}]}}));
});
