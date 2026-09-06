async (page) => {
  const targets = [
    ["iphone", "zh", 1284, 2778, "Screenshots/Product/zh-CN/07-OpenAI兼容.png"],
    ["iphone", "en", 1284, 2778, "Screenshots/Product/07-OpenAI-Compatible.png"],
    ["ipad", "zh", 2732, 2048, "Screenshots/AppStore/iPad/zh-CN/01-Model-Setup.png"],
    ["ipad", "en", 2732, 2048, "Screenshots/AppStore/iPad/en/01-Model-Setup.png"]
  ];
  for (const [device, language, width, height, path] of targets) {
    await page.setViewportSize({ width, height });
    await page.goto(`http://127.0.0.1:8768/${device}.html?lang=${language}`);
    await page.evaluate(() => document.fonts.ready);
    await page.locator("#screen").evaluate(image => image.decode());
    await page.screenshot({ path });
  }
}
