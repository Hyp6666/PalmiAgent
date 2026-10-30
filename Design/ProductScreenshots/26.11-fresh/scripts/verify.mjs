import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { sharp, taskRoot, devices, args } from './runtime.mjs';
import { sha256 } from './crop.mjs';

const cli = args();
const manifestPath = path.resolve(cli.manifest || path.join(taskRoot, 'config/manifest.json'));
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
const audit = { manifest: manifestPath, checked: [], errors: [], groups: {} };
const hashes = new Map();
for (const device of manifest.expectedDevices || Object.keys(devices)) for (const locale of manifest.expectedLocales || []) audit.groups[`${device}/${locale}`] = { ready: 0, target: manifest.expectedCountPerDeviceLocale ?? null };

for (const entry of manifest.entries) {
  const key = `${entry.device}/${entry.locale}/${entry.id}`, group = `${entry.device}/${entry.locale}`;
  audit.groups[group] ||= { ready: 0, target: manifest.expectedCountPerDeviceLocale ?? null };
  try {
    const record = JSON.parse(await readFile(path.join(taskRoot, 'provenance', entry.device, entry.locale, `${entry.id}.json`), 'utf8'));
    const sourceBytes = await readFile(record.source), outputBytes = await readFile(record.output), cropBytes = await readFile(record.crop.output);
    if (sha256(sourceBytes) !== record.sourceSha256) throw new Error('Source changed after rendering.');
    if (sha256(outputBytes) !== record.outputSha256) throw new Error('Final PNG changed after rendering.');
    if (sha256(cropBytes) !== record.crop.cropSha256) throw new Error('Device crop changed after rendering.');
    const metadata = await sharp(outputBytes).metadata(), expected = devices[entry.device];
    if (metadata.width !== expected.width || metadata.height !== expected.height || metadata.format !== 'png' || metadata.hasAlpha || metadata.channels !== 3 || metadata.space !== 'srgb') throw new Error('Final dimensions/RGB/no-alpha check failed.');
    if (record.headline !== entry.headline || record.layout.headline.lines > 2 || record.layout.device.areaFraction < 0.75) throw new Error('Headline or device dominance check failed.');
    const sourceRgb = await sharp(sourceBytes).toColourspace('srgb').removeAlpha().extract(record.crop.crop).raw().toBuffer();
    const { data: cropRgba, info } = await sharp(cropBytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    if (info.width !== record.crop.crop.width || info.height !== record.crop.crop.height || info.channels !== 4) throw new Error('Saved crop geometry differs from provenance.');
    for (let index = 0; index < info.width * info.height; index++) for (let channel = 0; channel < 3; channel++)
      if (sourceRgb[index * 3 + channel] !== cropRgba[index * 4 + channel]) throw new Error(`Saved crop RGB differs from source at pixel ${index}.`);
    const sourceKey = `${group}/${record.sourceSha256}`;
    if (hashes.has(sourceKey)) throw new Error(`Same source reused for two scenes: ${hashes.get(sourceKey)} and ${entry.id}.`);
    hashes.set(sourceKey, entry.id);
    audit.checked.push({ key, output: record.output, width: metadata.width, height: metadata.height, rgbCropSourceIdentical: true, areaFraction: record.layout.device.areaFraction, sourceSha256: record.sourceSha256 });
    audit.groups[group].ready++;
    console.log(`PASS ${key} | source pixels, hashes, size, RGB, no alpha, headline, device coverage`);
  } catch (error) { audit.errors.push({ key, error: error.message }); console.error(`FAIL ${key}: ${error.message}`); }
}

for (const [group, count] of Object.entries(audit.groups)) {
  console.log(`${group}: ${count.ready}/${count.target ?? '?'} ready`);
  if (cli.complete && count.target !== null && count.ready !== count.target) audit.errors.push({ key: group, error: `Expected ${count.target} distinct scenes; found ${count.ready}.` });
}
await mkdir(path.join(taskRoot, 'proofs'), { recursive: true });
await writeFile(path.join(taskRoot, 'proofs/verification-report.json'), JSON.stringify(audit, null, 2) + '\n');
console.log(`${audit.checked.length} verified, ${audit.errors.length} errors. --complete additionally requires the requested count in every expected device/locale group.`);
if (audit.errors.length) process.exitCode = 1;
