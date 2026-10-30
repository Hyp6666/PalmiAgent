import { readFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { sharp, taskRoot, args, escapeHtml } from './runtime.mjs';

const cli = args();
const reportPath = path.resolve(cli.report || path.join(taskRoot, 'proofs/render-report.json'));
const report = JSON.parse(await readFile(reportPath, 'utf8'));
const groups = new Map();
for (const entry of report.completed) {
  const key = `${entry.device}/${entry.locale}`;
  if (!groups.has(key)) groups.set(key, []);
  groups.get(key).push(entry);
}
const generated = [];
for (const [key, entries] of groups) {
  entries.sort((a, b) => a.id.localeCompare(b.id));
  const columns = 3, thumbWidth = entries[0].device === 'DI' ? 360 : 580;
  const source = await sharp(entries[0].output).metadata();
  const thumbHeight = Math.round(thumbWidth * source.height / source.width);
  const gap = 18, labelHeight = 36, titleHeight = 55;
  const width = columns * thumbWidth + (columns + 1) * gap;
  const height = titleHeight + Math.ceil(entries.length / columns) * (thumbHeight + labelHeight + gap) + gap;
  const layers = [];
  const title = Buffer.from(`<svg width="${width}" height="${titleHeight}"><text x="${gap}" y="36" fill="#173023" font-size="25" font-family="Helvetica,Arial,sans-serif">${escapeHtml(key)} · ${entries.length} real device captures</text></svg>`);
  layers.push({ input: title, left: 0, top: 0 });
  for (let index = 0; index < entries.length; index++) {
    const entry = entries[index], left = gap + (index % columns) * (thumbWidth + gap), top = titleHeight + Math.floor(index / columns) * (thumbHeight + labelHeight + gap);
    layers.push({ input: await sharp(entry.output).resize(thumbWidth, thumbHeight).png().toBuffer(), left, top });
    const label = Buffer.from(`<svg width="${thumbWidth}" height="${labelHeight}"><text x="4" y="25" fill="#42564a" font-size="17" font-family="Helvetica,Arial,sans-serif">${escapeHtml(entry.id)}</text></svg>`);
    layers.push({ input: label, left, top: top + thumbHeight });
  }
  const output = path.join(taskRoot, 'proofs/contact-sheets', key.replace('/', '--') + '.png');
  await mkdir(path.dirname(output), { recursive: true });
  await sharp({ create: { width, height, channels: 3, background: '#ffffff' } }).composite(layers).removeAlpha().png().toFile(output);
  generated.push({ group: key, output, entries: entries.map(entry => ({ id: entry.id, sourceSha256: entry.sourceSha256, outputSha256: entry.outputSha256 })) });
  console.log(output);
}
await writeFile(path.join(taskRoot, 'proofs/contact-sheets.json'), JSON.stringify(generated, null, 2) + '\n');
if (!generated.length) console.log('No completed real captures in the report; no contact sheet generated.');
