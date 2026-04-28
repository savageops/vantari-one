# VAR1 Architecture

This is the canonical architecture map for the current `VAR1` agent harness runtime.

## Architecture lock

- one execution primitive: session
- one durable source of truth: `.var/sessions/<id>/`
- one canonical host protocol: JSON-RPC 2.0 over stdio with Content-Length framing
- one bridge surface for browser clients: `/rpc`, `/events`, `/api/health`
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
  bridge --> kernel

  kernel --> host["src/host/stdio_rpc.zig"]
  host --> executor["src/core/executor/loop.zig"]
  host --> compactor["src/core/context/compactor.zig"]
  executor --> context["src/core/context/builder.zig"]
  executor --> store["src/core/sessions/store.zig"]
  executor --> provider["src/core/providers/openai_compatible.zig"]
  executor --> tools["src/core/tools/runtime.zig"]
  tools --> agents["src/core/agents/service.zig"]
  tools --> workspaceState["src/core/tools/workspace_runtime.zig"]
  executor --> docs["src/core/docs/sync.zig"]

  context --> store
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
  E->>P: provider turn
  P-->>E: assistant content or tool calls
  E->>S: append messages and events
  E->>S: write output and status
  E-->>K: session result
  E-->>K: session/event notifications
  K-->>B: JSON-RPC result
  B-->>C: response or UI refresh
```

## Session compaction flow

```mermaid
sequenceDiagram
  actor C as Client
  participant B as Bridge or CLI
  participant K as kernel-stdio
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
  X->>S: later reads latest checkpoint plus raw suffix
```

## Tool initialization flow

```mermaid
sequenceDiagram
  participant C as CLI or RPC client
  participant H as host/stdio_rpc.zig
  participant L as core/executor/loop.zig
  participant T as core/tools/runtime.zig
  participant P as core/providers/openai_compatible.zig
  participant I as iex executable

  C->>H: tools/list or session/send
  H->>T: renderCatalogJson or execution context
  T-->>H: built-in ToolDefinition catalog
  L->>T: builtinDefinitionsForContext(execution_context)
  T-->>L: context-filtered tool definitions
  L->>P: provider request with function schemas
  P-->>L: assistant tool call
  L->>T: execute(tool_call)
  T->>I: search_files invokes iex search --json
  I-->>T: JSON hits
  T-->>L: tool result envelope
```

Tool definitions are schema-first. The current repeated shape lives in `shared/types.zig` as `ToolDefinition { name, description, parameters_json, example_json, usage_hint }`. Provider request construction, CLI catalog export, RPC catalog export, and failure repair hints all derive from that single metadata surface.

`search_files` is the content-search tool. It resolves the workspace path in Zig, then invokes `iex search --json --max-hits ...` through the command-runner boundary. `list_files` is the native Zig path-discovery tool and does not shell to `iex`. Installing `VAR1` therefore requires a real `iex` executable for content search; the current binary does not embed or install `iex` by itself.

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
  sole owner for planning and writing manual summary checkpoints from stable message sequence entries/ranges
- `src/core/tools/`
  typed tool socket namespace, built-in tool registry/runtime, command-backed search dispatch, and workspace-state helpers
- `src/core/plugins/`
  plugin manifest/socket contracts only; plugin implementations do not live in core
- `src/shared/protocol/types.zig`
  JSON-RPC methods and payload shapes
- `src/host/stdio_rpc.zig`
  Content-Length framed stdio host and local child-process client
- `src/host/http_bridge.zig`
  HTTP bridge for `/rpc`, `/events`, and `/api/health`
- `src/clients/cli.zig`
  thin protocol-backed CLI
- `apps/frontend/var1-client`
  external static browser client over `/rpc` and `/events`

## Pluggability boundary

`core/` contains kernel capability domains, not plugin names. The current socket hierarchy is intentionally small:

- `core/context/` owns model-visible transcript assembly and manual checkpoint generation.
- `core/tools/` owns tool socket contracts and delegates to the current runtime body.
- `core/plugins/` owns manifest validation for future plugin roots.

Future plugin implementations should live outside `core/` and register through typed sockets. Auto-discovery is not enabled until manifest validation, explicit enablement, deterministic load order, and lifecycle tests are in place.

The next durable tool slice is a per-tool module registry with explicit availability metadata. Command-backed tools such as `search_files` should report the external executable dependency rather than relying on late process-spawn failure as the first availability signal.

## Validation lane

The current validation lane should always prove these slices together:

- `build test`
- `health`
- direct `run`
- delegated child-session `run`
- bridge root response is text, not embedded HTML
- bridge rejects removed facade routes
- external client exists at `apps/frontend/var1-client`

Latest local Windows validation on 2026-04-28:

- `.\scripts\zigw.ps1 build test --summary all` -> `67/67 tests passed`
- `.\scripts\health.ps1` -> `status: ready`
