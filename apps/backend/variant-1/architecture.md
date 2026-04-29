# VAR1 Architecture

This is the canonical architecture map for the current `VAR1` agent harness runtime.

## Architecture lock

- one execution primitive: session
- one durable source of truth: `.var/sessions/<id>/`
- one canonical host protocol: JSON-RPC 2.0 over stdio with Content-Length framing
- one local bridge surface for browser clients: `/rpc`, `/events`, `/api/health` with token-gated RPC/event access
- one executable name: `VAR1`
- one hidden host mode: `kernel-stdio`
- one external browser client: `apps/frontend/var1-client`

## Runtime slice

```mermaid
flowchart TB
  cli["VAR1 CLI"] --> client["src/clients/cli.zig"]
  browser["apps/frontend/var1-client"] --> bridge["src/host/http_bridge.zig"]

  client --> rpcClient["Local stdio RPC client"]
  rpcClient --> kernel["VAR1 kernel-stdio"]
  bridge --> bridgeAccess["src/host/bridge_access.zig"]
  bridge --> kernel

  kernel --> host["src/host/stdio_rpc.zig"]
  host --> executor["src/core/executor/loop.zig"]
  host --> compactor["src/core/context/compactor.zig"]
  executor --> context["src/core/context/builder.zig"]
  executor --> budget["src/core/context/budget.zig"]
  executor --> overflow["src/core/context/overflow.zig"]
  executor --> compactor
  executor --> store["src/core/sessions/store.zig"]
  executor --> provider["src/core/providers/openai_compatible.zig"]
  executor --> tools["src/core/tools/runtime.zig"]
  tools --> toolRegistry["src/core/tools/registry.zig"]
  tools --> toolModules["src/core/tools/builtin/*.zig"]
  tools --> agents["src/core/agents/service.zig"]
  tools --> workspaceState["src/core/tools/workspace_runtime.zig"]
  toolModules --> iex["iex executable"]
  executor --> docs["src/core/docs/sync.zig"]
  executor --> config["src/core/config/settings.zig"]

  context --> store
  budget --> config
  overflow --> provider
  compactor --> store
  store --> sessionRoot[".var/sessions/<id>/session.json + messages.jsonl + context.jsonl + events.jsonl + output.txt"]
  docs --> processRoot[".var/todos + .var/changelog + .var/memories"]
```

## Session message flow

```mermaid
sequenceDiagram
  actor C as Client
  participant B as Bridge or CLI
  participant K as kernel-stdio
  participant E as loop.zig
  participant X as context builder
  participant S as store.zig
  participant P as provider.zig

  C->>B: session/create or session/send
  B->>K: JSON-RPC request
  K->>E: dispatch session lifecycle call
  E->>S: load or create session
  E->>X: build model-visible transcript view
  X->>S: read messages and latest context checkpoint
  X-->>E: summary plus recent raw transcript
  E->>E: estimate provider window against context policy
  alt threshold exceeded
    E->>S: append context_compaction_started event
    E->>S: append context checkpoint through compactor
    E->>X: rebuild model-visible transcript view
  end
  E->>P: provider turn
  alt provider reports context overflow
    E->>S: append provider_overflow checkpoint through compactor
    E->>X: rebuild model-visible transcript view
    E->>P: retry provider turn once
  end
  P-->>E: assistant content or tool calls
  E->>S: append messages and events
  E->>S: write output and status
  E-->>K: session result
  E-->>K: session/event notifications
  K-->>B: JSON-RPC result
  B-->>C: response or UI refresh
```

## Context compaction flow

```mermaid
sequenceDiagram
  actor C as Client
  participant B as Bridge or CLI
  participant K as kernel-stdio
  participant E as loop.zig
  participant M as context compactor
  participant S as store.zig
  participant X as context builder

  C->>B: session/compact
  B->>K: JSON-RPC request
  K->>M: compact session by stable seq entry/range
  M->>S: read session + messages + latest checkpoint
  M->>M: plan next segment or higher-aggression recompact
  M->>S: append summary checkpoint to context.jsonl
  K-->>B: compacted checkpoint metadata
  B-->>C: JSON-RPC response
  E->>E: estimate provider window before model call
  E->>M: auto_threshold or provider_overflow compaction
  M->>S: append context_compaction_* events plus checkpoint
  X->>S: later reads latest checkpoint plus raw suffix
```

Manual and automatic compaction share the same primitive. The manual RPC path is gated by `context.manual_compaction`; the executor path is gated by `context.auto_compaction`, `context.context_window_tokens`, `context.compact_at_ratio`, and `context.reserve_output_tokens`. Provider overflow recovery is separately gated by `context.retry_on_provider_overflow` and retries one provider call after a real checkpoint is written.

```mermaid
stateDiagram-v2
  [*] --> ProviderWindowBuilt
  ProviderWindowBuilt --> ProviderCall: below policy threshold
  ProviderWindowBuilt --> AutoCompacting: estimated tokens >= threshold
  AutoCompacting --> ProviderWindowBuilt: checkpoint appended and window rebuilt
  AutoCompacting --> ProviderCall: compactor returns no eligible range
  ProviderCall --> ProviderOverflow: provider reports context overflow
  ProviderOverflow --> ProviderWindowBuilt: provider_overflow checkpoint appended
  ProviderOverflow --> Failed: no checkpoint can be written
  ProviderCall --> Completed: assistant content persisted
  ProviderCall --> ToolLoop: tool calls returned
  ToolLoop --> ProviderWindowBuilt: tool results appended to in-memory turn
```

## Tool initialization flow

```mermaid
sequenceDiagram
  participant C as CLI or RPC client
  participant H as host/stdio_rpc.zig
  participant L as core/executor/loop.zig
  participant T as core/tools/runtime.zig
  participant R as core/tools/registry.zig
  participant M as core/tools/builtin/*.zig
  participant P as core/providers/openai_compatible.zig
  participant I as iex executable

  C->>H: tools/list or session/send
  H->>T: renderCatalogJson or execution context
  T->>M: collect definition and availability specs
  T->>R: resolve capability availability
  R->>I: probe executable dependency when required
  R-->>T: availability metadata
  T-->>H: ToolDefinition catalog plus availability
  L->>T: builtinDefinitionsForContext(execution_context)
  T-->>L: context-filtered tool definitions
  L->>P: provider request with function schemas
  P-->>L: assistant tool call
  L->>T: execute(tool_call)
  T->>M: dispatch to per-tool execute
  M->>R: ensureAvailable(search_files)
  M->>I: search_files invokes iex search --json
  I-->>M: JSON hits
  M-->>T: tool result envelope
  T-->>L: tool result envelope
```

Tool definitions are schema-first. The shared shape lives in `shared/types.zig` as `ToolDefinition { name, description, parameters_json, example_json, usage_hint }`. Per-tool modules under `core/tools/builtin/` own their definition, availability contract, and execute path. The registry resolves availability from module-owned names/specs instead of duplicating string branches. Provider request construction, CLI catalog export, RPC catalog export, and failure repair hints derive from those module-owned metadata surfaces.

`search_files` is the content-search tool. It declares an `external_command("iex")` dependency, resolves the workspace path in Zig, then invokes `iex search --json --max-hits ...` through the command-runner boundary. `list_files` is the native Zig path-discovery tool and does not shell to `iex`. Installing `VAR1` therefore requires a real `iex` executable for content search; when it is absent, catalog availability reports `search_files` as unavailable and execution fails early with `ToolUnavailable`.

## Bridge access flow

```mermaid
sequenceDiagram
  actor Browser
  participant Bridge as host/http_bridge.zig
  participant Access as host/bridge_access.zig
  participant Kernel as kernel-stdio

  Browser->>Bridge: GET /api/health from local origin
  Bridge->>Access: validate local origin
  Bridge->>Kernel: health/get
  Kernel-->>Bridge: readiness payload
  Bridge->>Access: redact payload and attach bridge_token
  Bridge-->>Browser: redacted health plus bridge_token
  Browser->>Bridge: POST /rpc with X-VAR1-Bridge-Token
  Bridge->>Access: local-origin and token guard
  Bridge->>Kernel: JSON-RPC method
  Bridge->>Access: classify and log session/auth/write-capable action
  Kernel-->>Bridge: result
  Bridge-->>Browser: JSON response
  Browser->>Bridge: GET /events with X-VAR1-Bridge-Token
  Bridge-->>Browser: event snapshot stream
```

The bridge binds to `127.0.0.1` by default. CORS allows only explicit local HTTP origins; direct-file `Origin: null` callers are rejected so bridge access remains bound to a local browser origin. `/rpc` and `/events` require the health-issued bridge token; `/api/health` is the handshake route. `host/bridge_access.zig` owns access policy, sensitive-field redaction, and audit classification; `host/http_bridge.zig` owns the route transport.

## Session state machine

```mermaid
stateDiagram-v2
  [*] --> Initialized

  Initialized --> Running: session/send
  Running --> Completed: assistant output persisted
  Running --> Failed: provider or execution failure
  Running --> Cancelled: cancellation requested

  Completed --> [*]
  Failed --> [*]
  Cancelled --> [*]
```

## Durable contract

Every session directory contains:

- `session.json`
- `messages.jsonl`
- `context.jsonl`
- `events.jsonl`
- `output.txt`

`messages.jsonl` is the complete append-only transcript. `context.jsonl` is compact checkpoint history written by the context compactor and used by the context builder to create model-visible history without rewriting transcript history. Each checkpoint marks the covered source sequence range, the next raw `first_kept_seq`, `compacted_entry_count`, and `aggressiveness_milli`, so compaction can advance one JSONL entry at a time or recompact an existing range when a stronger slider value is requested.

`.var/config/settings.toml` is the optional non-secret policy file. The `[context]` table owns `auto_compaction`, `manual_compaction`, `context_window_tokens`, `compact_at_ratio`, `reserve_output_tokens`, `keep_recent_messages`, `max_entries_per_checkpoint`, `aggressiveness_milli`, and `retry_on_provider_overflow`. Provider URL, model, API keys, and auth-plan state do not move into this file.

`store.ensureStoreReady(...)` validates and rewrites existing `.var/sessions/<id>/session.json` records into the current canonical shape. It does not read old roots, old-layout files, or old-layout fields.

## Module ownership

- `src/shared/types.zig`
  shared runtime types and session contracts
- `src/core/sessions/store.zig`
  canonical session storage
- `src/core/executor/loop.zig`
  kernel-owned execution loop
- `src/core/context/builder.zig`
  sole owner for turning session storage into provider-ready transcript messages
- `src/core/context/compactor.zig`
  sole owner for planning and writing summary checkpoints from stable message sequence entries/ranges
- `src/core/context/budget.zig`
  approximate provider-window token estimator and compaction-threshold calculator
- `src/core/context/overflow.zig`
  provider-error classifier for explicit context-window overflow, excluding rate-limit and availability failures
- `src/core/config/settings.zig`
  optional `.var/config/settings.toml` policy loader for non-secret runtime controls
- `src/core/tools/`
  typed tool socket namespace, built-in module registry/runtime, availability resolver, command-backed search dispatch, and workspace-state helpers
- `src/core/plugins/`
  plugin manifest/socket contracts only; plugin implementations do not live in core
- `src/shared/protocol/types.zig`
  JSON-RPC methods and payload shapes
- `src/host/stdio_rpc.zig`
  Content-Length framed stdio host and local child-process client
- `src/host/bridge_access.zig`
  local HTTP bridge access policy for origin checks, token validation, redaction, and audit classification
- `src/host/http_bridge.zig`
  local HTTP bridge route transport for `/rpc`, `/events`, and `/api/health`
- `src/clients/cli.zig`
  thin protocol-backed CLI
- `apps/frontend/var1-client`
  external static browser client over `/api/health`, `/rpc`, and `/events`

## Pluggability boundary

`core/` contains kernel capability domains, not plugin names. The current socket hierarchy is intentionally small:

- `core/context/` owns model-visible transcript assembly, checkpoint generation, budget estimation, and provider-overflow classification.
- `core/tools/` owns tool socket contracts, per-tool built-in modules, catalog availability, and runtime dispatch.
- `core/plugins/` owns manifest validation for future plugin roots.

Future plugin implementations should live outside `core/` and register through typed sockets. Auto-discovery is not enabled until manifest validation, explicit enablement, deterministic load order, and lifecycle tests are in place.

## Validation lane

The current validation lane should always prove these slices together:

- `build test`
- `health`
- direct `run`
- delegated child-session `run`
- bridge root response is text, not embedded HTML
- bridge rejects removed facade routes
- bridge rejects unapproved origins and tokenless RPC/event access
- tool catalog reports availability metadata
- auto and provider-overflow compaction write observable checkpoint/event records
- external client exists at `apps/frontend/var1-client`

Latest local Windows validation on 2026-04-29:

- `.\scripts\zigw.ps1 build test --summary all` -> `80/80 tests passed`
- `.\zig-out\bin\VAR1.exe tools --json` -> `search_files` includes `external_command` dependency availability for `iex`
