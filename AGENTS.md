# VANTARI-ONE Agent Rules

## Runtime Ownership

- `apps/backend/variant-1` is the only live code lane until another app/package has real runtime ownership.
- `VAR1` is a headless kernel first. CLI, browser, and future desktop shells are clients.
- `.var/` is the only runtime/process state root. `.harness` is legacy text only and must not be reintroduced as live ownership.
- Project-local `.var/sessions/<session-id>/` is canonical. Do not copy global home-scoped Codex/Claude project-directory session IDs into this repo.

## Session Storage

Canonical session layout:

```text
.var/sessions/<session-id>/
  session.json
  messages.jsonl
  context.jsonl
  events.jsonl
  output.txt
```

- `messages.jsonl` is the complete durable transcript. It must be append-only after the context baseline lands.
- `context.jsonl` is the compacted/model-ready checkpoint ledger. It must not become a second full transcript.
- Add stable message IDs and monotonic sequence numbers before compaction boundaries depend on message positions.
- Keep old messages readable during migration. Do not rewrite durable transcript history unless a migration is explicit and tested.

## Context Builder Contract

- The context builder is the only owner allowed to turn session storage into provider messages.
- `loop.zig`, CLI clients, HTTP bridge, and provider adapters must not manually assemble chat history.
- The builder reads `session.json`, `messages.jsonl`, and the latest valid `context.jsonl` checkpoint, then emits model-ready messages as: system/runtime context, latest compacted summary, recent raw transcript.
- Full transcript retention and model-visible context are separate concerns. Truncate or summarize only model-visible context.
- Manual `session/compact` lands before auto-compaction. Auto triggers require proven token accounting and cancellation behavior.
- Use simple approximate token estimates first. Add exact tokenizer integration only when evidence proves the heuristic is insufficient.

## Source Hierarchy

- Prefer deep, named ownership modules over flat file sprawl, but do not create empty folder theater.
- New context work belongs under `apps/backend/variant-1/src/core/context/`.
- Core modules are kernel-owned capability domains such as `context`, `sessions`, and `tools`; do not place feature/plugin names directly under `core/`.
- Tool runtime contracts belong under `apps/backend/variant-1/src/core/tools/`. The existing flat `src/tools.zig` may remain the runtime body until a real extraction slice moves behavior behind the namespace.
- Plugin contract code belongs under `apps/backend/variant-1/src/core/plugins/`. Plugin implementations must not live inside `core/`; future project-local plugins should live under a dedicated plugin root such as `apps/backend/variant-1/plugins/<plugin-id>/` or local `.var/plugins/<plugin-id>/` once loading is implemented.
- Session storage helpers should move toward `apps/backend/variant-1/src/core/sessions/` only when the first context slice needs them.
- Keep protocol/shared types in `shared/` only when multiple clients or hosts consume them.

## Pluggability Sockets

- A socket is a typed connector contract: stable name, schema, owner, capability boundary, and tests.
- Add sockets before feature-specific plugins, but do not add empty loader machinery or placeholder adapters.
- Tool sockets use lowercase snake_case names and JSON-object parameter schemas.
- Plugin manifests declare sockets; they do not get direct store/provider/tool access unless the kernel passes a scoped capability.
- Auto-discovery requires manifest validation, deterministic load order, explicit enablement, and lifecycle tests before it becomes runtime behavior.
- Built-in tools remain the default capability surface. Plugin tools are opt-in and must not silently alter the model-visible tool list.

## Reference Discipline

- Use `iex` for repository search in this checkout.
- Before intricate harness changes, inspect the local references in `.refs/`, especially `badlogic__pi-mono` and `openai__codex`.
- Copy ownership patterns, not complexity. Borrow Pi-style checkpoint boundaries and Codex-style context ownership without importing extension trees, branch graphs, or global session stores prematurely.

## Planning Boundary

- Plan first for storage/context architecture changes. Implement only after the target contract, migration behavior, and tests are explicit.
- No parallel systems, hidden fallbacks, or prompt-scaffolding leakage into user-facing output.
- Public docs must describe current runtime truth, not intended future state.
