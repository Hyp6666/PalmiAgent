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
