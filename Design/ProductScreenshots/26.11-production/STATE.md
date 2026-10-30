# Palmi 26.11 App Store production state

Authorized scope: replace screenshots and edit/save promotional text, description, and What's New only, for en-US and zh-Hans. Do not submit for review. Do not modify app source or backend demo data. Do not record credentials in artifacts.

## Device identity (verified against Device Hub and XcodeBuildMCP)
| Order | Device | Runtime | UDID | State at start |
|---|---|---|---|---|
| 1 | iPhone 18 Pro | iOS 27.2 | 99F459A7-5B0D-45B3-97C2-259E06FF5A0B | Shutdown |
| 2 | iPhone Duo | iOS 27.2.iPhone19.4 | 6A321F29-6FD9-45B1-B6F7-062096BDDEF1 | Booted, real Chinese 2048 conversation |
| 3 | iPad Pro 13-inch (M4) | iOS 27.0 | 85116E22-5725-4A59-8693-C4605BD06FEF | Shutdown |

App: com.hongyupeng.PalmiAgent, local marketing version 26.11 build 5.

## Workflow
1. Read feature evidence; verify official specs and existing authorized Connect fields.
2. One device running at a time, in order above. Retain real conversations; use fresh locale-specific conversations. Capture clean structural views in both languages before generating demo content. Keep each locale's conversation history separate, never fabricate replies or alter databases.
3. Capture real native Device Hub window; retain raw images and crop provenance. Use only real screen/hardware, clean CSS background, one main headline.
4. Target nine distinct scenes per device/locale, adapt scenes to verified capabilities and quality. Use one selected model, medium reasoning; short prompts, no unnecessary repeated generation.
5. Validate dimensions, opacity, readability, locale, device identity, source fidelity, and screenshot order; upload and save each locale/device group; verify persisted counts and fields.
6. Build reusable skill only after main task completion, from actual observed workflow.

## Output targets
DI: 1206×2622. Duo: 2853×2007 unfolded or 1398×2034 folded, according to actual scene. iPad: 2752×2064 landscape. Verify in live Connect before upload.

## Progress
- 2026-10-30: identities and English Connect screenshot slots verified. Duo empty 0/10. Research delegated. No Connect edits yet.

- 21:26 local: DI installed and launched from verified Duo app bundle 26.11 build 5 (no rebuild); onboarding English completed; official API preset selected; user-authorized key entered masked; Fetch Models clicked; Mac locked before result could be observed. Do not repeat credential entry without checking UI. No Connect edits or production screenshots yet.

## Resume checkpoint — blocked by locked Mac

- Native computer-use twice reports: Mac is locked; automatic unlock failed. User must manually unlock before Device Hub or Connect work can resume. Do not attempt OS credential recovery or unlock bypass.
- DI remains the only running simulator. Duo shut down normally via Device Hub. DI installed from Duo native bundle verified 26.11/build5; initial display hang recovered by restarting only that existing simulator.
- Current DI UI: English first-run model management → Add Model → official provider preset, authorized temporary key entered masked, Fetch Models clicked. Result not observed because lock occurred. Never re-enter or expose key until checking field/state; no secrets in this folder.
- CUA native app bindings: hub=com.apple.dt.Devices, chrome=com.google.Chrome. Chrome existing App Store Connect tab remains 26.11 en-US; no fields modified. Native screenshot coordinates are image pixels, not half-retina points. Device Hub app UI requires post-action AX observation and a later screenshot to avoid transient animation frames. Drag scrolls inside device; native wheel scroll had no effect.
- XcodeBuildMCP default simulator is DI UDID. snapshot_ui returned No translation object errors on DI, despite visible Device Hub interaction; native CUA worked. Do not mistake UI helper failure for an app failure.
- Production assets: manifest entries empty; raw empty. No final screenshot exists. Old 26.11-fresh directory was pre-existing and remains untouched; do not count its two old overview images as this task completion.
- Metadata: metadata/store-copy.json plus six TXT files independently reviewed; exact-match, limits and prohibited-added-copy checks passed (zh 79/841/321, en 154/2585/943).
- Renderer: scripts + template + PIPELINE.md ready. Isolated old-Duo renderer smoke test passed in /private/tmp/palmi-production-renderer-lt3mozsn; old image not registered in production. Require final visual review of real captures.
- Remaining: model selection (specified sol, medium effort), vision and tool approval settings, 54 real localized captures, render/verify, six upload groups and both localized field saves, persistence verification. Only then create generalized reusable skill under ~/.codex/skills from actual observed results.

## Resume checkpoint 2 — 2026-10-30 22:48 Asia/Shanghai

- User changed authorized provider to DeepSeek, requested Flash. Do not reuse earlier provider for remaining demo requests. Keep keys out of all files.
- COMPLETE: both locales all three target text fields saved in Connect. Reload completed, default en-US reread matched all three exact; switched zh-Hans and reread matched exact. Proofs en-US-fields-saved.json and zh-Hans-fields-saved.json. Original values backed up in *-fields-before.json. Screenshots unchanged; no other Connect fields edited.
- Native CUA AX now exposes simulator controls after clean restart in original Device Hub window, much faster than coordinate-only workflow. New active DI remains correct UDID. Onboarding English, data notice accepted after source check proved Allow only navigates to modelConfiguration (no transmission/permissions). Auto-review initially rejected; evidence-based same-action retry accepted. No workaround.
- Current DI: Add Model form, DeepSeek preset URL https://api.deepseek.com, key populated; Fetch returned DeepSeek-V4.1-Flash (actual id deepseek-flash) and DeepSeek-V4-Pro. Chose Flash only. Text/vision checks both HTTP401 Authentication Fails (governor). Returned to Add Model. UI reveal/compare/hide verified exact key equality without emitting or saving plaintext. iOS Save Password prompt dismissed with Later.
- Pending diagnostic: normal UI change URL to full official https://api.deepseek.com/chat/completions, then import Flash and one text test. Endpoint write attempt was blocked BEFORE execution by Mac lock, so assume URL still root until verified. Agent report research/api-diagnostic.md says root and v1 both official; no proven fix. Do not change app code, OS proxy or security settings.
- Mac locked again, auto-unlock failed. Temporary bounded caffeinate process started to prevent idle sleep after manual unlock; does not unlock or change credentials. Clean it up at task completion.
- CUA helpers: fs imported; sharp via createRequire(path)(absolute package directory), not lib/index.js (current sharp uses dist/index.cjs). inspectHub crops display-only view from full native bytes at left1760 top140 width830 height1650 then resizes to1200h. tapHub(x,y) maps this view back with rawX=1760+1.375*x, rawY=140+1.375*y. Original window3840×1916. Always take fresh whole screenshot if window/zoom moves. Full saved raw must be uncropped original bytes.
- CUA Chrome uses native app; getAXState({disableDiffing:true}) renumbers indexes. Read field values with regex ending at next indexed line, NOT multiline $ (which prematurely ends at first paragraph). setValue works for web textarea and reliably handles Chinese; paste did not populate Chinese. Do not reload immediately after save; wait for completion before next command.
- Production raw/manifest still empty. Need 54 real screenshots and all image uploads; generalized skill intentionally deferred until entire main flow has real completion evidence.

## Resume checkpoint 3 — 2026-10-30 23:19 Asia/Shanghai

- DI is unlocked and running 26.11 build 5. After changing the normal connection URL field to `https://api.deepseek.com/chat/completions`, model discovery returned the same Flash and Pro entries. Only Flash was selected. Both Check Connection and Check Vision now visibly passed (green checks). Flash imported, selected as default; no other model imported. This establishes the configuration worked at this time, without proving the earlier 401 root cause.
- Chat thinking setting Medium confirmed in both quick configuration and actual composer. Simulator-only tool authorization confirmed 全部同意 in Palmi. Default vision follows the selected image-capable model. Professional tone set to concise. English/Chinese language switch is Settings → System Settings → Language.
- DI en-US/08-skills is the first real registered/rendered poster; source fidelity and output checks passed. DI raw also has en-US/05-model and zh-Hans/08-skills. Clean structural states preserved. Current DI app is zh-Hans; real Chinese 2048 generation in progress. Separate new conversations per language.
- CUA: native iOS typeText cannot reliably enter Chinese. Native setValue alone changes the visible input but may leave SwiftUI binding stale. Focus the field, setValue to Unicode, then type one ASCII space to trigger the real edit event, verify send-enabled and read back the actual sent bubble. Avoid macOS paste for simulator inputs: it can use stale simulator clipboard. Never transmit a credential as chat content.
- Use Configure → Thinking Effort menu → Medium (not unreliable drag gestures). Preserve original full device window bytes; click the inert Device Hub title area before saving to move pointer outside device.

## Resume checkpoint 4 — 2026-10-30 23:39 Asia/Shanghai

- `DI/zh-Hans`: all nine source captures, finished RGB PNGs, and visual/technical audit complete. Uploaded via native Chrome to zh-Hans, Dynamic Island iPhone medium. **Fully reloaded and verified 9/10, exact filenames 01–09 in ascending order**. Evidence `proofs/zh-Hans-DI-assets-reloaded.json` and `proofs/DI--zh-Hans-acceptance.json`.
- `DI/en-US`: all nine real raw scenes captured. 01 is authentic in-chat 2048 after real swipe gestures, 02 a real native LCP chart, 03 the English web.dev article in the app browser, 04 real Markdown report, 05 model/medium reasoning popover, 06 successful task step list, 07 the genuine Python transcript opened from project logs, 08 real built-in skills and 09 a real English conversation with Palmi. Early empty 05-model.jpg is an unused candidate; final id is 05-models. English render/QA delegated. Connect en-US DI tab currently uses inherited existing assets, 0 explicit screenshots.
- UI cost lesson: browsing with the autonomous browser operator can repeatedly fail with `browser_policy_not_ready`, despite the actual page opening and manual in-app navigation working. Stopped the failed English run. Read the public source in the real in-app browser, then used that verified threshold and asked the model to skip further web tools. The legitimate follow-up completed in 34s, one Python run generated the data, report and chart, and file reads verified results. For other devices, use a short compute/files request referencing the verified threshold, and use the real app browser for the source. Don't retry an unproductive autonomous browser loop.
- Open/Save panels: `Cmd+Shift+G`, wait for native `GoToWindow` and `PathTextField`, use `setValue` on that field, observe candidate path, Return; verify exact folder + files. Click Name header for ascending 01–09. Click first file then shift-click final file (modifier lowercase `shift`), confirm all nine distinct selected row IDs, click Open. `Cmd+A` selected only the first row here. Screenshot placements auto-save: after all 9 visible, reload, reselect locale and screenshot tab, allow async materialization, and read **buttons** for image names (some assets are not draggable while processing). Confirm 9/10 and all nine names in order.
- Apple's current [asset management help](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets/) distinguishes removing a screenshot placement on the version page (recoverable in Asset Library) from deleting the asset itself. Only placement replacement is authorized. Leave Asset Library intact.
- Current only running device: DI. Duo/iPad still shutdown. Metadata six saved values unchanged. No submission.

## Resume checkpoint 5 — 2026-10-30 23:50 Asia/Shanghai

- DI: both en-US and zh-Hans fully uploaded and reloaded, nine ordered screenshot names in each localization. `proofs/en-US-DI-assets-reloaded.json` and `proofs/zh-Hans-DI-assets-reloaded.json`. Six localized text values had already persisted. DI shut down before booting the exact existing Duo.
- Duo: preserved existing connection and prior Chinese game, created a separate DeepSeek Flash source with official full endpoint and only Flash, enabled vision, saved and selected as default. The saved connection passed its vision probe; tools already allow all. Switched conversation thinking to Medium. Genuine folded game reached 28 points after six device gestures. Captured 01 and 05. A separate Chinese professional workspace is running the six-week data exercise and a real Palmi conversation is underway. iPad remains off. No credentials written to files, no release submitted.

## Resume checkpoint 6 — 2026-10-31 00:01 Asia/Shanghai

- Duo zh-Hans 9/9 genuine captures, render and visual audit complete. Real current game, a separate on-device analysis (36 s), real browser article, global skill library and real persona chat. Folded 01/05/09: hardware 84.90%; six unfolded-landscape: 77.19%. Uploaded and reloaded 9/10 with exact ordered filenames: `proofs/zh-Hans-Duo-assets-reloaded.json`.
- Duo en-US 02–09 captured and delegated for rendering. Search `Website` in the actual sidebar isolates the English project without renaming or removing Chinese history. Folded bionic 09 shows genuine English-only conversation segment. English files/report/log and browser verified. Remaining English 01 is actively generating in separate Chat. Media placements persisted for DI both languages and Duo Chinese: 27 total.
- Both iPad locales currently contain four previous screenshot placements. Their names/order were backed up in proofs/{locale}-iPad-assets-before.json; no changes yet. Target existing M4 iPad has Palmi 26.9 build 5 installed; update in place using the real 26.11 build 5 universal simulator bundle from Duo (UIDeviceFamily=[1,2], min OS=26.1). Do not uninstall. Wait for Duo capture + shutdown before booting iPad.
- For simulator URL fields, focus actual field and clear it; AX setValue + type a space + BackSpace commits the full URL and preserves punctuation. Verify exact URL BEFORE Return. For manual Chinese IME input with hardware typing, Return may commit marked text before a second Return navigates. Native AX activate of a message/container scrolls the app to reveal that element. Existing chat histories need not be deleted.

## Resume checkpoint 7 — 2026-10-31 00:14 Asia/Shanghai

- Duo/en-US completed, visually audited and uploaded. After refresh, en-US+Duo showed 9/10 and exact ordered nine names, `proofs/en-US-Duo-assets-reloaded.json`. Now 36/54 version-page placements have persisted. DI and Duo shutdown.
- Original M4 iPad UDID 85116E22-5725-4A59-8693-C4605BD06FEF could not boot iOS 27.0: both Device Hub and Apple simctl reported runtime path not found although runtime images were registered. Apple `simctl upgrade` on that exact existing device to installed **generic** iOS 27.2 succeeded. Same UDID and data were retained, installed Palmi 26.11 build 5 over 26.9, verified Info.plist and app UI; no new device, no runtime download or erase. iPad alone is booted in native landscape orientation.
- iPad preserved its migrated model group; added separate DeepSeek Flash source, full official endpoint, only deepseek-flash, image input enabled. Green vision test, selected default; vision follows default, tool permission already allow all, actual composer Medium. Real Chinese chat game was generated and played (52 score). Professional Chinese run finished 46s and its files, browser, chart, steps and Python output are actual on-device data. Raw iPad/zh-Hans 01–08 complete; 09 will show a clean real photography conversation without incidental prior personal references. zh group manifest writer ipad_zh_art.

## Checkpoint 8 — 2026-10-31 00:31 Asia/Shanghai

- All 54 device/locale/scene sources have now been captured from the real Device Hub window. No simulator was cloned. iPad English includes its own played game (48), native English browser page, project chart, files, actual Python script, steps, skill importer and an English photography conversation.
- iPad/zh-Hans passed visual review and was placed on the version. Reloaded Connect confirmed all nine ordered filenames. English iPad previously showed four explicitly placed screenshots, recorded before replacement; both locales had zero app previews. All four iPhone device/locale groups were read again and still showed nine names in the requested order.
- Compared six live text field values against their local UTF-8 masters after reload. All comparisons matched (`proofs/en-US-fields-final.json`, `proofs/zh-Hans-fields-final.json`). Only the last English iPad image group remains to be accepted and placed.

## Final — 2026-10-31, Asia/Shanghai

- All 54 distinct native sources and all six sets of nine posters passed the full pixel, hash, geometry, opacity and visual checks. The real device covers 76.99–87.51% of each canvas. Final iPad/en-US includes 01 played to 48, 03 native English source and 09 the completed two-photo postcard exchange.
- English iPad's four former placements were removed only after Connect confirmed originals remain in the Asset Library. After uploading all nine, refreshed the version page, reselected English iPad and saw exactly nine ordered filenames. Switched to Chinese iPad to verify it too still had nine, verified the six localized field values again, then returned to the default English locale. No submission action.
- `scripts/release-receipt.py` joined the six visual acceptance decisions, six reloads and individual output SHA-256s with all six exact field comparisons. See [delivery](DELIVERY.md). iPad's system and Palmi display languages were returned to Simplified Chinese; the original M4, Dynamic Island and Duo devices are shut down.
