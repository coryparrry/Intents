// Actual frozen SDK/client + Intents connector, with synthetic daemon and cleanup providers.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile,readdir,realpath,lstat} from 'node:fs/promises';
import {createRequire,syncBuiltinESMExports} from 'node:module';
import {resolve,join,dirname} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';

const directory=resolve(process.argv[2]);
// Optional pins let the deterministic fixture runtime reuse this check; staged runtimes use the frozen receipt pins.
const expectedReceiptSHA256=process.argv[3]??'9fda71ac61b4d2428e4a08f6a9afb4ad363bd8fb20b8bc3dc10f03cc8f608bb3';
const expectedFileCount=Number(process.argv[4]??472);
assert.ok(/^[0-9a-f]{64}$/.test(expectedReceiptSHA256));assert.ok(Number.isSafeInteger(expectedFileCount) && expectedFileCount>0);
assert.equal(await realpath(directory),directory);
const receiptBytes=await readFile(join(directory,'intents-private-runtime.json'));
assert.equal(createHash('sha256').update(receiptBytes).digest('hex'),expectedReceiptSHA256);
const receipt=JSON.parse(receiptBytes);
assert.equal(receipt.customerRuntimeEnabled,false);assert.equal(receipt.hardwareQualified,false);
assert.equal(process.env.AGENT_DEVICE_MACOS_HELPER_BIN,join(directory,receipt.helperRelativePath));
async function verifyUnit(){
  const paths=await readdir(directory,{recursive:true});
  const actual=[];
  for(const relative of paths){
    const file=join(directory,relative),info=await lstat(file);assert.equal(info.isSymbolicLink(),false);
    if(info.isDirectory())continue;
    assert.equal(info.isFile(),true);assert.equal(info.nlink,1);
    if(relative==='intents-private-runtime.json')continue;
    assert.ok(info.size<=8*1024*1024);actual.push(relative);
    assert.equal(createHash('sha256').update(await readFile(file)).digest('hex'),receipt.files[relative]);
  }
  assert.deepEqual(actual.sort(),Object.keys(receipt.files).sort());assert.equal(actual.length,expectedFileCount);
}
await verifyUnit();
const processModule=createRequire(import.meta.url)('node:child_process');let processAttempts=0,fetchAttempts=0;
for(const name of ['spawn','spawnSync','exec','execSync','execFile','execFileSync','fork'])
  processModule[name]=()=>{processAttempts++;throw new Error('Synthetic SDK check attempted child activation');};
syncBuiltinESMExports();
globalThis.fetch=()=>{fetchAttempts++;throw new Error('Synthetic SDK check attempted fetch');};
const {createAgentDeviceClient}=await import(pathToFileURL(join(directory,'agent-device/dist/src/index.js')).href);
const tools=resolve(dirname(fileURLToPath(import.meta.url)),'..');
const {MacOwnedSDKTransport}=await import(pathToFileURL(join(tools,'dist/src/macOwnedSDKTransport.js')).href);
const {MacOwnedSession}=await import(pathToFileURL(join(tools,'dist/src/macOwnedSession.js')).href);
const scope={protocolVersion:1,runId:'private-sdk',attemptId:'attempt',segmentId:'segment',leaseGeneration:1};
const target={id:'host-macos-local',platform:'macos',kind:'nativeMac',bundleId:'example.Target',bundlePath:'/Applications/Selected.app',loginSession:'synthetic-login'};
const instance={bundleId:target.bundleId,canonicalBundlePath:target.bundlePath,pid:123,processStartIdentity:'100:0'};
const name='intents-private-sdk-1',requests=[];
const snapshot={applicationTarget:instance,appBundleId:target.bundleId,session:name,refsGeneration:1,truncated:false,nodes:[
  {index:1,ref:'e1',label:'Done',kind:'button',identifier:'done',hittable:true,enabled:true,visibleToUser:true,rect:{x:0,y:10,width:100,height:50}},
]};
const client=createAgentDeviceClient({session:name,lockPolicy:'reject'},{transport:async request=>{
  requests.push(request);
  assert.equal(request.session,name);assert.equal(request.flags.platform,'macos');assert.equal(request.flags.target,'desktop');
  assert.equal(request.flags.udid,target.id);
  if(request.command==='open'){
    assert.deepEqual(request.positionals,[target.bundleId]);assert.equal(request.flags.macBundlePath,target.bundlePath);
    return {ok:true,data:{applicationTarget:instance,appBundleId:target.bundleId,id:target.id,device:'Synthetic Mac',platform:'macos',target:'desktop'}};
  }
  if(request.command==='snapshot')return {ok:true,data:snapshot};
  if(request.command==='press'){
    assert.deepEqual(request.positionals,['50','35']);
    return {ok:true,data:{applicationTarget:instance,x:50,y:35,disposition:'submittedUnconfirmed',releaseSubmitted:true,
      action:'press',surface:'frontmost-app',syntheticExtraMetadata:true}};
  }
  throw new Error('Unexpected synthetic SDK command: '+request.command);
}});
let cleanupCalls=0;
const transport=new MacOwnedSDKTransport(client,target,scope,async(actualScope,actualInstance)=>{
  cleanupCalls++;assert.deepEqual(actualScope,scope);assert.deepEqual(actualInstance,instance);
  return {scope,applicationTarget:instance,commandsDrained:true,ownedHelperReaped:true,daemonStopped:true,subjectTerminated:false};
},'private-owned-mac-source');
const session=await MacOwnedSession.acquire(target,scope,transport,async()=>{});
const context={signal:new AbortController().signal,timeoutMs:1000,runId:scope.runId,attemptId:scope.attemptId,origin:'test'};
await session.snapshot(context);await session.perform('@e1~s1',{kind:'tap'},context);
assert.equal(session.selectionEvidence.lastInputDisposition,'submittedUnconfirmed');
assert.equal((await session.release()).released,true);assert.equal(cleanupCalls,1);
assert.deepEqual(requests.map(request=>request.command),['open','snapshot','snapshot','press']);
assert.equal(processAttempts,0);assert.equal(fetchAttempts,0);await verifyUnit();
console.log(JSON.stringify({artifactVariant:receipt.artifactVariant,sdkCommands:requests.map(request=>request.command),
  cleanupProvider:'synthetic',processAttempts,fetchAttempts,customerRuntimeEnabled:false,hardwareQualified:false,helperInvoked:false}));
