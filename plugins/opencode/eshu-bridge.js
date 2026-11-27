// eshu-bridge.js -- OpenCode global hooks bridge (V2 runtime: opencode v2.x).
// Default export is a V2 server plugin definition `{ id, setup(context) }`
// with zero external imports (node builtins only): a missing package import
// would break plugin load, and the bridge must never fail a session it cannot
// help.
//
// The installer bakes KIT_DIR in and copies this one file to the
// auto-discovered global plugins dir (~/.config/opencode/plugins/); the hook
// logic stays in the shared bash siblings, so there is one copy per event.
// Every handler fails open and never throws: a throwing prompt hook would
// block admission, and a throwing event or tool observer must never disturb
// the host.
//
// Shipped V2 mappings (proven live against opencode v2.4.0):
//   session.hook("prompt")     -> goal-refresh plus resume note appended to
//     input.prompt.text.
//   session.hook("compaction") -> on-compact warning pushed to input.system
//     as a `{ type: "text", text }` block.
//   event.subscribe            -> stop-failure note on
//     `session.execution.failed` (or `session.error`).
//   tool.hook("execute.after") -> skill-loaded marker + telemetry
//     (`KIT_HARNESS=opencode`) when the `skill` tool or a `SKILL.md` read
//     completes.
import { spawn } from "node:child_process";

// Kit-owned paths are baked in at install time: the global plugin must
// resolve its siblings without trusting the repo it runs in. ESHU_KIT_DIR
// overrides the baked path (relocating a checkout without reinstalling,
// and the node:test suites, which run the template before install).
const KIT_DIR = "%%KIT_DIR%%";

function resolveKitDir() {
  const override =
    typeof process !== "undefined" ? process.env?.ESHU_KIT_DIR : undefined;
  if (typeof override === "string" && override !== "") return override;
  return KIT_DIR;
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
// numeric provider status, then the V2 error type or name (including nested
// data.message). Anything missing degrades to unknown/empty.
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

function buildSkillLoadedEnvelope({ sessionID, skill, cwd }) {
  return {
    hook_event_name: "PostToolUse",
    tool_name: "Skill",
    session_id: asText(sessionID),
    cwd: asText(cwd),
    tool_input: { skill: asText(skill) },
  };
}

// Pull the restated goal or compaction warning out of a sibling's stdout.
// Returns the additionalContext string, or null when there is nothing to add.
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

// Extract a skill name from a completed V2 tool call (`skill` tool or a
// `read` of `.../<skill-name>/SKILL.md`). Returns "" for all other calls.
function extractSkillName(event) {
  const tool = asText(event?.tool).toLowerCase();
  const input =
    event?.input && typeof event.input === "object" ? event.input : {};
  if (tool === "skill") {
    const raw =
      asText(input.name) || asText(input.skill) || asText(input.skill_name);
    return raw.trim();
  }
  if (tool === "read" || tool === "read_file" || tool === "view_file") {
    const fp =
      asText(input.filePath) || asText(input.file_path) || asText(input.path);
    const match = fp.match(/(?:^|[/\\])([A-Za-z0-9._-]+)[/\\]SKILL\.md$/);
    return match ? match[1] : "";
  }
  return "";
}

// Spawn is used instead of execFile's input option: the input is written
// and the stream closed explicitly, so a stalled stream cannot wedge the
// host. A timeout kills a hung sibling. Resolves stdout on exit 0, null on
// any failure.
function runSibling(kitDir, name, payload) {
  return new Promise((resolve) => {
    let done = false;
    let timer;
    const finish = (value) => {
      if (done) return;
      done = true;
      if (timer !== undefined) clearTimeout(timer);
      resolve(value);
    };
    let child;
    try {
      child = spawn("/bin/bash", [joinKit(kitDir, name)], {
        stdio: ["pipe", "pipe", "ignore"],
        env: { ...process.env, KIT_HARNESS: "opencode" },
        detached: true,
      });
    } catch {
      finish(null);
      return;
    }
    let stdout = "";
    timer = setTimeout(() => {
      try {
        if (typeof child.pid === "number" && child.pid > 0) {
          process.kill(-child.pid, "SIGKILL");
        } else {
          child.kill("SIGKILL");
        }
      } catch {
        try {
          child.kill("SIGKILL");
        } catch {
          // Already gone; finish below reports the failure.
        }
      }
      finish(null);
    }, siblingTimeoutMs());
    if (typeof timer.unref === "function") timer.unref();
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stdout.on("error", () => finish(null));
    child.on("error", () => finish(null));
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

async function resolveCwd(resolveDir, sessionID, preferredDir) {
  if (typeof preferredDir === "string" && preferredDir !== "") {
    return preferredDir;
  }
  try {
    const dir = await resolveDir(sessionID);
    return typeof dir === "string" ? dir : "";
  } catch {
    return "";
  }
}

// Goal refresh (`session.hook("prompt")`): restate the session goal (plus
// any pending resume note) by appending to `input.prompt.text`.
async function handlePrompt(deps, input) {
  try {
    if (typeof input?.sessionID !== "string") return "silent";
    const prompt = input?.prompt;
    if (!prompt || typeof prompt.text !== "string" || prompt.text === "") {
      return "silent";
    }
    const cwd = await resolveCwd(deps.resolveDir, input.sessionID);
    const envelope = buildPromptEnvelope({
      sessionID: input.sessionID,
      text: prompt.text,
      cwd,
    });
    const stdout = await runSibling(
      resolveKitDir(),
      "goal-refresh.sh",
      envelope,
    );
    const context = extractContext(stdout);
    if (context === null) return "silent";
    if (prompt.text.includes(context)) return "silent";
    prompt.text = `${prompt.text}\n\n${context}`;
    return "restated";
  } catch {
    return "silent";
  }
}

// Compaction guard (`session.hook("compaction")`): append the on-compact
// warning to `input.system` as a text block so the post-compaction model
// re-invokes its skills instead of trusting the summary.
async function handleCompaction(deps, input) {
  try {
    if (typeof input?.sessionID !== "string") return "silent";
    if (!Array.isArray(input?.system)) return "silent";
    const cwd = await resolveCwd(deps.resolveDir, input.sessionID);
    const envelope = buildPromptEnvelope({
      sessionID: input.sessionID,
      text: "",
      cwd,
    });
    const stdout = await runSibling(
      resolveKitDir(),
      "on-compact.sh",
      envelope,
    );
    const context = extractContext(stdout);
    if (context === null) return "silent";
    if (
      input.system.some(
        (block) => block && typeof block.text === "string" && block.text === context,
      )
    ) {
      return "silent";
    }
    input.system.push({ type: "text", text: context });
    return "appended";
  } catch {
    return "silent";
  }
}

// Dead-turn recorder (`session.execution.failed` or `session.error`): write
// the at-most-once resume note that the next prompt picks up.
async function handleSessionEvent(deps, sessions, event) {
  try {
    if (!event || typeof event !== "object") return "ignored";
    const data =
      (event.data && typeof event.data === "object" && event.data) ||
      (event.properties && typeof event.properties === "object" && event.properties) ||
      {};
    const locDir = asText(event.location?.directory);
    if (event.type === "session.created") {
      const sid = asText(data.sessionID) || asText(data.info?.id);
      const dir = locDir || asText(data.info?.directory);
      sessions.note(sid, dir);
      return "noted";
    }
    if (
      event.type !== "session.execution.failed" &&
      event.type !== "session.error"
    ) {
      return "ignored";
    }
    const sessionID = asText(data.sessionID);
    if (sessionID === "") return "ignored";
    const cwd = await resolveCwd(deps.resolveDir, sessionID, locDir);
    const envelope = buildStopEnvelope({
      sessionID,
      cwd,
      error: data.error,
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

// Skill-load and PR-watch observer (`tool.hook("execute.after")`): record
// skill markers and PR watcher state/telemetry with `KIT_HARNESS=opencode`.
async function handleToolAfter(deps, event) {
  try {
    if (!event || event.status !== "completed") return "ignored";
    if (typeof event.sessionID !== "string" || event.sessionID === "") {
      return "ignored";
    }
    const skill = extractSkillName(event);
    if (skill !== "") {
      const cwd = await resolveCwd(deps.resolveDir, event.sessionID);
      const envelope = buildSkillLoadedEnvelope({
        sessionID: event.sessionID,
        skill,
        cwd,
      });
      const stdout = await runSibling(resolveKitDir(), "skill-loaded.sh", envelope);
      return stdout === null ? "silent" : "recorded";
    }
    const tool = asText(event.tool).toLowerCase();
    if (tool === "bash" || tool === "shell") {
      const input = event.input && typeof event.input === "object" ? event.input : {};
      const cmd = asText(input.command) || asText(input.cmd);
      const out = asText(event.output);
      if (
        cmd !== "" &&
        (cmd.includes("pr create") || cmd.includes("watch-pr.sh") || cmd.includes("pr-watch") || out.includes("/pull/"))
      ) {
        const cwd = await resolveCwd(deps.resolveDir, event.sessionID);
        const stdout = await runSibling(resolveKitDir(), "pr-watch-nudge.sh", {
          hook_event_name: "PostToolUse",
          tool_name: "Bash",
          session_id: event.sessionID,
          cwd,
          tool_input: { command: cmd },
          tool_response: { stdout: out },
        });
        const ctx = extractContext(stdout);
        if (ctx !== null && typeof event.output === "string" && !event.output.includes(ctx)) {
          event.output = `${event.output}\n\n${ctx}`;
        }
        return stdout === null ? "silent" : "recorded";
      }
    }
    return "ignored";
  } catch {
    return "silent";
  }
}

// Session working directories learned from `session.created` events, optional
// `context.session.get`, and finally `context.location.directory`.
function createSessionDirs(context) {
  const dirs = new Map();
  const fallbackDir =
    asText(context?.location?.directory) || asText(context?.directory);
  return {
    note(sessionID, directory) {
      if (
        typeof sessionID === "string" &&
        sessionID !== "" &&
        typeof directory === "string" &&
        directory !== ""
      ) {
        dirs.set(sessionID, directory);
      }
    },
    resolve() {
      return async (sessionID) => {
        if (typeof sessionID === "string" && dirs.has(sessionID)) {
          return dirs.get(sessionID);
        }
        if (
          typeof sessionID === "string" &&
          sessionID !== "" &&
          typeof context?.session?.get === "function"
        ) {
          try {
            const info = await context.session.get({ sessionID });
            const dir = asText(info?.directory) || asText(info?.location?.directory);
            if (dir !== "") {
              dirs.set(sessionID, dir);
              return dir;
            }
          } catch {
            // Fall through to location directory.
          }
        }
        return fallbackDir;
      };
    },
  };
}

async function safeDispose(handle) {
  try {
    if (handle && typeof handle.dispose === "function") {
      await handle.dispose();
    }
  } catch {
    // Fail open on teardown.
  }
}

export default {
  id: "eshu-bridge",
  async setup(context) {
    const sessions = createSessionDirs(context);
    const deps = { resolveDir: sessions.resolve() };
    const handles = [];
    const controller = new AbortController();

    if (typeof context?.session?.hook === "function") {
      try {
        handles.push(
          await context.session.hook("prompt", async (input) => {
            await handlePrompt(deps, input);
          }),
        );
      } catch {
        // Fail open: hook registration must not block startup.
      }
      try {
        handles.push(
          await context.session.hook("compaction", async (input) => {
            await handleCompaction(deps, input);
          }),
        );
      } catch {
        // Fail open.
      }
    }

    if (typeof context?.tool?.hook === "function") {
      try {
        handles.push(
          await context.tool.hook("execute.after", async (event) => {
            await handleToolAfter(deps, event);
          }),
        );
      } catch {
        // Fail open.
      }
    }

    let eventLoop = null;
    if (typeof context?.event?.subscribe === "function") {
      eventLoop = (async () => {
        try {
          const stream = context.event.subscribe({
            types: [
              "session.created",
              "session.execution.failed",
              "session.error",
            ],
            signal: controller.signal,
          });
          if (stream && typeof stream[Symbol.asyncIterator] === "function") {
            for await (const ev of stream) {
              await handleSessionEvent(deps, sessions, ev);
            }
          }
        } catch {
          // Aborted or stream closed; fail open.
        }
      })();
    }

    return async () => {
      // Allow any already-enqueued terminal event (e.g. session.execution.failed
      // right before standalone exit) to be picked up before aborting the stream.
      await new Promise((r) => setTimeout(r, 15));
      controller.abort();
      for (const h of handles) await safeDispose(h);
      if (eventLoop) {
        try {
          await eventLoop;
        } catch {
          // Ignore teardown errors.
        }
      }
    };
  },
};
