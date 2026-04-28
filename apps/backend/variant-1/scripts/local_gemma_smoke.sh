#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FRONTEND_CLIENT_DIR="$(cd "$ROOT_DIR/../.." && pwd)/frontend/var1-client"
RUN_TIMEOUT_SECONDS=90
BRIDGE_PORT=4311
SMOKE_DIR="$ROOT_DIR/.zig-cache/smoke"
SANITY_PROMPT='Count the lowercase letter r in this exact character sequence: s t r a w b e r r y. Return only the number.'
BRIDGE_PID=""

to_windows_path() {
  local path="$1"
  if command -v wslpath >/dev/null 2>&1; then
    wslpath -w "$path"
    return
  fi
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$path"
    return
  fi
  printf '%s\n' "$path"
}

if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* || -n "${MSYSTEM:-}" ]]; then
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(to_windows_path "$SCRIPT_DIR/local_gemma_smoke.ps1")" -Port "$BRIDGE_PORT"
fi

WINDOWS_ROOT="$(to_windows_path "$ROOT_DIR")"

cd "$ROOT_DIR"
mkdir -p "$SMOKE_DIR"

BRIDGE_OUT="$SMOKE_DIR/bridge-out.txt"
BRIDGE_ERR="$SMOKE_DIR/bridge-err.txt"

if ! grep -q '^OPENAI_BASE_URL=http://127.0.0.1:1234$' .env; then
  echo "GEMMA_LOCAL expected OPENAI_BASE_URL=http://127.0.0.1:1234 in .env" >&2
  exit 1
fi

if ! grep -q '^OPENAI_MODEL=gemma-4-26b-a4b-it-apex$' .env; then
  echo "GEMMA_LOCAL expected OPENAI_MODEL=gemma-4-26b-a4b-it-apex in .env" >&2
  exit 1
fi

provider_models_url() {
  local base_url="$1"
  base_url="${base_url%/}"
  if [[ "$base_url" =~ /v[0-9]+$ ]]; then
    printf '%s/models\n' "$base_url"
    return
  fi
  printf '%s/v1/models\n' "$base_url"
}

OPENAI_BASE_URL="$(grep '^OPENAI_BASE_URL=' .env | cut -d= -f2-)"
OPENAI_API_KEY="$(grep '^OPENAI_API_KEY=' .env | cut -d= -f2-)"
OPENAI_MODEL="$(grep '^OPENAI_MODEL=' .env | cut -d= -f2-)"
PROVIDER_MODELS_URL="$(provider_models_url "$OPENAI_BASE_URL")"
models_payload="$(curl -fsS -H "Authorization: Bearer $OPENAI_API_KEY" "$PROVIDER_MODELS_URL")" || {
  echo "GEMMA_LOCAL expected reachable provider at $PROVIDER_MODELS_URL" >&2
  exit 1
}

if ! python3 - <<'PY' "$models_payload" "$OPENAI_MODEL"
import json, sys
payload = json.loads(sys.argv[1])
target = sys.argv[2]
available = [item.get("id", "") for item in payload.get("data", [])]
if target in available:
    raise SystemExit(0)
print("GEMMA_LOCAL expected model %s to be served. Available models: %s" % (target, ", ".join(available) or "<none>"), file=sys.stderr)
raise SystemExit(1)
PY
then
  exit 1
fi

run_windows_variant1() {
  local label="$1"
  shift

  local output
  if ! output="$(run_with_optional_timeout "$ROOT_DIR/zig-out/bin/VAR1.exe" "$@" | sed 's/\r$//')"; then
    echo "GEMMA_LOCAL $label timed out or failed before completion" >&2
    return 1
  fi

  printf '%s\n' "$output"
  REPLY="$output"
}

run_with_optional_timeout() {
  if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then
    timeout "$RUN_TIMEOUT_SECONDS" "$@"
    return
  fi

  "$@"
}

get_bridge_owner() {
  powershell.exe -NoProfile -Command "\$connection = Get-NetTCPConnection -LocalPort $BRIDGE_PORT -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1; if (\$connection) { \$process = Get-Process -Id \$connection.OwningProcess -ErrorAction SilentlyContinue; if (\$process) { Write-Output (\$process.Id.ToString() + '|' + \$process.ProcessName) } }" | tr -d '\r'
}

clear_bridge_port() {
  local owner
  owner="$(get_bridge_owner)"
  if [[ -z "$owner" ]]; then
    return 0
  fi

  local pid="${owner%%|*}"
  local name="${owner#*|}"
  if [[ "$name" != "VAR1" ]]; then
    echo "GEMMA_LOCAL bridge port $BRIDGE_PORT is already owned by non-VAR1 process $name (PID $pid)" >&2
    return 1
  fi

  cmd.exe /c "taskkill /F /PID $pid" >/dev/null 2>&1
}

start_bridge() {
  clear_bridge_port
  rm -f "$BRIDGE_OUT" "$BRIDGE_ERR" "$ROOT_DIR/bridge-out.txt" "$ROOT_DIR/bridge-err.txt"
  "$ROOT_DIR/zig-out/bin/VAR1.exe" serve --host 127.0.0.1 --port "$BRIDGE_PORT" > "$BRIDGE_OUT" 2> "$BRIDGE_ERR" &
  BRIDGE_PID="$!"
}

stop_started_bridge() {
  if [[ -n "${BRIDGE_PID:-}" ]]; then
    kill "$BRIDGE_PID" >/dev/null 2>&1 || true
    wait "$BRIDGE_PID" 2>/dev/null || true
    BRIDGE_PID=""
  fi
  clear_bridge_port || true
}

windows_http_get() {
  local path="$1"
  local output_file="$2"
  rm -f "$output_file"
  curl.exe -s "http://127.0.0.1:$BRIDGE_PORT$path" | sed 's/\r$//' > "$output_file"
  cat "$output_file"
}

windows_http_post_json() {
  local path="$1"
  local request_file="$2"
  local output_file="$3"
  local windows_request_file

  windows_request_file="$(to_windows_path "$request_file")"
  rm -f "$output_file"
  curl.exe -s -X POST -H "Content-Type: application/json" --data-binary "@$windows_request_file" "http://127.0.0.1:$BRIDGE_PORT$path" | sed 's/\r$//' > "$output_file"
  cat "$output_file"
}

echo "GEMMA_LOCAL suite"
./scripts/zigw.sh build test --summary all

echo "GEMMA_LOCAL windows build"
./scripts/zigw.sh build -Dtarget=x86_64-windows-gnu --summary all

prompt_file="$(mktemp "$SMOKE_DIR/gemma-delegated-prompt.XXXXXX.txt")"
trap 'rm -f "$prompt_file"' EXIT
cat > "$prompt_file" <<'EOF'
Launch a child agent named berry-child.
Child prompt: Count the lowercase letter r in this exact character sequence: s t r a w b e r r y. Return only the number.
Use agent_status as the primary supervision surface.
Use wait_agent only when you are ready to collect a current or terminal snapshot.
Return only the child's final answer and nothing else.
EOF
WINDOWS_PROMPT_FILE="$(to_windows_path "$prompt_file")"

echo "GEMMA_LOCAL direct run"
run_windows_variant1 "direct-run" run --prompt "$SANITY_PROMPT"
direct_run_output="$REPLY"
if [[ "$direct_run_output" != *"3"* ]]; then
  echo "GEMMA_LOCAL direct run did not clearly report 3" >&2
  exit 1
fi

echo "GEMMA_LOCAL delegated"
run_windows_variant1 "delegated" run --prompt-file "$WINDOWS_PROMPT_FILE"
delegated_output="$REPLY"
if [[ "$delegated_output" != *"3"* ]]; then
  echo "GEMMA_LOCAL delegated run did not clearly report 3" >&2
  exit 1
fi

echo "GEMMA_LOCAL bridge"
start_bridge

health_file="$(mktemp "$SMOKE_DIR/gemma-bridge-health.XXXXXX.json")"
create_output_file="$(mktemp "$SMOKE_DIR/gemma-bridge-create.XXXXXX.json")"
detail_output_file="$(mktemp "$SMOKE_DIR/gemma-bridge-detail.XXXXXX.json")"
journal_output_file="$(mktemp "$SMOKE_DIR/gemma-bridge-journal.XXXXXX.json")"
trap 'rm -f "$prompt_file" "${bridge_request:-}" "$health_file" "$create_output_file" "$detail_output_file" "$journal_output_file"; stop_started_bridge' EXIT

health_output=""
for _ in $(seq 1 40); do
  if health_output="$(windows_http_get "/api/health" "$health_file")"; then
    break
  fi
  sleep 1
done

if [[ "$health_output" != *"gemma-4-26b-a4b-it-apex"* ]]; then
  echo "GEMMA_LOCAL bridge health did not report the active gemma model" >&2
  exit 1
fi

if [[ ! -f "$FRONTEND_CLIENT_DIR/index.html" ]]; then
  echo "GEMMA_LOCAL expected external browser client at $FRONTEND_CLIENT_DIR" >&2
  exit 1
fi

bridge_home="$(windows_http_get "/" "$health_file")"
if [[ "$bridge_home" != *"VAR1 HTTP bridge ready"* ]]; then
  echo "GEMMA_LOCAL bridge root did not return bridge-only text" >&2
  exit 1
fi
if [[ "$bridge_home" != *"apps/frontend/var1-client"* ]]; then
  echo "GEMMA_LOCAL bridge root did not point operators to apps/frontend/var1-client" >&2
  exit 1
fi

bridge_request="$(mktemp "$SMOKE_DIR/gemma-bridge-request.XXXXXX.json")"
printf '{"prompt":"%s"}' "$SANITY_PROMPT" > "$bridge_request"

create_output="$(windows_http_post_json "/api/tasks" "$bridge_request" "$create_output_file")"

task_id="$(python3 - <<'PY' "$create_output"
import json, sys
payload = json.loads(sys.argv[1])
print(payload["task"]["id"])
PY
)"

if [[ -z "$task_id" ]]; then
  echo "GEMMA_LOCAL bridge compatibility route did not return a task id" >&2
  exit 1
fi

detail_output=""
for _ in $(seq 1 40); do
  detail_output="$(windows_http_get "/api/tasks/$task_id" "$detail_output_file")"
  if python3 - <<'PY' "$detail_output"
import json, sys
payload = json.loads(sys.argv[1])
status = payload["task"]["status"]
answer = payload["task"].get("answer") or ""
raise SystemExit(0 if status == "completed" and "3" in answer else 1)
PY
  then
    break
  fi
  sleep 1
done

if ! python3 - <<'PY' "$detail_output"
import json, sys
payload = json.loads(sys.argv[1])
status = payload["task"]["status"]
answer = payload["task"].get("answer") or ""
raise SystemExit(0 if status == "completed" and "3" in answer else 1)
PY
then
  echo "GEMMA_LOCAL bridge compatibility task did not complete with the expected answer" >&2
  exit 1
fi

journal_output="$(windows_http_get "/api/tasks/$task_id/journal" "$journal_output_file")"
if [[ "$journal_output" != *"assistant_response"* ]]; then
  echo "GEMMA_LOCAL bridge compatibility journal did not expose assistant_response" >&2
  exit 1
fi

echo "GEMMA_LOCAL bridge ok"
