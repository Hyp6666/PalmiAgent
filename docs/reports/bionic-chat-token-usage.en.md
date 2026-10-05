# Bionic Chat Simulation Token Usage and Cost Analysis Report

[简体中文](bionic-chat-token-usage.zh-CN.md)

Report date: 2026-10-05. System: Palmi Bionic Mode, source revision [`12987237a22cecd2b1d0a9063e2e9c1970c6b1ce`](https://github.com/Hyp6666/PalmiAgent/tree/12987237a22cecd2b1d0a9063e2e9c1970c6b1ce). Pricing model: `deepseek-flash`, identified as DeepSeek-V4.1-Flash in the official documentation on that date. All monetary amounts are presented in USD. The original calculations use the provider's CNY tariff; conversion uses USD = CNY / 6.7104, based on the [China Guangfa Bank middle quote](https://www.cgbchina.com.cn/searchExchangePrice.gsp) dated 2026-10-05 14:35:26 Beijing time. Unrounded ledger amounts are converted before display rounding.

Abstract: With DeepSeek-Flash configured, moderate-to-intensive everyday conversation is estimated to cost an average of $0.48 per user per week, comparable to one model capability test asking it to “Create an HTML page using SVG to produce a 2D animation of a pelican riding a bicycle.”[^1] This study uses an offline algorithm to simulate 100 users per scenario over seven days, with 50 user-initiated messages per day, following the application's context construction, tool protocol, and maintenance workflow. The baseline input-token cache hit rate is 40.75%. Estimated weekly model charges are $47.90 for 100 users, compared with $77.80 if every input token in the same request stream is uncached. No inference, chat, or embedding API was called. These results are conditional simulation estimates, not server measurements or a commitment to a particular cost.

## 1. Runtime mechanism and context budgets

The Bionic Mode harness is the host execution layer outside the model. It freezes turn inputs, constructs requests, validates structured tool outputs, performs local retrieval, and persists accepted messages and delivery state. The host enforces participant scope, source evidence, manual memory revision barriers, and stale-task checks; unvalidated model output does not directly become long-term memory. Ordinary chat exposes `recall` and `speak`, requires a tool call, disables parallel calls, and permits at most six generation attempts per turn. One `speak` can submit several reply bubbles, so bubble count is not model-request count. See [BionicCoordinator](https://github.com/Hyp6666/PalmiAgent/blob/12987237a22cecd2b1d0a9063e2e9c1970c6b1ce/PalmiAgent/Core/Bionic/BionicCoordinator.swift) and [BionicToolbox](https://github.com/Hyp6666/PalmiAgent/blob/12987237a22cecd2b1d0a9063e2e9c1970c6b1ce/PalmiAgent/Core/Bionic/BionicToolbox.swift).

Ordinary chat has the following logical input order. Tool schemas also enter the model input; their protocol placement depends on the provider's encoding format.

| Order | Input content | Update condition |
|---|---|---|
| 1 | Fixed chat instructions, character profile, current local participant profile | Instruction or profile changes |
| 2 | Recent character diaries, selected complete memory facts, manual revision barriers, prior conversation summary | Diary writes, memory changes, or compaction |
| 3 | Chronological committed user and character message bodies between the compaction cursor and the turn's upper bound | Message commits or cursor advancement |
| 4 | `message_index`, including IDs, authors, timestamps, references, and pending-message locations | Rebuilt each turn |
| 5 | Local clock, unsent `prepared_reply` drafts, and `reply_delivery` data | Time, draft, or delivery changes |
| 6 | Optional `recalled_evidence` | Appended at the tail after `recall` |

Selected long-term memories enter as complete fact content, rather than the entire database or title-only summaries. Selection prioritizes preferences and boundaries, user facts, promises and open items, then shared events; ties use record time and ID, with participant/topic deduplication. The current implementation does not reorder this prefix using the current query. Records outside the budget remain available through local archive retrieval. Committed ordinary dialogue is replayed as message bodies; the previous `speak` arguments and native tool-protocol sequence are not retained verbatim as the next turn's history. See [BionicPromptBuilder](https://github.com/Hyp6666/PalmiAgent/blob/12987237a22cecd2b1d0a9063e2e9c1970c6b1ce/PalmiAgent/Core/Bionic/BionicPromptBuilder.swift).

Table 1. Default code budgets and experimental settings.

| Item | Value or setting |
|---|---:|
| Local character context limit | 200,000 |
| Chat compaction threshold | 180,000 |
| Ordinary request output limit | 8,192 |
| Diary request output limit | 1,600 |
| Chat memory selection budget | 1,200 |
| Combined budget for the latest three diaries | 1,200 |
| Conversation summary target budget | 1,400 |
| Memory comparison budget during compaction | 2,200 |
| Explicit thinking setting | `thinking.type = disabled` |

The application uses an approximate counter to estimate input occupancy and control memory, diary, and summary budgets. Request output limits are set through the API's token cap; provider tokenization and billing are calculated separately. The approximate counter counts non-whitespace ASCII characters divided by four and rounded up, plus one per non-ASCII Unicode scalar, with additional message, tool, and protocol overhead. The chat threshold is the smaller of 90% of the context limit and the context limit minus the output limit. The provider's published 1M context limit does not override the application's local 200,000 limit. Sources: [BionicModels](https://github.com/Hyp6666/PalmiAgent/blob/12987237a22cecd2b1d0a9063e2e9c1970c6b1ce/PalmiAgent/Core/Bionic/BionicModels.swift), [ApproximateTokenCounter](https://github.com/Hyp6666/PalmiAgent/blob/12987237a22cecd2b1d0a9063e2e9c1970c6b1ce/PalmiAgent/Core/Support/ApproximateTokenCounter.swift), and [DeepSeek model specifications](https://api-docs.deepseek.com/quick_start/pricing/).

Conversation settlement occurs across the sleep boundary; capacity pressure can trigger additional segmented compaction. Compaction submits a summary and source-backed memory changes, subject to manual revision barriers. Diaries describe fictional character life. Older diaries are compacted separately and do not create user facts. Proactive planning, personality evolution, and image generation are disabled by default. The experiment uses instant replies and the default 01:00–08:00 sleep interval.

## 2. Experimental design

Each scenario contains 100 distinct synthetic users, each starting with a new character, empty history, and no memories. Settings use Simplified Chinese, adult characters, default five-dimensional personality values, and the `Asia/Shanghai` timezone. The observation window is 2026-10-05 00:00 to 2026-10-12 00:00, excluding the endpoint. Each user initiates 350 messages, giving 35,000 turns per scenario. Seven scenarios total 245,000 user turns and 285,670 simulated model requests. The fixed random seed is `20261005`. Nine cache policies replay the same generated requests rather than generating additional conversations.

User and reply text are constructed from Chinese everyday-topic templates. Length parameters are 38 characters per user message and 48 per reply bubble; the long-text scenario uses 180 and 240. Truncation length is `max(3, floor(exp(N(log(m) − 0.25, 0.70²))))`, where `m` is the relevant parameter. A number from 1 to 29 and a full stop are appended with 15% probability. These parameters are not exact realized mean lengths. The probabilities of one through five reply bubbles are 50%, 30%, 13%, 5%, and 2%. The baseline produces 62,822 bubbles, averaging 1.795 per user turn. A single turn-ending `speak` returns all bubbles.

The baseline performs an exact message-ID retrieval before replying in 8% of turns. It returns one to four older records from the synthetic archive, followed by another model request to produce the reply. The high-retrieval scenario raises the probability to 35%; 10% of retrieval turns perform two successive retrievals. The keyword scenario matches topic words, returns at most 20 records per page, and constructs a cursor. Its message and memory search is an approximate offline reconstruction, not execution of the complete Swift database implementation. Retrieval decisions and selected IDs are prescribed algorithmically; the experiment does not establish whether a model would make the same decisions.

Daily conversation summaries use a 600-character length parameter and a 1,400-character cap; diaries use 400 and 2,400 respectively. Daily compaction proposes zero, one, or two synthetic memories with probabilities 25%, 55%, and 20%, taking fact content from synthetic user messages. The manual-revision scenario edits memories and updates revision barriers before the 9th, 25th, and 41st daily inputs. These settings estimate sequence lengths and state changes, not summary quality, extraction accuracy, or semantic consistency.

Three time distributions are used. The baseline has five daily sessions containing 7, 8, 7, 15, and 13 messages. Reference starts are 08:42, 12:24, 16:48, 20:12, and 21:54, each shifted uniformly by ±25 minutes; messages are sampled uniformly within the following 35 minutes. The dispersed scenario samples uniformly between 08:30 and 22:45. The evening scenario samples `21:00 + 100 minutes × Beta(1.4, 1.4)`. Sorted user messages are separated by at least 30 seconds. One synthetic baseline day has session intervals 08:29:45–08:57:02, 12:27:10–12:53:43, 16:35:45–16:56:29, 20:01:07–20:24:06, and 22:11:17–22:37:56, with the corresponding message counts above.

Foreground activity begins five minutes before the first daily input, allowing the prior day's sleep settlement and diary maintenance to finish. Chat ends before 23:00. Diaries become due at 23:00 and are written at the next day's foreground activation. Each user therefore incurs six conversation compactions, six diary writes, and three old-diary compactions within the observation window. Settlement for day seven occurs after the window and is excluded. Diary sourcing reconstructs the archive limit of 20 records and 12,000 UTF-8 body bytes per page; it does not assume that the entire day's conversation enters the diary request.

Billing tokens are calculated with the [official V4.1 tokenizer](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash) and [public DeepSeek encoding library](https://github.com/deepseek-ai/deepseek-recipe), without downloading model weights. The tokenizer file SHA-256 is `c90dfa01249db1be4245780a052ede752e1361c612ac6d08e2bdada7d599476b`; the encoding library distribution is `deepseek-recipe 0.1.1`. Ninety-nine full-tokenization comparisons and 98 full-rendering comparisons found no differences. Validation also covered seven cache-rule checks, reconciliation of user and request-category aggregates, and an independent evening-cost calculation. These checks establish internal consistency of the offline implementation; the public encoding format can still differ from production deployment.

## 3. Cache model and pricing

Caching requires an exact token-prefix match to a complete unit that has been saved, finished building, and has not expired. The [DeepSeek cache documentation](https://api-docs.deepseek.com/guides/kv_cache/) describes units at input endpoints, output endpoints, common prefixes across requests, and periodic positions in long sequences. A common prefix must be discovered and saved before a subsequent request can use it. For example, after `A+B` followed by `A+C`, the second request is not immediately credited with a hit on `A`. The offline model uses a compressed token radix tree, stores input and output endpoints, and tracks build availability and last-use time for each policy.

The provider states that construction usually takes seconds, unused caches generally persist for hours to days, and caching is best-effort. Exact retention, periodic spacing, routing, capacity, and eviction probabilities are unpublished. The baseline assumes six hours of inactivity retention, a 4,096-token interval, and a five-second build delay. It also assumes five seconds for generation and tool completion, six seconds between successive tool requests, and cache construction starting after step completion. Hits or renewed saves update last-use time. Each character begins with an independent cold cache; undocumented cross-character or cross-account reuse is excluded. Although the application has an internal `promptCacheKey`, its direct DeepSeek Chat Completions path does not send the OpenAI cache key, so that key cannot establish fixed server routing.

Table 2. USD equivalents of [official CNY prices](https://api-docs.deepseek.com/quick_start/pricing/) on the report date, per million tokens. Displayed unit prices are rounded to five decimal places; cost calculations use full precision.

| Period | Cached input | Uncached input | Output |
|---|---:|---:|---:|
| Off-peak | $0.00298 | $0.14902 | $0.59609 |
| Peak | $0.00596 | $0.29804 | $1.19218 |

Peak periods are 09:00–12:00 and 14:00–18:00 Beijing time, Monday through Friday excluding Chinese statutory holidays. Under the [2026 holiday schedule](https://www.beijing.gov.cn/fuwu/bmfw/sy/jrts/202511/t20251104_4258838.html), October 5–7 in this observation week fall within the National Day holiday and use off-peak prices; October 8–9 have weekday peak windows. October 10 remains a Saturday for this pricing rule despite being a make-up working day. A separate ordinary-week column reprices the same weekdays and message times with statutory holidays removed.

The token-weighted input hit rate is `R = Σhᵢ / Σnᵢ`. Per-request cost is `Cᵢ = [hᵢp_hit(tᵢ) + (nᵢ − hᵢ)p_miss(tᵢ) + oᵢp_out(tᵢ)] / 10⁶`, where `nᵢ`, `hᵢ`, and `oᵢ` are input, cached input, and output token counts, with prices determined by request time. Tool schemas count as input; function names, arguments, and output protocol count as output. Local archive search has no separate model charge, but returned evidence is billed when included in subsequent input. The output limit is a budget constraint, not the billed output quantity. Thinking is disabled, so the principal results include no hidden thinking tokens.

## 4. Results

Table 3. Scenario comparison under the principal cache parameters. Costs include initial chat requests, retrieval follow-ups, conversation compaction, and diary maintenance. Each scenario covers 100 users and seven days.

| Scenario | Model requests | Input hit rate | Observed-week estimate | Per user | Ordinary-week estimate |
|---|---:|---:|---:|---:|---:|
| Five daily short-chat sessions; 8% exact retrieval | 39,279 | 40.75% | $47.90 | $0.48 | $50.40 |
| Uniformly dispersed daytime short chat | 39,279 | 40.75% | $51.00 | $0.51 | $57.83 |
| Evening chat concentrated into 100 minutes | 39,279 | 40.75% | $46.10 | $0.46 | $46.10 |
| Long-text chat | 39,279 | 58.29% | $57.40 | $0.57 | $60.58 |
| 35% retrieval, including successive retrievals | 49,996 | 41.74% | $60.22 | $0.60 | $63.46 |
| Three manual memory revisions per day | 39,279 | 40.58% | $49.85 | $0.50 | $52.35 |
| 8% keyword retrieval; up to 20 records per page | 39,279 | 40.00% | $49.23 | $0.49 | $51.81 |

Table 4. Baseline request and billing breakdown.

| Request category | Count | Input tokens | Cached input tokens | Output tokens | Cost |
|---|---:|---:|---:|---:|---:|
| Initial chat, including initial `recall` calls | 35,000 | 416,883,631 | 180,270,662 | 4,700,102 | $40.08 |
| Reply after retrieval | 2,779 | 34,290,375 | 14,326,783 | 369,521 | $3.37 |
| Conversation compaction | 600 | 22,822,981 | 0 | 319,708 | $3.74 |
| Diary writing | 600 | 3,087,022 | 0 | 148,818 | $0.57 |
| Old-diary compaction | 300 | 416,011 | 0 | 101,280 | $0.13 |
| Total | 39,279 | 477,500,020 | 194,597,445 | 5,639,429 | $47.90 |

Uncached input totals 282,902,575 tokens. Mean input and output per request are 12,156.62 and 143.57 tokens. Initial chat requests alone have a 43.24% hit rate; including follow-ups and maintenance lowers the aggregate to 40.75%. At least one input token is cached in 93.05% of requests, and at least 128 in 92.54%; neither request-level proportion is the input-token hit rate. The same request stream would cost $77.80 with fully uncached input, making the simulated saving 38.43%. The 10th and 90th percentiles of per-user hit rates are 39.93% and 41.67%, describing only this synthetic population.

Across all scenarios, the maximum local input estimate is 60,392 and the maximum input count under the public encoding is 60,366. Neither reaches the experimental chat threshold, so there is no additional capacity-triggered compaction. Zero cached tokens for maintenance in Table 4 result from this experiment's independent cold caches, request differences, and build timing; they do not establish that maintenance requests can never hit a cache. Costs are summed before rounding to two decimal places, so displayed category amounts may differ from the displayed total by $0.01.

## 5. Sensitivity analysis and interpretation

Table 5. Cache-parameter changes applied to the same baseline request stream. Unchanged parameters are six-hour retention, 4,096-token spacing, and five-second construction.

| Cache parameter | Input hit rate | Weekly cost for 100 users |
|---|---:|---:|
| Principal parameters | 40.75% | $47.90 |
| Three-hour retention | 38.76% | $49.46 |
| 24-hour retention | 41.38% | $47.42 |
| 72-hour retention | 41.55% | $47.30 |
| Request endpoints and common prefixes only; no extra periodic units | 40.68% | $47.95 |
| 1,024-token spacing | 41.19% | $47.57 |
| 16,384-token spacing | 40.68% | $47.95 |
| One-second construction | 43.34% | $46.03 |
| 15-second construction | 40.75% | $47.90 |

The selected parameters produce hit rates of 38.76%–43.34%. This is a parameter sensitivity range, not a confidence interval for production performance. Within-day gaps are generally shorter than retention, giving the three short-chat schedules identical hit rates under the principal parameters. Different numbers of peak-period requests nevertheless change cost. Diary, memory, and summary updates alter earlier prefixes and require subsequent warming; a changed clock at the tail does not invalidate every unchanged preceding prefix.

A diagnostic decomposition of initial chat input assigns approximately 29.61% to fixed or daily stable prefixes, 14.68% to historical message bodies, 50.98% to the complete `message_index`, and 4.73% to other protocol and runtime content. Component counts have minor boundary attribution differences; billing uses tokenization of complete requests. With short message bodies, the rebuilt message-location index accounts for most input. More reusable body content raises the hit proportion, but the long-text scenario still costs more overall. Frequent retrieval adds requests and evidence, so a higher hit rate alone does not establish lower cost. Optimization should first examine necessary index fields and stable encoding, preserve correct references, participant scope, and revision barriers, and validate savings against production billing data.

For an output-price sensitivity calculation only, holding the request stream fixed and adding 512 or 1,536 thinking output tokens per request increases the 100-user cost by $12.69 or $38.07. Total estimates become $60.59 or $85.97, equivalent to $0.61 or $0.86 per user. Enabling thinking in practice can change latency, output, and tool decisions; this calculation does not predict that behavior.

The experiment excludes real semantic decisions, validation failures, network retries, provider capacity and routing changes, continuous background activation, proactive planning, and image-model requests. Configuration, accumulated history, and usage frequency also affect results. Template content is not a measured human conversation distribution; keyword search and archive fields are approximate reconstructions. Offline tokenizer checks do not replace server `usage` telemetry. Production analysis should aggregate `prompt_cache_hit_tokens` and `prompt_cache_miss_tokens` by model, pricing period, and request category. The source revision, parameters, and results support methodological inspection, but the complete synthetic request stream is not included; the seed alone cannot independently reconstruct token-level results.

## 6. References

1. DeepSeek. [Models & Pricing](https://api-docs.deepseek.com/quick_start/pricing/), [Chinese pricing documentation](https://api-docs.deepseek.com/zh-cn/quick_start/pricing/). Accessed 2026-10-05.
2. DeepSeek. [Context Caching](https://api-docs.deepseek.com/guides/kv_cache/). Accessed 2026-10-05.
3. DeepSeek. [DeepSeek-V4.1-Flash tokenizer](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash); [deepseek-recipe encoding library](https://github.com/deepseek-ai/deepseek-recipe).
4. Beijing Municipal Government Portal. [State Council General Office notice on the 2026 holiday schedule](https://www.beijing.gov.cn/fuwu/bmfw/sy/jrts/202511/t20251104_4258838.html).
5. PalmiAgent. [Analyzed source revision](https://github.com/Hyp6666/PalmiAgent/tree/12987237a22cecd2b1d0a9063e2e9c1970c6b1ce); model requests in [BionicModelService](https://github.com/Hyp6666/PalmiAgent/blob/12987237a22cecd2b1d0a9063e2e9c1970c6b1ce/PalmiAgent/Core/Bionic/BionicModelService.swift), diary protocols in [BionicDiaryPrompt](https://github.com/Hyp6666/PalmiAgent/blob/12987237a22cecd2b1d0a9063e2e9c1970c6b1ce/PalmiAgent/Core/Bionic/BionicDiaryPrompt.swift), and retrieval in [BionicArchiveStore](https://github.com/Hyp6666/PalmiAgent/blob/12987237a22cecd2b1d0a9063e2e9c1970c6b1ce/PalmiAgent/Core/Bionic/BionicArchiveStore.swift).
6. China Guangfa Bank. [Foreign Exchange Rates](https://www.cgbchina.com.cn/searchExchangePrice.gsp). USD/CNY middle quote: 6.7104, dated 2026-10-05 14:35:26 Beijing time.

[^1]: The cost comparison uses a model capability test result supplied by the project author, obtained with DSH and DeepSeek-Flash. The result varies with peak and off-peak pricing, DSH version updates, and iterations of the model itself; it is not a unique or fixed cost benchmark. That capability test is excluded from the simulated ledger of this offline Bionic Chat experiment.
