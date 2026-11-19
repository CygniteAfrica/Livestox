import { defineConfig } from 'vitest/config';

// Each test file starts its own in-memory Postgres and applies every migration,
// which takes a few seconds. The default 5 second limits are too tight for that.
export default defineConfig({
  test: {
    include: ['tests/**/*.test.ts'],
    testTimeout: 60_000,
    hookTimeout: 120_000,
  },
});
