import { App, ExpressAdapter } from '@microsoft/teams.apps';
import { PUBLIC } from '@microsoft/teams.api';
import type { Config } from './config.js';

// SDK HTTP errors can contain credential forms and tokens. Never serialize them.
class SafeSdkLogger {
  debug() {}
  trace() {}
  info() {}
  warn() { console.warn('SDK warning. Sensitive diagnostic details omitted.'); }
  error() { console.error('SDK error. Check tenant sign-in logs. Sensitive diagnostic details omitted.'); }
  log(level: string) {
    if (level === 'error') this.error();
    else if (level === 'warn') this.warn();
  }
  child() { return this; }
}

export function createSdk(config: Config) {
  const logger = new SafeSdkLogger();
  const adapter = new ExpressAdapter(undefined, { logger });
  adapter.get('/healthz', (_request, response) => {
    response.status(200).json({ status: 'running' });
  });
  return new App({
    clientId: config.blueprintClientId,
    clientSecret: config.secret,
    tenantId: config.tenantId,
    cloud: PUBLIC,
    dangerouslyAllowUnauthenticatedRequests: false,
    logger,
    httpServerAdapter: adapter
  });
}
