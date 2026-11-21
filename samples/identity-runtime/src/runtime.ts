import { getAgenticIdentity, type IMessageActivity } from '@microsoft/teams.api';
import { LabError, guid, safeFailure, type Agent, type Config } from './config.js';
import { diagnose, type TokenProvider } from './diagnostics.js';

export type LabActivity = Pick<IMessageActivity,
  'type' | 'id' | 'serviceUrl' | 'recipient' | 'from' | 'conversation' | 'channelData' | 'channelId' | 'text'>;

export function resolveAgent(config: Config, activity: LabActivity): Agent {
  const identity = getAgenticIdentity(activity.recipient);
  const tenants = [identity?.tenantId, activity.conversation.tenantId, activity.channelData?.tenant?.id]
    .filter(value => value !== undefined && value !== null);
  if (!tenants.length || tenants.some(value => guid(value) !== config.tenantId) ||
      guid(identity?.agenticAppBlueprintId) !== config.blueprintClientId) {
    throw new LabError('Rejected missing/conflicting tenant or blueprint identity.');
  }
  const agent = config.agents.find(row => row.tenantId === config.tenantId &&
    row.agentUserId === guid(identity?.agenticUserId) && row.enabled);
  // The SDK scopes replies from the recipient, so its client must match too.
  if (!agent || guid(identity?.agenticAppId) !== agent.agentClientId) {
    throw new LabError('Rejected unknown, disabled or mismatched recipient agent.');
  }
  if (activity.channelId !== 'msteams' || activity.conversation.conversationType !== 'personal' ||
      !config.testerIds.includes(guid(activity.from.aadObjectId) || '')) {
    throw new LabError('Rejected message outside an allowlisted tester personal Teams chat.');
  }
  return agent;
}

export function identityReport(agent: Agent, sender: string): string {
  return [
    'IDENTITY LAB - routing context, not a decoded/validated Graph token',
    `Tenant: ${agent.tenantId}`,
    `Blueprint client ID: ${agent.blueprintClientId}`,
    `Child agent client ID: ${agent.agentClientId}`,
    `Child object ID (local mapping): ${agent.agentObjectId}`,
    `Recipient agent-user object ID: ${agent.agentUserId}`,
    `Human sender object ID: ${sender}`,
    'Use graph to verify the downstream Graph identity.'
  ].join('\n');
}

export async function runCommand(
  config: Config, agent: Agent, activity: LabActivity, provider: TokenProvider
): Promise<string> {
  const text = (activity.text || '').trim();
  if (text.toLowerCase() === 'whoami') return identityReport(agent, guid(activity.from.aadObjectId)!);
  if (text.toLowerCase() === 'graph' || text.toLowerCase() === 'mailbox') {
    try {
      return await diagnose(config, agent, text.toLowerCase() === 'graph' ? 'graph' : 'mailbox', provider);
    } catch (error) {
      console.error(safeFailure(error));
      return `FAILED: ${safeFailure(error)}`;
    }
  }
  if (/^echo(?:\s|$)/i.test(text)) return `Echo: ${text.slice(4).trim().slice(0, 1000)}`;
  return 'Identity lab: help | echo <text> | whoami | graph | mailbox. No AI model. Graph/mailbox are opt-in, read-only checks.';
}
