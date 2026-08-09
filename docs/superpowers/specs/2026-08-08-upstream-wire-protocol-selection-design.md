# Upstream Wire Protocol Selection Design

## Summary

PalmiAgent will replace the implicit two-protocol behavior of custom model connections with an explicit upstream-format preference. The visible model-add flow gains one advanced-settings row and one protocol-selection sheet. The existing model discovery, bulk import, manual model ID, alias, model library, and model-plan flows remain in place.

The runtime will support three wire protocols:

- OpenAI Responses
- OpenAI Chat Completions
- Anthropic Messages

The user preference has a fourth value, Auto. Auto is a bounded negotiation strategy; it is not a wire protocol.

## Goals

1. Let users explicitly lock a custom upstream connection to Responses, Chat Completions, or Messages.
2. Preserve an Auto mode that works without provider or model-name allowlists.
3. Add a complete Anthropic Messages request, response, streaming, and local-tool adapter.
4. Make model discovery understand both OpenAI-style and Anthropic-style Models APIs while keeping manual model entry available.
5. Route normal chat, agent tool calls, streaming, candidate validation, and connection validation through the same protocol decision.
6. Keep protocol failures separate from authentication, model, parameter, and tool-schema failures.

## Non-goals

1. Do not add provider presets or model-name heuristics.
2. Do not add a visible custom Models URL, authentication-mode selector, or protocol-specific parameter editor.
3. Do not enable provider-hosted web search, code execution, file search, or other hosted tools in this change. Hosted tools remain a separate capability layer and must not be represented as Palmi local function tools.
4. Do not redesign model plans, the global model library, or the model discovery/import presentation.

## Current State

`LLMWireProtocol` contains only `responses` and `chatCompletions`. `OpenAICompatibleEndpointResolver` recognizes only `/responses` and `/chat/completions`. For a base URL, Auto begins with Responses and falls back to Chat Completions for a small unsupported-endpoint status set. The successful result is cached per profile, endpoint fingerprint, and opaque model ID for 24 hours.

Model discovery tries `/v1/models` and `/models`, sends an optional Bearer token, and decodes a tolerant OpenAI-style `data` array. It has no Anthropic header profile or pagination support.

Several execution paths build Chat or Responses requests directly, so adding an enum case without consolidating routing would leave inconsistent behavior.

## User Interface

### Add Model

The connection portion of the add-model form will appear in this order:

1. `API 请求地址`
2. `API 密钥`
3. `高级设置` with the current value on the trailing edge

The current “OpenAI compatible” wording is removed from the address label and related accessibility text.

Tapping Advanced Settings presents a native sheet containing one single-selection section titled `上游 API 格式`:

- `自动` — default and recommended
- `OpenAI Responses`
- `OpenAI Chat Completions`
- `Anthropic Messages`

The selected item has a checkmark. Selection is saved in the add-model draft and the sheet dismisses using the existing navigation conventions.

The sections below Advanced Settings remain visually and behaviorally unchanged:

- Fetch models
- Select and import discovered models
- Manual model ID
- Optional alias
- Add model

### Edit Model

The existing model editor gains the same Advanced Settings row and sheet. Existing connections display Auto after migration.

## Configuration Model

Introduce two distinct enums:

```swift
enum LLMWireProtocolPreference: String, Codable, CaseIterable, Sendable {
    case automatic
    case responses
    case chatCompletions
    case anthropicMessages
}

enum LLMWireProtocol: String, Codable, Sendable, Hashable {
    case responses
    case chatCompletions
    case anthropicMessages
}
```

`ModelAPIConnectionRecord` stores the preference and the derived Messages URL in addition to its existing endpoint data. The protocol preference belongs to the connection because one add/import operation applies the selected upstream format to every imported model. Auto resolution remains model-scoped.

Connection identity includes normalized input address, API-key value, and protocol preference. Two entries with the same address and key but different explicit formats must not be merged.

Old records decode with `.automatic`. Updating a connection address or preference clears the protocol and authentication-style contracts for that connection.

## Endpoint Resolution

The resolver normalizes HTTP(S) input and recognizes these terminal resource paths:

- `/responses`
- `/chat/completions`
- `/messages`

It derives sibling endpoints from the resource base:

- `responsesURL`
- `chatCompletionsURL`
- `anthropicMessagesURL`
- Models endpoint candidates

Resolution rules:

1. Auto plus a complete resource URL locks to the protocol named by the suffix.
2. An explicit preference plus a base URL derives and uses that protocol’s endpoint.
3. An explicit preference plus a matching complete resource URL uses it unchanged.
4. An explicit preference plus a conflicting complete resource URL fails validation with a localized address/protocol conflict error.
5. Query strings and fragments remain invalid for generated inference endpoints.

## Runtime Protocol Selection

All inference entry points call one selector before request encoding.

### Explicit preference

An explicit preference is authoritative. Palmi sends exactly that wire format and does not fall back to another inference protocol.

### Auto preference

Auto uses this deterministic order for an unqualified base URL:

1. A fresh cached success for the exact connection, endpoint fingerprint, and opaque model ID.
2. Responses.
3. Chat Completions, but only if Responses failed with HTTP 404, 405, 415, or 501 before any response content was accepted.
4. Anthropic Messages, but only if Chat Completions failed with the same bounded unsupported-endpoint evidence before any response content was accepted.

Auto never switches protocol for:

- HTTP 400, 401, 403, 409, 422, or 429
- unknown model errors
- rejected optional reasoning parameters
- invalid or reserved tool names
- unsupported tool schemas
- rate limits or transient transport errors
- a stream that has emitted a valid protocol event or user-visible content
- any unrecognized HTTP 2xx body, because the upstream may already have generated and billed a response

If a 2xx body or SSE stream is recognizable as another supported protocol, Palmi decodes that body without replaying the request and records the observed protocol. If it is not recognizable, Palmi returns a payload-format error without resending.

A protocol contract is stored only after a valid response envelope or stream event has been decoded. Auto contracts expire after 24 hours and remain isolated by connection, endpoint fingerprint, and model ID.

## Authentication Profiles

Responses and Chat Completions use `Authorization: Bearer <key>`.

Messages uses:

- `x-api-key: <key>`
- `anthropic-version: 2023-06-01`
- `content-type: application/json`

For Messages-compatible gateways that reject the standard API-key header with 401 or 403 before generation, Palmi may retry the same Messages request once with Bearer authentication. Authentication fallback never changes the inference protocol. A successful authentication style is cached per connection and cleared when its address or secret changes.

## Anthropic Messages Adapter

The adapter consumes Palmi’s provider-neutral message, image, reasoning, and tool representations and produces an Anthropic Messages request.

### Request mapping

- System and developer text become the top-level `system` value.
- User text becomes user text content blocks.
- Assistant text becomes assistant text content blocks.
- Images become base64 image source blocks with their media type.
- Local tool definitions become `{name, description, input_schema}`.
- Assistant local tool calls become `tool_use` blocks.
- Tool results become `tool_result` blocks inside a user message and remain adjacent to their corresponding assistant tool-use turn.
- Tool choice maps to Anthropic `auto`, `any`, `none`, or a named tool selector.
- `stream` follows the caller’s request mode.
- `max_tokens` defaults to 4096 when no trustworthy model metadata provides a lower supported cap.

The first version does not proactively send Anthropic native thinking controls for unknown custom models. It parses returned thinking blocks and preserves them only inside the existing connection, endpoint, model, and wire-protocol replay scope. Future native thinking controls require positive integration metadata and use the existing optional-control rejection mechanism.

### Response mapping

Non-streaming JSON and SSE events map into the existing internal result:

- `text` blocks → assistant text
- `thinking` and `redacted_thinking` blocks → native reasoning payload
- `tool_use` blocks → `AgentToolUse`
- `input_tokens`, `output_tokens`, and cache-token fields → `AgentModelTokenUsage`
- Anthropic stop reasons → Palmi completion/tool/limit states
- Anthropic error envelopes → the shared service-error model

The stream decoder handles message start, content-block start, content deltas, content-block stop, message delta, message stop, ping, and error events. Tool JSON deltas are accumulated by content-block index before decoding.

## Model Discovery

Model discovery is independent of inference protocol selection. A successful OpenAI-style `/models` response does not prove that inference uses Chat Completions or Responses, and an Anthropic-style list does not override an explicit inference preference.

### Endpoint candidates

The resolver strips a recognized complete inference suffix and derives the API resource root. It then tries the existing standards-based candidates in bounded order:

1. `<resource-root>/models`
2. For an origin-only input, `/v1/models`
3. For an origin-only input, `/models`

No provider-name or model-name path table is introduced.

### Request profiles

- Responses or Chat preference: OpenAI Bearer profile first.
- Messages preference: Anthropic header profile first, then a Bearer compatibility attempt when authentication or method evidence makes that safe.
- Auto preference: OpenAI profile first, then Anthropic profile; discovery success does not resolve the inference protocol.

### Response decoding

The decoder accepts a `data` array and extracts common fields without requiring a provider identity:

- `id`
- `display_name`, `displayName`, or `name`
- `owned_by` when present
- optional capability metadata when present

Anthropic pagination follows `has_more` and `last_id` with `after_id`, with deduplication, a finite page cap, and cancellation checks. OpenAI-style unpaginated lists continue to work.

Discovery error semantics remain user-friendly:

- 401/403 after compatible authentication attempts → authentication error
- 404/405/501 for every endpoint candidate → model listing unsupported
- valid empty `data` → empty model list
- invalid 2xx JSON → response-format error

Failure to discover models never invalidates the inference connection and never removes manual model entry.

## Tool Namespace and Hosted Tools

Palmi local tools retain canonical internal names. Every wire adapter applies a reversible safe-name codec before sending definitions, calls, and replay history, then maps returned names back to canonical names.

The codec prevents Palmi local functions from occupying protocol-reserved hosted-tool names such as `web_search`. The display title remains user-facing, for example “Palmi Web Search”; the wire identifier remains ASCII-safe and protocol-safe.

Provider-hosted tools are structurally different protocol objects. They are not inserted into local function definitions and are not dispatched by Palmi’s local `ToolRouter`. This change leaves a typed adapter boundary for a later hosted-tool registry but does not enable hosted tools.

## Unified Request Routing

The following paths must use the same resolved protocol and adapter registry:

- Non-streaming model calls
- Streaming chat
- Streaming agent tool calls
- Hidden workers and context compaction calls
- Model candidate validation
- API connection validation
- Subagent model calls

No path may directly assume Chat Completions after the selector returns Responses or Messages. Native reasoning replay is scoped to the resolved wire protocol so reasoning blocks are never replayed across formats.

## Error Handling

Errors are classified before retry decisions:

1. Transport/transient
2. Authentication/authorization
3. Unsupported endpoint or method
4. Unknown model
5. Optional control rejection
6. Tool name/schema rejection
7. Protocol payload mismatch
8. Remote generation failure

Only category 3 can advance Auto to the next wire protocol. Optional-control retries stay within the same protocol. Tool-name rejection stays within the same protocol and reports the canonical Palmi tool involved.

## Migration

1. Decode absent protocol preference as Auto.
2. Derive and persist Messages URLs the next time a connection is saved; old archives remain readable.
3. Preserve existing model IDs, aliases, validation status, plan membership, and selected slots.
4. Invalidate obsolete two-protocol contract records by moving to a new storage key version.
5. Do not migrate or expose API secrets outside the existing Keychain store.

## Testing Strategy

Tests are written before production changes and cover:

1. Preference Codable migration and connection identity.
2. Endpoint derivation for base URLs and all three complete endpoint suffixes.
3. Explicit preference locking and conflict rejection.
4. Auto order, bounded fallback statuses, no fallback for authentication/tool/parameter errors, and no replay after 2xx or stream output.
5. Protocol-contract cache isolation, expiry, and invalidation.
6. Messages authentication selection and safe Bearer compatibility retry.
7. Messages JSON request mapping for text, images, tools, tool results, and tool choice.
8. Messages non-streaming and SSE decoding, including fragmented tool JSON and usage.
9. OpenAI and Anthropic model discovery, authentication profiles, pagination, endpoint fallback, and manual-entry-preserving errors.
10. Existing Responses and Chat request behavior as regression coverage.
11. Add/edit model UI selection, migrated Auto display, and unchanged discovery/manual sections.
12. Full app test suite and a simulator build after focused tests pass.

## Acceptance Criteria

1. Users can see and select Auto, Responses, Chat Completions, or Messages from Advanced Settings on add and edit model screens.
2. Existing configurations load as Auto without losing model or plan data.
3. Explicit protocol choices never silently cross to another inference protocol.
4. Auto negotiates only on bounded unsupported-endpoint evidence and caches valid successes per model.
5. Messages supports streaming text and Palmi local tool calls end to end.
6. OpenAI-style and Anthropic-style model lists both populate the unchanged model-selection UI.
7. A missing Models API still leaves manual model entry usable.
8. A reserved local tool name cannot be sent unchanged as a hosted-tool identifier.
9. Normal chat, agent execution, validation, and subagents agree on the same resolved protocol.

## Protocol References

- OpenAI Models API: https://developers.openai.com/api/reference/resources/models/methods/list
- Anthropic API overview: https://platform.claude.com/docs/en/api/overview
- Anthropic Models API: https://platform.claude.com/docs/en/api/models/list
