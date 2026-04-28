const DEFAULT_BRIDGE_ORIGIN = "http://127.0.0.1:4310";
const STORAGE_KEY = "var1-client.bridge-origin";
const EVENT_POLL_MS = 1200;

const state = {
  bridgeOrigin: loadBridgeOrigin(),
  sessions: [],
  selectedSessionId: null,
  sessionDetail: null,
  lastEventId: 0,
  rpcCounter: 0,
  eventTimer: null,
};

const refs = {
  bridgeOrigin: document.getElementById("bridge-origin"),
  bridgeStatus: document.getElementById("bridge-status"),
  healthModel: document.getElementById("health-model"),
  healthRoot: document.getElementById("health-root"),
  sessionCount: document.getElementById("session-count"),
  sessionList: document.getElementById("session-list"),
  createForm: document.getElementById("create-form"),
  createPrompt: document.getElementById("create-prompt"),
  connectButton: document.getElementById("connect-button"),
  refreshButton: document.getElementById("refresh-button"),
  detailTitle: document.getElementById("detail-title"),
  detailEmpty: document.getElementById("detail-empty"),
  detailContent: document.getElementById("detail-content"),
  detailStatus: document.getElementById("detail-status"),
  detailUpdated: document.getElementById("detail-updated"),
  detailPrompt: document.getElementById("detail-prompt"),
  detailOutput: document.getElementById("detail-output"),
  messageTimeline: document.getElementById("message-timeline"),
  eventTimeline: document.getElementById("event-timeline"),
  followupForm: document.getElementById("followup-form"),
  followupPrompt: document.getElementById("followup-prompt"),
  resumeButton: document.getElementById("resume-button"),
  copyOutputButton: document.getElementById("copy-output-button"),
};

refs.bridgeOrigin.value = state.bridgeOrigin;

refs.connectButton.addEventListener("click", () => {
  void reconnect();
});

refs.refreshButton.addEventListener("click", () => {
  void refreshAll();
});

refs.createForm.addEventListener("submit", (event) => {
  event.preventDefault();
  void createAndRunSession();
});

refs.followupForm.addEventListener("submit", (event) => {
  event.preventDefault();
  void sendFollowup();
});

refs.resumeButton.addEventListener("click", () => {
  void resumeSession();
});

refs.copyOutputButton.addEventListener("click", async () => {
  const output = state.sessionDetail?.session?.output ?? "";
  if (!output) {
    return;
  }

  try {
    await navigator.clipboard.writeText(output);
    setBridgeStatus("Output copied", "ready");
  } catch (error) {
    console.error(error);
    setBridgeStatus("Clipboard failed", "error");
  }
});

void reconnect();

async function reconnect() {
  const nextOrigin = normalizeBridgeOrigin(refs.bridgeOrigin.value);
  state.bridgeOrigin = nextOrigin;
  refs.bridgeOrigin.value = nextOrigin;
  localStorage.setItem(STORAGE_KEY, nextOrigin);
  state.lastEventId = 0;
  setBridgeStatus("Connecting", "idle");
  await refreshAll();
  scheduleEventPoll();
}

async function refreshAll() {
  try {
    await rpc("initialize", {});
    await refreshHealth();
    await refreshSessions();
    setBridgeStatus("Connected", "ready");
  } catch (error) {
    console.error(error);
    setBridgeStatus(`Bridge error: ${error.message}`, "error");
  }
}

async function refreshHealth() {
  const response = await fetch(`${state.bridgeOrigin}/api/health`, {
    headers: { Accept: "application/json" },
  });

  if (!response.ok) {
    throw new Error(`health request failed with ${response.status}`);
  }

  const health = await response.json();
  refs.healthModel.textContent = health.model ?? "-";
  refs.healthRoot.textContent = health.workspace_root ?? "-";
}

async function refreshSessions() {
  const result = await rpc("session/list", {});
  state.sessions = Array.isArray(result.sessions) ? result.sessions.slice() : [];
  state.sessions.sort((left, right) => (right.updated_at_ms ?? 0) - (left.updated_at_ms ?? 0));
  refs.sessionCount.textContent = String(state.sessions.length);

  if (state.sessions.length === 0) {
    state.selectedSessionId = null;
    state.sessionDetail = null;
    renderSessionList();
    renderSessionDetail();
    return;
  }

  const stillExists = state.sessions.some((session) => session.session_id === state.selectedSessionId);
  if (!stillExists) {
    state.selectedSessionId = state.sessions[0].session_id;
  }

  renderSessionList();
  await loadSession(state.selectedSessionId, true);
}

async function loadSession(sessionId, silent = false) {
  if (!sessionId) {
    return;
  }

  try {
    const detail = await rpc("session/get", { session_id: sessionId });
    state.selectedSessionId = sessionId;
    state.sessionDetail = detail;
    renderSessionList();
    renderSessionDetail();
  } catch (error) {
    if (!silent) {
      throw error;
    }
  }
}

async function createAndRunSession() {
  const prompt = refs.createPrompt.value.trim();
  if (!prompt) {
    setBridgeStatus("Prompt required", "error");
    return;
  }

  try {
    const created = await rpc("session/create", { prompt });
    const sessionId = created.session.session_id;
    await rpc("session/send", { session_id: sessionId });
    refs.createPrompt.value = "";
    state.selectedSessionId = sessionId;
    await refreshSessions();
  } catch (error) {
    console.error(error);
    setBridgeStatus(`Create failed: ${error.message}`, "error");
  }
}

async function sendFollowup() {
  const prompt = refs.followupPrompt.value.trim();
  if (!state.selectedSessionId || !prompt) {
    return;
  }

  try {
    await rpc("session/send", {
      session_id: state.selectedSessionId,
      prompt,
    });
    refs.followupPrompt.value = "";
    await refreshSessions();
  } catch (error) {
    console.error(error);
    setBridgeStatus(`Follow-up failed: ${error.message}`, "error");
  }
}

async function resumeSession() {
  if (!state.selectedSessionId) {
    return;
  }

  try {
    await rpc("session/send", {
      session_id: state.selectedSessionId,
    });
    await refreshSessions();
  } catch (error) {
    console.error(error);
    setBridgeStatus(`Resume failed: ${error.message}`, "error");
  }
}

function renderSessionList() {
  refs.sessionList.innerHTML = "";

  if (state.sessions.length === 0) {
    refs.sessionList.innerHTML = '<div class="empty-state">No sessions yet.</div>';
    return;
  }

  for (const session of state.sessions) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "session-item";
    if (session.session_id === state.selectedSessionId) {
      button.classList.add("is-selected");
    }

    button.innerHTML = `
      <p class="session-item-title">${escapeHtml(session.prompt || session.session_id)}</p>
      <p class="session-item-meta">${escapeHtml(formatSessionMeta(session))}</p>
    `;

    button.addEventListener("click", () => {
      void loadSession(session.session_id);
    });

    refs.sessionList.append(button);
  }
}

function renderSessionDetail() {
  const detail = state.sessionDetail;
  if (!detail || !detail.session) {
    refs.detailEmpty.classList.remove("hidden");
    refs.detailContent.classList.add("hidden");
    refs.resumeButton.disabled = true;
    refs.copyOutputButton.disabled = true;
    refs.detailTitle.textContent = "Nothing selected";
    refs.detailOutput.textContent = "";
    refs.messageTimeline.innerHTML = "";
    refs.eventTimeline.innerHTML = "";
    return;
  }

  refs.detailEmpty.classList.add("hidden");
  refs.detailContent.classList.remove("hidden");
  refs.resumeButton.disabled = false;
  refs.copyOutputButton.disabled = !detail.session.output;
  refs.detailTitle.textContent = detail.session.session_id;
  refs.detailStatus.textContent = humanize(detail.session.status);
  refs.detailUpdated.textContent = formatTimestamp(detail.session.updated_at_ms);
  refs.detailPrompt.textContent = detail.session.prompt || "-";
  refs.detailOutput.textContent = detail.session.output || "(no output yet)";

  renderTimeline(
    refs.messageTimeline,
    detail.messages || [],
    (message) => ({
      title: humanize(message.role),
      meta: formatTimestamp(message.timestamp_ms),
      body: message.content,
      className: message.role === "assistant" ? "message-assistant" : "message-user",
    }),
  );

  renderTimeline(
    refs.eventTimeline,
    detail.events || [],
    (event) => ({
      title: humanize(event.event_type),
      meta: formatTimestamp(event.timestamp_ms),
      body: event.message,
      className: "",
    }),
  );
}

function renderTimeline(container, items, transform) {
  container.innerHTML = "";

  if (!Array.isArray(items) || items.length === 0) {
    container.innerHTML = '<div class="empty-state">No entries yet.</div>';
    return;
  }

  for (const item of items) {
    const view = transform(item);
    const article = document.createElement("article");
    article.className = `timeline-item ${view.className}`.trim();
    article.innerHTML = `
      <h4>${escapeHtml(view.title)}</h4>
      <p class="timeline-meta">${escapeHtml(view.meta)}</p>
      <p>${escapeHtml(view.body || "")}</p>
    `;
    container.append(article);
  }
}

function scheduleEventPoll() {
  if (state.eventTimer) {
    clearTimeout(state.eventTimer);
  }

  state.eventTimer = setTimeout(async () => {
    try {
      const response = await fetch(`${state.bridgeOrigin}/events?since=${state.lastEventId}`, {
        headers: { Accept: "text/event-stream" },
      });

      if (!response.ok) {
        throw new Error(`event poll failed with ${response.status}`);
      }

      const text = await response.text();
      const snapshot = parseSseSnapshot(text);
      if (snapshot) {
        state.lastEventId = Math.max(state.lastEventId, snapshot.id);
        await refreshSessions();
      }
    } catch (error) {
      console.error(error);
      setBridgeStatus(`Event poll failed: ${error.message}`, "error");
    } finally {
      scheduleEventPoll();
    }
  }, EVENT_POLL_MS);
}

function parseSseSnapshot(text) {
  if (!text || text.startsWith(":")) {
    return null;
  }

  let id = null;
  let eventName = "";
  const dataLines = [];
  const lines = text.split(/\r?\n/);
  for (const line of lines) {
    if (line.startsWith("id:")) {
      id = Number(line.slice(3).trim());
      continue;
    }
    if (line.startsWith("event:")) {
      eventName = line.slice(6).trim();
      continue;
    }
    if (line.startsWith("data:")) {
      dataLines.push(line.slice(5).trim());
    }
  }

  if (!id || dataLines.length === 0) {
    return null;
  }

  let data = null;
  try {
    data = JSON.parse(dataLines.join("\n"));
  } catch (error) {
    console.error(error);
  }

  return { id, eventName, data };
}

async function rpc(method, params) {
  const payload = {
    jsonrpc: "2.0",
    id: `req-${Date.now()}-${++state.rpcCounter}`,
    method,
    params,
  };

  const response = await fetch(`${state.bridgeOrigin}/rpc`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    throw new Error(`rpc ${method} failed with ${response.status}`);
  }

  const envelope = await response.json();
  if (envelope.error) {
    throw new Error(envelope.error.message || JSON.stringify(envelope.error));
  }

  return envelope.result;
}

function setBridgeStatus(text, tone) {
  refs.bridgeStatus.textContent = text;
  refs.bridgeStatus.className = `status-pill status-${tone}`;
}

function formatSessionMeta(session) {
  const parts = [
    humanize(session.status || "unknown"),
    formatTimestamp(session.updated_at_ms),
  ];
  return parts.filter(Boolean).join(" • ");
}

function formatTimestamp(timestampMs) {
  if (!timestampMs) {
    return "-";
  }

  const date = new Date(timestampMs);
  if (Number.isNaN(date.getTime())) {
    return "-";
  }

  return date.toLocaleString();
}

function humanize(value) {
  return String(value || "-")
    .replaceAll("_", " ")
    .replace(/\b\w/g, (match) => match.toUpperCase());
}

function normalizeBridgeOrigin(value) {
  const trimmed = String(value || "").trim();
  if (!trimmed) {
    return DEFAULT_BRIDGE_ORIGIN;
  }
  return trimmed.replace(/\/+$/, "");
}

function loadBridgeOrigin() {
  const stored = localStorage.getItem(STORAGE_KEY);
  return normalizeBridgeOrigin(stored || DEFAULT_BRIDGE_ORIGIN);
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
