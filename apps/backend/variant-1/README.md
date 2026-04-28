# VAR1 Zig Harness

`apps/backend/variant-1` is the live `VAR1` runtime lane inside `VANTARI-ONE`.

The current architecture is no longer an embedded workbench app. It is a headless session kernel with two thin clients:

- a protocol-backed CLI
- an external browser client in `apps/frontend/var1-client`

`VAR1 serve` is now a bridge, not a UI host.

## What ships

- one executable name: `VAR1`
- one hidden host mode: `kernel-stdio`
- one canonical protocol: JSON-RPC 2.0 over stdio with Content-Length framing
- one canonical durable runtime root: `.var/sessions/<id>/`
- one browser-facing bridge surface:
  - `POST /rpc`
  - `GET /events`
  - `GET /api/health`
- one-wave compatibility facades at the bridge edge:
  - `GET /api/tasks`
  - `POST /api/tasks`
  - `GET /api/tasks/:id`
  - `GET /api/tasks/:id/turns`
  - `GET /api/tasks/:id/journal`
  - `POST /api/tasks/:id/messages`
  - `POST /api/tasks/:id/resume`

The compatibility routes translate into session RPC calls. They do not preserve task-native kernel logic.

## Canonical session contract

Each durable run lives under `.var/sessions/<id>/`:

- `session.json`
- `messages.jsonl`
- `context.jsonl`
- `events.jsonl`
- `output.txt`

`messages.jsonl` is the append-only durable transcript. `context.jsonl` is the compact checkpoint ledger consumed by the context builder; it is not a second full transcript.

Session ids remain opaque. Existing ids may still look like `task-...` during the compatibility wave, but they are treated as session ids by the kernel.

## Layered ownership

The implementation is still physically close together in `src/`, but the canonical ownership split is now explicit:

| Layer | Canonical namespace | Owners | Responsibility |
| --- | --- | --- | --- |
| `shared` | `VAR1.shared` | `config.zig`, `fsutil.zig`, `types.zig` | config, contracts, filesystem helpers |
| `core` | `VAR1.core` | `loop.zig`, `store.zig`, `provider.zig`, `tools.zig`, `protocol_types.zig`, `agents.zig`, `harness_tools.zig` | execution, state, tools, delegation |
| `host` | `VAR1.host` | `stdio_rpc.zig`, `web.zig` | stdio RPC host and HTTP bridge |
| `clients` | `VAR1.clients` | `cli.zig` | protocol-backed client shell |

The browser client lives outside the kernel at `apps/frontend/var1-client`.

## Commands

### CLI

```powershell
.\zig-out\bin\VAR1.exe run --prompt "Count the lowercase letter r in strawberry."
.\zig-out\bin\VAR1.exe run --prompt-file .\prompt.txt --json
.\zig-out\bin\VAR1.exe run --session-id task-1776778021956-42e781c4c8b4efb8
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

The browser client uses the canonical bridge endpoints, not the temporary `/api/tasks*` facade.

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

### Resume

1. `session/send { session_id }`
2. the kernel reuses the stored prompt and transcript for that session

## Bridge behavior

`VAR1 serve` owns only transport and compatibility projection.

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
- bridge health and task-facade routes
- bridge-only root response
- external browser client presence at `apps/frontend/var1-client`

Before the first prompt run, the smoke scripts now also verify that the configured provider is reachable and that `OPENAI_MODEL` is actively served by the authenticated `/v1/models` surface.

## Configuration

Required `.env` keys:

- `OPENAI_BASE_URL`
- `OPENAI_API_KEY`
- `OPENAI_MODEL`
- `HARNESS_MAX_STEPS`
- `HARNESS_WORKSPACE`

Use `.env.example` as the public template. Keep live `.env` values local.

## Files worth reading first

- `src/root.zig`
- `src/cli.zig`
- `src/stdio_rpc.zig`
- `src/web.zig`
- `src/loop.zig`
- `src/core/context/builder.zig`
- `src/store.zig`
- `tests/`
- `../frontend/var1-client/`

## Current posture

This lane is now session-native end to end:

- store
- context builder
- executor
- protocol types
- stdio host
- bridge
- CLI
- smoke scripts
- tests

The remaining task-language surface is intentionally limited to bridge compatibility responses and migration fallbacks for old on-disk layouts.

Latest local Windows validation on 2026-04-28:

- `.\scripts\zigw.ps1 build test --summary all` -> `67/67 tests passed`
- `.\scripts\health.ps1` -> `status: ready`
