// Read-only inventory. Does not register, render, edit images, or operate any UI.
// Run from any directory: node /absolute/path/to/scripts/capture-checklist.mjs
import { readFile, access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const [matrix, manifest] = await Promise.all([
  readFile(path.join(root, 'research/capture-matrix.json'), 'utf8').then(JSON.parse),
  readFile(path.join(root, 'config/manifest.json'), 'utf8').then(JSON.parse),
]);
const key = x => `${x.device}/${x.locale}/${x.id}`;
const planned = new Set();
for (const row of matrix.entries) {
  if (planned.has(key(row))) throw new Error(`Duplicate planned slot: ${key(row)}`);
  planned.add(key(row));
  if (/openai|anthropic|deepseek|google|microsoft|meta\b/i.test(row.headline)) throw new Error(`Supplier in headline: ${key(row)}`);
  if (!/^0[1-9]-/.test(row.id)) throw new Error(`Invalid slot: ${key(row)}`);
}
if (planned.size !== 54) throw new Error(`Expected 54 planned slots; got ${planned.size}`);
const exists = async p => { try { await access(p); return true; } catch { return false; } };
const groups = [];
for (const device of manifest.expectedDevices) for (const locale of manifest.expectedLocales) {
  const rows = matrix.entries.filter(x => x.device === device && x.locale === locale);
  if (rows.length !== 9 || new Set(rows.map(x => x.id.slice(0, 2))).size !== 9) throw new Error(`Invalid nine-slot plan: ${device}/${locale}`);
  const registered = manifest.entries.filter(x => x.device === device && x.locale === locale);
  const slots = await Promise.all(rows.map(async row => {
    // Match slot number as a real approved fallback may use a different scene slug.
    const matches = registered.filter(x => x.id.slice(0, 2) === row.id.slice(0, 2));
    const entry = matches.length === 1 ? matches[0] : null;
    const source = entry?.source || row.raw;
    return { slot: row.id.slice(0, 2), plannedId: row.id, headline: row.headline,
      registration: matches.length > 1 ? 'duplicate-slot' : entry ? 'registered-unreviewed' : 'not-registered',
      registeredId: entry?.id || null, source, sourceExists: await exists(path.resolve(root, source)),
      headlineMatchesPlan: entry ? entry.headline === row.headline : null,
      captureIdentityPresent: Boolean(entry?.capture?.deviceName && entry?.capture?.capturedAt),
      noModelAttempt: row.withoutModelNetwork.canAttemptNow,
      acceptance: row.acceptance, fallback: row.withoutModelNetwork.action };
  }));
  groups.push({ device, locale, registeredCount: registered.length, slots });
}
console.log(JSON.stringify({ mode: 'read-only-inventory', matrixValid: true,
  note: 'File existence and registration do not prove scene truth, successful execution, localization, device identity, or final output acceptance. Run existing verifier and human review separately.',
  groups }, null, 2));
