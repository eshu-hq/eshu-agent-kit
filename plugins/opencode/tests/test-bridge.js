import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, readFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import eshuBridge from "../eshu-bridge.js";

const KIT_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");

// The bridge resolves its kit per call from ESHU_KIT_DIR (baked template
// value otherwise). Default it here so the suites drive the real checkout
// when run directly; the fail-open cases below override it per test.
if (!process.env.ESHU_KIT_DIR) process.env.ESHU_KIT_DIR = KIT_DIR;

// Await-aware: the restore must wait for the async body to settle,
// otherwise resolveKitDir reads the restored value mid-flight and the
// fixture never gets exercised. Callers must await this helper.
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

let work;
beforeEach(() => {
  work = mkdtempSync(join(tmpdir(), "ocp-bridge-"));
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

async function hooksFor(cwd) {
  return eshuBridge({ directory: cwd });
}

describe("prompt hook (chat.message)", () => {
  it("appends the restated goal as a fully-formed text part", async () => {
    const repo = repoWithGoal("ses1", "Ship the widgets.\n");
    const hooks = await hooksFor(repo);
    const output = {
      parts: [{ type: "text", text: "go", messageID: "m1", sessionID: "ses1", id: "p1" }],
    };
    await hooks["chat.message"]({ sessionID: "ses1", messageID: "m1" }, output);
    assert.equal(output.parts.length, 2);
    const added = output.parts[1];
    assert.equal(added.type, "text");
    assert.match(added.text, /Ship the widgets/);
    assert.equal(added.messageID, "m1");
    assert.equal(added.sessionID, "ses1");
    assert.match(added.id, /^prt_/);
  });

  it("leaves the prompt untouched when the sibling stays silent", async () => {
    const hooks = await hooksFor(join(work, "empty"));
    const output = { parts: [{ type: "text", text: "go" }] };
    await hooks["chat.message"]({ sessionID: "ses-none" }, output);
    assert.equal(output.parts.length, 1);
    assert.equal(output.parts[0].text, "go");
  });

  it("stays silent with no text parts to append to", async () => {
    const hooks = await hooksFor(work);
    const output = { parts: [{ type: "image", url: "x" }] };
    await hooks["chat.message"]({ sessionID: "s" }, output);
    assert.equal(output.parts.length, 1);
  });

  it("stays silent on a malformed event instead of writing undefined", async () => {
    const hooks = await hooksFor(work);
    const output = {};
    await hooks["chat.message"]({ sessionID: "s" }, output);
    assert.deepEqual(output, {});
  });

  it("resolves the session directory from the created event", async () => {
    const repo = repoWithGoal("ses9", "Hold the line.\n");
    const hooks = await hooksFor("/fallback");
    await hooks.event({
      event: {
        type: "session.created",
        properties: { info: { id: "ses9", directory: repo } },
      },
    });
    const output = {
      parts: [{ type: "text", text: "go", messageID: "m", sessionID: "ses9", id: "p" }],
    };
    await hooks["chat.message"]({ sessionID: "ses9", messageID: "m" }, output);
    assert.equal(output.parts.length, 2);
    assert.match(output.parts[1].text, /Hold the line/);
  });

  it("never throws when the kit tree is missing", async () => {
    const output = { parts: [{ type: "text", text: "go" }] };
    await withKitDir(join(work, "no-such-kit"), async () => {
      const hooks = await eshuBridge({ directory: work });
      await hooks["chat.message"]({ sessionID: "s" }, output);
      assert.equal(output.parts.length, 1);
    });
  });

  it("appends distinct part ids within the same millisecond", async () => {
    const repo = repoWithGoal("ses1", "Ship the widgets.\n");
    const hooks = await eshuBridge({ directory: repo });
    // Pin the clock: without the counter suffix both ids would be identical.
    const realNow = Date.now;
    Date.now = () => 1234567890000;
    try {
      const first = { parts: [{ type: "text", text: "go", messageID: "m", sessionID: "ses1", id: "p" }] };
      const second = { parts: [{ type: "text", text: "go", messageID: "m", sessionID: "ses1", id: "p" }] };
      await hooks["chat.message"]({ sessionID: "ses1", messageID: "m" }, first);
      await hooks["chat.message"]({ sessionID: "ses1", messageID: "m" }, second);
      assert.equal(first.parts.length, 2);
      assert.equal(second.parts.length, 2);
      assert.notEqual(first.parts[1].id, second.parts[1].id);
    } finally {
      Date.now = realNow;
    }
  });
});

describe("retry hook (session.error event)", () => {
  it("records a resume note on a terminal provider failure", async () => {
    const repo = repoWithGoal("ses9", "Hold the line.\n");
    const hooks = await hooksFor(repo);
    await hooks.event({
      event: {
        type: "session.error",
        properties: {
          sessionID: "ses9",
          error: { name: "UnknownError", data: { message: "model blew up" } },
        },
      },
    });
    const note = join(repo, ".claude", "active-goal.ses9.resume");
    assert.equal(existsSync(note), true);
    assert.match(readFileSync(note, "utf8"), /LAST TURN FAILED/);
    assert.match(readFileSync(note, "utf8"), /model blew up/);
  });

  it("prefers the numeric status when the error carries one", async () => {
    const repo = repoWithGoal("ses9", "Hold the line.\n");
    const hooks = await hooksFor(repo);
    await hooks.event({
      event: {
        type: "session.error",
        properties: {
          sessionID: "ses9",
          error: { status: 429, type: "provider.rate-limit", message: "slow down" },
        },
      },
    });
    const note = join(repo, ".claude", "active-goal.ses9.resume");
    assert.match(readFileSync(note, "utf8"), /\(429\)/);
  });

  it("ignores non-error events", async () => {
    const hooks = await hooksFor(work);
    await hooks.event({ event: { type: "session.idle", properties: { sessionID: "s" } } });
    assert.equal(existsSync(join(work, ".claude", "active-goal.s.resume")), false);
  });

  it("ignores errors without a session", async () => {
    const hooks = await hooksFor(work);
    await hooks.event({ event: { type: "session.error", properties: {} } });
  });
});

describe("fail-open", () => {
  it("a hung sibling is killed instead of stalling the host", async () => {
    const hungKit = join(work, "hung-kit", "hooks");
    mkdirSync(hungKit, { recursive: true });
    // The fixture marks its own start, then hangs: the marker proves the
    // bridge really executed this script (not the real sibling), the
    // missing append proves it never waited for it, and the time bound
    // proves the timeout fired instead of sleeping 30 seconds.
    // `exec` replaces the shell so SIGKILL takes the sleeper, not just bash.
    writeFileSync(
      join(hungKit, "goal-refresh.sh"),
      '#!/bin/bash\ntouch "$0.marker"\nexec sleep 30\n',
    );
    const { chmodSync } = await import("node:fs");
    chmodSync(join(hungKit, "goal-refresh.sh"), 0o755);
    await withKitDir(join(work, "hung-kit"), async () => {
      const hooks = await eshuBridge({ directory: work });
      const prev = process.env.OPENCODE_BRIDGE_TIMEOUT_MS;
      process.env.OPENCODE_BRIDGE_TIMEOUT_MS = "100";
      try {
        const started = Date.now();
        const output = { parts: [{ type: "text", text: "go" }] };
        await hooks["chat.message"]({ sessionID: "s" }, output);
        assert.equal(existsSync(join(hungKit, "goal-refresh.sh.marker")), true);
        assert.equal(output.parts.length, 1);
        assert.ok(Date.now() - started < 10000, "returns well before the sleep ends");
      } finally {
        if (prev === undefined) delete process.env.OPENCODE_BRIDGE_TIMEOUT_MS;
        else process.env.OPENCODE_BRIDGE_TIMEOUT_MS = prev;
      }
    });
  });
});
