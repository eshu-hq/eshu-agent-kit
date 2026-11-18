// eshu-bridge.js -- OpenCode global hooks bridge (V1 runtime: the `npm i
// opencode-ai` 1.x line). The default export is the whole plugin: V1 calls
// it per project and uses the returned hooks.
//
// This file intentionally has exactly one export. V1 silently skips plugin
// files that carry extra named exports, so every helper below is a plain
// module-local function. The node:test suite drives the default export
// directly with fixture events and the real bash siblings, which covers
// the wiring the unit tests would otherwise pin one function at a time.
// No external imports (node builtins only): a missing package import would
// break V1 load, and the bridge must never fail a session it cannot help.
//
// The installer bakes KIT_DIR in and copies this one file to the
// auto-discovered global plugins dir; the hook logic stays in the shared
// bash siblings, so there is one copy per event. Every handler fails open
// and never throws: a throwing prompt hook would block admission, and a
// throwing retry hook could disturb the decision the bridge never touches.
//
// Shipped mappings (each proven live against OpenCode 1.19.6):
//   chat.message -> goal-refresh plus the resume note, appended as a text
//     part. Firing and mutation verified with a live model.
//   session.error (event bus) -> stop-failure note on a terminal provider
//     failure. Firing and payload shape verified live.
// Deliberately not here (see hooks/README.md):
//   tool.execute.before blocks: V1 tool hooks carry no command text or
//     file path, and permission.ask stays silent on allowed calls.
//   tool.execute.after capture: same missing command text.
//   session.compacting: registration accepted; firing needs a real
//     compaction to confirm.
//   skill-loaded markers: no skill-load event to observe.
import { spawn } from "node:child_process";

// Kit-owned paths are baked in at install time: the global plugin must
// resolve its siblings without trusting the repo it runs in. ESHU_KIT_DIR
// overrides the baked path (relocating a checkout without reinstalling,
// and the node:test suites, which run the template before install).
// Read per call, not once at load, so a relocated checkout takes effect
// without restarting the host -- and so tests can point at fixture kits.
const KIT_DIR = "%%KIT_DIR%%";

function resolveKitDir() {
  const override =
    typeof process !== "undefined" ? process.env?.ESHU_KIT_DIR : undefined;
  if (typeof override === "string" && override !== "") return override;
  return KIT_DIR;
}

// Sibling part ids must be unique even for two restatements in the same
// millisecond, so a counter rides along with the timestamp.
let partCounter = 0;

function nextPartId() {
  partCounter = (partCounter + 1) % 1296;
  return `prt_eshu_bridge_${Date.now().toString(36)}_${partCounter
    .toString(36)
    .padStart(2, "0")}`;
}

// A hung sibling must never stall the in-process host. Tests shrink the
// window through OPENCODE_BRIDGE_TIMEOUT_MS; production uses the default.
const SIBLING_TIMEOUT_MS = 15_000;

function siblingTimeoutMs() {
  const raw = Number(process.env.OPENCODE_BRIDGE_TIMEOUT_MS);
  return Number.isInteger(raw) && raw > 0 ? raw : SIBLING_TIMEOUT_MS;
}

function asText(value) {
  return typeof value === "string" ? value : "";
}

function joinKit(kitDir, name) {
  const dir = typeof kitDir === "string" ? kitDir : "";
  return `${dir}/hooks/${name}`;
}

// The sibling UserPromptSubmit envelope for a goal refresh. An empty cwd
// takes the sibling have_cwd=0 path (standalone note, still silent).
function buildPromptEnvelope({ sessionID, text, cwd }) {
  return {
    hook_event_name: "UserPromptSubmit",
    prompt: asText(text),
    session_id: asText(sessionID),
    cwd: asText(cwd),
    transcript_path: null,
  };
}

// The sibling StopFailure envelope for a dead turn. Category prefers the
// numeric provider status (what operators grep for), then the error type
// or name -- including the V1 nested data.message shape. Anything missing
// degrades to unknown/empty.
function buildStopEnvelope({ sessionID, cwd, error }) {
  const err = error && typeof error === "object" ? error : {};
  const data = err.data && typeof err.data === "object" ? err.data : {};
  const status =
    typeof err.status === "number" ? String(err.status) : asText(err.status);
  const category =
    status !== ""
      ? status
      : asText(err.type) || asText(err.name) || "unknown";
  return {
    hook_event_name: "StopFailure",
    session_id: asText(sessionID),
    cwd: asText(cwd),
    failure_category: category,
    failure_details: asText(err.message) || asText(data.message),
  };
}

// Pull the restated goal out of a sibling's stdout. Returns the
// additionalContext string, or null when there is nothing to add: garbage,
// empty output, or an envelope without context all mean the prompt passes
// through untouched.
function extractContext(stdout) {
  if (typeof stdout !== "string" || stdout.trim() === "") return null;
  let parsed;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return null;
  }
  const inner = parsed?.hookSpecificOutput;
  const context = inner?.additionalContext;
  return typeof context === "string" && context !== "" ? context : null;
}

// Spawn is used instead of execFile's input option: the input is written
// and the stream closed explicitly, so a stalled stream cannot wedge the
// host. A timeout kills a hung sibling. Resolves the stdout string on a
// clean exit, null on any failure -- every sibling exits 0 even when it
// has nothing to say, so anything else means it never ran properly.
function runSibling(kitDir, name, payload) {
  return new Promise((resolve) => {
    let done = false;
    const finish = (value) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(value);
    };
    let child;
    try {
      child = spawn("/bin/bash", [joinKit(kitDir, name)], {
        stdio: ["pipe", "pipe", "ignore"],
      });
    } catch {
      finish(null);
      return;
    }
    let stdout = "";
    const timer = setTimeout(() => {
      try {
        child.kill("SIGKILL");
      } catch {
        // Already gone; finish below reports the failure.
      }
      finish(null);
    }, siblingTimeoutMs());
    if (typeof timer.unref === "function") timer.unref();
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.on("error", () => finish(null));
    // An stdin stream error (the child died before reading) is async and
    // uncaught by the try/catch around write: without this listener it
    // escapes as an uncaught exception in whoever hosts the plugin.
    child.stdin.on("error", () => finish(null));
    child.on("close", (code) => finish(code === 0 ? stdout : null));
    try {
      child.stdin.write(JSON.stringify(payload));
      child.stdin.end();
    } catch {
      finish(null);
    }
  });
}

async function resolveCwd(resolveDir, sessionID) {
  try {
    const dir = await resolveDir(sessionID);
    return typeof dir === "string" ? dir : "";
  } catch {
    return "";
  }
}

// Goal refresh: restate the session goal (plus any pending resume note)
// into the admitted prompt by appending a fully-formed text part, mirroring
// the documented files.push pattern. Returns "restated" or "silent".
async function handleChatMessage(deps, input, output) {
  try {
    if (typeof input?.sessionID !== "string") return "silent";
    const parts = output?.parts;
    if (!Array.isArray(parts) || parts.length === 0) return "silent";
    const texts = parts
      .filter((p) => p && typeof p.text === "string")
      .map((p) => p.text);
    if (texts.length === 0) return "silent";
    const cwd = await resolveCwd(deps.resolveDir, input.sessionID);
    const envelope = buildPromptEnvelope({
      sessionID: input.sessionID,
      text: texts.join("\n"),
      cwd,
    });
    const stdout = await runSibling(
      resolveKitDir(),
      "goal-refresh.sh",
      envelope,
    );
    const context = extractContext(stdout);
    if (context === null) return "silent";
    const first = parts[0];
    parts.push({
      type: "text",
      text: context,
      messageID: (first && asText(first.messageID)) || asText(input.messageID),
      sessionID: input.sessionID,
      id: nextPartId(),
    });
    return "restated";
  } catch {
    return "silent";
  }
}

// Dead-turn recorder: on a provider error event, write the at-most-once
// resume note the next prompt picks up. Observes only. Returns "recorded",
// "ignored", or "silent" when the note could not be written.
async function handleSessionError(deps, event) {
  try {
    if (!event || event.type !== "session.error") return "ignored";
    const props = event.properties || {};
    if (typeof props.sessionID !== "string") return "ignored";
    const cwd = await resolveCwd(deps.resolveDir, props.sessionID);
    const envelope = buildStopEnvelope({
      sessionID: props.sessionID,
      cwd,
      error: props.error,
    });
    const stdout = await runSibling(
      resolveKitDir(),
      "stop-failure.sh",
      envelope,
    );
    return stdout === null ? "silent" : "recorded";
  } catch {
    return "silent";
  }
}

// Session working directories, learned from session.created events (whose
// info carries the directory) with the plugin input directory as fallback.
// The prompt and error events carry no cwd of their own.
function createSessionDirs() {
  const dirs = new Map();
  return {
    note(sessionID, directory) {
      if (
        typeof sessionID === "string" &&
        typeof directory === "string" &&
        directory !== ""
      ) {
        dirs.set(sessionID, directory);
      }
    },
    resolve(fallbackDir) {
      return async (sessionID) => {
        if (typeof sessionID === "string" && dirs.has(sessionID)) {
          return dirs.get(sessionID);
        }
        return typeof fallbackDir === "string" ? fallbackDir : "";
      };
    },
  };
}

export default async (pluginInput) => {
  const fallbackDir =
    pluginInput && typeof pluginInput.directory === "string"
      ? pluginInput.directory
      : "";
  const sessions = createSessionDirs();
  const deps = {
    resolveDir: sessions.resolve(fallbackDir),
  };
  return {
    event: async ({ event }) => {
      try {
        if (
          event &&
          event.type === "session.created" &&
          event.properties &&
          event.properties.info
        ) {
          sessions.note(
            event.properties.info.id,
            event.properties.info.directory,
          );
        }
        await handleSessionError(deps, event);
      } catch {
        // Fail open: event observation must never break the host.
      }
    },
    "chat.message": async (input, output) => {
      await handleChatMessage(deps, input, output);
    },
  };
};
