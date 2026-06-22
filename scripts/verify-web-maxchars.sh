#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

fail() {
  printf 'verify-web-maxchars: %s\n' "$1" >&2
  exit 1
}

grep -q 'fetchStaticWebPageRecommendedMaxCharacters' PalmiAgent/Core/Agent/ReasoningStrengthProfile.swift \
  || fail "web content profile must carry a recommendation, not a hard max character count"

grep -q 'fetchStaticWebPageAbsoluteMaxCharacters = 100_000' PalmiAgent/Core/Agent/ReasoningStrengthProfile.swift \
  || fail "web page character cap must be the 100K absolute ceiling"

grep -q '"max_chars": ToolJSONSchema.integer' PalmiAgent/Integrations/Intelligence/LLMToolDefinitionBuilder.swift \
  || fail "fetchStaticWebPage schema must expose max_chars"

grep -q 'effectiveFetchStaticWebPageMaxCharacters' PalmiAgent/Infrastructure/ActionExecutor.swift \
  || fail "fetchStaticWebPage execution must derive max_chars from tool arguments"

if grep -q 'let maxChars = retrievalProfile.webContent.fetchStaticWebPageMaxCharacters' PalmiAgent/Infrastructure/ActionExecutor.swift; then
  fail "fetchStaticWebPage must not hard-code maxChars from the retrieval tier"
fi

grep -q 'fetchStaticWebPageToolPayloadMaxCharacters = ReasoningStrengthProfile.fetchStaticWebPageAbsoluteMaxCharacters' PalmiAgent/Core/Support/LLMGuardrails.swift \
  || fail "model-facing fetchStaticWebPage payload must allow up to 100K characters"

grep -q 'maxBodyCharacters: Int = ReasoningStrengthProfile.fetchStaticWebPageAbsoluteMaxCharacters' PalmiAgent/Integrations/Web/WebResearchService.swift \
  || fail "web fetch service defaults must use the shared 100K ceiling"

printf 'verify-web-maxchars: ok\n'
