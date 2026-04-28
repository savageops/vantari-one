# VAR1 Zig Kernel

`VAR1` is the Zig kernel that runs Ventari 1 agent sessions. It owns session storage, context construction, provider transport, tool dispatch, and bridge events so the CLI and browser use the same harness behavior.

This app is the only live backend lane in the repository. Operators use the CLI, browser users talk through the bridge, and agent-session state stays inside `.var/sessions`.

## At a glance

| Surface | Current contract |
| --- | --- |
| Executable | `VAR1` |
| Hidden host | `kernel-stdio` |
| CLI owner | `src/clients/cli.zig` |
| Browser bridge | `src/host/http_bridge.zig` |
| Protocol | JSON-RPC 2.0 over stdio with Content-Length framing |
| State root | `.var/sessions/<id>/` |
| Provider boundary | `src/core/providers/openai_compatible.zig` |
| Tool runtime | `src/core/tools/runtime.zig` |

## What ships

- `VAR1 run` for direct prompt execution.
- `VAR1 health` for provider and runtime readiness.
- `VAR1 tools` for the built-in schema catalog.
- `VAR1 serve` for the browser-facing bridge:
  - `POST /rpc`
  - `GET /events`
  - `GET /api/health`

There is no old HTTP facade or storage migration path. New checkouts start directly on the session contract.

## Canonical session contract

Each durable run lives under `.var/sessions/<id>/`:

- `session.json`
- `messages.jsonl`
- `context.jsonl`
- `events.jsonl`
- `output.txt`

`messages.jsonl` is the append-only session transcript. `context.jsonl` is the compact checkpoint history produced by `core/context/compactor.zig` and consumed by the context builder; it is not a second full transcript.

Session ids remain opaque. The store mints `session-...` ids for new runs.

## Layered ownership

Runtime code is physically partitioned by ownership under `src/`:

| Layer | Canonical namespace | Owners | Responsibility |
| --- | --- | --- | --- |
| `shared` | `VAR1.shared` | `shared/types.zig`, `shared/fsutil.zig`, `shared/protocol/` | contracts, filesystem helpers, wire payloads |
| `core` | `VAR1.core` | `core/config/`, `core/sessions/`, `core/executor/`, `core/providers/`, `core/tools/`, `core/agents/`, `core/auth/` | execution, state, provider transport, tools, delegation, auth resolution |
| `host` | `VAR1.host` | `host/stdio_rpc.zig`, `host/http_bridge.zig` | stdio RPC host and HTTP bridge |
| `clients` | `VAR1.clients` | `clients/cli.zig` | protocol-backed client shell |

The browser client lives outside the kernel at `apps/frontend/var1-client`.

## Tool runtime

The current tool surface is compiled into the `VAR1` binary. Tool definitions use the shared `ToolDefinition` shape: name, description, `parameters_json`, optional example, and optional usage hint. `src/core/tools/runtime.zig` owns the built-in registry and execution dispatch; `src/core/executor/loop.zig` injects the context-filtered definitions into provider requests; `src/core/providers/openai_compatible.zig` writes them as OpenAI-compatible function schemas.

`VAR1 tools --json` and the JSON-RPC `tools/list` method expose the same catalog. That catalog is the contract an installing client should inspect before assuming a tool exists.

File tools are split by role:

- `list_files` is native Zig workspace discovery.
- `search_files` is content search and invokes the external `iex` executable as `iex search --json`.
- `read_file`, `write_file`, `append_file`, and `replace_in_file` operate on exact workspace-relative paths.

An installed runtime must provide a real `iex` executable for `search_files`. PowerShell aliases are not enough for the Zig child-process runner. If `iex` is absent, search is unavailable at the command dependency boundary; it should not be represented as a native bundled capability.

`src/core/tools/sockets.zig` and `src/core/plugins/manifest.zig` are validation boundaries for typed sockets and plugin manifests. They do not load plugins, auto-discover plugin roots, or mutate the model-visible tool list.

## Quick start

Build, test, check provider readiness, then run one prompt:

```powershell
.\scripts\zigw.ps1 build test --summary all
.\scripts\health.ps1
.\zig-out\bin\VAR1.exe run --prompt "Count the lowercase letter r in strawberry."
```

## Commands

### CLI

```powershell
.\zig-out\bin\VAR1.exe run --prompt "Count the lowercase letter r in strawberry."
.\zig-out\bin\VAR1.exe run --prompt-file .\prompt.txt --json
.\zig-out\bin\VAR1.exe run --session-id session-1776778021956-42e781c4c8b4efb8
.\zig-out\bin\VAR1.exe health --json
.\zig-out\bin\VAR1.exe tools --json
.\zig-out\bin\VAR1.exe serve --host 127.0.0.1 --port 4310
```

### Browser client

1. Start the bridge:

   ```powershell
   .\zig-out\bin\VAR1.exe serve --host 127.0.0.1 --port 4310
   ```

2. Open `apps/frontend/var1-client/index.html`.

3. Point the client at `http://127.0.0.1:4310`.

The browser client uses only `POST /rpc`, `GET /events`, and `GET /api/health`.

## Session flow

### New session

1. `session/create`
2. `session/send`
3. kernel executes the run loop
4. bridge/client hydrates detail through `session/get` or `session/list`

### Follow-up on the same session

1. `session/send { session_id, prompt }`
2. the new user message appends to `messages.jsonl`
3. the context builder creates the model-visible view from the latest checkpoint plus recent raw messages
4. the next assistant output appends to the same session

### Manual compact

1. `session/compact { session_id, keep_recent_messages?, max_entries_per_checkpoint?, aggressiveness?, trigger? }`
2. the context compactor selects an older message entry or bounded range by stable `seq`
3. a structured summary checkpoint appends to `context.jsonl` with `aggressiveness_milli` and `compacted_entry_count`
4. repeated calls advance from `first_kept_seq`; higher aggressiveness recompacts the covered range from `messages.jsonl`
5. the next `session/send` keeps the checkpoint plus the recent raw suffix model-visible

### Resume

1. `session/send { session_id }`
2. the kernel reuses the stored prompt and transcript for that session

## Bridge behavior

`VAR1 serve` owns only transport projection.

- `/rpc` forwards JSON-RPC requests to the hidden stdio kernel host
- `/events` returns SSE-compatible event snapshots for session notifications
- `/api/health` is a thin readiness alias for scripts
- `/` is bridge-only text that points operators at `apps/frontend/var1-client`

No kernel-owned HTML is served from `src/`.

## Scripts

Windows-native operator scripts remain the primary lane:

```powershell
.\scripts\zigw.ps1 build test --summary all
.\scripts\health.ps1
.\scripts\local_gemma_smoke.ps1
```

Shell wrappers remain available:

```bash
./scripts/zigw.sh build test --summary all
./scripts/health.sh
./scripts/local_gemma_smoke.sh
```

The smoke lane now proves:

- direct CLI execution
- delegated child-session execution
- bridge health and canonical bridge routes
- bridge-only root response
- external browser client presence at `apps/frontend/var1-client`

Before the first prompt run, the smoke scripts now also verify that the configured provider is reachable and that `MODEL` is actively served by the authenticated `/v1/models` surface.

## Configuration

Required `.env` keys:

- `BASE_URL`
- `API_KEY`
- `MODEL`
- `MAX_STEPS`
- `WORKSPACE`

Use `.env.example` as the public template. Keep live `.env` values local.

## Files worth reading first

- `src/root.zig`
- `src/clients/cli.zig`
- `src/host/stdio_rpc.zig`
- `src/host/http_bridge.zig`
- `src/core/executor/loop.zig`
- `src/core/context/builder.zig`
- `src/core/context/compactor.zig`
- `src/core/sessions/store.zig`
- `tests/`
- `../frontend/var1-client/`

## Current posture

This lane is now session-native end to end:

- store
- context builder
- context compactor
- executor
- protocol types
- stdio host
- bridge
- CLI
- smoke scripts
- tests

No compatibility facade or old-layout storage reader remains in this lane.

Latest local Windows validation on 2026-04-28:

- `.\scripts\zigw.ps1 build test --summary all` -> `67/67 tests passed`
- `.\scripts\health.ps1` -> `status: ready`
