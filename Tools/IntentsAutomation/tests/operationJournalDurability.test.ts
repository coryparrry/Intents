import test from 'node:test';import assert from 'node:assert/strict';
import {mkdtemp,readFile,rm} from 'node:fs/promises';import {join} from 'node:path';import {tmpdir} from 'node:os';
import {OperationJournal} from '../src/operationJournal.js';

test('dispatch waits for directory durability before invoking native work',async()=>{
 const root=await mkdtemp(join(tmpdir(),'intents-journal-durability-')),path=join(root,'operations.json');
 let release!:()=>void,entered!:()=>void,syncs=0,dispatches=0;
 const pending=new Promise<void>(resolve=>{release=resolve;}),entering=new Promise<void>(resolve=>{entered=resolve;});
 const journal=new OperationJournal(path,async directory=>{assert.equal(directory,root);syncs++;if(syncs===1){entered();await pending;}});
 try{
  const operation=journal.dispatch('operation','a'.repeat(64),async()=>{dispatches++;return true;});
  await entering;assert.equal(dispatches,0);assert.equal(JSON.parse(await readFile(path,'utf8')).operation.state,'dispatched');
  release();assert.equal(await operation,true);assert.equal(dispatches,1);assert.equal(syncs,2);
 }finally{release();await rm(root,{recursive:true,force:true});}
});
test('failed directory sync refuses native work and preserves uncertain dispatch for retry',async()=>{
 const root=await mkdtemp(join(tmpdir(),'intents-journal-durability-fail-')),path=join(root,'operations.json');let dispatches=0;
 try{
  const journal=new OperationJournal(path,async()=>{throw new Error('Directory durability unknown');});
  await assert.rejects(journal.dispatch('operation','b'.repeat(64),async()=>{dispatches++;return true;}),/Directory durability unknown/);
  await assert.rejects(new OperationJournal(path).dispatch('operation','b'.repeat(64),async()=>{dispatches++;return true;}),/ACTION_MAY_HAVE_COMMITTED/);
  assert.equal(dispatches,0);
 }finally{await rm(root,{recursive:true,force:true});}
});
