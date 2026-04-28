# VAR1 Client

Framework-free browser client for the `VAR1` bridge.

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

## Usage

1. Start the bridge from `apps/backend/variant-1`:

   ```powershell
   .\zig-out\bin\VAR1.exe serve --host 127.0.0.1 --port 4310
   ```

2. Open [index.html](./index.html) directly or serve this folder from any static file host.

3. Point the bridge field at `http://127.0.0.1:4310`.
