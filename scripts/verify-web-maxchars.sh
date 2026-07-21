#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

fail() {
  printf 'verify-web-fetch-contract: %s\n' "$1" >&2
  exit 1
}

grep -q 'const bodyText = normalize(document.body?.innerText' PalmiAgent/Integrations/Web/WebResearchService.swift \
  || fail "fetch must return the complete visible body text"

if grep -q 'const root = best ? best.el : document.body' PalmiAgent/Integrations/Web/WebResearchService.swift; then
  fail "fetch must not select a single guessed content root"
fi

grep -q '"start": ToolJSONSchema.integer' PalmiAgent/Integrations/Intelligence/LLMToolDefinitionBuilder.swift \
  || fail "fetch schema must expose start"

grep -q '"end": ToolJSONSchema.integer' PalmiAgent/Integrations/Intelligence/LLMToolDefinitionBuilder.swift \
  || fail "fetch schema must expose end"

grep -q 'enum WebFetchMode' PalmiAgent/Integrations/Web/WebResearchService.swift \
  || fail "fetch must expose named page_text/full_snapshot modes"

grep -q 'case fullSnapshot = "full_snapshot"' PalmiAgent/Integrations/Web/WebResearchService.swift \
  || fail "fetch must support full_snapshot mode"

grep -q 'performance.getEntriesByType' PalmiAgent/Integrations/Web/WebResearchService.swift \
  || fail "full_snapshot must collect resources actually loaded by the page"

grep -q 'let assets: \[WebFetchAsset\]' PalmiAgent/Integrations/Web/WebResearchService.swift \
  || fail "full_snapshot must carry archived assets and failures"

grep -Fq 'assets/\(localFileName)' PalmiAgent/Infrastructure/ActionExecutor.swift \
  || fail "full_snapshot must save assets into the page archive folder"

if grep -q 'screenshotPNGData' PalmiAgent/Integrations/Web/WebResearchService.swift; then
  fail "a screenshot must not be used as a substitute for page assets"
fi

grep -q '换过更合适来源' PalmiAgent/Integrations/Intelligence/LLMToolDefinitionBuilder.swift \
  || fail "tool guidance must discourage premature full_snapshot use"

if grep -q '每个网页希望返回的正文字符上限' PalmiAgent/Integrations/Intelligence/LLMToolDefinitionBuilder.swift; then
  fail "fetch schema must not retain the obsolete max_chars control"
fi

printf 'verify-web-fetch-contract: ok\n'
