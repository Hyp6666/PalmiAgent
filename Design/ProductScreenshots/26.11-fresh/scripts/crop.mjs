import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { sharp, args } from './runtime.mjs';

export const cropVersion = 1;
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

function union(a, b) {
  const left = Math.min(a.left, b.left), top = Math.min(a.top, b.top);
  return { left, top, width: Math.max(a.left + a.width, b.left + b.width) - left, height: Math.max(a.top + a.height, b.top + b.height) - top };
}

function components(rgb, width, height, threshold) {
  const visited = new Uint8Array(width * height), queue = new Int32Array(width * height), found = [];
  const dark = index => {
    const offset = index * 3;
    return (rgb[offset] * 0.2126 + rgb[offset + 1] * 0.7152 + rgb[offset + 2] * 0.0722) < threshold;
  };
  for (let index = 0; index < visited.length; index++) {
    if (visited[index] || !dark(index)) continue;
    let read = 0, write = 1, left = width, right = 0, top = height, bottom = 0;
    queue[0] = index; visited[index] = 1;
    while (read < write) {
      const pixel = queue[read++], x = pixel % width, y = Math.floor(pixel / width);
      left = Math.min(left, x); right = Math.max(right, x); top = Math.min(top, y); bottom = Math.max(bottom, y);
      const neighbors = [x ? pixel - 1 : -1, x + 1 < width ? pixel + 1 : -1, y ? pixel - width : -1, y + 1 < height ? pixel + width : -1];
      for (const neighbor of neighbors) if (neighbor >= 0 && !visited[neighbor] && dark(neighbor)) { visited[neighbor] = 1; queue[write++] = neighbor; }
    }
    if (write >= 10) found.push({ left, top, width: right - left + 1, height: bottom - top + 1, pixels: write });
  }
  return found;
}

export function detectDevice(rgb, width, height, options = {}) {
  const threshold = options.darkThreshold ?? 145;
  const all = components(rgb, width, height, threshold);
  const large = all.filter(c => c.width >= width * 0.15 && c.height >= height * 0.3 && c.pixels >= 350)
    .sort((a, b) => b.width * b.height - a.width * a.height);
  if (!large.length) throw new Error('No convincing outer hardware rim detected. Supply crop.bounds after reviewing the real source; do not substitute a screen image.');
  let bounds = { ...large[0] };
  const merged = [large[0]];
  // Merge a detached second half only when it is almost vertically aligned.
  for (const candidate of large.slice(1)) {
    const overlapY = Math.max(0, Math.min(bounds.top + bounds.height, candidate.top + candidate.height) - Math.max(bounds.top, candidate.top));
    const gapX = Math.max(0, candidate.left - bounds.left - bounds.width, bounds.left - candidate.left - candidate.width);
    if (overlapY / Math.min(bounds.height, candidate.height) > 0.8 && gapX < Math.min(bounds.height, candidate.height) * 0.09) { bounds = union(bounds, candidate); merged.push(candidate); }
  }
  // Physical buttons may be detached by one or two background pixels in JPEG.
  const reach = options.buttonReach ?? Math.max(7, Math.round(Math.min(bounds.width, bounds.height) * 0.02));
  const original = { ...bounds };
  for (const candidate of all) {
    const gapX = Math.max(0, candidate.left - original.left - original.width, original.left - candidate.left - candidate.width);
    const gapY = Math.max(0, candidate.top - original.top - original.height, original.top - candidate.top - candidate.height);
    const verticalOverlap = Math.min(original.top + original.height, candidate.top + candidate.height) - Math.max(original.top, candidate.top);
    const horizontalOverlap = Math.min(original.left + original.width, candidate.left + candidate.width) - Math.max(original.left, candidate.left);
    if ((gapX <= reach && verticalOverlap > 0 && candidate.width < original.width * 0.15) ||
        (gapY <= reach && horizontalOverlap > 0 && candidate.height < original.height * 0.1)) bounds = union(bounds, candidate);
  }
  delete bounds.pixels;
  return { bounds, threshold, seedCandidates: large.slice(0, 8), mergedSeeds: merged.length };
}

function addMargin(bounds, width, height, margin) {
  const left = Math.max(0, bounds.left - margin), top = Math.max(0, bounds.top - margin);
  return { left, top, width: Math.min(width, bounds.left + bounds.width + margin) - left, height: Math.min(height, bounds.top + bounds.height + margin) - top };
}

function validateBounds(bounds, width, height) {
  for (const key of ['left', 'top', 'width', 'height']) if (!Number.isInteger(bounds[key])) throw new Error(`crop.bounds.${key} must be an integer`);
  if (bounds.left < 0 || bounds.top < 0 || bounds.width <= 0 || bounds.height <= 0 || bounds.left + bounds.width > width || bounds.top + bounds.height > height) throw new Error('Crop bounds exceed the source image.');
}

function maskEdgeWhite(rgb, width, height, options) {
  const rgba = Buffer.alloc(width * height * 4), mask = new Uint8Array(width * height), queue = new Int32Array(width * height);
  for (let index = 0; index < width * height; index++) { rgb.copy(rgba, index * 4, index * 3, index * 3 + 3); rgba[index * 4 + 3] = 255; }
  if (!options.maskOuterWhite) return { rgba, maskedPixels: 0 };
  const threshold = options.whiteThreshold ?? 247, chroma = options.whiteChroma ?? 8;
  const white = index => { const o = index * 3, low = Math.min(rgb[o], rgb[o+1], rgb[o+2]), high = Math.max(rgb[o], rgb[o+1], rgb[o+2]); return low >= threshold && high - low <= chroma; };
  let read = 0, write = 0;
  const add = index => { if (!mask[index] && white(index)) { mask[index] = 1; queue[write++] = index; } };
  for (let x = 0; x < width; x++) { add(x); add((height - 1) * width + x); }
  for (let y = 0; y < height; y++) { add(y * width); add(y * width + width - 1); }
  while (read < write) {
    const pixel = queue[read++], x = pixel % width, y = Math.floor(pixel / width);
    if (x) add(pixel - 1); if (x + 1 < width) add(pixel + 1); if (y) add(pixel - width); if (y + 1 < height) add(pixel + width);
  }
  for (let index = 0; index < mask.length; index++) if (mask[index]) rgba[index * 4 + 3] = 0;
  return { rgba, maskedPixels: write };
}

export async function cropDevice(input, output, options = {}) {
  const sourceBytes = await readFile(input), metadata = await sharp(sourceBytes).metadata();
  if (metadata.orientation && metadata.orientation !== 1) throw new Error('Rotated EXIF input requires a fresh upright Device Hub capture.');
  const { data: sourceRgb, info } = await sharp(sourceBytes).toColourspace('srgb').removeAlpha().raw().toBuffer({ resolveWithObject: true });
  const detection = options.bounds ? { bounds: options.bounds, manual: true } : detectDevice(sourceRgb, info.width, info.height, options);
  validateBounds(detection.bounds, info.width, info.height);
  const bounds = addMargin(detection.bounds, info.width, info.height, options.margin ?? 5);
  const croppedRgb = await sharp(sourceRgb, { raw: info }).extract(bounds).raw().toBuffer();
  const { rgba, maskedPixels } = maskEdgeWhite(croppedRgb, bounds.width, bounds.height, options);
  // All RGB samples, including hidden background samples, remain source-identical.
  for (let index = 0; index < bounds.width * bounds.height; index++) for (let channel = 0; channel < 3; channel++)
    if (rgba[index * 4 + channel] !== croppedRgb[index * 3 + channel]) throw new Error('Source-pixel fidelity audit failed.');
  if (maskedPixels > bounds.width * bounds.height * 0.45) throw new Error('Outer mask removed over 45% of crop; review rim detection and mask threshold.');
  const png = await sharp(rgba, { raw: { width: bounds.width, height: bounds.height, channels: 4 } }).png().toBuffer();
  await mkdir(path.dirname(output), { recursive: true });
  await writeFile(output, png);
  const provenance = {
    cropVersion, captureOrigin: 'native-device-hub-window', source: path.resolve(input), sourceSha256: sha256(sourceBytes),
    sourceFormat: metadata.format, sourceWidth: info.width, sourceHeight: info.height,
    crop: bounds, detectedHardwareBounds: detection.bounds, detection, options,
    operations: ['integer-coordinate crop', ...(options.maskOuterWhite ? ['edge-connected near-white background alpha mask'] : [])],
    rgbPixelsSourceIdentical: true, maskedPixels, cropSha256: sha256(png), output: path.resolve(output),
  };
  await writeFile(output.replace(/\.png$/i, '') + '.provenance.json', JSON.stringify(provenance, null, 2) + '\n');
  return provenance;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const cli = args();
  if (!cli.input || !cli.output) { console.log('Usage: node scripts/crop.mjs --input raw/Duo/en-US/01-chat.jpg --output crops/Duo/en-US/01-chat.png [--bounds x,y,width,height] [--no-mask] [--margin 5]'); process.exitCode = 1; }
  else {
    const options = { margin: Number(cli.margin ?? 5), maskOuterWhite: !cli['no-mask'], whiteThreshold: Number(cli['white-threshold'] ?? 247) };
    if (cli.bounds) { const [left, top, width, height] = cli.bounds.split(',').map(Number); options.bounds = { left, top, width, height }; }
    console.log(JSON.stringify(await cropDevice(path.resolve(cli.input), path.resolve(cli.output), options), null, 2));
  }
}
