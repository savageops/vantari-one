# VAR1 Client

Framework-free browser client for the `VAR1` bridge.

This folder is the browser operator surface for the harness. It sends session RPC calls to `VAR1 serve`, renders bridge events, and leaves storage, context, tools, and provider calls inside the Zig kernel.

## What it does

- Connects to a running `VAR1` HTTP bridge.
- Creates, resumes, sends to, lists, and reads sessions through canonical RPC methods.
- Displays session progress from bridge event snapshots.
- Runs as static HTML, CSS, and JavaScript with no package install step.

## Quick start

From `apps/backend/variant-1`, start the bridge:

```powershell
.\zig-out\bin\VAR1.exe serve --host 127.0.0.1 --port 4310
```

Open [`index.html`](./index.html), then set the bridge URL to `http://127.0.0.1:4310`.

## Runtime contract

- `POST /rpc`
- `GET /events`
- `GET /api/health`

The client talks to the bridge through the canonical session RPC methods:

- `initialize`
- `session/create`
- `session/send`
- `session/get`
- `session/list`

## Operator flow

1. Confirm bridge health through `GET /api/health`.
2. Create or select a session.
3. Send prompts through `session/send`.
4. Read progress from `GET /events` and hydrate details through `session/get`.

## Boundary

The client does not read `.var/`, construct provider messages, execute tools, or persist transcript state. Those responsibilities belong to `apps/backend/variant-1`.
