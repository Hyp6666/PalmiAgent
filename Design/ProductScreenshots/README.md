# Product screenshot templates

These templates preserve the original July 2026 product artwork: blue gradients, orbit lines, localized typography, translucent frames, and shadows. The iPad template rotates the supplied portrait-encoded landscape screenshot by −90° inside its frame. Both iPad artwork languages use the supplied Chinese app screenshot; their promotional headings are localized.

## Render

From the repository root, serve the templates:

```sh
python3 -m http.server 8768 --bind 127.0.0.1 --directory Design/ProductScreenshots
```

In another terminal, with Node.js and Chrome installed:

```sh
npx --yes --package @playwright/cli playwright-cli --session palmi-product open about:blank
npx --yes --package @playwright/cli playwright-cli --session palmi-product run-code "$(cat Design/ProductScreenshots/render.js)"
npx --yes --package @playwright/cli playwright-cli --session palmi-product close
```

The script renders the English and Chinese iPhone images at 1284 × 2778 and the two iPad images at 2732 × 2048. iPhone output replaces the existing README images. iPad output is under `Screenshots/AppStore/iPad/` for manual upload to App Store Connect.

Update titles and subtitles in `iphone.html` and `ipad.html`; replace screenshot inputs in `assets/`. Typography uses macOS system fonts, matching the original rendered artwork.

## 26.10 release artwork

`iphone.html?page=bionic|details|reasoning|models&lang=en|zh` adds four localized themes to the existing iPhone template. Their source screenshots are kept in `assets/26.10/` without changes to the app UI. The English and Chinese bionic screenshots intentionally show different characters.

`ipad-composite.html?page=1|2|3&lang=en|zh` places two real iPhone screenshots side by side on the same blue or light gradient. These compositions present feature combinations; they do not simulate an iPad interface. The existing native iPad setup screenshot is included as the fourth image.

`creative.html?placement=header|search&lang=en|zh` renders the separate App Store header and search artwork. Both reuse the supplied reasoning and bionic screenshots.

Render all release artwork with Playwright available to Node.js:

```sh
NODE_PATH=/Users/hongyupeng/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules node Design/ProductScreenshots/render-release.js
```

The renderer starts a separate headless Chrome process and reads the local HTML files. It writes to `Screenshots/AppStore/26.10/`:

- `iPhone/en/` and `iPhone/zh-CN/`: 10 images each, at 1284 × 2778. Upload in filename order.
- `iPad/en/` and `iPad/zh-CN/`: 4 images each, at 2732 × 2048.
- `Creative/en/` and `Creative/zh-CN/`: `Header.png` at 3840 × 1646 and `Search.png` at 3840 × 2560.

The 10-image iPhone selection retains Agent tasks, playable games, multi-agent work, multimodal input, model protocols, and skills. Bionic conversations, conversation details, execution timelines, and Codex OAuth replace the older OCR, thinking-effort, and model-plan artwork. Original images in `Screenshots/Product/` remain available.

Dimensions were checked against Apple's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications) and [asset best practices](https://developer.apple.com/app-store/asset-best-practices/).
