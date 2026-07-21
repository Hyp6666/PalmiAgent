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

if grep -q '每个网页希望返回的正文字符上限' PalmiAgent/Integrations/Intelligence/LLMToolDefinitionBuilder.swift; then
  fail "fetch schema must not retain the obsolete max_chars control"
fi

printf 'verify-web-fetch-contract: ok\n'
