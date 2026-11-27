import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtempSync,
  rmSync,
  readFileSync,
  existsSync,
  mkdirSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import eshuBridge from "../eshu-bridge.js";

const KIT_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");

// The bridge resolves its kit per call from ESHU_KIT_DIR (baked template
// value otherwise). Default it here so the suites drive the real checkout
// when run directly; the fail-open cases below override it per test.
if (!process.env.ESHU_KIT_DIR) process.env.ESHU_KIT_DIR = KIT_DIR;

async function withKitDir(dir, fn) {
  const prev = process.env.ESHU_KIT_DIR;
  process.env.ESHU_KIT_DIR = dir;
  try {
    return await fn();
  } finally {
    if (prev === undefined) delete process.env.ESHU_KIT_DIR;
    else process.env.ESHU_KIT_DIR = prev;
  }
}

async function withEnv(overrides, fn) {
  const saved = {};
  for (const [k, v] of Object.entries(overrides)) {
    saved[k] = process.env[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return await fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

let work;
beforeEach(() => {
  work = mkdtempSync(join(tmpdir(), "ocp-bridge-v2-"));
});
afterEach(() => {
  rmSync(work, { recursive: true, force: true });
});

function repoWithGoal(sid, body) {
  const repo = join(work, "repo");
  mkdirSync(join(repo, ".claude"), { recursive: true });
  writeFileSync(join(repo, ".claude", `active-goal.${sid}`), body);
  return repo;
}

// Minimal V2 plugin host harness: collects hooks registered via setup(context),
// exposes a pushable event stream, and tracks dispose calls.
function makeHost(cwd, { sessionLookup } = {}) {
  const sessionHooks = new Map();
  const toolHooks = new Map();
  const disposed = [];
  const queue = [];
  let waiting = null;
  let closed = false;

  const eventStream = {
    [Symbol.asyncIterator]() {
      return {
        next() {
          if (queue.length > 0) {
            return Promise.resolve({ value: queue.shift(), done: false });
          }
          if (closed) {
            return Promise.resolve({ value: undefined, done: true });
          }
          return new Promise((resolve) => {
            waiting = resolve;
          });
        },
        return() {
          closed = true;
          if (waiting) {
            const w = waiting;
            waiting = null;
            w({ value: undefined, done: true });
          }
          return Promise.resolve({ value: undefined, done: true });
        },
      };
    },
  };

  function emit(ev) {
    if (waiting) {
      const w = waiting;
      waiting = null;
      w({ value: ev, done: false });
    } else {
      queue.push(ev);
    }
  }

  function closeEvents() {
    closed = true;
    if (waiting) {
      const w = waiting;
      waiting = null;
      w({ value: undefined, done: true });
    }
  }

  const context = {
    location: { directory: cwd },
    session: {
      async hook(name, fn) {
        sessionHooks.set(name, fn);
        return {
          async dispose() {
            disposed.push(`session:${name}`);
          },
        };
      },
      async get({ sessionID }) {
        if (typeof sessionLookup === "function") return sessionLookup(sessionID);
        return { id: sessionID, directory: "" };
      },
    },
    tool: {
      async hook(name, fn) {
        toolHooks.set(name, fn);
        return {
          async dispose() {
            disposed.push(`tool:${name}`);
          },
        };
      },
    },
    event: {
      subscribe({ signal } = {}) {
        if (signal) {
          signal.addEventListener("abort", () => closeEvents(), { once: true });
        }
        return eventStream;
      },
    },
  };

  return { context, sessionHooks, toolHooks, disposed, emit, closeEvents };
}

async function setupHost(cwd, opts) {
  const host = makeHost(cwd, opts);
  const cleanup = await eshuBridge.setup(host.context);
  return { ...host, cleanup };
}

describe("V2 plugin export contract", () => {
  it("default-exports an object with id and async setup(context)", () => {
    assert.equal(typeof eshuBridge, "object");
    assert.notEqual(eshuBridge, null);
    assert.equal(eshuBridge.id, "eshu-bridge");
    assert.equal(typeof eshuBridge.setup, "function");
  });

  it("registers prompt, compaction, and tool hooks and disposes cleanly", async () => {
    const host = await setupHost(work);
    assert.equal(host.sessionHooks.has("prompt"), true);
    assert.equal(host.sessionHooks.has("compaction"), true);
    assert.equal(host.toolHooks.has("execute.after"), true);
    await host.cleanup();
    assert.deepEqual(host.disposed.sort(), [
      "session:compaction",
      "session:prompt",
      "tool:execute.after",
    ]);
  });
});

describe("prompt hook (session.hook('prompt'))", () => {
  it("appends the restated goal to input.prompt.text", async () => {
    const repo = repoWithGoal("ses1", "Ship the widgets.\n");
    const host = await setupHost(repo);
    const input = {
      sessionID: "ses1",
      messageID: "m1",
      prompt: { text: "go", files: [] },
    };
    await host.sessionHooks.get("prompt")(input);
    assert.match(input.prompt.text, /^go\n\n/);
    assert.match(input.prompt.text, /Ship the widgets/);
    await host.cleanup();
  });

  it("leaves the prompt untouched when the sibling stays silent", async () => {
    const host = await setupHost(join(work, "empty"));
    const input = { sessionID: "ses-none", prompt: { text: "go" } };
    await host.sessionHooks.get("prompt")(input);
    assert.equal(input.prompt.text, "go");
    await host.cleanup();
  });

  it("stays silent on malformed or empty prompt input", async () => {
    const host = await setupHost(work);
    const input = { sessionID: "s", prompt: { text: "" } };
    await host.sessionHooks.get("prompt")(input);
    assert.equal(input.prompt.text, "");
    await host.sessionHooks.get("prompt")({ sessionID: "s" });
    await host.cleanup();
  });

  it("resolves session directory from session.created event", async () => {
    const repo = repoWithGoal("ses9", "Hold the line.\n");
    const host = await setupHost("/fallback");
    host.emit({
      type: "session.created",
      location: { directory: repo },
      data: { sessionID: "ses9" },
    });
    // Flush event loop microtask so session.created is recorded.
    await new Promise((r) => setTimeout(r, 25));
    const input = { sessionID: "ses9", prompt: { text: "go" } };
    await host.sessionHooks.get("prompt")(input);
    assert.match(input.prompt.text, /Hold the line/);
    await host.cleanup();
  });

  it("never throws when the kit tree is missing", async () => {
    await withKitDir(join(work, "no-such-kit"), async () => {
      const host = await setupHost(work);
      const input = { sessionID: "s", prompt: { text: "go" } };
      await host.sessionHooks.get("prompt")(input);
      assert.equal(input.prompt.text, "go");
      await host.cleanup();
    });
  });

  it("does not duplicate the restatement on repeated invocation", async () => {
    const repo = repoWithGoal("ses1", "Ship the widgets.\n");
    const host = await setupHost(repo);
    const input = { sessionID: "ses1", prompt: { text: "go" } };
    await host.sessionHooks.get("prompt")(input);
    const once = input.prompt.text;
    await host.sessionHooks.get("prompt")(input);
    assert.equal(input.prompt.text, once);
    await host.cleanup();
  });
});

describe("dead-turn recorder (session.execution.failed & session.error)", () => {
  it("records a resume note on V2 session.execution.failed", async () => {
    const repo = repoWithGoal("ses9", "Hold the line.\n");
    const host = await setupHost(repo);
    host.emit({
      type: "session.execution.failed",
      location: { directory: repo },
      data: {
        sessionID: "ses9",
        error: { type: "provider.no-route", message: "model unavailable" },
      },
    });
    host.closeEvents();
    await host.cleanup();
    const note = join(repo, ".claude", "active-goal.ses9.resume");
    assert.equal(existsSync(note), true);
    assert.match(readFileSync(note, "utf8"), /LAST TURN FAILED/);
    assert.match(readFileSync(note, "utf8"), /provider\.no-route/);
    assert.match(readFileSync(note, "utf8"), /model unavailable/);
  });

  it("prefers the numeric status when the error carries one", async () => {
    const repo = repoWithGoal("ses9", "Hold the line.\n");
    const host = await setupHost(repo);
    host.emit({
      type: "session.error",
      properties: {
        sessionID: "ses9",
        error: { status: 429, type: "provider.rate-limit", message: "slow down" },
      },
    });
    host.closeEvents();
    await host.cleanup();
    const note = join(repo, ".claude", "active-goal.ses9.resume");
    assert.match(readFileSync(note, "utf8"), /\(429\)/);
  });

  it("ignores non-error events and errors without sessionID", async () => {
    const host = await setupHost(work);
    host.emit({ type: "session.idle", data: { sessionID: "s" } });
    host.emit({ type: "session.execution.failed", data: {} });
    host.closeEvents();
    await host.cleanup();
    assert.equal(existsSync(join(work, ".claude", "active-goal.s.resume")), false);
  });
});

describe("compaction hook (session.hook('compaction'))", () => {
  function pinnedRepo() {
    const repo = join(work, "repo");
    mkdirSync(join(repo, ".claude"), { recursive: true });
    writeFileSync(join(repo, ".agent-kit-version"), "test\n");
    return repo;
  }

  it("pushes the compaction warning text block into input.system", async () => {
    const repo = pinnedRepo();
    const host = await setupHost(repo);
    const input = { sessionID: "ses1", system: [{ type: "text", text: "base" }] };
    await host.sessionHooks.get("compaction")(input);
    assert.equal(input.system.length, 2);
    assert.equal(input.system[1].type, "text");
    assert.match(input.system[1].text, /CONTEXT WAS COMPACTED OR RESUMED/);
    await host.cleanup();
  });

  it("stays silent outside a kit-pinned checkout", async () => {
    const unpinned = join(work, "unpinned");
    mkdirSync(unpinned, { recursive: true });
    const host = await setupHost(unpinned);
    const input = { sessionID: "s", system: [] };
    await host.sessionHooks.get("compaction")(input);
    assert.equal(input.system.length, 0);
    await host.cleanup();
  });

  it("clears its own markers without widening deletion to a hostile glob", async () => {
    const repo = pinnedRepo();
    const own = `/tmp/claude-skill-loaded-zz9v2brdg-probe`;
    const decoy = `/tmp/claude-skill-loaded-KEEPMEV2-probe`;
    writeFileSync(own, "x");
    writeFileSync(decoy, "x");
    try {
      const host = await setupHost(repo);
      await host.sessionHooks.get("compaction")({
        sessionID: "zz9v2brdg",
        system: [],
      });
      assert.equal(existsSync(own), false);
      const input = { sessionID: "*", system: [] };
      await host.sessionHooks.get("compaction")(input);
      assert.equal(existsSync(decoy), true);
      await host.cleanup();
    } finally {
      rmSync(decoy, { force: true });
      rmSync(own, { force: true });
    }
  });

  it("does not duplicate the warning on a repeated compaction event", async () => {
    const repo = pinnedRepo();
    const host = await setupHost(repo);
    const input = { sessionID: "ses1", system: [] };
    await host.sessionHooks.get("compaction")(input);
    await host.sessionHooks.get("compaction")(input);
    assert.equal(input.system.length, 1);
    await host.cleanup();
  });
});

describe("skill-load observer (tool.hook('execute.after'))", () => {
  it("records skill-load telemetry with KIT_HARNESS=opencode for skill tool and SKILL.md read", async () => {
    const xdgData = join(work, "xdg-data");
    const sid = "ocv2test1234";
    const markerA = `/tmp/claude-skill-loaded-${sid}-code-review`;
    const markerB = `/tmp/claude-skill-loaded-${sid}-golang-engineering`;
    rmSync(markerA, { force: true });
    rmSync(markerB, { force: true });
    try {
      await withEnv(
        { XDG_DATA_HOME: xdgData, ESHU_SKILLS_TELEMETRY_OFF: undefined },
        async () => {
          const host = await setupHost(work);
          const after = host.toolHooks.get("execute.after");
          await after({
            sessionID: sid,
            tool: "skill",
            status: "completed",
            input: { name: "code-review" },
          });
          await after({
            sessionID: sid,
            tool: "read",
            status: "completed",
            input: { filePath: "/repo/skills/eshu/golang-engineering/SKILL.md" },
          });
          // Non-skill and failed calls must be ignored.
          await after({
            sessionID: sid,
            tool: "read",
            status: "completed",
            input: { filePath: "/repo/README.md" },
          });
          await after({
            sessionID: sid,
            tool: "skill",
            status: "error",
            input: { name: "postgres-rigor" },
          });
          await host.cleanup();
        },
      );
      assert.equal(existsSync(markerA), true);
      assert.equal(existsSync(markerB), true);
      const log = join(xdgData, "eshu-agent-kit", "skills-usage.jsonl");
      assert.equal(existsSync(log), true);
      const lines = readFileSync(log, "utf8")
        .trim()
        .split("\n")
        .map((l) => JSON.parse(l));
      assert.equal(lines.length, 2);
      assert.equal(lines[0].harness, "opencode");
      assert.equal(lines[0].detail.skill, "code-review");
      assert.equal(lines[1].harness, "opencode");
      assert.equal(lines[1].detail.skill, "golang-engineering");
    } finally {
      rmSync(markerA, { force: true });
      rmSync(markerB, { force: true });
    }
  });
});

describe("fail-open timeout", () => {
  it("kills a hung sibling after OPENCODE_BRIDGE_TIMEOUT_MS and returns silently", async () => {
    const fakeKit = join(work, "fake-kit");
    mkdirSync(join(fakeKit, "hooks"), { recursive: true });
    writeFileSync(
      join(fakeKit, "hooks", "goal-refresh.sh"),
      "#!/bin/bash\nsleep 30\n",
      { mode: 0o755 },
    );
    await withEnv(
      { ESHU_KIT_DIR: fakeKit, OPENCODE_BRIDGE_TIMEOUT_MS: "150" },
      async () => {
        const host = await setupHost(work);
        const input = { sessionID: "s1", prompt: { text: "go" } };
        const t0 = Date.now();
        await host.sessionHooks.get("prompt")(input);
        assert.ok(Date.now() - t0 < 3000, "hung sibling must be killed promptly");
        assert.equal(input.prompt.text, "go");
        await host.cleanup();
      },
    );
  });
});
