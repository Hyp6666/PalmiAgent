# Palmi 26.11 — production visual direction

Prepared 2026-10-30. Scope: executable visual guidance only; no app changes, simulator operations, account access, or fabricated UI. Inspected existing `26.11-fresh` template, manifest, crop provenance and Duo contact sheet, and the previous screenshot README/creative direction. No applicable AGENTS.md was found in the repository or its inspected ancestor locations. Applied the local frontend-design skill for deliberate typography, composition, restraint and reproducibility.

## Decision

Use **warm porcelain, pale mint, dark forest typography, and a single upright real device**. The distinguishing feature is the combination of softly editorial headline typography and an unusually large, complete product surface. Keep every image quiet: only a headline and the real captured product. No badges, subtitles, tiny feature labels, page numbers, floating interface cards, backdrop illustrations, orbit lines, or decorative 3D objects.

The existing `26.11-fresh` direction is a good structural starting point. Its Duo proof is clean and complete, but the empty conversation is weak as a lead image. Prefer a real completed useful interaction or actual working interface in slot 1. Do not seed or paint fake results to achieve this. The old iPad composite and English titles over Chinese UI must not be reused.

## Output families and orientation

Apple's current specification explicitly lists Duo, including separate inner/outer screen dimensions. These are not inferred or hypothetical: [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

| Family/state | Preferred output | Use |
|---|---:|---|
| Large Dynamic Island iPhone | 1320 × 2868 portrait, or another accepted size matching the captured target | Default portrait narrative; use the actual selected large-display simulator |
| Medium Dynamic Island iPhone, if that is the available target | 1206 × 2622 portrait | Existing runtime uses this; do not label it a large-display asset |
| Duo, unfolded inner display | 2853 × 2007 landscape | Main Duo sequence, real wide app layout |
| Duo, folded outer display | 1398 × 2034 portrait | One or two scenes when a real folded capture is available |
| iPad Pro 13-inch M4 | 2752 × 2064 landscape | Actual iPad scene and hardware; never a phone image in a tablet frame |

Ship separate `zh-Hans` and `en-US` groups. Target 9 screenshots in each of the three device families (54 total), never more than 10 in a device/language set. Duo state is metadata within its device family, not a reason to double its count. Native app interface language, keyboard and user-visible sample content should match the locale where the app supports it.

Apple recommends genuine app UI, up to ten screenshots, and prioritizing the app's essence in the first one to three images: [Creating your product page](https://developer.apple.com/app-store/product-page/). Therefore put completed work or a strong capability first; settings and empty states belong late, if used at all.

## Color system

Use one background recipe across the release, with slight intentional variation in the final lower-edge color. Avoid a different decorative style on every screenshot.

```css
--ink: #153B2B;
--paper: #FFFDF8;
--mint: #DDEDE3;
background:
  radial-gradient(ellipse at 15% 0%, #fff8ec 0%, transparent 56%),
  linear-gradient(160deg, #fffdf8 3%, #f8fbf7 52%, #ddeee4 100%);
```

Sequence rhythm: mint for slots 1–3; `#E5ECEF` blue-grey lower edge for 4–6; `#EAE6DC` warm stone lower edge for 7–9. All use the same warm-white upper field and forest headline. Colors must remain background tints, not saturated halos. Do not tint, blur, brighten or otherwise recolor screenshot pixels.

If one true dark-mode capture is available and valuable, keep this same light background: the real dark device becomes the variation. A dark poster variant is optional, not needed for visual variety.

## Typography

Recommended production face: **Source Serif 4, 650** for English; **Noto Serif SC, 600** for Chinese, both already bundled under `Design/ProductScreenshots/fonts/`. These tie to the project's prior editorial creative assets and distinguish the outer headline from the app's system UI. Use upright roman, never italic. Use one face per locale consistently. Do not mix serif and sans-serif headlines across pages.

If the first visual proof shows the serif headline competing with the actual app, the safe alternate is the existing system headline face across the entire batch, weight 650 English / 600 Chinese. Pick one direction before batch rendering; do not switch per asset.

| Canvas | Headline top | Size, start → minimum | Line height | Preferred lines | Gap below text | Bottom clear space |
|---|---:|---:|---:|---:|---:|---:|
| DI 1320 × 2868 | 44 px | 110 → 98 px | 1.08 | 1–2 | 26 px | 24 px |
| DI 1206 × 2622 | 40 px | 102 → 92 px | 1.08 | 1–2 | 24 px | 22 px |
| Duo inner 2853 × 2007 | 40 px | 122 → 110 px | 1.08 | 1 | 24 px | 22 px |
| Duo outer 1398 × 2034 | 32 px | 108 → 94 px | 1.08 | 1 | 22 px | 20 px |
| iPad 2752 × 2064 | 42 px | 122 → 110 px | 1.08 | 1 | 24 px | 24 px |

Headline box: x = 4% W, width = 92% W, center aligned. Letter spacing English `-0.025em`, Chinese `0`. A Chinese heading should normally fit within 7–10 characters (Latin AI can be included); English 3–5 compact words. Exact language equivalence matters more than equal character count. No automatic arbitrary rephrasing by the renderer. If too long, edit the copy rather than shrinking it into a subtitle.

The user's 1–2-line allowance is an upper limit, not a requirement to use two lines. On wide Duo/iPad canvases, two 122 px lines typically consume enough height to break 75% occupancy. Default to one line there. Allow two only after the actual image geometry passes the occupancy check without overlap or crop.

## Geometry: measure pixels, not impressions

Center the entire captured device horizontally. No rotation, skew, perspective, duplicated screen fragments or partially off-canvas phone. Preserve the actual hardware edge, camera/island, physical buttons and hinge. A raw simulator screen without hardware can be used honestly as a raw screen; do not draw a fictional device rim around it. If DeviceHub supplies real hardware, preserve that captured hardware.

Given the tightly cropped real source dimensions `sw × sh`, canvas `W × H`, measured headline bottom `B`, gap `G`, bottom margin `M`, side margin `S`:

```js
const availableH = H - (B + G) - M;
const scale = Math.min((W - 2*S) / sw, availableH / sh);
const dw = sw * scale;
const dh = sh * scale;
const left = (W - dw) / 2;
const top = B + G + (availableH - dh) / 2;
const deviceAreaFraction = (dw * dh) / (W * H);
if (deviceAreaFraction < 0.75) throw new Error('Shorten headline or select a matching canvas; do not crop or distort the device.');
```

Set `S = 0.012 × W` for an initial fit. Aim for 77–81% device-bounding-box area, which leaves a small margin above the 75% minimum. Height fraction alone is not area fraction: a device at 75% height can occupy only 56% of the area when both dimensions scale proportionally.

Record both device bounding-box occupancy and, when measurable, actual app-screen occupancy. The existing Duo proof reports 77.55% *device bounding-box* occupancy; this does not prove that 77.55% of the canvas is app UI. Do not count transparent crop padding or a large enclosing composition box as screenshot content. If the task's 75% criterion is specifically screen pixels rather than the complete native device capture, use the measured screen rectangle/mask for the threshold and increase scale or simplify the title accordingly.

The outer white removal must be strictly edge-connected background masking. Preserve every RGB pixel of the real screen and hardware. Avoid treating the white interior UI as removable background. Five-pixel crop padding is enough; arbitrary empty padding must not inflate occupancy calculations. Render resampling is permitted; stretching axes independently is not.

## Duo: folded and unfolded fidelity

Use at most one device per poster. Capture each state independently from DeviceHub. Do not infer folded geometry from half of an unfolded capture, draw a seam, warp a screenshot into a fold, move camera elements, mirror a half, or call a resized iPad screenshot Duo.

Suggested nine-shot mix: seven inner-display scenes and two outer-display scenes, only if two meaningful genuine outer-display captures can be obtained. Put an inner-display scene first to establish the wide experience. Place outer-display scenes near slots 4 and 8 to add honest pacing. The content may differ by state, but each headline must match the visible feature.

Export inner scenes at the accepted inner-display size and outer scenes at the accepted outer-display size. This preserves occupancy and makes the actual device state legible. Avoid combining folded and unfolded images into a single split poster: it makes both interfaces smaller and introduces ambiguous timing. If a delivery pipeline insists on one size for the whole Duo group, keep all nine as inner-display captures and provide outer-display proofs separately until the upload schema is confirmed; do not stretch outer captures into landscape.

## iPad fidelity

Capture the real iPad Pro M4 app at its normal landscape layout. Real sidebars, multi-column behavior, popovers and sheet geometry carry the tablet experience. Preserve those differences. A modal may be useful, but do not use nine nearly identical modal screenshots. Never reuse the old `ipad-composite.html` phone-pair artwork, translate only the poster heading over a Chinese screenshot, or place an iPhone capture in an iPad-shaped frame.

For each iPad raw asset, provenance should include actual simulator/device name, source dimensions, locale and capture timestamp. A local PNG file name alone is not evidence of a true iPad capture.

## Scene selection and copy discipline

The nine positions should tell a sequence of visibly supported benefits rather than repeat empty UI. Suggested slots are selection prompts, not claims of completed captures:

| Slot | Look for a real scene showing | Short headline direction, if supported |
|---|---|---|
| 1 | Best completed task / active workspace | 你的 AI 工作空间 / Your AI workspace |
| 2 | Useful task execution and visible outcome | 把想法变成行动 / Ideas into action |
| 3 | Execution details or reasoning timeline | 每一步，都清楚 / Follow every step |
| 4 | Skills collection or a skill in use | 为你所用的技能 / Skills for your work |
| 5 | Files with useful content or interaction | 文件，就在手边 / Files within reach |
| 6 | In-app browsing with actual page content | 探索，不必切换 / Explore in one place |
| 7 | Image or multimodal conversation, if available | 看见更多可能 / See more possibilities |
| 8 | Real bionic/persona conversation, if available | 聊天，也有个性 / A little personality |
| 9 | Another distinct strong feature, or real dark mode | 根据最终真实画面写一句，不强凑功能 |

If a slot cannot be captured truthfully, replace it with another distinct available scene. The 9-image target does not justify duplicate shots with different headlines. Avoid model setup screens if the prohibited names appear within the UI. The prohibition applies to the whole final poster: do not include **OpenAI** or **Anthropic** in headlines, visible app text, menus, account panels or generated content. Select a clean real state; do not retouch app labels to hide them.

## HTML/CSS implementation notes

Keep the existing isolated local HTML renderer and JSON manifest pattern. Each entry should carry `device`, `state`, `locale`, `headline`, `source`, `canvasWidth`, `canvasHeight`, source dimensions, crop rectangle and capture origin. Add state-aware Duo dimensions rather than overriding the entire group silently. Load local font files with `@font-face`, then wait for `document.fonts.ready` and `img.decode()` before geometry measurement or capture.

The actual DOM can remain two elements:

```html
<h1 id="headline">Localized headline</h1>
<img id="device" src="the-real-source-crop.png" alt="Real captured app interface">
```

```css
* { box-sizing: border-box; }
html, body { margin: 0; width: var(--w); height: var(--h); overflow: hidden; }
h1 { position: absolute; left: 4%; width: 92%; margin: 0;
  text-align: center; font-weight: 650; line-height: 1.08;
  letter-spacing: -.025em; color: #153b2b; white-space: pre-line; }
html:lang(zh-Hans) h1 { font-weight: 600; letter-spacing: 0; }
img { position: absolute; display: block; object-fit: contain; }
```

Do not add a synthetic bezel, CSS corner rounding to the screenshot, or a heavy box shadow. The real captured hardware already supplies contrast. If an actual source includes hardware shadow, preserve it.

## Proof and acceptance

Before full batch rendering, render a three-device proof sheet using one representative real scene in each device family plus a second locale headline. Check at full size and at approximately 20–25% scale (store browsing scale). Freeze typography and color after that visual check.

For all delivered PNGs: accepted canvas dimensions, sRGB RGB with no alpha, one or two headline lines, no headline overflow, complete device, proportional scale, centered x coordinate, no headline/device collision, occupancy ≥75% under the explicitly reported metric, unique genuine source per distinct scene, language consistency, and visual inspection of forbidden names. Save raw image hash, integer crop rectangle, layout coordinates and output hash. Contact sheets are review artifacts, not upload assets.

Final visual review must compare each poster with its source: button edges, camera area, hinge, all app controls and screenshot text. Confirm actual iPad content instead of trusting filename. Count each of the six device/locale groups individually. A successful render is not evidence that all 54 requested images exist.

## Source notes

- [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications), accessed 2026-10-30: current sizes and no-alpha requirement. In particular, Duo inner 2853 × 2007 and outer 1398 × 2034 are explicitly documented.
- [Apple product-page guidance](https://developer.apple.com/app-store/product-page/), accessed 2026-10-30: captured app UI, up to ten screenshots, first images communicate essence, later images focus on a benefit.
- Local inspected references: `Design/ProductScreenshots/26.11-fresh/{DIRECTION.md,templates/store.html,scripts/runtime.mjs,scripts/render.mjs,config/manifest.json,proofs/render-report.json,proofs/contact-sheets/Duo--en-US.png}`; `Design/ProductScreenshots/{README.md,CREATIVE.md}`. Existing code uses a medium DI canvas (1206 × 2622), not the large DI canvas.
