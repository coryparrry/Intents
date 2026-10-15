import { EvaluationApp } from '../../server/app.mjs';
if (process.argv[2] === '--hold') {
  process.stdout.write('locked\n');
  setInterval(() => {}, 1000);
} else {
  const app = new EvaluationApp({ dataDir: process.argv[2], invoke: async () => { throw new Error('Unexpected inference'); } });
  await app.init();
  process.send({ ready: true });
  process.once('message', async (args) => {
    try { process.send({ suite: (await app.call('eval_save_suite', args)).suite }); }
    catch (error) { process.send({ error: error.message }); }
    finally { await app.shutdown(); process.disconnect(); }
  });
}
