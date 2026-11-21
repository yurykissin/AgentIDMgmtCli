import { diagnose } from './diagnostics.js';
import { guid, LabError, loadConfig, safeFailure } from './config.js';
import { createSdk } from './sdk.js';

async function main() {
  const [command, userId, ...extra] = process.argv.slice(2);
  if ((command !== 'graph' && command !== 'mailbox') || !guid(userId) || extra.length) {
    throw new LabError('Usage: npm run probe -- graph|mailbox <agent-user-object-id>');
  }
  const config = loadConfig();
  const agent = config.agents.find(row => row.enabled && row.agentUserId === guid(userId));
  if (!agent) throw new LabError('Agent user is not enabled/registered in local mapping.');
  const app = createSdk(config);
  console.log(await diagnose(config, agent, command, app.tokenProvider));
}

main().catch(error => { console.error(safeFailure(error)); process.exitCode = 1; });
