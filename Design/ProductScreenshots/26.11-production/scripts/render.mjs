import { readFile, writeFile, mkdir, access } from 'node:fs/promises';
import path from 'node:path';
import { sharp, taskRoot, devices, deviceSpec, args, safeSegment, escapeHtml, launchBrowser } from './runtime.mjs';
import { cropDevice, cropVersion, sha256 } from './crop.mjs';

const renderVersion = 3;
const cli = args();
const manifestPath = path.resolve(cli.manifest || path.join(taskRoot, 'config/manifest.json'));
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
if (manifest.version !== 1 || !Array.isArray(manifest.entries)) throw new Error('Manifest must use version 1 and contain an entries array.');
const outputRoot = path.resolve(path.dirname(manifestPath), manifest.outputRoot);
const template = await readFile(path.join(taskRoot, 'templates/store.html'), 'utf8');
const backgrounds = {
  mint: 'radial-gradient(ellipse at 15% 0%, #fff8ec 0%, transparent 56%), linear-gradient(160deg, #fffdf8 3%, #f8fbf7 52%, #ddeee4 100%)',
  blue: 'radial-gradient(ellipse at 15% 0%, #fff8ec 0%, transparent 56%), linear-gradient(160deg, #fffdf8 3%, #f8fbf7 52%, #e5ecef 100%)',
  stone: 'radial-gradient(ellipse at 15% 0%, #fff8ec 0%, transparent 56%), linear-gradient(160deg, #fffdf8 3%, #f8fbf7 52%, #eae6dc 100%)',
};
const selected = manifest.entries.filter(entry => (!cli.device || entry.device === cli.device) && (!cli.locale || entry.locale === cli.locale) && (!cli.id || entry.id === cli.id));
const report = { renderVersion, manifest: manifestPath, outputRoot, expectedCountPerDeviceLocale: manifest.expectedCountPerDeviceLocale ?? null, completed: [], missing: [], failed: [], counts: {} };
let browser;

async function exists(file) { try { await access(file); return true; } catch { return false; } }

function validateEntry(entry) {
  safeSegment(entry.id, 'id'); safeSegment(entry.locale, 'locale');
  if (!/^0[1-9]-[a-z0-9][a-z0-9-]*$/.test(entry.id)) throw new Error('Scene id must be 01-topic through 09-topic.');
  if (!['en-US', 'zh-Hans'].includes(entry.locale)) throw new Error('Locale must be en-US or zh-Hans.');
  if (!devices[entry.device]) throw new Error(`Unknown device: ${entry.device}. Use Duo, DI, or iPad.`);
  if (typeof entry.headline !== 'string' || !entry.headline.trim()) throw new Error('Each entry needs a nonempty headline.');
  if (/openai|anthropic/i.test(entry.headline)) throw new Error('Prohibited brand in headline.');
  if (entry.subtitle) throw new Error('Subtitles are not part of this production format.');
  if (typeof entry.source !== 'string') throw new Error('Each entry needs a source path.');
  if ((entry.captureOrigin || manifest.captureOrigin) !== 'native-device-hub-window') throw new Error('Only actual native Device Hub window captures are allowed.');
  if (entry.headline.split('\n').length > 2) throw new Error('Headlines may use at most two explicit lines.');
}

async function renderEntry(entry) {
  validateEntry(entry);
  const device = deviceSpec(entry);
  const source = path.resolve(taskRoot, entry.source);
  if (!await exists(source)) { report.missing.push({ id: entry.id, device: entry.device, locale: entry.locale, source }); console.log(`MISSING ${entry.device}/${entry.locale}/${entry.id}: ${source}`); return; }
  const output = path.join(outputRoot, entry.device, entry.locale, `${entry.id}.png`);
  const provenancePath = path.join(taskRoot, 'provenance', entry.device, entry.locale, `${entry.id}.json`);
  const sourceSha256 = sha256(await readFile(source));
  const fingerprint = sha256(JSON.stringify({ renderVersion, cropVersion, entry, defaults: manifest.defaults, device, sourceSha256, template }));
  if (!cli.force && await exists(output) && await exists(provenancePath)) {
    const cached = JSON.parse(await readFile(provenancePath, 'utf8'));
    if (cached.fingerprint === fingerprint && cached.outputSha256 === sha256(await readFile(output)) && await exists(cached.crop.output) && cached.crop.cropSha256 === sha256(await readFile(cached.crop.output))) {
      report.completed.push({ ...cached, cached: true }); console.log(`CACHED  ${entry.device}/${entry.locale}/${entry.id}`); return;
    }
  }
  const cropOutput = path.join(taskRoot, 'crops', entry.device, entry.locale, `${entry.id}.png`);
  const cropOptions = { ...(manifest.defaults?.crop || {}), ...(entry.crop || {}) };
  const crop = await cropDevice(source, cropOutput, cropOptions);
  let backgroundName = entry.background || manifest.defaults?.background || 'sequence';
  if (backgroundName === 'sequence') backgroundName = Number(entry.id.slice(0, 2)) <= 3 ? 'mint' : Number(entry.id.slice(0, 2)) <= 6 ? 'blue' : 'stone';
  if (!backgrounds[backgroundName]) throw new Error(`Unknown background: ${backgroundName}`);
  const tokens = {
    LANG: escapeHtml(entry.locale), TITLE: escapeHtml(entry.headline.replace(/\n/g, ' ')),
    WIDTH: device.width, HEIGHT: device.height, TOP: device.top, FONT_SIZE: device.headlineSize,
    HEADLINE: escapeHtml(entry.headline), BACKGROUND: backgrounds[backgroundName],
    DEVICE_DATA: `data:image/png;base64,${(await readFile(cropOutput)).toString('base64')}`,
  };
  let html = template.replace(/\{\{([A-Z_]+)\}\}/g, (_, key) => { if (!(key in tokens)) throw new Error(`Missing template token: ${key}`); return tokens[key]; });
  browser ||= await launchBrowser();
  const page = await browser.newPage({ viewport: { width: device.width, height: device.height }, deviceScaleFactor: 1 });
  try {
    await page.setContent(html, { waitUntil: 'load' });
    await page.evaluate(async () => { await document.fonts.ready; await document.querySelector('#device').decode(); });
    const minimumDeviceArea = Math.max(0.75, manifest.defaults?.minDeviceAreaFraction ?? 0.75);
    const layout = await page.evaluate(({ device, crop, minimumDeviceArea }) => {
      const headline = document.querySelector('#headline'), image = document.querySelector('#device');
      let fontSize = device.headlineSize;
      const measure = () => {
        const rect = headline.getBoundingClientRect(), style = getComputedStyle(headline);
        return { left: rect.left, top: rect.top, width: rect.width, height: rect.height, right: rect.right, bottom: rect.bottom, lines: Math.round(rect.height / parseFloat(style.lineHeight)), fontSize: parseFloat(style.fontSize) };
      };
      let text, placement;
      while (fontSize >= device.minHeadlineSize) {
        headline.style.fontSize = `${fontSize}px`; text = measure();
        const areaTop = Math.ceil(text.bottom + device.gap), availableHeight = device.height - device.bottom - areaTop;
        const scale = Math.min((device.width - device.side * 2) / crop.crop.width, availableHeight / crop.crop.height);
        const width = crop.crop.width * scale, height = crop.crop.height * scale;
        const left = (device.width - width) / 2, top = areaTop + (availableHeight - height) / 2;
        const areaFraction = crop.detectedHardwareBounds.width * crop.detectedHardwareBounds.height * scale * scale / (device.width * device.height);
        placement = { scale, width, height, left, top, areaFraction, cropAreaFraction: width * height / (device.width * device.height) };
        if (text.lines <= device.maxHeadlineLines && headline.scrollWidth <= headline.clientWidth && placement.areaFraction >= minimumDeviceArea) break;
        fontSize -= 2;
      }
      if (text.lines > device.maxHeadlineLines || headline.scrollWidth > headline.clientWidth) throw new Error('Headline does not fit in two lines at the allowed minimum size. Shorten the essential headline.');
      const { scale, width, height, left, top, areaFraction, cropAreaFraction } = placement;
      if (areaFraction < minimumDeviceArea) throw new Error(`Complete real device covers only ${(areaFraction * 100).toFixed(1)}% of canvas; shorten headline or adjust layout while retaining the entire hardware.`);
      Object.assign(image.style, { left: `${left}px`, top: `${top}px`, width: `${width}px`, height: `${height}px` });
      const heightFraction = height / device.height, widthFraction = width / device.width;
      const dominantFraction = Math.max(heightFraction, widthFraction);
      if (dominantFraction < 0.75) throw new Error(`Real device is too small: dominant dimension ${(100 * dominantFraction).toFixed(1)}%.`);
      if (left < 0 || top < text.bottom || left + width > device.width + 0.01 || top + height > device.height + 0.01) throw new Error('Device bounds overlap text or exceed the canvas.');
      const hardware = { left: left + (crop.detectedHardwareBounds.left - crop.crop.left) * scale, top: top + (crop.detectedHardwareBounds.top - crop.crop.top) * scale, width: crop.detectedHardwareBounds.width * scale, height: crop.detectedHardwareBounds.height * scale };
      return { headline: text, device: { left, top, width, height, scale, areaFraction, cropAreaFraction, heightFraction, widthFraction, dominantFraction }, hardware, areaMetric: 'detected hardware bounding box, excluding crop padding', upright: true, centered: true, textDeviceGap: top - text.bottom };
    }, { device, crop, minimumDeviceArea });
    html = await page.content();
    const htmlPath = path.join(taskRoot, 'rendered', entry.device, entry.locale, `${entry.id}.html`);
    await mkdir(path.dirname(htmlPath), { recursive: true });
    await writeFile(htmlPath, html);
    const rendered = await page.screenshot({ type: 'png', animations: 'disabled', omitBackground: false });
    const outputBytes = await sharp(rendered).flatten({ background: '#ffffff' }).removeAlpha().toColourspace('srgb').png({ compressionLevel: 9 }).toBuffer();
    const metadata = await sharp(outputBytes).metadata();
    if (metadata.width !== device.width || metadata.height !== device.height || metadata.hasAlpha || metadata.channels !== 3 || metadata.space !== 'srgb') throw new Error(`Output acceptance failed: ${JSON.stringify(metadata)}`);
    await mkdir(path.dirname(output), { recursive: true });
    await writeFile(output, outputBytes);
    const record = {
      id: entry.id, device: entry.device, locale: entry.locale, headline: entry.headline, orientation: device.orientation, fingerprint,
      entrySha256: sha256(JSON.stringify(entry)), canvasWidth: device.width, canvasHeight: device.height, background: backgroundName,
      capture: entry.capture || null,
      source, sourceSha256, crop, layout, output, outputSha256: sha256(outputBytes),
      acceptance: { width: metadata.width, height: metadata.height, format: metadata.format, colourspace: metadata.space, channels: metadata.channels, hasAlpha: metadata.hasAlpha, headlineFits: true, rgbCropSourceIdentical: true },
      visualReviewRequired: 'Check actual rim, physical buttons, hinge, complete app UI and headline against source before upload.',
    };
    await mkdir(path.dirname(provenancePath), { recursive: true });
    await writeFile(provenancePath, JSON.stringify(record, null, 2) + '\n');
    report.completed.push(record);
    console.log(`RENDERED ${entry.device}/${entry.locale}/${entry.id} ${metadata.width}×${metadata.height} RGB | device ${(layout.device.areaFraction * 100).toFixed(1)}% canvas area, ${(layout.device.dominantFraction * 100).toFixed(1)}% dominant dimension`);
  } finally { await page.close(); }
}

try {
  const seen = new Set();
  for (const entry of selected) {
    const key = `${entry.device}/${entry.locale}/${entry.id}`;
    if (seen.has(key)) { report.failed.push({ key, error: 'Duplicate entry' }); continue; }
    seen.add(key);
    try { await renderEntry(entry); } catch (error) { report.failed.push({ key, error: error.stack || error.message }); console.error(`FAILED  ${key}: ${error.message}`); }
  }
} finally { if (browser) await browser.close(); }

for (const entry of selected) {
  const group = `${entry.device}/${entry.locale}`;
  report.counts[group] ||= { declared: 0, rendered: 0, target: manifest.expectedCountPerDeviceLocale ?? null };
  report.counts[group].declared++;
}
for (const entry of report.completed) report.counts[`${entry.device}/${entry.locale}`].rendered++;
await mkdir(path.join(taskRoot, 'proofs'), { recursive: true });
const reportPath = path.join(taskRoot, 'proofs', 'render-report.json');
await writeFile(reportPath, JSON.stringify(report, null, 2) + '\n');
console.log(`\n${report.completed.length} ready, ${report.missing.length} missing, ${report.failed.length} failed. Report: ${reportPath}`);
if (!selected.length) console.log('No entries yet. Register real captures with scripts/register.mjs; no placeholder screenshot has been generated.');
if (report.failed.length || (cli.strict && report.missing.length)) process.exitCode = 1;
