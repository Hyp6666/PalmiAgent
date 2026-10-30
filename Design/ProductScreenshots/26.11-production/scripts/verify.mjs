import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
import path from 'node:path';
import { sharp, taskRoot, devices, deviceSpec, args } from './runtime.mjs';
import { sha256 } from './crop.mjs';

const cli = args();
const manifestPath = path.resolve(cli.manifest || path.join(taskRoot, 'config/manifest.json'));
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
const outputRoot = path.resolve(path.dirname(manifestPath), manifest.outputRoot);
const audit = { manifest: manifestPath, checked: [], errors: [], groups: {}, visualReviewRequired: 'Compare source and poster for genuine device, complete screen, correct language and forbidden visible brand names. Pixel and geometry checks cannot interpret app text.' };
const hashes = new Map(), seen = new Set();
const close = (a, b) => Math.abs(a - b) < 0.01;
for (const device of Object.keys(devices)) for (const locale of ['en-US', 'zh-Hans']) audit.groups[`${device}/${locale}`] = { declared: 0, ready: 0, target: 9 };

for (const entry of manifest.entries) {
  const key = `${entry.device}/${entry.locale}/${entry.id}`, group = `${entry.device}/${entry.locale}`;
  audit.groups[group] ||= { declared: 0, ready: 0, target: manifest.expectedCountPerDeviceLocale ?? 9 };
  audit.groups[group].declared++;
  try {
    if (seen.has(key)) throw new Error('Duplicate manifest key.');
    seen.add(key);
    if (!/^0[1-9]-[a-z0-9][a-z0-9-]*$/.test(entry.id) || !['en-US', 'zh-Hans'].includes(entry.locale)) throw new Error('Invalid scene number or locale.');
    const record = JSON.parse(await readFile(path.join(taskRoot, 'provenance', entry.device, entry.locale, `${entry.id}.json`), 'utf8'));
    const expected = deviceSpec(entry), expectedSource = path.resolve(taskRoot, entry.source), expectedOutput = path.join(outputRoot, entry.device, entry.locale, `${entry.id}.png`);
    if (record.source !== expectedSource || record.output !== expectedOutput || record.entrySha256 !== sha256(JSON.stringify(entry))) throw new Error('Manifest entry changed or provenance paths differ; render again.');
    const sourceBytes = await readFile(record.source), outputBytes = await readFile(record.output), cropBytes = await readFile(record.crop.output);
    if (sha256(sourceBytes) !== record.sourceSha256 || record.crop.sourceSha256 !== record.sourceSha256) throw new Error('Source changed after rendering.');
    if (sha256(outputBytes) !== record.outputSha256) throw new Error('Final PNG changed after rendering.');
    if (sha256(cropBytes) !== record.crop.cropSha256) throw new Error('Device crop changed after rendering.');
    const metadata = await sharp(outputBytes).metadata();
    if (metadata.width !== expected.width || metadata.height !== expected.height || metadata.format !== 'png' || metadata.hasAlpha || metadata.channels !== 3 || metadata.space !== 'srgb') throw new Error('Final dimensions/RGB/no-alpha check failed.');
    const d = record.layout.device, h = record.layout.headline, c = record.crop.crop, hardware = record.crop.detectedHardwareBounds;
    const area = hardware.width * hardware.height * d.scale ** 2 / (expected.width * expected.height);
    if (record.headline !== entry.headline || /openai|anthropic/i.test(entry.headline) || h.lines < 1 || h.lines > 2 || area < Math.max(0.75, manifest.defaults?.minDeviceAreaFraction || 0.75) || !close(area, d.areaFraction)) throw new Error('Headline or hardware area check failed.');
    if (!close(d.width, c.width * d.scale) || !close(d.height, c.height * d.scale) || !close(d.left, (expected.width - d.width) / 2) || d.left < 0 || d.top < h.bottom + expected.gap - 0.01 || d.left + d.width > expected.width + 0.01 || d.top + d.height > expected.height + 0.01) throw new Error('Proportional scale, centering, complete visibility or headline gap failed.');
    if (hardware.left < c.left || hardware.top < c.top || hardware.left + hardware.width > c.left + c.width || hardware.top + hardware.height > c.top + c.height) throw new Error('Crop cuts the recorded hardware bounds.');
    const sourceRgb = await sharp(sourceBytes).toColourspace('srgb').removeAlpha().extract(c).raw().toBuffer();
    const { data: cropRgba, info } = await sharp(cropBytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    if (info.width !== c.width || info.height !== c.height || info.channels !== 4) throw new Error('Saved crop geometry differs from provenance.');
    for (let index = 0; index < info.width * info.height; index++) for (let channel = 0; channel < 3; channel++) if (sourceRgb[index * 3 + channel] !== cropRgba[index * 4 + channel]) throw new Error(`Saved crop RGB differs from source at pixel ${index}.`);
    const sourceKey = `${group}/${record.sourceSha256}`;
    if (hashes.has(sourceKey)) throw new Error(`Same source reused for two scenes: ${hashes.get(sourceKey)} and ${entry.id}.`);
    hashes.set(sourceKey, entry.id);
    audit.checked.push({ key, output: record.output, width: metadata.width, height: metadata.height, rgbCropSourceIdentical: true, completeRecordedDeviceVisible: true, areaFraction: area, areaMetric: record.layout.areaMetric, sourceSha256: record.sourceSha256 });
    audit.groups[group].ready++;
    console.log(`PASS ${key} | original RGB, hashes, canvas, complete device, headline, ${(area * 100).toFixed(2)}% hardware area`);
  } catch (error) { audit.errors.push({ key, error: error.message }); console.error(`FAIL ${key}: ${error.message}`); }
}

for (const [group, count] of Object.entries(audit.groups)) {
  console.log(`${group}: ${count.ready}/${count.target} ready (${count.declared} declared)`);
  if (cli.complete) {
    if (count.ready !== count.target || count.declared !== count.target) audit.errors.push({ key: group, error: `Expected ${count.target} distinct scenes; found ${count.ready} ready / ${count.declared} declared.` });
    const entries = manifest.entries.filter(entry => `${entry.device}/${entry.locale}` === group), slots = new Set(entries.map(entry => entry.id.slice(0, 2)));
    if (slots.size !== count.target) audit.errors.push({ key: group, error: 'Scene numbers must cover 01 through 09 exactly once.' });
    const expectedNames = new Set(entries.map(entry => `${entry.id}.png`));
    const names = await readdir(path.join(outputRoot, group)).catch(error => { if (error.code === 'ENOENT') return []; throw error; });
    const extras = names.filter(name => name.endsWith('.png') && !expectedNames.has(name));
    if (extras.length) audit.errors.push({ key: group, error: `Unregistered PNGs in upload folder: ${extras.join(', ')}` });
  }
}
await mkdir(path.join(taskRoot, 'proofs'), { recursive: true });
await writeFile(path.join(taskRoot, 'proofs/verification-report.json'), JSON.stringify(audit, null, 2) + '\n');
console.log(`${audit.checked.length} verified, ${audit.errors.length} errors. --complete requires all six groups of nine.`);
if (audit.errors.length) process.exitCode = 1;
