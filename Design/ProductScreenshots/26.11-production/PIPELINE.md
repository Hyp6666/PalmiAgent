# Production screenshot pipeline

Run from this directory. The scripts use existing local `sharp`, Playwright and Chromium; they never install dependencies, navigate to websites, use browser accounts, or operate Device Hub. Chromium renders only an in-memory static HTML artwork in a temporary browser profile. If sandbox restrictions prevent Chromium from starting, run the same local render command with the execution tool's approved escalation. Registration, crop verification and contact sheets do not require Chromium.

## Register real captures

The capture operator owns `raw/`, `research/` and `STATE.md`. Save each complete native Device Hub window at:

```text
raw/{DI,Duo,iPad}/{en-US,zh-Hans}/{01-topic … 09-topic}.jpg
```

Actual image bytes determine the decoder; JPEG bytes are accepted regardless of a misleading filename suffix. Use a distinct real scene for each numbered slot. Do not register older release images, synthetic UI or placeholders. The initial production manifest deliberately contains `entries: []`.

```sh
node scripts/register.mjs --device Duo --locale en-US --id 01-workspace \
  --headline "Your AI workspace" --device-name "iPhone Duo" \
  --captured-at "2026-10-30T21:00:00+08:00"

node scripts/register.mjs --device Duo --locale zh-Hans --id 04-skills \
  --headline "为你所用的技能" --orientation folded --device-name "iPhone Duo"
```

The source defaults to the matching `raw/.../*.jpg`. Use `--source` to specify another real capture file. `--captured-at` records the actual capture time when known; `fileModifiedAt` is recorded separately and is never presented as capture time. `--device-name` should identify the actual selected target. The entry records decoded source format and dimensions.

Automatic cropping finds the real dark hardware rim and nearby physical buttons, with a five-pixel margin. Inspect every crop. If auto-detection is wrong, pass `--bounds left,top,width,height` measured in original source pixels, enclosing **all hardware**, before margin. Example:

```sh
node scripts/register.mjs --device DI --locale en-US --id 02-action \
  --headline "Ideas into action" --bounds 900,120,470,1010
```

The bounds above illustrate syntax only. Do not copy them onto an unrelated image. Optional `--no-mask` preserves the complete crop rectangle. The default removes only near-white background pixels reachable from the crop edge by changing alpha; every RGB sample remains source-identical. No screen recoloring, synthetic rim, shadow, corner rounding, perspective or UI retouching is applied.

## Render and inspect

```sh
node scripts/render.mjs --strict
node scripts/contact-sheets.mjs
node scripts/verify.mjs
node scripts/verify.mjs --complete
```

Render filters: `--device Duo`, `--locale en-US`, `--id 01-workspace`; `--force` bypasses the hash cache. `--strict` fails on missing files as well as rendering errors. `--manifest /absolute/path.json` is supported by register, render, contact sheets and verify; relative source paths always resolve from this production directory, and `outputRoot` resolves relative to the manifest file.

Each poster has exactly one centered upright real device and a one- or two-line headline. Wide canvases normally need one line to meet area coverage. The renderer tries the declared font-size range, then fails if the copy or device geometry cannot meet the constraints. Shorten the title or select the correct device orientation; do not crop or stretch the device to force a fit. Literal `\n` in `--headline` inserts an explicit newline. Subtitles and prohibited brand names in headlines are rejected.

System fonts, forest text `#153B2B`, warm-white upper background and pale mint lower background are shared across the release. Slots 4–6 use a subtle blue-grey lower tint; 7–9 use warm stone. These backgrounds never recolor the image. The template has no network assets.

| Device / entry.orientation | Output PNG |
| --- | --- |
| DI / `portrait` (default) | 1206 × 2622 |
| Duo / `landscape` or `unfolded-landscape` (default) | 2853 × 2007 |
| Duo / `folded` | 1398 × 2034 |
| Duo / `unfolded-portrait` | 2007 × 2853 |
| iPad / `landscape` (default) | 2752 × 2064 |

Do not set orientation based on desired composition: it must match the actual independently captured hardware state. Canvas dimensions cannot be overridden with `layout`. A genuine iPad capture remains necessary even when a phone crop could technically fit an iPad output.

## Files and acceptance

- `config/manifest.json`: source registry and exact final headline copy.
- `scripts/runtime.mjs`: local dependencies, supported device sizes and common helpers.
- `scripts/crop.mjs`: standalone auto/manual crop, edge background mask, source fidelity record.
- `scripts/register.mjs`: validates and adds or updates one real source entry.
- `scripts/render.mjs`: static HTML composition and RGB PNG export.
- `scripts/contact-sheets.mjs`: per-device, per-locale proof sheets; preserves aspect ratios when Duo orientations are mixed.
- `scripts/verify.mjs`: output audit and final six-group count checks.
- `templates/store.html`: two-element headline/device artwork with system typography.
- `crops/{device}/{locale}/{id}.png` and `.provenance.json`: integer crop and complete crop provenance.
- `rendered/{device}/{locale}/{id}.html`: exact static artwork with embedded real crop.
- `provenance/{device}/{locale}/{id}.json`: source/crop/output SHA-256, actual decoded dimensions, crop rectangle, scale, placement, measured headline lines and hardware occupancy.
- `proofs/render-report.json`, `verification-report.json`, `contact-sheets.json`, `contact-sheets/*.png`: review records. Render report covers the last selected render; contact sheets read all registered entries' saved provenance.
- `../../../../Screenshots/AppStore/26.11-production/{device}/{locale}/{id}.png` from the manifest directory: upload PNGs (repository root `Screenshots/AppStore/26.11-production/`).

`verify` checks exact source, crop and output hashes; decoded source-to-crop RGB equality for every pixel, including transparent ones; PNG format; sRGB, three channels and no alpha; orientation-specific canvas; one or two headline lines; proportional scale; horizontal centering; headline separation; complete saved crop and recorded hardware visibility; unique source hashes per group; and at least 75% canvas area occupied by the **hardware bounding box excluding crop padding**. It does not describe that metric as screen-pixel coverage.

`verify --complete` additionally requires all six device/locale groups to contain nine verified distinct scenes, numbered 01–09 exactly once, and rejects unregistered PNGs in upload folders. A partial batch can pass `verify` while it must fail `verify --complete`.

Final human visual review must compare each poster to its raw capture: complete screen, rim, camera/island, hinge and physical buttons; genuine correct device; matching UI language and sample content; distinct meaningful feature; and no prohibited company names in added promotional headings. Original app UI may retain provider and model names, as expressly authorized by the user. Geometry and pixel audits do not interpret UI meaning, so a successful script cannot replace this review.
