import {test,expect,type Screen} from 'e2e';import {readFile,writeFile} from 'node:fs/promises';
import {BrokerClient} from '../segmentBroker.js';import {targetSchema} from '../protocol.js';import {captureReadback,verifyReadback} from '../uiReadback.js';
import {segmentSchema, type Segment} from '../segment.js';
const path=process.env.INTENTS_SEGMENT;if(!path)throw new Error('Missing trusted segment data');
const segment:Segment=segmentSchema.parse(JSON.parse(await readFile(path,'utf8')));
const outputs:Record<string,unknown>=Object.create(null);
test('bounded approved UI segment',{timeout:segment.timeoutMs,retries:0},async(fixtures)=>{
 const screen=fixtures.screen;const deadline=Date.now()+segment.timeoutMs;
 for(const operation of segment.operations){
  function locate(screen:Screen){if(!('locator' in operation))throw new Error('No locator');
   const visible=['tap','fillBinding'].includes(operation.kind);
   if(operation.locator.role==='button')return screen.getByRole('button',operation.locator.value,{exact:true,visible});
   if(operation.locator.kind==='role')return screen.getByRole(operation.locator.value as 'textbox'|'searchbox',{visible});
   return operation.locator.kind==='testId'?screen.getByTestId(operation.locator.value,{visible}):screen.getByLabel(operation.locator.value,{exact:true,visible});}
  switch(operation.kind){
   case 'navigateGoal':await fixtures.agent.act(operation.goal.instruction,{params:{goalId:operation.goal.id}});break;
   case 'tap':await locate(screen).tap();break;
   case 'fillBinding':{const value=segment.bindings[operation.binding];if(value===undefined)throw new Error('Missing approved binding');await locate(screen).fill(value);break;}
   case 'observeProperty':{
    const broker=new BrokerClient(process.env.INTENTS_BROKER_SOCKET!,process.env.INTENTS_BROKER_TOKEN!);
    const timeoutMs=Math.min(60000,deadline-Date.now());
    if(timeoutMs<=0)throw new Error('Readback deadline expired');
    const proof=captureReadback(await broker.snapshot({runId:segment.scope.runId,attemptId:segment.scope.attemptId,origin:'test',signal:AbortSignal.timeout(timeoutMs),timeoutMs}),targetSchema.parse(JSON.parse(process.env.INTENTS_TARGET!)));
    verifyReadback(proof,operation);outputs[operation.id]=proof;break;
   }
   case 'readProperty':outputs[operation.id]=operation.property==='value'?await locate(screen).inputValue():await locate(screen).textContent();break;
   case 'assertEndpoint':await expect(locate(screen)).toBeVisible();break;
   case 'locate':outputs[operation.id]=await locate(screen).count();break;
   case 'scroll':await screen.swipe({direction:operation.direction});break;
  }
 }
 const output=process.env.INTENTS_SEGMENT_RECEIPT;if(!output)throw new Error('Missing owned receipt path');
 const receipt=JSON.stringify({schemaVersion:1,scope:segment.scope,operationId:segment.operationId,complete:true,outputs});
 if(Buffer.byteLength(receipt)>1047552)throw new Error('UI receipt exceeds evidence budget');
 await writeFile(output,receipt,{mode:0o600});
});
