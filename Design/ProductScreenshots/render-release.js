#!/usr/bin/env node
// Render the 26.10 screenshots in an isolated, headless browser.
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require('playwright');

const repo = path.resolve(__dirname, '../..');
const output = path.join(repo, 'Screenshots/AppStore/26.10');
const kept = [
  ['01-Real-Agent.png', '01-真正的Agent.png', '01-Real-Agent.png'],
  ['02-Playable-Game.png', '02-一句话生成游戏.png', '05-Playable-Game.png'],
  ['03-Multi-Agent.png', '03-多智能体协作.png', '06-Multi-Agent.png'],
  ['04-Multimodal.png', '04-多模态理解.png', '07-Multimodal.png'],
  ['07-OpenAI-Compatible.png', '07-OpenAI兼容.png', '09-Model-Protocols.png'],
  ['09-Skills.png', '09-技能扩展.png', '10-Skills.png']
];
const added = [
  ['bionic', '02-Bionic-Mode.png'],
  ['details', '03-Conversation-Details.png'],
  ['reasoning', '04-Execution-Timeline.png'],
  ['models', '08-Codex-OAuth.png']
];

async function render(page, template, params, width, height, destination) {
  await page.setViewportSize({ width, height });
  const url = pathToFileURL(path.join(__dirname, template));
  url.search = new URLSearchParams(params).toString();
  await page.goto(url.href);
  await page.evaluate(async () => {
    await document.fonts.ready;
    await Promise.all([...document.images].map(image => image.decode()));
  });
  await page.screenshot({ path: destination });
  console.log(path.relative(repo, destination));
}

(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await browser.newPage({ deviceScaleFactor: 1 });
    for (const [lang, queryLang] of [['en', 'en'], ['zh-CN', 'zh']]) {
      const phoneOutput = path.join(output, 'iPhone', lang);
      const tabletOutput = path.join(output, 'iPad', lang);
      await fs.mkdir(phoneOutput, { recursive: true });
      await fs.mkdir(tabletOutput, { recursive: true });
      for (const [english, chinese, filename] of kept) {
        const source = lang === 'en'
          ? path.join(repo, 'Screenshots/Product', english)
          : path.join(repo, 'Screenshots/Product/zh-CN', chinese);
        await fs.copyFile(source, path.join(phoneOutput, filename));
      }
      for (const [topic, filename] of added) {
        await render(page, 'iphone.html', { lang: queryLang, page: topic }, 1284, 2778, path.join(phoneOutput, filename));
      }
      for (const [index, filename] of ['01-Bionic-Mode.png', '02-Task-Execution.png', '03-Models-and-Skills.png'].entries()) {
        await render(page, 'ipad-composite.html', { lang: queryLang, page: String(index + 1) }, 2732, 2048, path.join(tabletOutput, filename));
      }
      await fs.copyFile(path.join(repo, 'Screenshots/AppStore/iPad', lang, '01-Model-Setup.png'), path.join(tabletOutput, '04-Model-Setup.png'));
      const creativeOutput = path.join(output, 'Creative', lang);
      await fs.mkdir(creativeOutput, { recursive: true });
      await render(page, 'creative.html', { lang: queryLang, placement: 'header' }, 3840, 1646, path.join(creativeOutput, 'Header.png'));
      await render(page, 'creative.html', { lang: queryLang, placement: 'search' }, 3840, 2560, path.join(creativeOutput, 'Search.png'));
    }
    await page.close();
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
