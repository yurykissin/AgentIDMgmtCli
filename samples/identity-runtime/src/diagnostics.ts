import type { IAppTokenProvider } from '@microsoft/teams.apps';
import { LabError, guid, type Agent, type Config } from './config.js';

export type Diagnostic = 'graph' | 'mailbox';
export type TokenProvider = Pick<IAppTokenProvider, 'getAgenticUserToken'>;

export async function diagnose(
  config: Config, agent: Agent, command: Diagnostic, provider: TokenProvider,
  request: typeof fetch = fetch
): Promise<string> {
  if (!agent.enabled || !config.agents.includes(agent)) throw new LabError('Agent is not enabled/registered.');
  if (!config.graphEnabled) throw new LabError('Graph checks are disabled. Set LAB_GRAPH_ENABLED=true after consent.');
  if (command === 'mailbox' && !config.mailboxEnabled) throw new LabError('Mailbox checks are disabled. Set LAB_MAILBOX_ENABLED=true after consent.');
  const token = await provider.getAgenticUserToken(
    'https://graph.microsoft.com/.default', agent.agentClientId, agent.agentUserId, agent.tenantId
  );
  if (!token?.toString()) throw new LabError('SDK returned no agent-user token. No fallback identity was used.');
  const get = async (path: string) => {
    const response = await request(`https://graph.microsoft.com/v1.0/${path}`, {
      headers: { Authorization: `Bearer ${token.toString()}` },
      redirect: 'error',
      signal: AbortSignal.timeout(15000)
    });
    if (!response.ok) {
      throw new LabError(`Graph HTTP ${response.status}. Check scoped delegated consent, workload provisioning and sign-in logs.`);
    }
    return response;
  };
  const me: unknown = await (await get('me?$select=id')).json();
  if (!me || typeof me !== 'object' || !('id' in me) || guid(me.id) !== agent.agentUserId) {
    throw new LabError('Graph /me identity mismatch. Stopped before accessing a workload.');
  }
  if (command === 'graph') return `PASS: Graph /me is agent user ${agent.agentUserId}, not the human tester or blueprint.`;
  const inbox = await get('me/mailFolders/inbox?$select=id');
  await inbox.body?.cancel();
  return 'PASS: Graph /me matched the agent user and its Inbox is accessible. No messages were read or sent. Teams readiness is a separate test.';
}
