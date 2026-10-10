import type {E2EConfig} from 'e2e';import {intentsUIEngine} from './engine.js';import {BrokerClient} from '../segmentBroker.js';
import {targetSchema} from '../protocol.js';
import {readFileSync} from 'node:fs';import {segmentSchema} from '../segment.js';
import {decisionSchema} from '../controllerProtocol.js';
import {nativeControllerExecutor} from './nativeController.js';
function required(name:string){const value=process.env[name];if(!value)throw new Error(`Missing ${name}`);return value;}
const target=targetSchema.parse(JSON.parse(required('INTENTS_TARGET')));
const segment=segmentSchema.parse(JSON.parse(readFileSync(required('INTENTS_SEGMENT'),'utf8')));
const navigationOnly=segment.operations.every(operation=>['tap','fillBinding','scroll','navigateGoal'].includes(operation.kind));
const broker=new BrokerClient(required('INTENTS_BROKER_SOCKET'),required('INTENTS_BROKER_TOKEN'));
const goal=segment.operations[0]?.kind==='navigateGoal'?segment.operations[0].goal:undefined;
let approvedNode:string|undefined;
const config:E2EConfig={...(goal?{agents:{default:{executor:nativeControllerExecutor(goal,segment.bindings,segment.phase,async(request,ctx)=>{approvedNode=undefined;const decision=decisionSchema.parse(await broker.decide(request,
 {runId:segment.scope.runId,attemptId:segment.scope.attemptId,origin:'agent',signal:ctx.signal,timeoutMs:Math.max(1,Math.min(30000,ctx.budgets.remainingMs()))}));approvedNode='node' in decision?decision.node:decision.kind==='scroll'?'root':undefined;return decision;}),maxSteps:goal.maximumActions,maxModelCalls:goal.maximumCalls}}}:{}),
 targets:[{name:'approved',engine:intentsUIEngine(broker,
 target.platform,target.bundleId,navigationOnly,goal?{node:()=>approvedNode,consume:()=>{approvedNode=undefined;}}:undefined,target.kind==='nativeMac'?['tap',...(process.env.INTENTS_MAC_FILL_IMPLEMENTED==='1'?['fill' as const]:[]),...(process.env.INTENTS_MAC_SCROLL_IMPLEMENTED==='1'?['swipe' as const]:[])]:undefined),app:{bundleId:target.bundleId,environment:'test'}}],
 tests:[required('INTENTS_INTERPRETER')],workers:1,retries:0,cache:'off',timeout:segment.timeoutMs,actionTimeout:target.kind==='nativeMac'?Math.min(segment.timeoutMs,60000):segment.timeoutMs,
 trace:'off',video:'off',output:required('INTENTS_OUTPUT'),reporters:['json']};
export default config;
