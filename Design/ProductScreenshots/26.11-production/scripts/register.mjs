import { readFile, writeFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { args, taskRoot, devices, deviceSpec, safeSegment, sharp } from './runtime.mjs';

const cli = args();
if (!cli.device || !cli.locale || !cli.id || !cli.headline) {
  console.log('Usage: node scripts/register.mjs --device Duo --locale en-US --id 01-chat --headline "Your concise headline" [--source raw/Duo/en-US/01-chat.jpg] [--orientation folded|unfolded-portrait|landscape] [--bounds x,y,width,height] [--device-name "iPhone Duo"] [--captured-at ISO-8601]');
  process.exitCode = 1;
} else {
  if (!devices[cli.device]) throw new Error('Device must be Duo, DI, or iPad.');
  safeSegment(cli.locale, 'locale'); safeSegment(cli.id, 'id');
  if (!['en-US', 'zh-Hans'].includes(cli.locale) || !/^0[1-9]-[a-z0-9][a-z0-9-]*$/.test(cli.id)) throw new Error('Use locale en-US/zh-Hans and id 01-topic through 09-topic.');
  const manifestPath = path.resolve(cli.manifest || path.join(taskRoot, 'config/manifest.json'));
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  const entry = { id: cli.id, device: cli.device, locale: cli.locale, source: cli.source || `raw/${cli.device}/${cli.locale}/${cli.id}.jpg`, headline: cli.headline.replace(/\\n/g, '\n') };
  if (entry.headline.split('\n').length > 2 || /openai|anthropic/i.test(entry.headline)) throw new Error('Use 1–2 lines without prohibited brand names.');
  if (cli.orientation) entry.orientation = cli.orientation;
  deviceSpec(entry);
  const sourcePath = path.resolve(taskRoot, entry.source), metadata = await sharp(sourcePath).metadata(), sourceStat = await stat(sourcePath);
  entry.capture = { origin: 'native-device-hub-window', deviceName: cli['device-name'] || null, capturedAt: cli['captured-at'] || null, fileModifiedAt: sourceStat.mtime.toISOString(), sourceWidth: metadata.width, sourceHeight: metadata.height, sourceFormat: metadata.format };
  if (cli['captured-at'] && !Number.isFinite(Date.parse(cli['captured-at']))) throw new Error('captured-at must be an ISO timestamp.');
  if (cli.bounds) {
    const values = cli.bounds.split(',').map(Number);
    if (values.length !== 4 || values.some(value => !Number.isInteger(value))) throw new Error('bounds must be four integer coordinates.');
    const [left, top, width, height] = values;
    if (left < 0 || top < 0 || width <= 0 || height <= 0 || left + width > metadata.width || top + height > metadata.height) throw new Error('bounds exceed source.');
    entry.crop = { bounds: { left, top, width, height } };
  }
  if (cli['no-mask']) entry.crop = { ...entry.crop, maskOuterWhite: false };
  const index = manifest.entries.findIndex(item => item.id === entry.id && item.device === entry.device && item.locale === entry.locale);
  if (index >= 0) manifest.entries[index] = { ...manifest.entries[index], ...entry }; else manifest.entries.push(entry);
  manifest.entries.sort((a, b) => `${a.device}/${a.locale}/${a.id}`.localeCompare(`${b.device}/${b.locale}/${b.id}`));
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
  console.log(`Registered ${entry.device}/${entry.locale}/${entry.id} in ${manifestPath}`);
}
