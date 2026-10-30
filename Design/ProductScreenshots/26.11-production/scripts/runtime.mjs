import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const bundledModules = path.join(homedir(), '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules');

function load(name, extra = []) {
  const candidates = [name, ...(process.env.SCREENSHOT_NODE_MODULES ? [path.join(process.env.SCREENSHOT_NODE_MODULES, name)] : []), path.join(bundledModules, name), ...extra];
  for (const candidate of candidates) {
    try { return require(candidate); } catch (error) {
      if (error.code !== 'MODULE_NOT_FOUND') throw error;
    }
  }
  throw new Error(`Cannot load ${name}. Set SCREENSHOT_NODE_MODULES to an existing node_modules directory; this script never installs packages.`);
}

export const sharp = load('sharp');
export const playwright = load('playwright', [path.join(homedir(), '.codex/skills/develop-web-game/node_modules/playwright')]);
export const taskRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export const devices = Object.freeze({
  Duo: { width: 2853, height: 2007, headlineSize: 122, minHeadlineSize: 110, maxHeadlineLines: 2, top: 40, gap: 24, bottom: 22, side: 34 },
  DI: { width: 1206, height: 2622, headlineSize: 102, minHeadlineSize: 92, maxHeadlineLines: 2, top: 40, gap: 24, bottom: 22, side: 15 },
  iPad: { width: 2752, height: 2064, headlineSize: 122, minHeadlineSize: 110, maxHeadlineLines: 2, top: 42, gap: 24, bottom: 24, side: 33 },
});

export function deviceSpec(entry) {
  if (!devices[entry.device]) throw new Error('Device must be DI, Duo, or iPad.');
  const orientation = entry.orientation || (entry.device === 'DI' ? 'portrait' : 'landscape');
  let result = { ...devices[entry.device] };
  if (entry.device === 'Duo') {
    if (orientation === 'folded') result = { ...result, width: 1398, height: 2034, headlineSize: 108, minHeadlineSize: 94, top: 32, gap: 22, bottom: 20, side: 17 };
    else if (orientation === 'unfolded-portrait') result = { ...result, width: 2007, height: 2853, headlineSize: 122, minHeadlineSize: 110, side: 24 };
    else if (!['landscape', 'unfolded-landscape'].includes(orientation)) throw new Error('Duo orientation must be landscape, unfolded-landscape, unfolded-portrait, or folded.');
  } else if (orientation !== (entry.device === 'DI' ? 'portrait' : 'landscape')) throw new Error('Only DI portrait and iPad landscape are supported.');
  const layout = entry.layout || {};
  if (Object.keys(layout).some(key => !['headlineSize', 'minHeadlineSize', 'maxHeadlineLines', 'top', 'gap', 'bottom', 'side'].includes(key))) throw new Error('layout may adjust spacing and typography, never canvas dimensions.');
  result = { ...result, ...layout, orientation };
  if (Object.values(result).some(value => typeof value === 'number' && (!Number.isFinite(value) || value < 0)) || result.minHeadlineSize > result.headlineSize || result.maxHeadlineLines < 1 || result.maxHeadlineLines > 2) throw new Error('Invalid layout limits.');
  return result;
}

export async function launchBrowser() {
  const candidates = [process.env.SCREENSHOT_CHROME, playwright.chromium.executablePath(), '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].filter(Boolean);
  const executablePath = candidates.find(existsSync);
  if (!executablePath) throw new Error('No existing Chromium executable found. Set SCREENSHOT_CHROME; no browser download is attempted.');
  return playwright.chromium.launch({ executablePath, headless: true });
}

export function args(argv = process.argv.slice(2)) {
  const result = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith('--')) throw new Error(`Unexpected argument: ${argv[i]}`);
    const name = argv[i].slice(2);
    result[name] = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
  }
  return result;
}

export function safeSegment(value, label) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(value)) throw new Error(`Invalid ${label}: ${value}`);
  return value;
}

export function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
}
