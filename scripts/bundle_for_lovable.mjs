// Builds the scripts that are pasted into the SQL editor of the Lovable project.
//
//   dist/install.sql  every migration in order, then a row per migration in
//                     Supabase's migration history, so the database's record of
//                     what was applied matches the files in supabase/migrations.
//   dist/dryrun.sql   every migration in order, then the smoke script. The smoke
//                     script always ends in an error, so nothing is kept.
//
// For a database that already has the core, pass the first version to apply:
//
//   node scripts/bundle_for_lovable.mjs --from 20261120090000
//
// That writes dist/update.sql (those migrations and their history rows) and
// dist/update_dryrun.sql (the same, then the smoke script, so nothing is kept).
//
// The SQL editor runs a script as one transaction: if any statement fails, the
// whole script is rolled back.
//
// Run: node scripts/bundle_for_lovable.mjs

import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const migrationsDir = join(root, 'supabase', 'migrations');
const TAG = '$lsx_migration$';
const NL = '\n';

export function migrations() {
  return readdirSync(migrationsDir)
    .filter((f) => f.endsWith('.sql'))
    .sort()
    .map((file) => {
      const m = /^(\d{14})_([a-z0-9_]+)\.sql$/.exec(file);
      if (!m) throw new Error(`Bad migration file name: ${file}`);
      const sql = readFileSync(join(migrationsDir, file), 'utf8');
      if (sql.includes(TAG)) throw new Error(`${file} contains the quoting tag ${TAG}`);
      return { file, version: m[1], name: m[2], sql };
    });
}

function body(list) {
  return list.map((m) => `-- ===== ${m.file} =====${NL}${m.sql}${NL}`).join(NL);
}

function history(list) {
  const rows = list.map((m) =>
    `insert into supabase_migrations.schema_migrations (version, name, statements)${NL}` +
    `values ('${m.version}', '${m.name}', array[${TAG}${m.sql}${TAG}]);${NL}`);
  return `-- ===== migration history =====${NL}${rows.join(NL)}`;
}

function smoke() {
  const sql = readFileSync(join(root, 'tests', 'real', 'smoke_on_supabase.sql'), 'utf8');
  return `-- ===== smoke test, ends in an error on purpose =====${NL}${sql}`;
}

export function buildInstall() {
  const list = migrations();
  return `${body(list)}${NL}${history(list)}`;
}

export function buildDryRun() {
  return `${body(migrations())}${NL}${smoke()}`;
}

/** Migrations from a version onward, with their history rows. */
export function buildUpdate(fromVersion) {
  const list = migrations().filter((m) => m.version >= fromVersion);
  if (list.length === 0) throw new Error(`No migration at or after ${fromVersion}`);
  return `${body(list)}${NL}${history(list)}`;
}

/** The same, then the smoke script: a rehearsal of the real update that keeps nothing. */
export function buildUpdateDryRun(fromVersion) {
  return `${buildUpdate(fromVersion)}${NL}${smoke()}`;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  mkdirSync(join(root, 'dist'), { recursive: true });
  writeFileSync(join(root, 'dist', 'install.sql'), buildInstall());
  writeFileSync(join(root, 'dist', 'dryrun.sql'), buildDryRun());
  console.log(`Wrote dist/install.sql and dist/dryrun.sql from ${migrations().length} migrations.`);
  const at = process.argv.indexOf('--from');
  if (at > 0) {
    const from = process.argv[at + 1];
    writeFileSync(join(root, 'dist', 'update.sql'), buildUpdate(from));
    writeFileSync(join(root, 'dist', 'update_dryrun.sql'), buildUpdateDryRun(from));
    console.log(`Wrote dist/update.sql and dist/update_dryrun.sql from version ${from}.`);
  }
}
