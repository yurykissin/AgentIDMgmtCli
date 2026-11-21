import { loadConfig, safeFailure } from './config.js';

try {
  const config = loadConfig();
  console.log(`Configuration valid: ${config.agents.length} mapping(s). No network requests or credentials tested.`);
} catch (error) {
  console.error(safeFailure(error));
  process.exitCode = 1;
}
