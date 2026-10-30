import { readFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { sharp, taskRoot, args, escapeHtml } from './runtime.mjs';

const cli = args();
const manifest = JSON.parse(await readFile(path.resolve(cli.manifest || path.join(taskRoot, 'config/manifest.json')), 'utf8'));
const groups = new Map();
for (const entry of manifest.entries) {
  if ((cli.device && entry.device !== cli.device) || (cli.locale && entry.locale !== cli.locale)) continue;
  const key = `${entry.device}/${entry.locale}`;
  try {
    const record = JSON.parse(await readFile(path.join(taskRoot, 'provenance', key, `${entry.id}.json`), 'utf8'));
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(record);
  } catch (error) { if (error.code !== 'ENOENT') throw error; console.warn(`SKIP ${key}/${entry.id}: render first`); }
}
const generated = [];
for (const [key, entries] of groups) {
  entries.sort((a, b) => a.id.localeCompare(b.id));
  const columns = 3, cellWidth = 580, gap = 18, labelHeight = 38, titleHeight = 55;
  const cellHeight = Math.max(...entries.map(entry => Math.round(cellWidth * entry.canvasHeight / entry.canvasWidth)));
  const width = columns * cellWidth + (columns + 1) * gap;
  const height = titleHeight + Math.ceil(entries.length / columns) * (cellHeight + labelHeight + gap) + gap;
  const layers = [{ input: Buffer.from(`<svg width="${width}" height="${titleHeight}"><text x="${gap}" y="36" fill="#153b2b" font-size="25" font-family="Helvetica,Arial,sans-serif">${escapeHtml(key)} · ${entries.length} real captures</text></svg>`), left: 0, top: 0 }];
  for (let index = 0; index < entries.length; index++) {
    const entry = entries[index], left = gap + (index % columns) * (cellWidth + gap), top = titleHeight + Math.floor(index / columns) * (cellHeight + labelHeight + gap);
    const thumb = await sharp(entry.output).resize({ width: cellWidth, height: cellHeight, fit: 'inside' }).png().toBuffer(), meta = await sharp(thumb).metadata();
    layers.push({ input: thumb, left: left + Math.floor((cellWidth - meta.width) / 2), top: top + Math.floor((cellHeight - meta.height) / 2) });
    const label = `${entry.id} · ${entry.orientation} · ${(entry.layout.device.areaFraction * 100).toFixed(1)}%`;
    layers.push({ input: Buffer.from(`<svg width="${cellWidth}" height="${labelHeight}"><text x="4" y="25" fill="#42564a" font-size="17" font-family="Helvetica,Arial,sans-serif">${escapeHtml(label)}</text></svg>`), left, top: top + cellHeight });
  }
  const output = path.join(taskRoot, 'proofs/contact-sheets', key.replace('/', '--') + '.png');
  await mkdir(path.dirname(output), { recursive: true });
  await sharp({ create: { width, height, channels: 3, background: '#fffdf8' } }).composite(layers).removeAlpha().png().toFile(output);
  generated.push({ group: key, output, entries: entries.map(entry => ({ id: entry.id, sourceSha256: entry.sourceSha256, outputSha256: entry.outputSha256 })) });
  console.log(output);
}
await mkdir(path.join(taskRoot, 'proofs'), { recursive: true });
await writeFile(path.join(taskRoot, 'proofs/contact-sheets.json'), JSON.stringify(generated, null, 2) + '\n');
if (!generated.length) console.log('No rendered real captures; no contact sheet generated.');
