# Fresh App Store screenshots

Only new **native Device Hub window captures** belong in this pipeline. Input content must show the actual outer device rim, physical buttons, and hinge where present. Raw simulator screen exports, synthesized frames, replacement UI, and previous task outputs are not accepted source material.

No package installation is needed. The scripts load the existing local Sharp and Playwright runtimes and launch an existing Chromium executable only to render local artifact HTML. `SCREENSHOT_NODE_MODULES` and `SCREENSHOT_CHROME` can point to other existing runtimes.

## Capture and register

Save the original captured bytes under `raw/{device}/{locale}/{nn-topic}.jpg`. Device Hub captures may contain JPEG bytes despite a misleading `.png` source filename; decoding and provenance use the real file format, not the extension. Device names are `Duo`, `DI`, and `iPad`.

Run from the repository root:

```sh
node Design/ProductScreenshots/26.11-fresh/scripts/register.mjs \
  --device Duo --locale en-US --id 01-chat \
  --source raw/Duo/en-US/01-chat.jpg \
  --headline 'Ideas become real.'

node Design/ProductScreenshots/26.11-fresh/scripts/render.mjs

node Design/ProductScreenshots/26.11-fresh/scripts/contact-sheets.mjs

node Design/ProductScreenshots/26.11-fresh/scripts/verify.mjs
```

The entry list starts empty on purpose. Register actual scenes after capture rather than freezing a feature list in advance. The target is nine screenshots per device/locale. Missing registered source files are reported and skipped; use `--strict` to fail on missing sources. Use `--device Duo`, `--locale en-US`, or `--id 01-chat` for incremental selections. `--force` bypasses unchanged-source caching.

The independent `verify.mjs` reopens the saved files, checks source/crop/final hashes, compares every saved crop RGB sample to the original source, verifies output format and layout constraints, and rejects repeated source images within a device/locale group. Run `verify.mjs --complete` at the end to require all nine distinct images in every expected device/locale group.

## Inspect the crop first

```sh
node Design/ProductScreenshots/26.11-fresh/scripts/crop.mjs \
  --input Design/ProductScreenshots/26.11-fresh/raw/Duo/en-US/01-chat.jpg \
  --output Design/ProductScreenshots/26.11-fresh/crops/Duo/en-US/01-chat.png
```

Detection finds a large connected dark hardware rim, joins aligned foldable halves when necessary, and includes nearby detached physical buttons. A five-pixel margin remains. This is a heuristic and needs a visual check against the source. If the capture has extra dark window chrome, use an inspected integer rectangle with `--bounds x,y,width,height`, or store `{ "crop": { "bounds": { "left": 0, "top": 0, "width": 100, "height": 100 } } }` on that specific manifest entry. Those example coordinates are schema documentation, not source measurements.

The optional outer-background mask only makes edge-connected near-white pixels transparent; it never replaces RGB samples. The crop audit checks all decoded RGB samples against the original source crop. Disable the mask with `--no-mask` for the crop tool or `"maskOuterWhite": false` in an entry when the actual background or hardware makes it unsuitable. Review bright hardware carefully before accepting any mask. No screen clipping, color adjustment, retouching, rotation, fabricated hardware, or shadow is applied.

## Manifest and output

`config/manifest.json` is a flexible list of `{ id, device, locale, source, headline }`. Sources resolve relative to this task directory; `outputRoot` resolves relative to the manifest file. A headline can contain one explicit newline. The only design variation is the restrained `background` value: `ice` (default), `white`, or `lilac`.

Accepted final PNGs are written to:

| Device | Output size | Folder |
| --- | --- | --- |
| Duo | 2853 × 2007 | `Screenshots/AppStore/26.11-fresh/Duo/{locale}` |
| DI | 1206 × 2622 | `Screenshots/AppStore/26.11-fresh/DI/{locale}` |
| iPad | 2752 × 2064 | `Screenshots/AppStore/26.11-fresh/iPad/{locale}` |

Every final PNG is checked for exact dimensions, RGB/sRGB color, and absence of alpha. The headline must fit in one or two lines. The actual device is centered, upright, wholly contained, and fills at least 75% of canvas area. Both actual bounding-box area coverage and dimensional coverage are recorded so those measurements are never conflated. A long headline is reduced within the allowed size range; if the complete hardware still cannot meet coverage, the renderer fails with a request to shorten the headline. There is no artificial cropping to inflate coverage.

`provenance/` records source SHA-256, actual source encoding, integer bounds, crop options, retained RGB fidelity, complete layout geometry, final SHA-256, and acceptance checks. `crops/` holds source-derived device PNGs. `rendered/` holds exact local HTML. `proofs/render-report.json` records completed, missing, failed, and per-group counts; `proofs/contact-sheets/` provides a review grid. None of these sidecars are mixed into the App Store upload folder.

Review each source/crop pair and the contact sheet before upload, including full rim/buttons/hinge, unaltered playable 2048 in the chat scene, native palette, headline clarity, and complete UI. This pipeline composes captures; it does not create or modify the app's demo content.
