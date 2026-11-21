import { readFileSync } from 'node:fs';

export class LabError extends Error {}

export interface Agent {
  tenantId: string;
  blueprintClientId: string;
  agentClientId: string;
  agentObjectId: string;
  agentUserId: string;
  enabled: boolean;
}

export interface Config {
  tenantId: string;
  blueprintClientId: string;
  secret: string;
  agents: Agent[];
  testerIds: string[];
  port: number;
  graphEnabled: boolean;
  mailboxEnabled: boolean;
}

export function guid(value: unknown): string | undefined {
  return typeof value === 'string' &&
    /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value)
    ? value.toLowerCase() : undefined;
}

export function parseConfig(env: NodeJS.ProcessEnv, data: unknown): Config {
  const tenantId = guid(env.TENANT_ID);
  const blueprintClientId = guid(env.CLIENT_ID);
  if (!tenantId || !blueprintClientId || !env.CLIENT_SECRET?.trim() ||
      env.CLIENT_SECRET === 'replace-with-blueprint-secret-value') {
    throw new LabError('Set valid TENANT_ID, CLIENT_ID and a blueprint CLIENT_SECRET.');
  }
  if (env.MANAGED_IDENTITY_CLIENT_ID) {
    throw new LabError('This local lab uses a blueprint secret; unset MANAGED_IDENTITY_CLIENT_ID.');
  }
  const flag = (name: string) => {
    if (env[name] && env[name] !== 'true' && env[name] !== 'false') {
      throw new LabError(`${name} must be true or false.`);
    }
    return env[name] === 'true';
  };
  const graphEnabled = flag('LAB_GRAPH_ENABLED');
  const mailboxEnabled = flag('LAB_MAILBOX_ENABLED');
  if (mailboxEnabled && !graphEnabled) throw new LabError('Mailbox checks require LAB_GRAPH_ENABLED=true.');
  const port = Number(env.PORT || '3978');
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new LabError('PORT must be 1-65535.');
  const testerIds = (env.LAB_TESTER_IDS || '').split(',').map(value => guid(value.trim()));
  if (!testerIds.length || testerIds.some(id => !id)) throw new LabError('Set LAB_TESTER_IDS to human tester object IDs.');
  if (!Array.isArray(data) || !data.length) throw new LabError('Agent mapping must be a nonempty JSON array.');
  const keys = new Set<string>();
  const agents = data.map((item: unknown): Agent => {
    if (!item || typeof item !== 'object') throw new LabError('Invalid agent mapping.');
    const row = item as Record<string, unknown>;
    const values = ['tenantId', 'blueprintClientId', 'agentClientId', 'agentObjectId', 'agentUserId']
      .map(key => guid(row[key]));
    const [tenant, blueprint, client, object, user] = values;
    if (!tenant || !blueprint || !client || !object || !user || typeof row.enabled !== 'boolean') {
      throw new LabError('Each mapping needs five GUIDs and an explicit enabled boolean.');
    }
    if (tenant !== tenantId || blueprint !== blueprintClientId) {
      throw new LabError('Mapping tenant/blueprint differs from runtime credentials.');
    }
    if (new Set([blueprint, client, object, user]).size !== 4 ||
        [client, object, user].some(id => keys.has(id))) {
      throw new LabError('Duplicate or confused blueprint, child and agent-user IDs.');
    }
    keys.add(user);
    keys.add(client);
    keys.add(object);
    return { tenantId: tenant, blueprintClientId: blueprint, agentClientId: client,
      agentObjectId: object, agentUserId: user, enabled: row.enabled };
  });
  return { tenantId, blueprintClientId, secret: env.CLIENT_SECRET, agents,
    testerIds: testerIds.filter((id): id is string => !!id), port, graphEnabled, mailboxEnabled };
}

export function loadConfig(): Config {
  let data: unknown;
  try {
    data = JSON.parse(readFileSync(process.env.LAB_AGENTS_FILE || './agents.local.json', 'utf8'));
  } catch {
    throw new LabError('Cannot read agent mapping JSON. Check LAB_AGENTS_FILE and JSON syntax.');
  }
  return parseConfig(process.env, data);
}

export function safeFailure(error: unknown): string {
  return error instanceof LabError ? error.message :
    'SDK/runtime operation failed. Check credential expiry, consent and tenant sign-in logs; sensitive details omitted.';
}
