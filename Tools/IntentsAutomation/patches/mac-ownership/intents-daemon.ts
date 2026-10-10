/** Private composition API. The caller owns the daemon, its native provider and cleanup.
 * This entry does not qualify a device or enable the Intents customer Mac route.
 */
export {
  startDaemonRuntime,
  type DaemonRuntimeOptions,
  type DaemonRuntimeController,
} from '../daemon/server/daemon-runtime.ts';
export { createLocalAppleToolProvider } from '@agent-device/platform-apple/tool-provider';
export type { AppleToolProviderResolver } from '../platform-runtime/request-providers.ts';
export { createAgentDeviceClient } from '../agent-device-client.ts';
