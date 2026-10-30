import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { args, taskRoot, devices, safeSegment } from './runtime.mjs';

const cli = args();
if (!cli.device || !cli.locale || !cli.id || !cli.source || !cli.headline) {
  console.log('Usage: node scripts/register.mjs --device Duo --locale en-US --id 01-chat --source raw/Duo/en-US/01-chat.jpg --headline "Your concise headline" [--bounds x,y,width,height]');
  process.exitCode = 1;
} else {
  if (!devices[cli.device]) throw new Error('Device must be Duo, DI, or iPad.');
  safeSegment(cli.locale, 'locale'); safeSegment(cli.id, 'id');
  const manifestPath = path.resolve(cli.manifest || path.join(taskRoot, 'config/manifest.json'));
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  const entry = { id: cli.id, device: cli.device, locale: cli.locale, source: cli.source, headline: cli.headline.replace(/\\n/g, '\n') };
  if (cli.bounds) { const [left, top, width, height] = cli.bounds.split(',').map(Number); entry.crop = { bounds: { left, top, width, height } }; }
  const index = manifest.entries.findIndex(item => item.id === entry.id && item.device === entry.device && item.locale === entry.locale);
  if (index >= 0) manifest.entries[index] = { ...manifest.entries[index], ...entry }; else manifest.entries.push(entry);
  manifest.entries.sort((a, b) => `${a.device}/${a.locale}/${a.id}`.localeCompare(`${b.device}/${b.locale}/${b.id}`));
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
  console.log(`Registered ${entry.device}/${entry.locale}/${entry.id} in ${manifestPath}`);
}
