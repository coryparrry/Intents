import { randomUUID } from 'node:crypto';
import { EvaluationApp } from '../../server/app.mjs';

let finishNative, resumeDecision, resumePublication;
function rawRun(source, instructions, runId) {
  return { id: runId, suiteID: source.id, suiteName: source.name, suiteVersion: source.version, instructions, criteria: '', scoringMode: 'review', repetitions: 1,
    startedAt: new Date().toISOString(), completedAt: new Date().toISOString(), cancelled: false,
    suiteDefinition: { formatVersion: 1, ...source, instructions },
    results: source.cases.map((item) => ({ id: randomUUID(), caseID: item.id, caseName: item.name, repetition: 1, prompt: item.prompt, expected: '', response: 'apple', status: 'unscored', durationMilliseconds: 8, usage: { inputTokens: 5, outputTokens: 1 }, workflowTrace: { spans: [] } })) };
}
const app = new EvaluationApp({ dataDir: process.argv[2], resolveBinary: async () => '/fixture',
  invoke: async (_binary, request) => {
    if (request.operation === 'create-experiment') {
      const current = { id: randomUUID(), name: 'Current', instructions: request.suite.instructions };
      const candidate = { id: randomUUID(), name: 'Candidate', instructions: request.candidateInstructions };
      return { id: randomUUID(), name: request.name, suiteRevision: 'native-revision', casesDigest: 'cases', scoringDigest: 'scoring', judgeDigest: 'judge', current, candidate, executionOrder: [current.id, candidate.id], runIDs: [] };
    }
    if (request.operation !== 'run-experiment') throw Error('Unexpected native operation');
    const success = await new Promise((resolve) => { finishNative = resolve; });
    if (!success) throw Error('Controlled native failure');
    return { current: rawRun(request.suite, request.suite.instructions, request.currentRunID), candidate: rawRun(request.suite, request.experiment.candidate.instructions, request.candidateRunID), summary: {} };
  } });
await app.init();
process.on('message', async ({ requestId, command, args }) => {
  try {
    let result;
    if (command === 'call') result = await app.call(args.name, args.arguments);
    else if (command === 'pauseDecision') {
      const write = app.store.write.bind(app.store);
      app.store.write = async (kind, value) => {
        if (kind === 'experiments') {
          app.store.write = write;
          process.send({ event: 'decisionRead' });
          await new Promise((resolve) => { resumeDecision = resolve; });
        }
        return write(kind, value);
      };
      result = await app.call('eval_decide_experiment', { experimentId: args.experimentId, decision: 'keepCurrent' });
    } else if (command === 'pausePublication') {
      const write = app.store.write.bind(app.store);
      app.store.write = async (kind, value) => {
        await write(kind, value);
        if (kind === 'runs') {
          app.store.write = write;
          process.send({ event: 'variantStaged', runId: value.id });
          await new Promise((resolve) => { resumePublication = resolve; });
        }
      };
    } else if (command === 'resumePublication') resumePublication();
    else if (command === 'resumeDecision') resumeDecision();
    else if (command === 'finishNative') { finishNative(args?.success); await app.active.promise; }
    else if (command === 'shutdown') { finishNative?.(); resumeDecision?.(); resumePublication?.(); await app.shutdown(); }
    else throw Error('Unknown fixture command');
    process.send({ requestId, result });
  } catch (error) { process.send({ requestId, error: error.message }); }
});
process.send({ ready: true });
