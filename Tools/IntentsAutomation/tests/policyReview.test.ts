import test from 'node:test';
import assert from 'node:assert/strict';
import {EngineError} from 'e2e/engine';
import {policyDenialReasons,PolicyDeniedError,requirePolicyApproval} from '../src/policyReview.js';
import {createBroker,BrokerClient} from '../src/segmentBroker.js';
import type {UIBackend} from '../src/deviceSession.js';
import {mkdtemp,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {runWorker,payloadDigest} from '../src/workerRunner.js';
import {OwnedUIWorkerError} from '../src/ownedUIWorker.js';
import type {Segment} from '../src/segment.js';

test('policy replies preserve fixed denials and accept the legacy denial shape',()=>{
  requirePolicyApproval({allowed:true});
  for (const reason of policyDenialReasons) {
    assert.throws(()=>requirePolicyApproval({allowed:false,reason}),error=>
      error instanceof PolicyDeniedError && error.reason===reason && error.message===`Action denied: ${reason}`);
  }
  assert.throws(()=>requirePolicyApproval({allowed:false}),error=>error instanceof PolicyDeniedError && error.reason==='unspecified');
  for (const reply of [{allowed:true,reason:'scopeLease'}, {allowed:false,reason:'private-canary'},
    {allowed:false,reason:'budget',value:'private-canary'}, {allowed:'true'}, null]) {
    assert.throws(()=>requirePolicyApproval(reply));
  }
});

test('actual e2e worker preserves fixed denial after process exit and owned drain',async()=>{
  for (const owned of [false,true]) {
    let admissions=0,dispatches=0;
    const backend:UIBackend={snapshot:async()=>({truncated:false,
      nodes:[{index:1,ref:'@e1',identifier:'open',role:'button',label:'Open',rect:{x:0,y:0,width:100,height:50}}],
      refsGeneration:7,identifiers:{udid:'exact'},appBundleId:'com.example.App'}),
      perform:async()=>{requirePolicyApproval({allowed:false,reason:'controllerNode'});dispatches++;},
      release:async()=>({released:false,reason:'Synthetic fixture'})};
    const segment:Segment={scope:{protocolVersion:1,runId:'run',attemptId:'attempt',segmentId:'setup',leaseGeneration:1},
      operationId:'op',payloadDigest:'a'.repeat(64),phase:'setup',bindings:{},timeoutMs:50000,
      operations:[{id:'tap',kind:'tap',locator:{kind:'testId',value:'open'}}]};
    const {payloadDigest:ignored,...body}=segment;segment.payloadDigest=payloadDigest(body);
    const root=await mkdtemp(join(tmpdir(),'intents-policy-worker-'));
    try {
      await assert.rejects(runWorker(backend,{id:'exact',platform:'ios',kind:'simulator',bundleId:'com.example.App',bundlePath:null,loginSession:null},
        segment,root,new AbortController().signal,undefined,owned?async pid=>{assert.ok(pid>0);admissions++;}:undefined),error=>{
          assert.ok(error instanceof Error);assert.equal(error.message,'Action denied: controllerNode');
          if(owned){assert.ok(error instanceof OwnedUIWorkerError);assert.equal(error.commandsDrained,true);}
          return true;
        });
      assert.equal(dispatches,0);assert.equal(admissions,owned?1:0);
    } finally {await rm(root,{recursive:true,force:true});}
  }
});

test('broker carries safe guard reasons without text, forged codes, or consumed input',async()=>{
  const canary='private-input-canary';
  let reply:unknown={allowed:false,reason:'actionMismatch'},dispatches=0,override:unknown;
  const backend:UIBackend={snapshot:async()=>({nodes:[],identifiers:{}}),
    perform:async()=>{if(override!==undefined)throw override;requirePolicyApproval(reply);dispatches++;},
    release:async()=>({released:false,reason:'Fixture'})};
  const broker=await createBroker(backend);
  const client=new BrokerClient(broker.socket,broker.token);
  const context={runId:'run',attemptId:'attempt',origin:'test' as const,signal:new AbortController().signal,timeoutMs:2000};
  const perform=()=>client.perform('@e1~s1',{kind:'fill',value:canary,sensitive:false},context);
  try {
    for (const reason of policyDenialReasons) {
      reply={allowed:false,reason};
      await assert.rejects(perform(),error=>error instanceof EngineError && error.code==='ENGINE_FAILURE' &&
        error.message===`Action denied: ${reason}` && !JSON.stringify(error).includes(canary));
    }
    reply={allowed:false,reason:canary};
    await assert.rejects(perform(),error=>error instanceof EngineError && error.message==='Broker command failed');
    const changed=new PolicyDeniedError('controllerNode');changed.message=canary;override=changed;
    await assert.rejects(perform(),error=>error instanceof EngineError && error.message==='Action denied: controllerNode');
    for (const error of [new Error(canary), {code:canary,message:canary,reason:'budget'},null]) {
      override=error;
      await assert.rejects(perform(),error=>error instanceof EngineError && error.code==='ENGINE_FAILURE' && error.message==='Broker command failed');
    }
    assert.equal(dispatches,0);
    override=undefined;reply={allowed:true};await perform();assert.equal(dispatches,1);
  } finally {await broker.close();}
});
