import { defineConfig } from 'vitest/config';

// Each test file starts its own in-memory Postgres and applies every migration,
// which takes a few seconds. The default 5 second limits are too tight for that.
//
// Every in-memory Postgres holds a few hundred megabytes. With one worker per
// test file, many files at once have crashed the runner on a busy machine
// ('Channel closed'), which reads as a red gate with no failing test. Two at a
// time keeps the run reliable and costs a few seconds.
export default defineConfig({
  test: {
    include: ['tests/**/*.test.ts'],
    testTimeout: 60_000,
    hookTimeout: 120_000,
    pool: 'forks',
    poolOptions: { forks: { maxForks: 2, minForks: 1 } },
  },
});
