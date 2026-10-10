import {defineConfig} from 'vitest/config';

// These tests use injected providers and create no device, app or daemon process.
// Keep upstream's hermetic test setup, without its host-wide process inventory hook.
export default defineConfig({test:{
  include:['src/intents-mac-sdk-ownership.test.ts',
    'packages/platform-apple/src/os/macos/helper.test.ts',
    'src/daemon/snapshot-runtime-capture-input.test.ts',
    'src/commands/capture/runtime/snapshot.test.ts'],
  setupFiles:['src/__tests__/hermetic-env-setup.ts','src/__tests__/hermetic-signal-setup.ts',
    'src/__tests__/process-memo-setup.ts'],
  maxWorkers:2,
}});
