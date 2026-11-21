import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { test, mock } from 'node:test';
import { parseConfig, safeFailure, type Config } from '../src/config.js';
import { diagnose, type TokenProvider } from '../src/diagnostics.js';
import { resolveAgent, runCommand, type LabActivity } from '../src/runtime.js';
import { createRuntime } from '../src/server.js';

const ids = {
  tenant: '11111111-1111-4111-8111-111111111111',
  blueprint: '22222222-2222-4222-8222-222222222222',
  client: '33333333-3333-4333-8333-333333333333',
  object: '44444444-4444-4444-8444-444444444444',
  user: '55555555-5555-4555-8555-555555555555',
  human: '66666666-6666-4666-8666-666666666666',
  other: '77777777-7777-4777-8777-777777777777'
};
const env = { TENANT_ID: ids.tenant, CLIENT_ID: ids.blueprint, CLIENT_SECRET: 'synthetic-only',
  LAB_TESTER_IDS: ids.human, LAB_GRAPH_ENABLED: 'true', LAB_MAILBOX_ENABLED: 'true' };
const mapping = { tenantId: ids.tenant, blueprintClientId: ids.blueprint, agentClientId: ids.client,
  agentObjectId: ids.object, agentUserId: ids.user, enabled: true };
const config = () => parseConfig(env, [mapping]);
const agentFor = (cfg: Config) => cfg.agents[0]!;
const activity = (): LabActivity => ({
  type: 'message', id: 'test', channelId: 'msteams', serviceUrl: 'https://smba.trafficmanager.net/teams/',
  from: { id: 'sender', role: 'user', aadObjectId: ids.human },
  recipient: { id: 'recipient', role: 'bot', agenticAppBlueprintId: ids.blueprint,
    agenticAppId: ids.client, agenticUserId: ids.user, tenantId: ids.tenant },
  conversation: { id: 'test-chat', conversationType: 'personal', tenantId: ids.tenant },
  text: 'whoami'
});

test('validates mappings and normalizes GUID case', () => {
  const cfg = parseConfig({ ...env, TENANT_ID: ids.tenant.toUpperCase() }, [mapping]);
  assert.equal(resolveAgent(cfg, activity()), agentFor(cfg));
});

for (const [name, alteredEnv, data] of [
  ['missing credential', { ...env, CLIENT_SECRET: '' }, [mapping]],
  ['placeholder credential', { ...env, CLIENT_SECRET: 'replace-with-blueprint-secret-value' }, [mapping]],
  ['ambiguous credential source', { ...env, MANAGED_IDENTITY_CLIENT_ID: ids.client }, [mapping]],
  ['no human allowlist', { ...env, LAB_TESTER_IDS: '' }, [mapping]],
  ['bad flag', { ...env, LAB_GRAPH_ENABLED: 'yes' }, [mapping]],
  ['mailbox without Graph', { ...env, LAB_GRAPH_ENABLED: 'false' }, [mapping]],
  ['invalid port', { ...env, PORT: '0' }, [mapping]],
  ['wrong tenant mapping', env, [{ ...mapping, tenantId: ids.other }]],
  ['wrong blueprint mapping', env, [{ ...mapping, blueprintClientId: ids.other }]],
  ['confused child ID', env, [{ ...mapping, agentObjectId: ids.client }]],
  ['duplicate mapping', env, [mapping, mapping]],
  ['reused child object', env, [mapping, { ...mapping, agentUserId: ids.other,
    agentClientId: '88888888-8888-4888-8888-888888888888' }]],
  ['no mappings', env, []],
  ['enabled not boolean', env, [{ ...mapping, enabled: 'true' }]]
] as const) {
  test(`configuration rejects ${name}`, () => assert.throws(() => parseConfig(alteredEnv, data)));
}

for (const [name, change] of [
  ['missing recipient identity', (a: LabActivity) => { a.recipient = { id: 'recipient', role: 'bot' }; }],
  ['foreign tenant', (a: LabActivity) => { a.recipient = { ...a.recipient, tenantId: ids.other }; }],
  ['conflicting conversation tenant', (a: LabActivity) => { a.conversation = { ...a.conversation, tenantId: ids.other }; }],
  ['conflicting channel tenant', (a: LabActivity) => { a.channelData = { tenant: { id: ids.other } }; }],
  ['unknown user', (a: LabActivity) => { a.recipient = { ...a.recipient, agenticUserId: ids.other }; }],
  ['wrong blueprint', (a: LabActivity) => { a.recipient = { ...a.recipient, agenticAppBlueprintId: ids.other }; }],
  ['wrong child client', (a: LabActivity) => { a.recipient = { ...a.recipient, agenticAppId: ids.other }; }],
  ['missing child client', (a: LabActivity) => { a.recipient = { ...a.recipient, agenticAppId: undefined }; }],
  ['unapproved sender', (a: LabActivity) => { a.from = { ...a.from, aadObjectId: ids.other }; }],
  ['group chat', (a: LabActivity) => { a.conversation = { ...a.conversation, conversationType: 'groupChat' }; }],
  ['non-Teams channel', (a: LabActivity) => { a.channelId = 'emulator'; }]
] as const) {
  test(`routing rejects ${name}`, () => {
    const message = activity();
    change(message);
    assert.throws(() => resolveAgent(config(), message));
  });
}

test('disabled agent cannot be selected, even by an approved human', () => {
  const cfg = config();
  agentFor(cfg).enabled = false;
  assert.throws(() => resolveAgent(cfg, activity()));
});

test('second agent routes only to its own mapping', () => {
  const second = { ...mapping, agentUserId: ids.other,
    agentClientId: '88888888-8888-4888-8888-888888888888',
    agentObjectId: '99999999-9999-4999-8999-999999999999' };
  const cfg = parseConfig(env, [mapping, second]);
  const message = activity();
  message.recipient = { ...message.recipient, agenticUserId: second.agentUserId, agenticAppId: second.agentClientId };
  assert.equal(resolveAgent(cfg, message), cfg.agents[1]);
});

const forbiddenProvider: TokenProvider = {
  getAgenticUserToken: async () => { throw new Error('must not acquire token'); }
};

test('whoami distinguishes all IDs; echo/help acquire no token', async () => {
  const cfg = config();
  const message = activity();
  const report = await runCommand(cfg, agentFor(cfg), message, forbiddenProvider);
  for (const id of Object.values(ids).filter(id => id !== ids.other)) assert.ok(report.includes(id));
  message.text = 'echo hello';
  assert.equal(await runCommand(cfg, agentFor(cfg), message, forbiddenProvider), 'Echo: hello');
  message.text = 'help';
  assert.match(await runCommand(cfg, agentFor(cfg), message, forbiddenProvider), /No AI model/);
});

function provider() {
  const acquire = mock.fn<TokenProvider['getAgenticUserToken']>(async () => ({
    appId: ids.client, serviceUrl: '', from: 'azure', fromId: ids.user,
    isExpired: () => false, toString: () => 'synthetic-token'
  }));
  return { acquire, source: { getAgenticUserToken: acquire } satisfies TokenProvider };
}

test('Graph uses the SDK agent-user grant with mapped client, user and tenant', async () => {
  const cfg = config();
  const { acquire, source } = provider();
  const request = mock.fn<typeof fetch>(async (url, init) => {
    assert.equal(url, 'https://graph.microsoft.com/v1.0/me?$select=id');
    assert.equal(new Headers(init?.headers).get('Authorization'), 'Bearer synthetic-token');
    assert.equal(init?.redirect, 'error');
    return Response.json({ id: ids.user });
  });
  assert.match(await diagnose(cfg, agentFor(cfg), 'graph', source, request), /PASS/);
  assert.deepEqual(acquire.mock.calls[0]?.arguments,
    ['https://graph.microsoft.com/.default', ids.client, ids.user, ids.tenant]);
  assert.equal(request.mock.callCount(), 1);
});

test('mailbox probes only Inbox metadata after confirming /me', async () => {
  const cfg = config();
  const request = mock.fn<typeof fetch>(async url =>
    Response.json(String(url).includes('mailFolders') ? { id: 'folder' } : { id: ids.user }));
  assert.match(await diagnose(cfg, agentFor(cfg), 'mailbox', provider().source, request), /No messages were read or sent/);
  assert.deepEqual(request.mock.calls.map(call => call.arguments[0]), [
    'https://graph.microsoft.com/v1.0/me?$select=id',
    'https://graph.microsoft.com/v1.0/me/mailFolders/inbox?$select=id'
  ]);
});

test('mismatched human /me prevents mailbox access', async () => {
  const cfg = config();
  const request = mock.fn<typeof fetch>(async () => Response.json({ id: ids.human }));
  await assert.rejects(diagnose(cfg, agentFor(cfg), 'mailbox', provider().source, request), /identity mismatch/);
  assert.equal(request.mock.callCount(), 1);
});

test('opt-in flags prevent token acquisition', async () => {
  const cfg = config();
  cfg.graphEnabled = false;
  await assert.rejects(diagnose(cfg, agentFor(cfg), 'graph', forbiddenProvider), /disabled/);
  cfg.graphEnabled = true;
  cfg.mailboxEnabled = false;
  await assert.rejects(diagnose(cfg, agentFor(cfg), 'mailbox', forbiddenProvider), /disabled/);
});

test('null token never falls back to admin or blueprint identity', async () => {
  const cfg = config();
  await assert.rejects(diagnose(cfg, agentFor(cfg), 'graph',
    { getAgenticUserToken: async () => null }), /No fallback/);
});

test('unregistered and disabled mappings cannot acquire tokens', async () => {
  const cfg = config();
  await assert.rejects(diagnose(cfg, { ...agentFor(cfg) }, 'graph', forbiddenProvider), /registered/);
  agentFor(cfg).enabled = false;
  await assert.rejects(diagnose(cfg, agentFor(cfg), 'graph', forbiddenProvider), /enabled/);
});

test('Graph errors expose status but not response bodies or tokens', async () => {
  const cfg = config();
  const request: typeof fetch = async () => new Response('sensitive-response-and-token', { status: 403 });
  await assert.rejects(diagnose(cfg, agentFor(cfg), 'graph', provider().source, request),
    error => error instanceof Error && error.message.includes('403') && !error.message.includes('sensitive'));
  assert.ok(!safeFailure(new Error('secret-in-provider-error')).includes('secret-in-provider-error'));
});

test('SDK credential errors in Teams diagnostics are sanitized', async t => {
  t.mock.method(console, 'error', () => {});
  const cfg = config();
  const message = activity();
  message.text = 'graph';
  const result = await runCommand(cfg, agentFor(cfg), message, {
    getAgenticUserToken: async () => { throw new Error('synthetic-secret-provider-error'); }
  });
  assert.match(result, /^FAILED:/);
  assert.ok(!result.includes('synthetic-secret'));
});

test('CLI validates config, refuses disabled probes and exits nonzero on occupied port', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'agent-id-runtime-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const mappingFile = join(directory, 'agents.local.json');
  writeFileSync(mappingFile, JSON.stringify([mapping]), { mode: 0o600 });
  const reservation = createServer();
  await new Promise<void>(resolve => reservation.listen(0, resolve));
  t.after(() => new Promise<void>((resolve, reject) =>
    reservation.close(error => error ? reject(error) : resolve())));
  const address = reservation.address();
  assert.ok(address && typeof address !== 'string');
  const run = (name: string, args: string[] = []) => spawnSync(process.execPath, [
    fileURLToPath(new URL(`../src/${name}.js`, import.meta.url)), ...args
  ], {
    cwd: directory, encoding: 'utf8', timeout: 10000,
    env: { ...process.env, ...env, PORT: String(address.port), LAB_AGENTS_FILE: mappingFile,
      LAB_GRAPH_ENABLED: 'false', LAB_MAILBOX_ENABLED: 'false' }
  });
  const check = run('check');
  assert.equal(check.status, 0, check.stderr);
  assert.match(check.stdout, /Configuration valid/);
  const probe = run('probe', ['graph', ids.user]);
  assert.equal(probe.status, 1, probe.stderr);
  assert.match(probe.stderr, /disabled/);
  const server = run('server');
  assert.ifError(server.error);
  assert.equal(server.status, 1, server.stderr);
  assert.match(server.stderr, /failed to start/);
  assert.ok(!server.stdout.includes('listening'));
  assert.ok(![check, probe, server].some(result =>
    `${result.stdout}${result.stderr}`.includes('synthetic-only')));
});

test('real HTTP health responds and SDK rejects missing/forged authentication', async t => {
  t.mock.method(console, 'warn', () => {});
  t.mock.method(console, 'error', () => {});
  const previous = process.env.DANGEROUSLY_ALLOW_UNAUTHENTICATED_REQUESTS;
  process.env.DANGEROUSLY_ALLOW_UNAUTHENTICATED_REQUESTS = 'true';
  t.after(() => {
    if (previous === undefined) delete process.env.DANGEROUSLY_ALLOW_UNAUTHENTICATED_REQUESTS;
    else process.env.DANGEROUSLY_ALLOW_UNAUTHENTICATED_REQUESTS = previous;
  });
  const reservation = createServer();
  await new Promise<void>(resolve => reservation.listen(0, '127.0.0.1', resolve));
  const address = reservation.address();
  assert.ok(address && typeof address !== 'string');
  const port = address.port;
  await new Promise<void>((resolve, reject) => reservation.close(error => error ? reject(error) : resolve()));
  const app = createRuntime(config());
  try {
    await app.start(port);
    const base = `http://127.0.0.1:${port}`;
    const health = await fetch(`${base}/healthz`);
    assert.equal(health.status, 200);
    assert.deepEqual(await health.json(), { status: 'running' });
    for (const authorization of ['', 'Bearer forged.invalid.token']) {
      const response = await fetch(`${base}/api/messages`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', ...(authorization ? { authorization } : {}) },
        body: JSON.stringify(activity())
      });
      assert.equal(response.status, 401);
    }
  } finally {
    await app.stop();
  }
});
