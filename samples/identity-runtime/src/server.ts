import { pathToFileURL } from 'node:url';
import { LabError, loadConfig, safeFailure, type Config } from './config.js';
import { createSdk } from './sdk.js';
import { resolveAgent, runCommand } from './runtime.js';

export function createRuntime(config: Config) {
  const app = createSdk(config);
  app.on('message', async ({ activity, reply }) => {
    let agent;
    try {
      agent = resolveAgent(config, activity);
    } catch (error) {
      console.warn(safeFailure(error));
      return;
    }
    await reply({ type: 'message', text: await runCommand(config, agent, activity, app.tokenProvider), textFormat: 'plain' });
  });
  app.event('error', () => console.error('SDK activity failed. Check tenant sign-in logs; sensitive details omitted.'));
  return app;
}

async function main() {
  const config = loadConfig();
  const app = createRuntime(config);
  let startupFailed = false;
  app.event('error', () => { startupFailed = true; });
  await app.start(config.port);
  // SDK 2.2.1 reports HTTP startup errors as events rather than rejecting start().
  if (startupFailed) throw new LabError('Runtime failed to start. Check PORT availability and SDK warnings.');
  console.log(`Identity lab listening on port ${config.port}. Health is not tenant/workload readiness.`);
  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => { void app.stop().catch(() => { process.exitCode = 1; }); });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(safeFailure(error)); process.exitCode = 1; });
}
