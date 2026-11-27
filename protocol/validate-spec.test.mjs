import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  extractErrorKinds,
  extractProtocolNotifications,
  extractServerMethods,
  resolveJsonPointer,
  validateSpec,
} from "./validate-spec.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..");
const realSpecPath = path.join(here, "openrpc.json");

function makeTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "zmux-openrpc-test-"));
}

test("canonical protocol/openrpc.json validates cleanly against Zig server sources", () => {
  const result = validateSpec({ repoRoot, specPath: realSpecPath });
  assert.equal(result.ok, true, `unexpected validation errors:\n${result.errors.join("\n")}`);
  assert.ok(result.stats.methods >= 39);
  assert.ok(result.stats.notifications >= 13);
  assert.equal(result.stats.serverMethodsChecked, 39);
  assert.equal(result.stats.sourceNotificationsChecked, 13);
  assert.equal(result.stats.sourceErrorKindsChecked, 11);
});

test("extractServerMethods discovers modularized src/server/*.zig dispatch files", () => {
  const tmp = makeTempDir();
  try {
    fs.mkdirSync(path.join(tmp, "src", "server"), { recursive: true });
    fs.writeFileSync(
      path.join(tmp, "src", "server", "dispatch.zig"),
      `
      pub fn dispatch(req: anytype) !void {
          if (std.mem.eql(u8, req.method, "daemon.ping")) return;
          if (std.mem.eql(u8, req.method, "session.screen")) return;
      }
      test "ignores test methods" {
          if (std.mem.eql(u8, req.method, "bogus.testMethod")) return;
      }
      `,
    );
    const methods = extractServerMethods(tmp);
    assert.deepEqual(methods, ["daemon.ping", "session.screen"]);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("validateSpec fails when Zig server dispatches an undocumented method", () => {
  const tmp = makeTempDir();
  try {
    fs.mkdirSync(path.join(tmp, "src", "server"), { recursive: true });
    fs.writeFileSync(
      path.join(tmp, "src", "server", "dispatch.zig"),
      `
      pub fn dispatch(req: anytype) !void {
          if (std.mem.eql(u8, req.method, "daemon.ping")) return;
          if (std.mem.eql(u8, req.method, "pane.undocumentedFutureRpc")) return;
      }
      `,
    );
    fs.writeFileSync(
      path.join(tmp, "src", "protocol.zig"),
      fs.readFileSync(path.join(repoRoot, "src", "protocol.zig"), "utf8"),
    );

    const result = validateSpec({ repoRoot: tmp, specPath: realSpecPath });
    assert.equal(result.ok, false);
    assert.ok(
      result.errors.some((e) => e.includes("pane.undocumentedFutureRpc")),
      `expected missing method error, got: ${result.errors.join("; ")}`,
    );
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("validateSpec fails on broken $ref pointers", () => {
  const tmp = makeTempDir();
  try {
    const spec = JSON.parse(fs.readFileSync(realSpecPath, "utf8"));
    spec.methods[0].result.schema = { $ref: "#/components/schemas/DoesNotExist" };
    const brokenPath = path.join(tmp, "openrpc.json");
    fs.writeFileSync(brokenPath, JSON.stringify(spec, null, 2));

    const result = validateSpec({ repoRoot, specPath: brokenPath });
    assert.equal(result.ok, false);
    assert.ok(result.errors.some((e) => e.includes("DoesNotExist")));
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("validateSpec fails when a required v0.4.0 method or error kind is removed", () => {
  const tmp = makeTempDir();
  try {
    const spec = JSON.parse(fs.readFileSync(realSpecPath, "utf8"));
    spec.methods = spec.methods.filter((m) => m.name !== "command.exec");
    spec.components.schemas.ErrorKind.enum = spec.components.schemas.ErrorKind.enum.filter(
      (k) => k !== "conflict",
    );
    const brokenPath = path.join(tmp, "openrpc.json");
    fs.writeFileSync(brokenPath, JSON.stringify(spec, null, 2));

    const result = validateSpec({ repoRoot, specPath: brokenPath });
    assert.equal(result.ok, false);
    assert.ok(result.errors.some((e) => e.includes("command.exec")));
    assert.ok(result.errors.some((e) => e.includes("conflict")));
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("extractProtocolNotifications and extractErrorKinds read real Zig sources accurately", () => {
  const notifs = extractProtocolNotifications(repoRoot);
  assert.ok(notifs.includes("pane_output"));
  assert.ok(notifs.includes("client_switched"));
  assert.ok(notifs.includes("pane_title_changed"));
  assert.equal(notifs.length, 13);

  const kinds = extractErrorKinds(repoRoot);
  assert.ok(kinds.includes("not_found"));
  assert.ok(kinds.includes("spawn_failed"));
  assert.equal(kinds.length, 11);
});

test("resolveJsonPointer rejects external and malformed refs", () => {
  const doc = { components: { schemas: { Ok: { type: "object" } } } };
  assert.equal(resolveJsonPointer(doc, "#/components/schemas/Ok").ok, true);
  assert.equal(resolveJsonPointer(doc, "#/components/schemas/Missing").ok, false);
  assert.equal(resolveJsonPointer(doc, "https://example.com/schema.json").ok, false);
});
