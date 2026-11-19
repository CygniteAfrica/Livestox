// Builds the scripts that are pasted into the SQL editor of the Lovable project.
//
//   dist/install.sql  every migration in order, then a row per migration in
//                     Supabase's migration history, so the database's record of
//                     what was applied matches the files in supabase/migrations.
//   dist/dryrun.sql   every migration in order, then the smoke script. The smoke
//                     script always ends in an error, so nothing is kept.
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
  return list.map((m) => `-- ===== ${m.file} =====\n${m.sql}\n`).join('\n');
}

export function buildInstall() {
  const list = migrations();
  const history = list
    .map((m) =>
      `insert into supabase_migrations.schema_migrations (version, name, statements)\n` +
      `values ('${m.version}', '${m.name}', array[${TAG}${m.sql}${TAG}]);\n`)
    .join('\n');
  return `${body(list)}\n-- ===== migration history =====\n${history}`;
}

export function buildDryRun() {
  const smoke = readFileSync(join(root, 'tests', 'real', 'smoke_on_supabase.sql'), 'utf8');
  return `${body(migrations())}\n-- ===== smoke test, ends in an error on purpose =====\n${smoke}`;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  mkdirSync(join(root, 'dist'), { recursive: true });
  writeFileSync(join(root, 'dist', 'install.sql'), buildInstall());
  writeFileSync(join(root, 'dist', 'dryrun.sql'), buildDryRun());
  console.log(`Wrote dist/install.sql and dist/dryrun.sql from ${migrations().length} migrations.`);
}
