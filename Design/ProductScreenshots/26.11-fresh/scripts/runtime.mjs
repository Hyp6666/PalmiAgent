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
  Duo: { width: 2853, height: 2007, headlineSize: 122, minHeadlineSize: 94, maxHeadlineLines: 2, top: 45, gap: 25, bottom: 22, side: 25 },
  DI: { width: 1206, height: 2622, headlineSize: 104, minHeadlineSize: 84, maxHeadlineLines: 2, top: 52, gap: 28, bottom: 25, side: 18 },
  iPad: { width: 2752, height: 2064, headlineSize: 122, minHeadlineSize: 94, maxHeadlineLines: 2, top: 47, gap: 24, bottom: 24, side: 25 },
});

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
